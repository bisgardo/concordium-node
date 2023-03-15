{-# LANGUAGE TemplateHaskell #-}

module Concordium.KonsensusV1.Consensus where

import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Maybe (isJust)
import qualified Data.Vector as Vector

import Data.Foldable
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord
import qualified Data.Vector as Vec
import Lens.Micro.Platform

import Concordium.GlobalState.BakerInfo
import Concordium.KonsensusV1.Types
import Concordium.Types
import qualified Concordium.Types.Accounts as Accounts
import Concordium.Types.BakerIdentity
import Concordium.Types.Parameters

import Concordium.KonsensusV1.TreeState.Implementation
import qualified Concordium.KonsensusV1.TreeState.LowLevel as LowLevel
import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types

-- |A Monad for multicasting timeout messages.
class MonadMulticast m where
    -- |Multicast a timeout message over the network
    sendTimeoutMessage :: TimeoutMessage -> m ()

-- |A baker context containing the baker identity. Used for accessing relevant baker keys and the baker id.
newtype BakerContext = BakerContext
    { _bakerIdentity :: BakerIdentity
    }

makeClassy ''BakerContext

-- |A Monad for timer related actions.
class MonadTimeout m where
    -- |Reset the timeout from the supplied 'Duration'.
    resetTimer :: Duration -> m ()

-- |Make a block if the consensus runner is leader for the
-- current round.
-- TODO: call 'makeBlock' if we're leader for the current round.
makeBlockIfLeader :: MonadState (SkovData (MPV m)) m => m ()
makeBlockIfLeader = return ()

-- |Advance the provided 'RoundStatus' to the provided 'Round'.
--
-- The consensus protocol can advance round in two ways.
-- 1. Via a QC i.e. @Right QuorumCertificate@
-- 2. Via a TC i.e. @Left (TimeoutCertificate, QuorumCertificate)@
--
-- All properties from the old 'RoundStatus' are being carried over to new 'RoundStatus'
-- except for the following.
-- * 'rsCurrentRound' will become the provided 'Round'.
-- * 'rsCurrentQuorumSignatureMessages' will be 'emptySignatureMessages'.
-- * 'rsCurrentTimeoutSignatureMessages' will be 'emptySignatureMessages'.
-- * 'rsPreviousRoundTC' will become 'Absent' if we're progressing via a 'QuorumCertificate' otherwise
--   it will become the values of the supplied @Left (TimeoutCertificate, QuorumCertificate)@.
-- * 'rsHighestQC' will become the supplied @Right QuorumCertificate@ otherwise it is carried over.
advanceRoundStatus ::
    -- |The round to advance to.
    Round ->
    -- |@Left (tc, qc)@ if consensus is advancing from a TC.
    -- @Right qc@ if consensus is advancing from a QC.
    Either (TimeoutCertificate, QuorumCertificate) QuorumCertificate ->
    -- |The 'RoundStatus' we are advancing from.
    RoundStatus ->
    -- |The advanced 'RoundStatus'.
    RoundStatus
advanceRoundStatus toRound (Left (tc, qc)) currentRoundStatus =
    currentRoundStatus
        { rsCurrentRound = toRound,
          rsCurrentQuorumSignatureMessages = emptySignatureMessages,
          rsCurrentTimeoutSignatureMessages = emptySignatureMessages,
          rsPreviousRoundTC = Present (tc, qc)
        }
advanceRoundStatus toRound (Right qc) currentRoundStatus =
    currentRoundStatus
        { rsCurrentRound = toRound,
          rsCurrentQuorumSignatureMessages = emptySignatureMessages,
          rsCurrentTimeoutSignatureMessages = emptySignatureMessages,
          rsHighestQC = Present qc,
          rsPreviousRoundTC = Absent
        }

-- |Advance to the provided 'Round'.
--
-- This function does the following:
-- * Update the current 'RoundStatus'.
-- * Persist the new 'RoundStatus'.
-- * If the consensus runner is leader in the new
--   round then make the new block.
advanceRound ::
    ( MonadReader r m,
      HasBakerContext r,
      MonadTimeout m,
      LowLevel.MonadTreeStateStore m,
      MonadState (SkovData (MPV m)) m
    ) =>
    -- |The 'Round' to progress to.
    Round ->
    -- |If we are advancing from a round that timed out
    -- then this will be @Left 'TimeoutCertificate, 'QuorumCertificate')@
    -- The 'TimeoutCertificate' is from the round we're
    -- advancing from and the associated 'QuorumCertificate' verifies it.
    --
    -- Otherwise if we're progressing via a 'QuorumCertificate' then @Right QuorumCertificate@
    -- should be the QC we're advancing round via.
    Either (TimeoutCertificate, QuorumCertificate) QuorumCertificate ->
    m ()
advanceRound newRound newCertificate = do
    currentRoundStatus <- use roundStatus
    -- We always reset the timer.
    -- This ensures that the timer is correct for consensus runners which have been
    -- leaving or joining the finalization committe (if we're advancing to the first round
    -- of that new epoch)
    -- Hence it is crucial when throwing the timeout then it must be checked that
    -- the consensus runner is either part of the current epoch (i.e. the new one) OR
    -- the prior epoch, as it could be the case that the consensus runner left the finalization committee
    -- coming into this new (current) epoch - but we still want to ensure that a timeout is thrown either way.
    resetTimer =<< use currentTimeout
    -- Advance and save the round.
    setRoundStatus $! advanceRoundStatus newRound newCertificate currentRoundStatus
    -- Make a new block if the consensus runner is leader of
    -- the 'Round' progressed to.
    makeBlockIfLeader

-- |Compute and return the 'LeadershipElectionNonce' for
-- the provided 'Epoch' and 'FinalizationEntry'
-- TODO: implement.
computeLeadershipElectionNonce ::
    -- |The 'Epoch' to compute the 'LeadershipElectionNonce' for.
    Epoch ->
    -- |The witness for the new 'Epoch'
    FinalizationEntry ->
    -- |The new 'LeadershipElectionNonce'
    LeadershipElectionNonce
computeLeadershipElectionNonce epoch finalizationEntry = undefined

-- |Advance the provided 'RoundStatus' to the provided 'Epoch'.
-- In particular this does the following to the provided 'RoundStatus'
--
-- * Set the 'rsCurrentEpoch' to the provided 'Epoch'
-- * Set the 'rsLatestEpochFinEntry' to the provided 'FinalizationEntry'.
-- * Set the 'rsLeadershipElectionNonce' to the provided 'LeadershipElectionNonce'.
advanceRoundStatusEpoch ::
    -- |The 'Epoch' we advance to.
    Epoch ->
    -- |The 'FinalizationEntry' that witnesses the
    -- new 'Epoch'.
    FinalizationEntry ->
    -- |The new leader election nonce.
    LeadershipElectionNonce ->
    -- |The 'RoundStatus' we're progressing from.
    RoundStatus ->
    -- |The new 'RoundStatus'.
    RoundStatus
advanceRoundStatusEpoch toEpoch latestFinalizationEntry newLeadershipElectionNonce currentRoundStatus =
    currentRoundStatus
        { rsCurrentEpoch = toEpoch,
          rsLatestEpochFinEntry = Present latestFinalizationEntry,
          rsLeadershipElectionNonce = newLeadershipElectionNonce
        }

-- |Advance the 'Epoch' of the current 'RoundStatus'.
--
-- Advancing epochs in particular carries out the following:
-- * Updates the 'rsCurrentEpoch' to the provided 'Epoch' for the current 'RoundStatus'.
-- * Computes the new 'LeadershipElectionNonce' and updates the current 'RoundStatus'.
-- * Updates the 'rsLatestEpochFinEntry' of the current 'RoundStatus' to @Present finalizationEntry@.
-- * Persist the new 'RoundStatus' to disk.
advanceEpoch ::
    ( MonadState (SkovData (MPV m)) m,
      LowLevel.MonadTreeStateStore m
    ) =>
    Epoch ->
    FinalizationEntry ->
    m ()
advanceEpoch newEpoch finalizationEntry = do
    currentRoundStatus <- use roundStatus
    let newRoundStatus = advanceRoundStatusEpoch newEpoch finalizationEntry newLeadershipElectionNonce currentRoundStatus
    setRoundStatus newRoundStatus
  where
    -- compute the new leadership election nonce.
    newLeadershipElectionNonce = computeLeadershipElectionNonce newEpoch finalizationEntry

-- |Compute the finalization committee given the bakers and the finalization committee parameters.
computeFinalizationCommittee :: FullBakers -> FinalizationCommitteeParameters -> FinalizationCommittee
computeFinalizationCommittee FullBakers{..} FinalizationCommitteeParameters{..} =
    FinalizationCommittee{..}
  where
    -- We use an insertion sort to construct the '_fcpMaxFinalizers' top bakers.
    -- Order them by descending stake and ascending baker ID.
    insert ::
        Map.Map (Down Amount, BakerId) FullBakerInfo ->
        FullBakerInfo ->
        Map.Map (Down Amount, BakerId) FullBakerInfo
    insert m fbi
        | Map.size m == fromIntegral _fcpMaxFinalizers = case Map.maxViewWithKey m of
            Nothing -> error "computeFinalizationCommittee: _fcpMaxFinalizers must not be 0"
            Just ((k, _), m')
                | insKey < k -> Map.insert insKey fbi m'
                | otherwise -> m
        | otherwise = Map.insert insKey fbi m
      where
        insKey = (Down (fbi ^. bakerStake), fbi ^. Accounts.bakerIdentity)
    amountSortedBakers = Map.elems $ foldl' insert Map.empty fullBakerInfos
    -- Threshold stake required to be a finalizer
    finalizerAmountThreshold :: Amount
    finalizerAmountThreshold =
        ceiling $
            partsPerHundredThousandsToRational _fcpFinalizerRelativeStakeThreshold
                * toRational bakerTotalStake
    -- Given the bakers sorted by their stakes, takes the first 'n' and then those that are
    -- at least at the threshold.
    takeFinalizers 0 fs = takeWhile ((>= finalizerAmountThreshold) . view bakerStake) fs
    takeFinalizers n (f : fs) = f : takeFinalizers (n - 1) fs
    takeFinalizers _ [] = []
    -- Compute the set of finalizers by applying the caps.
    cappedFinalizers = takeFinalizers _fcpMinFinalizers amountSortedBakers
    -- Sort the finalizers by baker ID.
    sortedFinalizers = sortOn (view Accounts.bakerIdentity) cappedFinalizers
    -- Construct finalizer info given the index and baker info.
    mkFinalizer finalizerIndex bi =
        FinalizerInfo
            { finalizerWeight = fromIntegral (bi ^. bakerStake),
              finalizerSignKey = bi ^. Accounts.bakerSignatureVerifyKey,
              finalizerVRFKey = bi ^. Accounts.bakerElectionVerifyKey,
              finalizerBlsKey = bi ^. Accounts.bakerAggregationVerifyKey,
              finalizerBakerId = bi ^. Accounts.bakerIdentity,
              ..
            }
    committeeFinalizers = Vec.fromList $ zipWith mkFinalizer [FinalizerIndex 0 ..] sortedFinalizers
    committeeTotalWeight = sum $ finalizerWeight <$> committeeFinalizers
