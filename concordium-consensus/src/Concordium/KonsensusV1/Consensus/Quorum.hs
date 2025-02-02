{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module contains the logic for creating 'QuorumCertificate's, receiving and
--  verifying quorum signatures that is used for the consensus v1 protocol.
module Concordium.KonsensusV1.Consensus.Quorum where

import Control.Monad.Catch
import Control.Monad.State
import qualified Data.Map.Strict as Map
import Lens.Micro.Platform

import Concordium.Genesis.Data.BaseV1
import Concordium.Logger
import Concordium.TimeMonad
import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.Types.Parameters
import Concordium.Utils

import Concordium.GlobalState.BlockState
import qualified Concordium.GlobalState.Persistent.BlockState as PBS
import qualified Concordium.GlobalState.Types as GSTypes
import Concordium.KonsensusV1.Consensus
import Concordium.KonsensusV1.Consensus.Finality
import Concordium.KonsensusV1.Flag
import Concordium.KonsensusV1.TreeState.Implementation
import qualified Concordium.KonsensusV1.TreeState.LowLevel as LowLevel
import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types

-- | Reasons that a 'QuorumMessage' can be rejected.
data ReceiveQuorumMessageRejectReason
    = -- | The 'Round' presented in the 'QuorumMessage' is obsolete.
      ObsoleteRound
    | -- | The finalizer for the 'QuorumMessage' is not present
      --  in the finalization committee.
      NotAFinalizer
    | -- | The signature on the 'QuorumMessage' is invalid.
      InvalidSignature
    | -- | The finalizer has already signed another 'QuorumMessage' for the
      --  'Round'.
      AlreadySigned
    | -- | The 'QuorumMessage' points to an invalid block.
      InvalidBlock
    | -- | The 'Round' of the 'QuorumMessage' and the 'Round' of the
      --  block that it points to are not consistent.
      InconsistentRounds
    | -- | The 'Epoch' of the 'QuorumMessage' and the 'Epoch' of the
      --  block that it points to are not consistent.
      InconsistentEpochs
    | -- | The 'QuorumMessage' is a duplicate.
      Duplicate
    deriving (Eq, Show)

-- | Result codes for receiving a 'QuorumMessage'.
data ReceiveQuorumMessageResult (pv :: ProtocolVersion)
    = -- | The 'QuorumMessage' was received i.e. it passed verification.
      Received !(VerifiedQuorumMessage pv)
    | -- | The 'QuorumMessage' was received but is a result of double signing.
      ReceivedNoRelay !(VerifiedQuorumMessage pv)
    | -- | The 'QuorumMessage' was rejected.
      Rejected !ReceiveQuorumMessageRejectReason
    | -- | The 'QuorumMessage' points to a round which indicates a catch up is required.
      CatchupRequired
    | -- | Consensus has been shutdown.
      ConsensusShutdown
    deriving (Eq, Show)

-- | A _received_ and verified 'QuorumMessage' together with
--  the weight associated with the finalizer for the quorum message.
data VerifiedQuorumMessage (pv :: ProtocolVersion) = VerifiedQuorumMessage
    { -- | The verified 'QuorumMessage'.
      vqmMessage :: !QuorumMessage,
      -- | The weight of the finalizer.
      vqmFinalizerWeight :: !VoterPower,
      -- | The baker id of the finalizer.
      vqmFinalizerBakerId :: !BakerId,
      -- | The block that is the target of the quorum message.
      vqmBlock :: !(BlockPointer pv)
    }
    deriving (Eq, Show)

-- | Receive a 'QuorumMessage'.
--  Verify the 'QuorumMessage' and if this turns out successful, then the 'QuorumMessage' will be
--  relayed to the network before processing (via 'processQuorumMessage'). Processing checks whether enough (weighted) signatures
--  are gathered, if this is the case then a 'QuorumCertificate' is formed and the consensus runner advances the round.
--
--  Possible return codes are
--  * 'Received' The 'QuorumMessage' was received, relayed and processed.
--  * 'Rejected' The 'QuorumMessage' failed validation and possible it has been flagged.
--  * 'CatchupRequired' The 'QuorumMessage' cannot be processed before it is caught up.
receiveQuorumMessage ::
    (MonadIO m, LowLevel.MonadTreeStateStore m) =>
    -- | The 'QuorumMessage' to receive.
    QuorumMessage ->
    -- | The tree state to verify the 'QuorumMessage' within.
    SkovData (MPV m) ->
    -- | Result of receiving the 'QuorumMessage'.
    m (ReceiveQuorumMessageResult (MPV m))
receiveQuorumMessage qm@QuorumMessage{..} skovData = receive
  where
    receive
        -- Consensus has been shutdown.
        | skovData ^. isConsensusShutdown = return ConsensusShutdown
        -- The consensus runner is not caught up.
        | qmEpoch > skovData ^. roundStatus . rsCurrentEpoch =
            return CatchupRequired
        -- The round of the quorum signature message is obsolete.
        | qmRound < skovData ^. roundStatus . rsCurrentRound =
            return $ Rejected ObsoleteRound
        | otherwise = case getFinalizer of
            -- Signer is not in the finalization committee or the committee is old/unknown. Reject the message.
            Nothing -> return $ Rejected NotAFinalizer
            Just FinalizerInfo{..}
                -- Check if the quorum message is a duplicate.
                | Just existingMessage <- getExistingMessage,
                  existingMessage == qm ->
                    return $ Rejected Duplicate
                -- Check whether the signature is ok or not.
                | not (checkQuorumSignatureSingle getQuorumSignatureMessage finalizerBlsKey qmSignature) ->
                    return $ Rejected InvalidSignature
                | otherwise -> do
                    -- Check for double signing. Later, we will not relay the message if it is
                    -- a case of double signing.
                    forM_ getExistingMessage $ \existingMessage ->
                        flag $! QuorumDoubleSigning qm existingMessage
                    -- Continue verifying by looking up the block.
                    getBlockStatus qmBlock skovData >>= \case
                        -- The signatory signed an already-finalized block. We flag and stop.
                        BlockFinalized fb -> do
                            -- Since the block is finalized, the round is less than the current
                            -- round, so we flag as an inconsistent round.
                            flag $! RoundInconsistency qm (bpBlock fb)
                            return $ Rejected InconsistentRounds
                        -- The signer signed a dead block. We flag and stop.
                        BlockDead -> do
                            -- Note that we do not flag here as the block
                            -- could've been pruned in the mean time of when
                            -- the block was received by the consensus runner and
                            -- when receiving this quorum message.
                            return $ Rejected InvalidBlock
                        -- The block is unknown so catch up.
                        BlockUnknown ->
                            return CatchupRequired
                        -- The block is executed but not finalized.
                        -- Perform the remaining checks before processing the 'QuorumMessage'.
                        BlockAlive targetBlock
                            -- Inconsistent rounds of the quorum signature message and the block it points to.
                            -- Note. We do these checks here, but if we want to punish the finalizer then the
                            -- checks should be deferred until after relaying the message otherwise the
                            -- next baker might not see the bad behaviour.
                            | blockRound targetBlock /= qmRound -> do
                                flag $! RoundInconsistency qm (bpBlock targetBlock)
                                return $ Rejected InconsistentRounds
                            -- Inconsistent epochs of the quorum signature message and the block it points to.
                            | blockEpoch targetBlock /= qmEpoch -> do
                                flag $! EpochInconsistency qm (bpBlock targetBlock)
                                return $ Rejected InconsistentEpochs
                            -- Return the verified quorum message.
                            | otherwise -> do
                                let vqm =
                                        VerifiedQuorumMessage
                                            { vqmMessage = qm,
                                              vqmFinalizerWeight = finalizerWeight,
                                              vqmFinalizerBakerId = finalizerBakerId,
                                              vqmBlock = targetBlock
                                            }
                                return $! case getExistingMessage of
                                    Just _ -> ReceivedNoRelay vqm
                                    Nothing -> Received vqm
              where
                -- Try get an existing 'QuorumMessage' if present otherwise return 'Nothing'.
                getExistingMessage =
                    skovData
                        ^? currentQuorumMessages . smBakerIdToQuorumMessage . ix finalizerBakerId
    -- Extract the quorum signature message
    getQuorumSignatureMessage =
        let genesisHash = skovData ^. genesisMetadata . to gmCurrentGenesisHash
        in  quorumSignatureMessageFor qm genesisHash
    -- Get the finalizer if it is present in the current finalization committee
    -- or old committee otherwise return 'Nothing'.
    getFinalizer = do
        bakers <- getBakersForEpoch qmEpoch skovData
        finalizerByIndex (bakers ^. bfFinalizers) qmFinalizerIndex

-- | Adds a 'QuorumMessage' and the finalizer weight (deducted from the current epoch)
--  to the 'QuorumMessages' for the current round.
--
--  Precondition. The finalizer must not be present already.
addQuorumMessage ::
    -- | The verified quorum message
    VerifiedQuorumMessage pv ->
    -- | The messages to update.
    QuorumMessages ->
    -- | The resulting messages.
    QuorumMessages
addQuorumMessage
    (VerifiedQuorumMessage quorumMessage@QuorumMessage{..} weight bId _)
    (QuorumMessages currentMessages currentWeights) =
        QuorumMessages
            { _smBakerIdToQuorumMessage = newSignatureMessages,
              _smBlockToWeightsAndSignatures = updatedWeightAndSignature
            }
      where
        finalizerIndex = qmFinalizerIndex
        newSignatureMessages = Map.insert bId quorumMessage currentMessages
        justOrIncrement =
            maybe
                (Just (weight, qmSignature, finalizerSet [finalizerIndex]))
                ( \(aggWeight, aggSig, aggFinalizers) ->
                    Just
                        ( aggWeight + weight,
                          aggSig <> qmSignature,
                          addFinalizer aggFinalizers finalizerIndex
                        )
                )
        updatedWeightAndSignature = Map.alter justOrIncrement qmBlock currentWeights

-- | If there are enough (weighted) signatures on the block provided
--  then this function creates the 'QuorumCertificate' for the block and returns @Just QuorumCertificate@
--
--  If a 'QuorumCertificate' could not be formed then this function returns @Nothing@.
makeQuorumCertificate ::
    -- | The block we want to check whether a
    --  can 'QuorumCertificate' can be formed or not.
    BlockPointer pv ->
    -- | The state to use for making the
    -- 'QuorumCertificate'.
    SkovData pv ->
    -- | Return @Just QuorumCertificate@ if there are enough (weighted) quorum signatures
    --  for the provided block.
    --  Otherwise return @Nothing@.
    Maybe QuorumCertificate
makeQuorumCertificate qcBlockPointer sd@SkovData{..} = do
    case _currentQuorumMessages ^? smBlockToWeightsAndSignatures . ix qcBlockHash of
        -- There wasn't any signature(s) for the supplied block.
        Nothing -> Nothing
        -- Check whether the accumulated weight is more or equal to the configured signature threshold.
        Just (accummulatedWeight, aggregatedSignature, finalizers) ->
            if enoughWeight
                then Just createQuorumCertificate
                else Nothing
          where
            -- The required signature threshold.
            signatureThreshold = _genesisMetadata ^. to gmParameters . to genesisSignatureThreshold
            -- The total weight of the finalization committee.
            totalWeight = bakersForCurrentEpoch sd ^. bfFinalizers . to committeeTotalWeight
            -- Return whether enough weighted signatures has been gathered with respect to the set signature threshold.
            enoughWeight = toRational accummulatedWeight / toRational totalWeight >= toRational signatureThreshold
            createQuorumCertificate =
                QuorumCertificate
                    { qcBlock = qcBlockHash,
                      qcRound = _roundStatus ^. rsCurrentRound,
                      qcEpoch = blockEpoch . bpBlock $ qcBlockPointer,
                      qcAggregateSignature = aggregatedSignature,
                      qcSignatories = finalizers
                    }
  where
    -- The hash of the block that the QC points to.
    qcBlockHash = getHash qcBlockPointer

-- | Process a 'QuorumMessage'
--  Check whether a 'QuorumCertificate' can be created.
--  If that is the case the this function checks for finality and
--  advance the round via the constructed 'QuorumCertificate'.
--  If the round is advanced, we attempt to make a block by calling the provided @makeBlock@
--  continuation. (Note, providing the continuation is to avoid a cyclic module dependency with
--  'Concordium.KonsensusV1.Consensus.Blocks'.)
processQuorumMessage ::
    ( IsConsensusV1 (MPV m),
      MonadThrow m,
      MonadIO m,
      BlockStateStorage m,
      TimeMonad m,
      MonadTimeout m,
      MonadState (SkovData (MPV m)) m,
      MonadConsensusEvent m,
      MonadLogger m,
      GSTypes.BlockState m ~ PBS.HashedPersistentBlockState (MPV m),
      LowLevel.MonadTreeStateStore m
    ) =>
    -- | The 'VerifiedQuorumMessage' to process.
    VerifiedQuorumMessage (MPV m) ->
    -- | Continuation to make a block
    m () ->
    m ()
processQuorumMessage vqm@VerifiedQuorumMessage{..} makeBlock = do
    currentRound <- use (roundStatus . rsCurrentRound)
    -- Check that the round of the 'QuorumMessage' corresponds to
    -- the current round of the tree state.
    -- Note that due to the invariants of `uponReceivingBlock` and `receiveQuorumMessage`
    -- then the rounds (quorum message round and current round) should be equal when this function is
    -- called immediately after 'receiveQuorumMessage'
    -- and so the 'not equal' case below shouldn't happen in normal operation.
    when (currentRound == qmRound vqmMessage) $ do
        currentQuorumMessages %=! addQuorumMessage vqm
        skovData <- get
        let maybeQuorumCertificate = makeQuorumCertificate vqmBlock skovData
        forM_ maybeQuorumCertificate $ \newQC -> do
            logEvent Konsensus LLDebug $
                "Quorum certificate generated for block "
                    ++ show (qcBlock newQC)
                    ++ " in round "
                    ++ show (theRound $ qcRound newQC)
            logEvent Konsensus LLTrace $
                "QC signed by finalizer indexes: "
                    ++ show (theFinalizerIndex <$> finalizerList (qcSignatories newQC))
            let newCertifiedBlock =
                    CertifiedBlock
                        { cbQuorumCertificate = newQC,
                          cbQuorumBlock = vqmBlock
                        }
            -- Process the certified block, including checking for finalization.
            processCertifiedBlock newCertifiedBlock
            advanceRoundWithQuorum newCertifiedBlock
            recordCheckedQuorumCertificate newQC
            makeBlock
