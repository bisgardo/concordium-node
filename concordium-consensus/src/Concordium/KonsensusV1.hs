{-# LANGUAGE TypeFamilies #-}

module Concordium.KonsensusV1 where

import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.State.Class

import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Persistent.BlockState
import qualified Concordium.GlobalState.Transactions as Transactions
import Concordium.GlobalState.Types
import Concordium.KonsensusV1.Consensus
import Concordium.KonsensusV1.Consensus.Blocks
import qualified Concordium.KonsensusV1.Consensus.Quorum as Quorum
import qualified Concordium.KonsensusV1.Consensus.Timeout as Timeout
import Concordium.KonsensusV1.TreeState.Implementation
import Concordium.KonsensusV1.TreeState.LowLevel
import Concordium.KonsensusV1.Types
import Concordium.Logger
import Concordium.Skov.Monad (UpdateResult (..), transactionVerificationResultToUpdateResult)
import Concordium.TimeMonad
import Concordium.TimerMonad
import Concordium.Types
import Concordium.Types.Parameters
import Control.Monad.Reader.Class

-- |Handle receiving a finalization message (either a quorum message or a timeout message).
-- Returns @Left res@ in the event of a failure, with the appropriate failure code.
-- Otherwise, returns @Right followup@, where @followup@ is an action that should be performed
-- after or concurrently with relaying the message.
receiveFinalizationMessage ::
    ( IsConsensusV1 (MPV m),
      MonadThrow m,
      MonadIO m,
      BlockStateStorage m,
      TimeMonad m,
      MonadTimeout m,
      MonadState (SkovData (MPV m)) m,
      MonadReader r m,
      HasBakerContext r,
      MonadConsensusEvent m,
      MonadLogger m,
      BlockState m ~ HashedPersistentBlockState (MPV m),
      MonadTreeStateStore m,
      MonadMulticast m,
      TimerMonad m
    ) =>
    FinalizationMessage ->
    m (Either UpdateResult (m ()))
receiveFinalizationMessage (FMQuorumMessage qm) = do
    res <- Quorum.receiveQuorumMessage qm =<< get
    case res of
        Quorum.Received vqm -> return $ Right $ Quorum.processQuorumMessage vqm makeBlock
        Quorum.Rejected _ -> return $ Left ResultInvalid
        Quorum.CatchupRequired -> return $ Left ResultUnverifiable
        Quorum.Duplicate -> return $ Left ResultDuplicate
receiveFinalizationMessage (FMTimeoutMessage tm) = do
    res <- Timeout.receiveTimeoutMessage tm =<< get
    case res of
        Timeout.Received vtm -> return $ Right $ void $ Timeout.executeTimeoutMessage vtm
        Timeout.Rejected _ -> return $ Left ResultInvalid
        Timeout.CatchupRequired -> return $ Left ResultUnverifiable
        Timeout.Duplicate -> return $ Left ResultDuplicate

-- |Convert an 'Transactions.AddTransactionResult' to the corresponding 'UpdateResult'.
addTransactionResult :: Transactions.AddTransactionResult -> UpdateResult
addTransactionResult Transactions.Duplicate{} = ResultDuplicate
addTransactionResult Transactions.Added{} = ResultSuccess
addTransactionResult Transactions.ObsoleteNonce{} = ResultStale
addTransactionResult (Transactions.NotAdded verRes) =
    transactionVerificationResultToUpdateResult verRes
