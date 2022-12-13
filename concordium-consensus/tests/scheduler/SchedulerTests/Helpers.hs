{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module SchedulerTests.Helpers where

import qualified Control.Monad.Except as Except
import Control.Monad.RWS.Strict
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time
import Data.Word
import Lens.Micro.Platform
import Test.HUnit

import qualified Concordium.Crypto.SHA256 as Hash
import qualified Concordium.ID.Types as Types
import qualified Concordium.Types.Accounts as Types
import qualified Concordium.Types.Accounts.Releases as Types
import Concordium.Types.SeedState (initialSeedState)

import qualified Concordium.Common.Time as Time
import qualified Concordium.Cost as Cost
import qualified Concordium.GlobalState.Basic.BlockState.Account as Basic
import qualified Concordium.GlobalState.BlockState as BS
import qualified Concordium.GlobalState.DummyData as DummyData
import qualified Concordium.GlobalState.Persistent.Account as BS
import qualified Concordium.GlobalState.Persistent.BlobStore as Blob
import qualified Concordium.GlobalState.Persistent.BlockState as BS
import qualified Concordium.GlobalState.Persistent.BlockState.Modules as BS
import Concordium.GlobalState.Persistent.Cache
import qualified Concordium.GlobalState.Rewards as Rewards
import Concordium.GlobalState.Types
import Concordium.Logger
import Concordium.Scheduler
import qualified Concordium.Scheduler.DummyData as DummyData
import qualified Concordium.Scheduler.EnvironmentImplementation as EI
import qualified Concordium.Scheduler.Runner as SchedTest
import Concordium.Scheduler.TreeStateEnvironment
import qualified Concordium.Scheduler.Types as Types
import Concordium.TimeMonad

getResults :: [(a, Types.TransactionSummary)] -> [(a, Types.ValidResult)]
getResults = map (\(x, r) -> (x, Types.tsResult r))

-- | The cost for processing a simple transfer (account to account)
-- with one signature in the transaction.
--
-- * @SPEC: <$DOCS/Transactions#transaction-cost-header-simple-transfer>
simpleTransferCost :: Types.Energy
simpleTransferCost = Cost.baseCost (Types.transactionHeaderSize + 41) 1 + Cost.simpleTransferCost

simpleTransferCostWithMemo1 :: Word64 -> Types.Energy
simpleTransferCostWithMemo1 memoSize =
    Cost.baseCost
        (Types.transactionHeaderSize + 41 + 2 + memoSize)
        1

simpleTransferCostWithMemo2 :: Word64 -> Types.Energy
simpleTransferCostWithMemo2 memoSize =
    Cost.baseCost
        (Types.transactionHeaderSize + 41 + 2 + memoSize)
        1
        + Cost.simpleTransferCost

-- | Monad that implements the necessary constraints to be used for running the scheduler.
newtype PersistentBSM pv a = PersistentBSM
    { _runPersistentBSM ::
        BS.PersistentBlockStateMonad
            pv
            (BS.PersistentBlockStateContext pv)
            (Blob.BlobStoreM' (BS.PersistentBlockStateContext pv))
            a
    }
    deriving
        ( Applicative,
          Functor,
          Monad,
          BS.AccountOperations,
          BS.ContractStateOperations,
          BS.ModuleQuery,
          MonadProtocolVersion,
          BlockStateTypes,
          Blob.MonadBlobStore,
          BS.BlockStateQuery,
          BS.BlockStateOperations,
          MonadIO,
          MonadCache BS.ModuleCache,
          BS.BlockStateStorage
        )

deriving instance
    (Types.AccountVersionFor pv ~ av) =>
    MonadCache (BS.AccountCache av) (PersistentBSM pv)

instance MonadLogger (PersistentBSM pv) where
    logEvent _ _ _ = return ()

instance TimeMonad (PersistentBSM pv) where
    currentTime = return $ read "1970-01-01 13:27:13.257285424 UTC"

-- |Call a function for each protocol version, returning a list of results.
-- Notice the return type for the function must be independent of the protocol version.
--
-- This is used to run a test against every protocol version.
forEveryProtocolVersion ::
    (forall pv. (Types.IsProtocolVersion pv) => Types.SProtocolVersion pv -> String -> a) ->
    [a]
forEveryProtocolVersion check =
    [ check Types.SP1 "P1",
      check Types.SP2 "P2",
      check Types.SP3 "P3",
      check Types.SP4 "P4",
      check Types.SP5 "P5"
    ]

-- |Construct a test block state containing the provided accounts.
createTestBlockStateWithAccounts ::
    (Types.IsProtocolVersion pv) =>
    [Basic.Account (Types.AccountVersionFor pv)] ->
    PersistentBSM pv (BS.HashedPersistentBlockState pv)
createTestBlockStateWithAccounts accounts =
    BS.initialPersistentState
        (initialSeedState (Hash.hash "") 1_000)
        DummyData.dummyCryptographicParameters
        accounts
        DummyData.dummyIdentityProviders
        DummyData.dummyArs
        DummyData.dummyKeyCollection
        DummyData.dummyChainParameters

-- |Run test block state computation provided an account cache size.
-- The module cache size is 100.
--
-- This function creates a temporary file for the blobstore, which is removed right after the
-- running the computation, meaning the result of the computation should not retain any references
-- and should be fully evaluated.
runTestBlockStateWithCacheSize :: Int -> PersistentBSM pv a -> IO a
runTestBlockStateWithCacheSize cacheSize computation =
    Blob.runBlobStoreTemp "." $
        BS.withNewAccountCache cacheSize $
            BS.runPersistentBlockStateMonad $
                _runPersistentBSM computation

-- |Run test block state computation with a account cache size and module cache size of 100.
--
-- This function creates a temporary file for the blobstore, which is removed right after the
-- running the computation, meaning the result of the computation should not retain any references
-- and should be fully evaluated.
runTestBlockState :: PersistentBSM pv a -> IO a
runTestBlockState = runTestBlockStateWithCacheSize 100

-- |Config for running the scheduler in a test environment.
data TestConfig = TestConfig
    { -- | Maximum block size in bytes.
      tcBlockSize :: Integer,
      -- |Timeout for block construction in milliseconds.
      -- This is the absolute time after which we stop trying to add new transctions to the block.
      tcBlockTimeout :: Time.Timestamp,
      -- |The context state used for running the scheduler.
      tcContextState :: EI.ContextState
    }

-- |Default settings the running the scheduler in a test environment.
defaultTestConfig :: TestConfig
defaultTestConfig =
    TestConfig
        { tcBlockSize = DummyData.dummyBlockSize,
          tcBlockTimeout = Time.utcTimeToTimestamp DummyData.dummyBlockTimeout,
          tcContextState = defaultContextState
        }

defaultContextState :: EI.ContextState
defaultContextState =
    EI.ContextState
        { _chainMetadata = DummyData.dummyChainMeta,
          _maxBlockEnergy = maxBound,
          _accountCreationLimit = maxBound
        }

-- |Result from running the scheduler in a test environment.
data SchedulerResult = SchedulerResult
    { -- | The outcome for constructing a block.
      srTransactions :: FilteredTransactions,
      -- | The total execution cost of the block.
      srExecutionCosts :: Types.Amount,
      -- | The total execution energy of the block.
      srUsedEnergy :: Types.Energy
    }

-- | Run the scheduler on transactions in a test environment.
runScheduler ::
    forall pv.
    (Types.IsProtocolVersion pv) =>
    TestConfig ->
    BS.HashedPersistentBlockState pv ->
    Types.GroupedTransactions ->
    PersistentBSM pv (SchedulerResult, BS.PersistentBlockState pv)
runScheduler TestConfig{..} stateBefore transactions = do
    blockStateBefore <- BS.thawBlockState stateBefore
    let txs = filterTransactions tcBlockSize (Time.timestampToUTCTime tcBlockTimeout) transactions
    let schedulerState = EI.mkInitialSS @(PersistentBSM pv) blockStateBefore
    (filteredTransactions, stateAfter, ()) <- runRWST (_runBSM txs) tcContextState schedulerState

    let result =
            SchedulerResult
                { srTransactions = filteredTransactions,
                  srExecutionCosts = EI._ssSchedulerExecutionCosts stateAfter,
                  srUsedEnergy = EI._ssSchedulerEnergyUsed stateAfter
                }
    return (result, EI._ssBlockState stateAfter)

-- | Run the scheduler on transactions in a test environment.
-- Allows for a block state monad computation for constructing the initial block state and takes a
-- block state monad computation for extracting relevant values.
--
-- This function creates a temporary file for the blobstore, which is removed right after the
-- running transactions and the extractor, meaning the result of the extractor should not retain any
-- references and should be fully evaluated.
runSchedulerTest ::
    forall pv a.
    (Types.IsProtocolVersion pv) =>
    TestConfig ->
    PersistentBSM pv (BS.HashedPersistentBlockState pv) ->
    (BS.PersistentBlockState pv -> PersistentBSM pv a) ->
    Types.GroupedTransactions ->
    IO (SchedulerResult, a)
runSchedulerTest config constructState extractor transactions = runTestBlockState computation
  where
    computation :: PersistentBSM pv (SchedulerResult, a)
    computation = do
        blockStateBefore <- constructState
        (result, blockStateAfter) <- runScheduler config blockStateBefore transactions
        (result,) <$> extractor blockStateAfter

-- | Run the scheduler on transactions in a test environment.
-- Allows for a block state monad computation for constructing the initial block state and takes a
-- block state monad computation for extracting relevant values.
--
-- The transactions are provided using TransactionJSON.
runSchedulerTestTransactionJson ::
    forall pv a.
    (Types.IsProtocolVersion pv) =>
    TestConfig ->
    PersistentBSM pv (BS.HashedPersistentBlockState pv) ->
    (BS.PersistentBlockState pv -> PersistentBSM pv a) ->
    [SchedTest.TransactionJSON] ->
    IO (SchedulerResult, a)
runSchedulerTestTransactionJson config constructState extractor transactionJsonList = do
    transactions <- SchedTest.processUngroupedTransactions transactionJsonList
    runSchedulerTest config constructState extractor transactions

-- | Intermediate results collected while running a number of transactions.
type IntermediateResults a = [(SchedulerResult, a)]

-- | Run the scheduler on transactions in a test environment, while collecting all of the
-- intermediate results and extracted values.
runSchedulerTestWithIntermediateStates ::
    forall pv a.
    (Types.IsProtocolVersion pv) =>
    TestConfig ->
    PersistentBSM pv (BS.HashedPersistentBlockState pv) ->
    (BS.PersistentBlockState pv -> PersistentBSM pv a) ->
    Types.GroupedTransactions ->
    IO (IntermediateResults a, BS.HashedPersistentBlockState pv)
runSchedulerTestWithIntermediateStates config constructState extractor transactions =
    runTestBlockState blockStateComputation
  where
    blockStateComputation :: PersistentBSM pv (IntermediateResults a, BS.HashedPersistentBlockState pv)
    blockStateComputation = do
        blockStateBefore <- constructState
        foldM transactionRunner ([], blockStateBefore) transactions

    transactionRunner ::
        (IntermediateResults a, BS.HashedPersistentBlockState pv) ->
        Types.TransactionGroup ->
        PersistentBSM pv (IntermediateResults a, BS.HashedPersistentBlockState pv)
    transactionRunner (acc, currentState) tx = do
        (result, updatedState) <- runScheduler config currentState [tx]
        extracted <- extractor updatedState
        nextState <- BS.freezeBlockState updatedState
        return (acc ++ [(result, extracted)], nextState)

-- | Save and load block state, used to test the block state written to disc.
--
-- This can be used together with `runSchedulerTest*` functions for creating assertions about the
-- block state on disc.
reloadBlockState ::
    (Types.IsProtocolVersion pv) =>
    BS.PersistentBlockState pv ->
    PersistentBSM pv (BS.PersistentBlockState pv)
reloadBlockState persistentState = do
    frozen <- BS.freezeBlockState persistentState
    br <- BS.saveBlockState frozen
    BS.thawBlockState =<< BS.loadBlockState (BS.hpbsHash frozen) br

-- | Information accumulated when iterating the accounts in block state during
-- checkBlockStateInvariants.
type AccountAccumulated av =
    ( Map.Map Types.AccountAddress Types.AccountIndex,
      Map.Map Types.RawCredentialRegistrationID Types.AccountIndex,
      Set.Set Types.BakerId,
      DefinedWhenSupportDelegation av (Set.Set Types.DelegatorId),
      Types.Amount
    )

-- | Check block state for a number of invariants.
--
-- The invariants being check are:
-- - No dublicate account addresses.
-- - No dublicate account credentials.
-- - For each account
--   - Ensure the tracking of the total locked amount matches the sum of the pending releases.
--   - If the account is a baker, check the baker ID matches account index and it is part of the set
--     of active bakers.
--   - When protocol version supports delegation, see if the account is an active delegator.
--     If so, check the delegator ID matches account index and it is part of the set of active
--     delegators.
-- - Ensure all of the active bakers have a corresponding account in block state.
-- - When protocol version supports delegation, ensure all of the active delegators have a
--   corresponding account in block state.
-- - Ensure the total balance of accounts and instances, matches the total amount tracked in the
--   block state.
assertBlockStateInvariants ::
    (Types.IsProtocolVersion pv) =>
    BS.HashedPersistentBlockState pv ->
    Types.Amount ->
    PersistentBSM pv Assertion
assertBlockStateInvariants bs extraBalance = do
    result <- Except.runExceptT $ checkBlockStateInvariants bs extraBalance
    return $ either assertFailure return result

-- | Data type for holding data which is only defined for account versions supporting delegation.
data DefinedWhenSupportDelegation (av :: Types.AccountVersion) a where
    Defined :: (Types.AVSupportsDelegation av) => a -> DefinedWhenSupportDelegation av a
    NotDefined :: DefinedWhenSupportDelegation 'Types.AccountV0 a

-- | Check block state for a number of invariants.
--
-- The invariants being check are:
-- - No dublicate account addresses.
-- - No dublicate account credentials.
-- - For each account
--   - Ensure the tracking of the total locked amount matches the sum of the pending releases.
--   - If the account is a baker, check the baker ID matches account index and it is part of the set
--     of active bakers.
--   - When protocol version supports delegation, see if the account is an active delegator.
--     If so, check the delegator ID matches account index and it is part of the set of active
--     delegators.
-- - Ensure all of the active bakers have a corresponding account in block state.
-- - When protocol version supports delegation, ensure all of the active delegators have a
--   corresponding account in block state.
-- - Ensure the total balance of accounts and instances, matches the total amount tracked in the
--   block state.
checkBlockStateInvariants ::
    forall pv av.
    (Types.IsProtocolVersion pv, Types.IsAccountVersion av, Types.AccountVersionFor pv ~ av) =>
    BS.HashedPersistentBlockState pv ->
    Types.Amount ->
    Except.ExceptT String (PersistentBSM pv) ()
checkBlockStateInvariants bs extraBalance = do
    -- Iterate all of the accounts in block state, check and accumulate the total public balance.
    allAccounts <- BS.getAccountList bs

    -- Get the active bakers and for protocol versions supporting delegation, get the active delegators.
    (allActiveBakers, allActiveDelegators) <- case Types.delegationSupport @av of
        Types.SAVDelegationNotSupported -> do
            allActiveBakers <- Set.fromList <$> BS.getActiveBakers bs
            return (allActiveBakers, NotDefined)
        Types.SAVDelegationSupported -> do
            (allActiveBakerInfoList, allActiveDelegatorInfoList) <- BS.getActiveBakersAndDelegators bs
            allActiveBakerList <- mapM (BS.loadBakerId . BS.activeBakerInfoRef) allActiveBakerInfoList
            let allActiveDelegatorList = BS.activeDelegatorId <$> allActiveDelegatorInfoList
            return (Set.fromList allActiveBakerList, Defined @av $ Set.fromList allActiveDelegatorList)

    -- Iterates all of the accounts, running checks and accumulates the total public balance.
    (_, _, bakerIdsLeft, delegatorIdsLeft, totalAmountAccounts) <-
        foldM
            checkAccount
            (Map.empty, Map.empty, allActiveBakers, allActiveDelegators, 0)
            allAccounts

    -- Ensure all of the active bakers were covered by the above iteration of accounts.
    unless (Set.null bakerIdsLeft) $
        Except.throwError $
            "Active bakers with no baker record: " ++ show bakerIdsLeft

    -- For protocol versions with delegation:
    -- ensure all of the active bakers were covered by the above iteration of accounts.
    _ :: () <- case delegatorIdsLeft of
        NotDefined -> return ()
        Defined idsLeft ->
            unless (Set.null idsLeft) $
                Except.throwError $
                    "Active delegators with no delegator record: " ++ show idsLeft

    -- Check the total amount of CCD matches the one being tracked in block state.
    allInstances <- BS.getContractInstanceList bs
    totalAmountInstances <- foldM sumInstanceBalance 0 allInstances
    bankStatus <- BS.bsoGetBankStatus =<< BS.thawBlockState bs
    let totalAmountCalculated =
            totalAmountAccounts
                + (bankStatus ^. Rewards.totalEncryptedGTU)
                + totalAmountInstances
                + (bankStatus ^. Rewards.bankRewardAccounts . to Rewards.rewardsTotal)
                + extraBalance
    let totalAmountBank = bankStatus ^. Rewards.totalGTU
    unless (totalAmountBank == totalAmountCalculated) $
        Except.throwError $
            "Total CCD "
                ++ show totalAmountBank
                ++ " does not match the sum of all accounts, instances and rewards "
                ++ show totalAmountCalculated
  where
    -- Check account and accumulate the total public balance.
    checkAccount ::
        AccountAccumulated av ->
        Types.AccountAddress ->
        Except.ExceptT String (PersistentBSM pv) (AccountAccumulated av)
    checkAccount (accountsSoFar, credentialsSoFar, bakerIdsLeft, delegatorIdsLeft, totalAccountAmount) accountAddress = do
        -- Check that we didn't already find this same account.
        when (Map.member accountAddress accountsSoFar) $
            Except.throwError $
                "Duplicate account address: " ++ show accountAddress

        maybeAccount <- BS.getAccount bs accountAddress
        (accountIndex, account) <-
            maybe
                (Except.throwError $ "No account information for address: " ++ show accountAddress)
                return
                maybeAccount

        let nextAccountsSoFar = Map.insert accountAddress accountIndex accountsSoFar

        -- Check that we didn't already find this credential.
        credentials <- BS.accountCredentials account
        nextCredentialsSoFar <-
            foldM
                (checkAndInsertAccountCredential accountIndex)
                credentialsSoFar
                credentials

        -- Check that the locked balance is the same as the sum of the pending releases.
        lockedBalance <- BS.accountLockedAmount account
        sumOfReleases <- Types.releaseTotal <$> BS.accountReleaseSummary account
        unless (sumOfReleases == lockedBalance) $
            Except.throwError $
                "Sum of pending releases ("
                    ++ show sumOfReleases
                    ++ ") does not match the total locked amount "
                    ++ show lockedBalance
                    ++ " for account "
                    ++ show accountAddress

        -- If the account is a baker, check the baker ID matches account index and it is part of the
        -- set of active bakers.
        maybeAccountBakerInfoRef <- BS.accountBakerInfoRef account
        nextBakerIdsLeft <- case maybeAccountBakerInfoRef of
            Nothing -> return bakerIdsLeft
            Just bakerInfoRef -> do
                bakerId <- BS.loadBakerId bakerInfoRef
                unless (bakerId == fromIntegral accountIndex) $
                    Except.throwError $
                        "Baker ID ("
                            ++ show bakerId
                            ++ ") does not match the account index ("
                            ++ show accountIndex
                            ++ ") for account "
                            ++ show accountAddress
                unless (Set.member bakerId bakerIdsLeft) $
                    Except.throwError $
                        "Account has baker record, but is not an active baker "
                            ++ show bakerId
                            ++ " account "
                            ++ show accountAddress
                return $ Set.delete bakerId bakerIdsLeft

        -- When protocol version supports delegation, see if the account is an active delegator.
        -- If so, check the delegator ID matches account index and it is part of the
        -- set of active delegators.
        nextDelegatorIdsLeft <- case delegatorIdsLeft of
            NotDefined -> return delegatorIdsLeft
            Defined idsLeft -> do
                maybeAccountDelegation <- BS.accountDelegator account
                case maybeAccountDelegation of
                    Nothing -> return delegatorIdsLeft
                    Just accountDelegation -> do
                        let delegatorId = Types._delegationIdentity accountDelegation

                        unless (delegatorId == fromIntegral accountIndex) $
                            Except.throwError $
                                "Delegator ID ("
                                    ++ show delegatorId
                                    ++ ") does not match the account index ("
                                    ++ show accountIndex
                                    ++ ") for account "
                                    ++ show accountAddress
                        unless (Set.member delegatorId idsLeft) $
                            Except.throwError $
                                "Account has delegator record, but is not an active delegator "
                                    ++ show delegatorId
                                    ++ " account "
                                    ++ show accountAddress

                        return $ Defined $ Set.delete delegatorId idsLeft

        -- Add the public balance to the accumulated total public balance of accounts.
        publicBalance <- BS.accountAmount account
        let nextTotalAccountAmount = totalAccountAmount + publicBalance

        return
            ( nextAccountsSoFar,
              nextCredentialsSoFar,
              nextBakerIdsLeft,
              nextDelegatorIdsLeft,
              nextTotalAccountAmount
            )

    -- Ensure the provided contract address have and entry in the block state and accumulate the
    -- total balance of instances.
    sumInstanceBalance ::
        Types.Amount -> Types.ContractAddress -> Except.ExceptT String (PersistentBSM pv) Types.Amount
    sumInstanceBalance totalInstanceAmount instanceAddress = do
        maybeInstance <- BS.getContractInstance bs instanceAddress
        instanceInfo <-
            maybe
                (Except.throwError $ "No instance information for address: " ++ show instanceAddress)
                return
                maybeInstance
        let instanceAmount = case instanceInfo of
                BS.InstanceInfoV0 info -> BS.iiBalance info
                BS.InstanceInfoV1 info -> BS.iiBalance info
        return $! totalInstanceAmount + instanceAmount

    -- Check whether this is the first time we see a credential.
    checkAndInsertAccountCredential ::
        Types.AccountIndex ->
        Map.Map Types.RawCredentialRegistrationID Types.AccountIndex ->
        Types.RawAccountCredential ->
        Except.ExceptT
            String
            (PersistentBSM pv)
            (Map.Map Types.RawCredentialRegistrationID Types.AccountIndex)
    checkAndInsertAccountCredential accountIndex credentialsSoFar credential = do
        let credentialRegistrationId = Types.credId credential
        when (Map.member credentialRegistrationId credentialsSoFar) $
            Except.throwError $
                "Duplicate account credentials: " ++ show credential
        return $ Map.insert credentialRegistrationId accountIndex credentialsSoFar
