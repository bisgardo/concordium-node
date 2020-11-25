{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE UndecidableInstances #-}
module Concordium.GlobalState.Persistent.BlockState (
    PersistentBlockState,
    BlockStatePointers(..),
    HashedPersistentBlockState(..),
    hashBlockState,
    PersistentModule(..),
    persistentModuleToModule,
    Modules(..),
    emptyModules,
    makePersistentModules,
    PersistentBirkParameters(..),
    makePersistentBirkParameters,
    makePersistent,
    initialPersistentState,
    emptyBlockState,
    fromPersistentInstance,
    PersistentBlockStateContext(..),
    PersistentState,
    PersistentBlockStateMonad(..)
) where

import Data.Serialize
import qualified Data.HashMap.Strict as HM
import Data.IORef
import Control.Monad.Reader.Class
import Control.Monad.Trans
import Control.Monad
import Data.Foldable
import Data.Maybe
import Control.Exception
import Lens.Micro.Platform
import Concordium.Utils
import qualified Data.Set as Set
import qualified Data.Vector as Vec
import qualified Data.Map.Strict as Map

import GHC.Generics (Generic)

import qualified Concordium.Crypto.SHA256 as H
import Concordium.Types
import Concordium.Types.Execution
import qualified Concordium.Wasm as Wasm
import qualified Concordium.ID.Types as ID
import Concordium.Types.Updates

import Concordium.GlobalState.BakerInfo
import qualified Concordium.GlobalState.Basic.BlockState.Bakers as BB
import Concordium.GlobalState.Persistent.BlobStore
import qualified Concordium.GlobalState.Persistent.Trie as Trie
import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Types
import Concordium.GlobalState.Account
import qualified Concordium.GlobalState.IdentityProviders as IPS
import qualified Concordium.GlobalState.AnonymityRevokers as ARS
import qualified Concordium.GlobalState.Rewards as Rewards
import qualified Concordium.GlobalState.Persistent.Accounts as Accounts
import Concordium.GlobalState.Persistent.Bakers
import qualified Concordium.GlobalState.Persistent.Instances as Instances
import qualified Concordium.Types.Transactions as Transactions
import qualified Concordium.Types.Execution as Transactions
import Concordium.GlobalState.Persistent.Instances(PersistentInstance(..), PersistentInstanceParameters(..), CacheableInstanceParameters(..))
import Concordium.GlobalState.Instance (Instance(..),InstanceParameters(..),makeInstanceHash')
import Concordium.GlobalState.Persistent.Account
import Concordium.GlobalState.Persistent.BlockState.Updates
import qualified Concordium.GlobalState.Basic.BlockState.Account as TransientAccount
import qualified Concordium.GlobalState.Basic.BlockState as Basic
import qualified Concordium.GlobalState.Basic.BlockState.Updates as Basic
import qualified Concordium.GlobalState.Modules as TransientMods
import Concordium.GlobalState.SeedState
import Concordium.Logger (MonadLogger)
import Concordium.Types.HashableTo
import qualified Concordium.GlobalState.Persistent.LFMBTree as L

import qualified Concordium.GlobalState.Basic.BlockState.AccountReleaseSchedule as TransientReleaseSchedule

type PersistentBlockState = IORef (BufferedRef BlockStatePointers)

data BlockStatePointers = BlockStatePointers {
    bspAccounts :: !Accounts.Accounts,
    bspInstances :: !Instances.Instances,
    bspModules :: !(HashedBufferedRef Modules),
    bspBank :: !(Hashed Rewards.BankStatus),
    bspIdentityProviders :: !(HashedBufferedRef IPS.IdentityProviders),
    bspAnonymityRevokers :: !(HashedBufferedRef ARS.AnonymityRevokers),
    bspBirkParameters :: !PersistentBirkParameters,
    bspCryptographicParameters :: !(HashedBufferedRef CryptographicParameters),
    bspUpdates :: !(BufferedRef Updates),
    bspReleaseSchedule :: !(BufferedRef (Map.Map AccountAddress Timestamp)),
    -- FIXME: Store transaction outcomes in a way that allows for individual indexing.
    bspTransactionOutcomes :: !Transactions.TransactionOutcomes
}

data HashedPersistentBlockState = HashedPersistentBlockState {
    hpbsPointers :: !PersistentBlockState,
    hpbsHash :: !StateHash
}

hashBlockState :: MonadBlobStore m => PersistentBlockState -> m HashedPersistentBlockState
hashBlockState hpbsPointers = do
        rbsp <- liftIO $ readIORef hpbsPointers
        bsp <- refLoad rbsp
        hpbsHash <- getHashM bsp
        return HashedPersistentBlockState{..}

instance MonadBlobStore m => MHashableTo m StateHash BlockStatePointers where
    getHashM BlockStatePointers{..} = do
        bshBirkParameters <- getHashM bspBirkParameters
        bshCryptographicParameters <- getHashM bspCryptographicParameters
        bshIdentityProviders <- getHashM bspIdentityProviders
        bshAnonymityRevokers <- getHashM bspAnonymityRevokers
        bshModules <- getHashM bspModules
        let bshBankStatus = getHash bspBank
        bshAccounts <- getHashM bspAccounts
        bshInstances <- getHashM bspInstances
        bshUpdates <- getHashM bspUpdates
        return $ makeBlockStateHash BlockStateHashInputs{..}

instance (MonadBlobStore m, BlobStorable m (Nullable (BlobRef Accounts.RegIdHistory))) => BlobStorable m BlockStatePointers where
    storeUpdate bsp0@BlockStatePointers{..} = do
        (paccts, bspAccounts') <- storeUpdate bspAccounts
        (pinsts, bspInstances') <- storeUpdate bspInstances
        (pmods, bspModules') <- storeUpdate bspModules
        (pips, bspIdentityProviders') <- storeUpdate bspIdentityProviders
        (pars, bspAnonymityRevokers') <- storeUpdate bspAnonymityRevokers
        (pbps, bspBirkParameters') <- storeUpdate bspBirkParameters
        (pcryptps, bspCryptographicParameters') <- storeUpdate bspCryptographicParameters
        (pupdates, bspUpdates') <- storeUpdate bspUpdates
        (preleases, bspReleaseSchedule') <- storeUpdate bspReleaseSchedule
        let putBSP = do
                paccts
                pinsts
                pmods
                put $ _unhashed bspBank
                pips
                pars
                pbps
                pcryptps
                put bspTransactionOutcomes
                pupdates
                preleases
        return (putBSP, bsp0 {
                    bspAccounts = bspAccounts',
                    bspInstances = bspInstances',
                    bspModules = bspModules',
                    bspIdentityProviders = bspIdentityProviders',
                    bspAnonymityRevokers = bspAnonymityRevokers',
                    bspBirkParameters = bspBirkParameters',
                    bspCryptographicParameters = bspCryptographicParameters',
                    bspUpdates = bspUpdates',
                    bspReleaseSchedule = bspReleaseSchedule'
                })
    store bsp = fst <$> storeUpdate bsp
    load = do
        maccts <- label "Accounts" load
        minsts <- label "Instances" load
        mmods <- label "Modules" load
        bspBank <- makeHashed <$> label "Bank" get
        mpips <- label "Identity providers" load
        mars <- label "Anonymity revokers" load
        mbps <- label "Birk parameters" load
        mcryptps <- label "Cryptographic parameters" load
        bspTransactionOutcomes <- label "Transaction outcomes" get
        mUpdates <- label "Updates" load
        mReleases <- label "Release schedule" load
        return $! do
            bspAccounts <- maccts
            bspInstances <- minsts
            bspModules <- mmods
            bspIdentityProviders <- mpips
            bspAnonymityRevokers <- mars
            bspBirkParameters <- mbps
            bspCryptographicParameters <- mcryptps
            bspUpdates <- mUpdates
            bspReleaseSchedule <- mReleases
            return $! BlockStatePointers{..}

instance MonadBlobStore m => Cacheable m BlockStatePointers where
    cache BlockStatePointers{..} = do
        accts <- cache bspAccounts
        insts <- cache bspInstances
        mods <- cache bspModules
        ips <- cache bspIdentityProviders
        ars <- cache bspAnonymityRevokers
        birkParams <- cache bspBirkParameters
        cryptoParams <- cache bspCryptographicParameters
        upds <- cache bspUpdates
        rels <- cache bspReleaseSchedule
        return BlockStatePointers{
            bspAccounts = accts,
            bspInstances = insts,
            bspModules = mods,
            bspBank = bspBank,
            bspIdentityProviders = ips,
            bspAnonymityRevokers = ars,
            bspBirkParameters = birkParams,
            bspCryptographicParameters = cryptoParams,
            bspUpdates = upds,
            bspReleaseSchedule = rels,
            bspTransactionOutcomes = bspTransactionOutcomes
        }

data PersistentModule = PersistentModule {
    pmInterface :: !Wasm.ModuleInterface,
    pmIndex :: !ModuleIndex
}

persistentModuleToModule :: PersistentModule -> Module
persistentModuleToModule PersistentModule{..} = Module {
    moduleInterface = pmInterface,
    moduleIndex = pmIndex
}

instance Serialize PersistentModule where
    put PersistentModule{..} = put pmInterface <> put pmIndex
    get = PersistentModule <$> get <*> get

instance MonadBlobStore m => BlobStorable m PersistentModule
instance Applicative m => Cacheable m PersistentModule

data Modules = Modules {
    modules :: Trie.TrieN (BufferedBlobbed BlobRef) ModuleRef PersistentModule,
    nextModuleIndex :: !ModuleIndex,
    runningHash :: !H.Hash
}

emptyModules :: Modules
emptyModules = Modules {
        modules = Trie.empty,
        nextModuleIndex = 0,
        runningHash = H.hash ""
    }

instance (MonadBlobStore m) => BlobStorable m Modules where
    storeUpdate ms@Modules{..} = do
        (pm, modules') <- storeUpdate modules
        return (pm >> put nextModuleIndex >> put runningHash, ms {modules = modules'})
    store m = fst <$> storeUpdate m
    load = do
        mmodules <- load
        nextModuleIndex <- get
        runningHash <- get
        return $ do
            modules <- mmodules
            return Modules{..}

instance HashableTo H.Hash Modules where
  getHash Modules {..} = runningHash

instance Monad m => MHashableTo m H.Hash Modules

instance (MonadBlobStore m) => Cacheable m Modules where
    cache m = do
        modules' <- cache (modules m)
        return m{modules = modules'}

makePersistentModules :: MonadIO m => TransientMods.Modules -> m Modules
makePersistentModules TransientMods.Modules{..} = do
    m' <- Trie.fromList $ upd <$> HM.toList _modules
    return $ Modules m' _nextModuleIndex _runningHash
    where
        upd (mref, Module{..}) = (mref, PersistentModule{
                pmInterface = moduleInterface,
                pmIndex = moduleIndex
            })

data PersistentBirkParameters = PersistentBirkParameters {
    -- |The current stake of bakers. All updates should be to this state.
    _birkCurrentBakers :: !PersistentBakers,
    -- |The state of bakers at the end of the previous epoch,
    -- will be used as lottery bakers in next epoch.
    _birkPrevEpochBakers :: !(BufferedRef PersistentBakers),
    -- |The state of the bakers fixed before previous epoch,
    -- the lottery power and reward account is used in leader election.
    _birkLotteryBakers :: !(BufferedRef PersistentBakers),
    _birkSeedState :: !SeedState
} deriving (Generic, Show)

makeLenses ''PersistentBirkParameters

instance MonadBlobStore m => MHashableTo m H.Hash PersistentBirkParameters where
  getHashM PersistentBirkParameters {..} = do
    currentHash <- getHashM _birkCurrentBakers
    prevHash <- getHashM _birkPrevEpochBakers
    lotteryHash <- getHashM _birkLotteryBakers
    let bpH0 = H.hash $ "SeedState" <> encode _birkSeedState
        bpH1 = H.hashOfHashes prevHash lotteryHash
        bpH2 = H.hashOfHashes currentHash bpH1
    return $ H.hashOfHashes bpH0 bpH2

instance MonadBlobStore m => BlobStorable m PersistentBirkParameters where
    storeUpdate bps@PersistentBirkParameters{..} = do
        (ppebs, prevEpochBakers) <- storeUpdate _birkPrevEpochBakers
        (plbs, lotteryBakers) <- storeUpdate _birkLotteryBakers
        (pcbs, currBakers) <- storeUpdate _birkCurrentBakers
        let putBSP = do
                pcbs
                ppebs
                plbs
                put _birkSeedState
        return (putBSP, bps {
                    _birkCurrentBakers = currBakers,
                    _birkPrevEpochBakers = prevEpochBakers,
                    _birkLotteryBakers = lotteryBakers
                })
    store bps = fst <$> storeUpdate bps
    load = do
        mcbs <- label "Current bakers" $ load
        mpebs <- label "Previous-epoch bakers" $ load
        mlbs <- label "Lottery bakers" $ load
        _birkSeedState <- label "Seed state" get
        return $! do
            _birkCurrentBakers <- mcbs
            _birkPrevEpochBakers <- mpebs
            _birkLotteryBakers <- mlbs
            return PersistentBirkParameters{..}

instance MonadBlobStore m => Cacheable m PersistentBirkParameters where
    cache PersistentBirkParameters{..} = do
        cur <- cache _birkCurrentBakers
        prev <- cache _birkPrevEpochBakers
        lot <- cache _birkLotteryBakers
        return PersistentBirkParameters{
            _birkCurrentBakers = cur,
            _birkPrevEpochBakers = prev,
            _birkLotteryBakers = lot,
            ..
        }

makePersistentBirkParameters :: MonadBlobStore m => Basic.BasicBirkParameters -> m PersistentBirkParameters
makePersistentBirkParameters Basic.BasicBirkParameters{..} = do
    prevEpochBakers <- refMake =<< makePersistentBakers ( _unhashed _birkPrevEpochBakers)
    lotteryBakers <- refMake =<< makePersistentBakers (_unhashed _birkLotteryBakers)
    currBakers <- makePersistentBakers _birkCurrentBakers
    return $ PersistentBirkParameters
        currBakers
        prevEpochBakers
        lotteryBakers
        _birkSeedState

makePersistent :: MonadBlobStore m  => Basic.BlockState -> m HashedPersistentBlockState
makePersistent Basic.BlockState{..} = do
  persistentBlockInstances <- Instances.makePersistent _blockInstances
  persistentBirkParameters <- makePersistentBirkParameters _blockBirkParameters
  persistentMods <- makePersistentModules _blockModules
  modules <- refMake persistentMods
  identityProviders <- bufferHashed _blockIdentityProviders
  anonymityRevokers <- bufferHashed _blockAnonymityRevokers
  cryptographicParameters <- bufferHashed _blockCryptographicParameters
  blockAccounts <- Accounts.makePersistent _blockAccounts
  updates <- makeBufferedRef =<< makePersistentUpdates _blockUpdates
  rels <- makeBufferedRef _blockReleaseSchedule
  bsp <-
    makeBufferedRef $
      BlockStatePointers
        { bspAccounts = blockAccounts,
          bspInstances = persistentBlockInstances,
          bspModules = modules,
          bspBank = _blockBank,
          bspIdentityProviders = identityProviders,
          bspAnonymityRevokers = anonymityRevokers,
          bspBirkParameters = persistentBirkParameters,
          bspCryptographicParameters = cryptographicParameters,
          bspTransactionOutcomes = _blockTransactionOutcomes,
          bspUpdates = updates,
          bspReleaseSchedule = rels
        }
  bps <- liftIO $ newIORef $! bsp
  hashBlockState bps

initialPersistentState :: MonadBlobStore m => Basic.BasicBirkParameters
             -> CryptographicParameters
             -> [TransientAccount.Account]
             -> IPS.IdentityProviders
             -> ARS.AnonymityRevokers
             -> Amount
             -> Authorizations
             -> ChainParameters
             -> m HashedPersistentBlockState
initialPersistentState bps cps accts ips ars amt auths chainParams = makePersistent $ Basic.initialState bps cps accts ips ars amt auths chainParams

-- |Mostly empty block state, apart from using 'Rewards.genesisBankStatus' which
-- has hard-coded initial values for amount of gtu in existence.
emptyBlockState :: MonadBlobStore m => PersistentBirkParameters -> CryptographicParameters -> Authorizations -> ChainParameters -> m PersistentBlockState
emptyBlockState bspBirkParameters cryptParams auths chainParams = do
  modules <- refMake emptyModules
  identityProviders <- refMake IPS.emptyIdentityProviders
  anonymityRevokers <- refMake ARS.emptyAnonymityRevokers
  cryptographicParameters <- refMake cryptParams
  bspUpdates <- refMake =<< initialUpdates auths chainParams
  bspReleaseSchedule <- refMake $ Map.empty
  bsp <- makeBufferedRef $ BlockStatePointers
          { bspAccounts = Accounts.emptyAccounts,
            bspInstances = Instances.emptyInstances,
            bspModules = modules,
            bspBank = makeHashed Rewards.emptyBankStatus,
            bspIdentityProviders = identityProviders,
            bspAnonymityRevokers = anonymityRevokers,
            bspCryptographicParameters = cryptographicParameters,
            bspTransactionOutcomes = Transactions.emptyTransactionOutcomes,
            ..
          }
  liftIO $ newIORef $! bsp

fromPersistentInstance ::  MonadBlobStore m =>
    PersistentBlockState -> Instances.PersistentInstance -> m Instance
fromPersistentInstance _ Instances.PersistentInstance{pinstanceCachedParameters = (Some CacheableInstanceParameters{..}), ..} = do
    PersistentInstanceParameters{..} <- loadBufferedRef pinstanceParameters
    let instanceParameters = InstanceParameters {
            instanceAddress = pinstanceAddress,
            instanceOwner = pinstanceOwner,
            instanceContractModule = pinstanceContractModule,
            instanceInitName = pinstanceInitName,
            instanceReceiveFuns = pinstanceReceiveFuns,
            instanceModuleInterface = pinstanceModuleInterface,
            instanceParameterHash = pinstanceParameterHash
        }
    return Instance{ instanceModel = pinstanceModel,
            instanceAmount = pinstanceAmount,
            instanceHash = pinstanceHash,
            ..
         }
fromPersistentInstance pbs Instances.PersistentInstance{..} = do
    PersistentInstanceParameters{..} <- loadBufferedRef pinstanceParameters
    doGetModule pbs pinstanceContractModule >>= \case
        Nothing -> error "fromPersistentInstance: unresolvable module" -- TODO: Possibly don't error here
        Just m -> do
            let instanceParameters = InstanceParameters {
                    instanceAddress = pinstanceAddress,
                    instanceOwner = pinstanceOwner,
                    instanceContractModule = pinstanceContractModule,
                    instanceInitName = pinstanceInitName,
                    instanceReceiveFuns = pinstanceReceiveFuns,
                    instanceModuleInterface = moduleInterface m,
                    instanceParameterHash = pinstanceParameterHash
                }
            return Instance{
                    instanceModel = pinstanceModel,
                    instanceAmount = pinstanceAmount,
                    instanceHash = pinstanceHash,
                    ..
                }

loadPBS :: MonadBlobStore m => PersistentBlockState -> m BlockStatePointers
loadPBS = loadBufferedRef <=< liftIO . readIORef
{-# INLINE loadPBS #-}

storePBS :: MonadBlobStore m => PersistentBlockState -> BlockStatePointers -> m PersistentBlockState
storePBS pbs bsp = liftIO $ do
    pbsp <- makeBufferedRef bsp
    writeIORef pbs pbsp
    return pbs
{-# INLINE storePBS #-}

doGetModule :: MonadBlobStore m => PersistentBlockState -> ModuleRef -> m (Maybe Module)
doGetModule s modRef = do
    bsp <- loadPBS s
    mods <- refLoad (bspModules bsp)
    fmap persistentModuleToModule <$> Trie.lookup modRef (modules mods)

doGetModuleList :: MonadBlobStore m => PersistentBlockState -> m [ModuleRef]
doGetModuleList s = do
    bsp <- loadPBS s
    mods <- refLoad (bspModules bsp)
    Trie.keys (modules mods)

doPutNewModule :: MonadBlobStore m =>PersistentBlockState
    -> Wasm.ModuleInterface
    -> m (Bool, PersistentBlockState)
doPutNewModule pbs pmInterface = do
        let mref = Wasm.miModuleRef pmInterface
        bsp <- loadPBS pbs
        mods <- refLoad (bspModules bsp)
        let
            newMod = PersistentModule{pmIndex = nextModuleIndex mods, ..}
            tryIns Nothing = return (True, Trie.Insert newMod)
            tryIns (Just _) = return (False, Trie.NoChange)
        (b, modules') <- Trie.adjust tryIns mref (modules mods)
        if b then do
            let
                newMods = mods {modules = modules', nextModuleIndex = nextModuleIndex mods + 1}
            modules <- refMake newMods
            (True,) <$> storePBS pbs (bsp {bspModules = modules})
        else
            return (False, pbs)

doGetBlockBirkParameters :: MonadBlobStore m => PersistentBlockState -> m PersistentBirkParameters
doGetBlockBirkParameters pbs = bspBirkParameters <$> loadPBS pbs

doAddBaker :: MonadBlobStore m => PersistentBlockState -> BakerInfo -> m (Either BakerError BakerId, PersistentBlockState)
doAddBaker pbs binfo = do
        bsp <- loadPBS pbs
        createBaker binfo (bspBirkParameters bsp ^. birkCurrentBakers) >>= \case
            Left err -> return (Left err, pbs)
            Right (bid, newBakers) -> (Right bid,) <$> storePBS pbs (bsp {bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newBakers})

doUpdateBaker :: MonadBlobStore m => PersistentBlockState -> BB.BakerUpdate -> m (Bool, PersistentBlockState)
doUpdateBaker pbs bupdate = do
        bsp <- loadPBS pbs
        updateBaker bupdate (bspBirkParameters bsp ^. birkCurrentBakers) >>= \case
            Nothing -> return (False, pbs)
            Just newBakers ->
              (True,) <$!> storePBS pbs (bsp {bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newBakers})

doRemoveBaker :: MonadBlobStore m => PersistentBlockState -> BakerId -> m (Bool, PersistentBlockState)
doRemoveBaker pbs bid = do
        bsp <- loadPBS pbs
        (rv, newBakers) <- removeBaker bid (bspBirkParameters bsp ^. birkCurrentBakers)
        (rv,) <$> storePBS pbs (bsp {bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newBakers})

doGetRewardStatus :: MonadBlobStore m => PersistentBlockState -> m Rewards.BankStatus
doGetRewardStatus pbs = _unhashed . bspBank <$> loadPBS pbs

doSetInflation :: MonadBlobStore m => PersistentBlockState -> Amount -> m PersistentBlockState
doSetInflation pbs amount = do
        bsp <- loadPBS pbs
        storePBS pbs (bsp {bspBank = bspBank bsp & unhashed . Rewards.mintedGTUPerSlot .~ amount})

doMint :: MonadBlobStore m => PersistentBlockState -> Amount -> m (Amount, PersistentBlockState)
doMint pbs amount = do
        bsp <- loadPBS pbs
        let newBank = bspBank bsp & (unhashed . Rewards.totalGTU +~ amount) . (unhashed . Rewards.centralBankGTU +~ amount)
        (newBank ^. unhashed . Rewards.centralBankGTU,) <$> storePBS pbs (bsp {bspBank = newBank})

doDecrementCentralBankGTU :: MonadBlobStore m => PersistentBlockState -> Amount -> m (Amount, PersistentBlockState)
doDecrementCentralBankGTU pbs amount = do
        bsp <- loadPBS pbs
        let newBank = bspBank bsp & unhashed . Rewards.centralBankGTU -~ amount
        (newBank ^. unhashed . Rewards.centralBankGTU,) <$> storePBS pbs (bsp {bspBank = newBank})

doGetAccount :: MonadBlobStore m => PersistentBlockState -> AccountAddress -> m (Maybe PersistentAccount)
doGetAccount pbs addr = do
        bsp <- loadPBS pbs
        Accounts.getAccount addr (bspAccounts bsp)

doAccountList :: MonadBlobStore m => PersistentBlockState -> m [AccountAddress]
doAccountList pbs = do
        bsp <- loadPBS pbs
        Accounts.accountAddresses (bspAccounts bsp)

doRegIdExists :: MonadBlobStore m => PersistentBlockState -> ID.CredentialRegistrationID -> m Bool
doRegIdExists pbs regid = do
        bsp <- loadPBS pbs
        fst <$> Accounts.regIdExists regid (bspAccounts bsp)

doPutNewAccount :: MonadBlobStore m => PersistentBlockState -> PersistentAccount -> m (Bool, PersistentBlockState)
doPutNewAccount pbs acct = do
        bsp <- loadPBS pbs
        -- Add the account
        (res, accts1) <- Accounts.putNewAccount acct (bspAccounts bsp)
        if res then (True,) <$> do
            PersistingAccountData{..} <- acct ^^. id
            -- Record the RegIds of any credentials
            accts2 <- foldM (flip Accounts.recordRegId) accts1 (ID.regId <$> _accountCredentials)
            -- Update the delegation if necessary
            case _accountStakeDelegate of
                Nothing -> storePBS pbs (bsp {bspAccounts = accts2})
                target@(Just _) -> assert (null _accountInstances) $ do
                    newCurrBakers <- addStake target (acct ^. accountAmount) (bspBirkParameters bsp ^. birkCurrentBakers)
                    storePBS pbs (bsp {
                            bspAccounts = accts2,
                            bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newCurrBakers
                        })
        else
            return (False, pbs)

doModifyAccount :: MonadBlobStore m => PersistentBlockState -> AccountUpdate -> m PersistentBlockState
doModifyAccount pbs aUpd@AccountUpdate{..} = do
        bsp <- loadPBS pbs
        -- Do the update to the account
        (mbalinfo, accts1) <- Accounts.updateAccounts upd _auAddress (bspAccounts bsp)
        -- If we deploy a credential, record it
        accts2 <- case _auCredential of
            Just cdi -> Accounts.recordRegId (ID.regId cdi) accts1
            Nothing -> return accts1
        -- If the amount is changed update the delegate stake
        birkParams1 <- case  mbalinfo of
                Just delegate ->
                  case (_auAmount, _auReleaseSchedule) of
                    (Nothing, Nothing) -> return $ bspBirkParameters bsp
                    _ -> do
                      let amnt = fromMaybe (amountToDelta 0) _auAmount
                          rels = maybe (amountToDelta 0) (\rel -> amountToDelta (foldl' (+) 0 (concatMap (\(l, _) -> map snd l) rel))) _auReleaseSchedule
                      newCurrBakers <- modifyStake delegate (amnt + rels) (bspBirkParameters bsp ^. birkCurrentBakers)
                      return $ bspBirkParameters bsp & birkCurrentBakers .~ newCurrBakers
                _ -> return $ bspBirkParameters bsp
        storePBS pbs (bsp {bspAccounts = accts2, bspBirkParameters = birkParams1})
    where
        upd oldAccount = do
          delegate <- oldAccount ^^. accountStakeDelegate
          newAcc <- Accounts.updateAccount aUpd oldAccount
          return (delegate, newAcc)

doGetInstance :: MonadBlobStore m => PersistentBlockState -> ContractAddress -> m (Maybe Instance)
doGetInstance pbs caddr = do
        bsp <- loadPBS pbs
        minst <- Instances.lookupContractInstance caddr (bspInstances bsp)
        forM minst $ fromPersistentInstance pbs

doContractInstanceList :: MonadBlobStore m => PersistentBlockState -> m [Instance]
doContractInstanceList pbs = do
        bsp <- loadPBS pbs
        insts <- Instances.allInstances (bspInstances bsp)
        mapM (fromPersistentInstance pbs) insts

doPutNewInstance :: MonadBlobStore m => PersistentBlockState -> (ContractAddress -> Instance) -> m (ContractAddress, PersistentBlockState)
doPutNewInstance pbs fnew = do
        bsp <- loadPBS pbs
        -- Create the instance
        (inst, insts) <- Instances.newContractInstance fnew' (bspInstances bsp)
        let ca = instanceAddress (instanceParameters inst)
        -- Update the owner account's set of instances
        let updAcct oldAccount = do
              delegate <- oldAccount ^^. accountStakeDelegate
              newAccount <- oldAccount & accountInstances %~~ Set.insert ca
              return (delegate, newAccount)
        (mdelegate, accts) <- Accounts.updateAccounts updAcct (instanceOwner (instanceParameters inst)) (bspAccounts bsp)
        -- Update the stake delegate
        case mdelegate of
            Nothing -> error "Invalid contract owner"
            Just delegate -> do
                newCurrBakers <- modifyStake delegate (amountToDelta (instanceAmount inst)) (bspBirkParameters bsp ^. birkCurrentBakers)
                (ca,) <$> storePBS pbs bsp{
                                    bspInstances = insts,
                                    bspAccounts = accts,
                                    bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newCurrBakers
                                }
    where
        fnew' ca = let inst@Instance{instanceParameters = InstanceParameters{..}, ..} = fnew ca in do
            params <- makeBufferedRef $ PersistentInstanceParameters {
                                            pinstanceAddress = instanceAddress,
                                            pinstanceOwner = instanceOwner,
                                            pinstanceContractModule = instanceContractModule,
                                            pinstanceReceiveFuns = instanceReceiveFuns,
                                            pinstanceInitName = instanceInitName,
                                            pinstanceParameterHash = instanceParameterHash
                                        }
            return (inst, PersistentInstance{
                pinstanceParameters = params,
                pinstanceCachedParameters = Some (CacheableInstanceParameters{
                        pinstanceModuleInterface = instanceModuleInterface
                    }),
                pinstanceModel = instanceModel,
                pinstanceAmount = instanceAmount,
                pinstanceHash = instanceHash
            })

doModifyInstance :: MonadBlobStore m => PersistentBlockState -> ContractAddress -> AmountDelta -> Wasm.ContractState -> m PersistentBlockState
doModifyInstance pbs caddr deltaAmnt val = do
        bsp <- loadPBS pbs
        -- Update the instance
        Instances.updateContractInstance upd caddr (bspInstances bsp) >>= \case
            Nothing -> error "Invalid contract address"
            Just (Nothing, insts) -> -- no change to staking
                storePBS pbs bsp{bspInstances = insts}
            Just (Just owner, insts) ->
                -- Lookup the owner account and update its stake delegate
                Accounts.getAccount owner (bspAccounts bsp) >>= \case
                    Nothing -> error "Invalid contract owner"
                    Just acct -> do
                        delegate <- acct ^^. accountStakeDelegate
                        newCurrBakers <- modifyStake delegate deltaAmnt (bspBirkParameters bsp ^. birkCurrentBakers)
                        storePBS pbs bsp{
                            bspInstances = insts,
                            bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newCurrBakers
                        }
    where
        upd oldInst = do
            (piParams, newParamsRef) <- cacheBufferedRef (pinstanceParameters oldInst)
            if deltaAmnt == 0 then
                return (Nothing, rehash (pinstanceParameterHash piParams) $ oldInst {pinstanceParameters = newParamsRef, pinstanceModel = val})
            else do
                acct <- pinstanceOwner <$> loadBufferedRef (pinstanceParameters oldInst)
                return (Just acct, rehash (pinstanceParameterHash piParams) $ oldInst {pinstanceParameters = newParamsRef, pinstanceAmount = applyAmountDelta deltaAmnt (pinstanceAmount oldInst), pinstanceModel = val})
        rehash iph inst@(PersistentInstance {..}) = inst {pinstanceHash = makeInstanceHash' iph pinstanceModel pinstanceAmount}

doDelegateStake :: MonadBlobStore m => PersistentBlockState -> AccountAddress -> Maybe BakerId -> m (Bool, PersistentBlockState)
doDelegateStake pbs aaddr target = do
        bsp <- loadPBS pbs
        targetValid <- case target of
                Nothing -> return True
                Just bid -> do
                    mbInfo <- L.lookup bid $ bspBirkParameters bsp ^. birkCurrentBakers . bakerMap
                    case mbInfo of
                      Just (Some _) -> return True
                      _ -> return False
        if targetValid then do
            let updAcc acct = do
                  delegate <- acct ^^. accountStakeDelegate
                  newAccount <- acct & accountStakeDelegate .~~ target
                  instances <- acct ^^. accountInstances
                  return ((delegate, acct ^. accountAmount, Set.toList instances), newAccount)
            Accounts.updateAccounts updAcc aaddr (bspAccounts bsp) >>= \case
                (Nothing, _) -> error "Invalid account address"
                (Just (acctOldTarget, acctBal, acctInsts), accts) -> do
                    instBals <- forM acctInsts $ \caddr -> maybe (error "Invalid contract instance") pinstanceAmount <$> Instances.lookupContractInstance caddr (bspInstances bsp)
                    let stake = acctBal + sum instBals
                    newCurrBakers <- removeStake acctOldTarget stake =<< addStake target stake (bspBirkParameters bsp ^. birkCurrentBakers)
                    pbs' <- storePBS pbs bsp{
                            bspAccounts = accts,
                            bspBirkParameters = bspBirkParameters bsp & birkCurrentBakers .~ newCurrBakers
                        }
                    return (True, pbs')
        else return (False, pbs)

doGetIdentityProvider :: MonadBlobStore m => PersistentBlockState -> ID.IdentityProviderIdentity -> m (Maybe IPS.IpInfo)
doGetIdentityProvider pbs ipId = do
        bsp <- loadPBS pbs
        ips <- refLoad (bspIdentityProviders bsp)
        return $! IPS.idProviders ips ^? ix ipId

doGetAllIdentityProvider :: MonadBlobStore m => PersistentBlockState -> m [IPS.IpInfo]
doGetAllIdentityProvider pbs = do
        bsp <- loadPBS pbs
        ips <- refLoad (bspIdentityProviders bsp)
        return $! Map.elems $ IPS.idProviders ips

doGetAnonymityRevokers :: MonadBlobStore m => PersistentBlockState -> [ID.ArIdentity] -> m (Maybe [ARS.ArInfo])
doGetAnonymityRevokers pbs arIds = do
        bsp <- loadPBS pbs
        ars <- refLoad (bspAnonymityRevokers bsp)
        return
          $! let arsMap = ARS.arRevokers ars
              in forM arIds (`Map.lookup` arsMap)

doGetAllAnonymityRevokers :: MonadBlobStore m => PersistentBlockState -> m [ARS.ArInfo]
doGetAllAnonymityRevokers pbs = do
        bsp <- loadPBS pbs
        ars <- refLoad (bspAnonymityRevokers bsp)
        return $! Map.elems $ ARS.arRevokers ars

doGetCryptoParams :: MonadBlobStore m => PersistentBlockState -> m CryptographicParameters
doGetCryptoParams pbs = do
        bsp <- loadPBS pbs
        refLoad (bspCryptographicParameters bsp)

doGetTransactionOutcome :: MonadBlobStore m => PersistentBlockState -> Transactions.TransactionIndex -> m (Maybe TransactionSummary)
doGetTransactionOutcome pbs transHash = do
        bsp <- loadPBS pbs
        return $! bspTransactionOutcomes bsp ^? ix transHash

doGetTransactionOutcomesHash :: MonadBlobStore m => PersistentBlockState -> m TransactionOutcomesHash
doGetTransactionOutcomesHash pbs =  do
    bsp <- loadPBS pbs
    return $! getHash (bspTransactionOutcomes bsp)

doSetTransactionOutcomes :: MonadBlobStore m => PersistentBlockState -> [TransactionSummary] -> m PersistentBlockState
doSetTransactionOutcomes pbs transList = do
        bsp <- loadPBS pbs
        storePBS pbs bsp {bspTransactionOutcomes = Transactions.transactionOutcomesFromList transList}

doNotifyExecutionCost :: MonadBlobStore m => PersistentBlockState -> Amount -> m PersistentBlockState
doNotifyExecutionCost pbs amnt = do
        bsp <- loadPBS pbs
        storePBS pbs bsp {bspBank = bspBank bsp & unhashed . Rewards.executionCost +~ amnt}

doNotifyEncryptedBalanceChange :: MonadBlobStore m => PersistentBlockState -> AmountDelta -> m PersistentBlockState
doNotifyEncryptedBalanceChange pbs amntDiff = do
        bsp <- loadPBS pbs
        storePBS pbs bsp{bspBank = bspBank bsp & unhashed . Rewards.totalEncryptedGTU %~ applyAmountDelta amntDiff}

doNotifyIdentityIssuerCredential :: MonadBlobStore m => PersistentBlockState -> ID.IdentityProviderIdentity -> m PersistentBlockState
doNotifyIdentityIssuerCredential pbs idk = do
        bsp <- loadPBS pbs
        storePBS pbs bsp {bspBank = bspBank bsp & (unhashed . Rewards.identityIssuersRewards . at' idk . non 0) +~ 1}

doGetExecutionCost :: MonadBlobStore m => PersistentBlockState -> m Amount
doGetExecutionCost pbs = (^. unhashed . Rewards.executionCost) . bspBank <$> loadPBS pbs

doGetSpecialOutcomes :: MonadBlobStore m => PersistentBlockState -> m [Transactions.SpecialTransactionOutcome]
doGetSpecialOutcomes pbs = (^. to bspTransactionOutcomes . Transactions.outcomeSpecial) <$> loadPBS pbs

doGetOutcomes :: MonadBlobStore m => PersistentBlockState -> m (Vec.Vector TransactionSummary)
doGetOutcomes pbs = (^. to bspTransactionOutcomes . to Transactions.outcomeValues) <$> loadPBS pbs

doAddSpecialTransactionOutcome :: MonadBlobStore m => PersistentBlockState -> Transactions.SpecialTransactionOutcome -> m PersistentBlockState
doAddSpecialTransactionOutcome pbs !o = do
        bsp <- loadPBS pbs
        storePBS pbs $! bsp {bspTransactionOutcomes = bspTransactionOutcomes bsp & Transactions.outcomeSpecial %~ (o :)}

doUpdateBirkParameters :: MonadBlobStore m => PersistentBlockState -> PersistentBirkParameters -> m PersistentBlockState
doUpdateBirkParameters pbs newBirk = do
        bsp <- loadPBS pbs
        storePBS pbs bsp {bspBirkParameters = newBirk}

doGetElectionDifficulty :: MonadBlobStore m => PersistentBlockState -> Timestamp -> m ElectionDifficulty
doGetElectionDifficulty pbs ts = do
        bsp <- loadPBS pbs
        futureElectionDifficulty (bspUpdates bsp) ts

doGetNextUpdateSequenceNumber :: MonadBlobStore m => PersistentBlockState -> UpdateType -> m UpdateSequenceNumber
doGetNextUpdateSequenceNumber pbs uty = do
        bsp <- loadPBS pbs
        lookupNextUpdateSequenceNumber (bspUpdates bsp) uty

doGetCurrentElectionDifficulty :: MonadBlobStore m => PersistentBlockState -> m ElectionDifficulty
doGetCurrentElectionDifficulty pbs = do
        bsp <- loadPBS pbs
        upds <- refLoad (bspUpdates bsp)
        _cpElectionDifficulty . unStoreSerialized <$> refLoad (currentParameters upds)

doGetUpdates :: MonadBlobStore m => PersistentBlockState -> m Basic.Updates
doGetUpdates = makeBasicUpdates <=< refLoad . bspUpdates <=< loadPBS

doProcessUpdateQueues :: MonadBlobStore m => PersistentBlockState -> Timestamp -> m PersistentBlockState
doProcessUpdateQueues pbs ts = do
        bsp <- loadPBS pbs
        u' <- processUpdateQueues ts (bspUpdates bsp)
        storePBS pbs bsp{bspUpdates = u'}

doProcessReleaseSchedule :: MonadBlobStore m => PersistentBlockState -> Timestamp -> m PersistentBlockState
doProcessReleaseSchedule pbs ts = do
        bsp <- loadPBS pbs
        releaseSchedule <- loadBufferedRef (bspReleaseSchedule bsp)
        if Map.null releaseSchedule
          then return pbs
          else do
          let (accountsToRemove, blockReleaseSchedule') = Map.partition (<= ts) releaseSchedule
              f (ba, readded) addr = do
                let upd acc = do
                      rData <- loadBufferedRef (acc ^. accountReleaseSchedule)
                      let (_, rData') = TransientReleaseSchedule.unlockAmountsUntil ts rData
                      rDataRef <- makeBufferedRef rData'
                      pData <- loadBufferedRef (acc ^. persistingData)
                      eData <- loadPersistentAccountEncryptedAmount =<< loadBufferedRef (acc ^. accountEncryptedAmount)
                      return $ (Map.lookupMin . undefined -- TransientReleaseSchedule._pendingReleases
                                $ rData',
                                acc & accountReleaseSchedule .~ rDataRef
                                    & accountHash .~ makeAccountHash (_accountNonce acc) (_accountAmount acc) eData rData' pData)
                (toRead, ba') <- Accounts.updateAccounts upd addr ba
                return (ba', case join toRead of
                               Just (t, _) -> (addr, t) : readded
                               Nothing -> readded)
          (bspAccounts', accsToReadd) <- foldlM f (bspAccounts bsp, []) (Map.keys accountsToRemove)
          bspReleaseSchedule' <- makeBufferedRef $ foldl' (\b (a, t) -> Map.insert a t b) blockReleaseSchedule' accsToReadd
          storePBS pbs (bsp {bspAccounts = bspAccounts', bspReleaseSchedule = bspReleaseSchedule'})

doGetCurrentAuthorizations :: MonadBlobStore m => PersistentBlockState -> m Authorizations
doGetCurrentAuthorizations pbs = do
        bsp <- loadPBS pbs
        u <- refLoad (bspUpdates bsp)
        unStoreSerialized <$> refLoad (currentAuthorizations u)

doEnqueueUpdate :: MonadBlobStore m => PersistentBlockState -> TransactionTime -> UpdatePayload -> m PersistentBlockState
doEnqueueUpdate pbs effectiveTime payload = do
        bsp <- loadPBS pbs
        u' <- enqueueUpdate effectiveTime payload (bspUpdates bsp)
        storePBS pbs bsp{bspUpdates = u'}

doAddReleaseSchedule :: MonadBlobStore m => PersistentBlockState -> [(AccountAddress, Timestamp)] -> m PersistentBlockState
doAddReleaseSchedule pbs rel = do
        bsp <- loadPBS pbs
        releaseSchedule <- loadBufferedRef (bspReleaseSchedule bsp)
        let f relSchedule (addr, t) = Map.alter (\case
                                                    Nothing -> Just t
                                                    Just t' -> Just $ min t' t) addr relSchedule
        bspReleaseSchedule' <- makeBufferedRef $ foldl' f releaseSchedule rel
        storePBS pbs bsp {bspReleaseSchedule = bspReleaseSchedule'}

doGetEnergyRate :: MonadBlobStore m => PersistentBlockState -> m EnergyRate
doGetEnergyRate pbs = do
    bsp <- loadPBS pbs
    lookupEnergyRate (bspUpdates bsp)

newtype PersistentBlockStateContext = PersistentBlockStateContext {
    pbscBlobStore :: BlobStore
}

instance HasBlobStore PersistentBlockStateContext where
    blobStore = pbscBlobStore

newtype PersistentBlockStateMonad r m a = PersistentBlockStateMonad {runPersistentBlockStateMonad :: m a}
    deriving (Functor, Applicative, Monad, MonadIO, MonadReader r, MonadLogger)

type PersistentState r m = (MonadIO m, MonadReader r m, HasBlobStore r)

instance PersistentState r m => MonadBlobStore (PersistentBlockStateMonad r m)

type instance BlockStatePointer PersistentBlockState = BlobRef BlockStatePointers
type instance BlockStatePointer HashedPersistentBlockState = BlobRef BlockStatePointers

instance BlockStateTypes (PersistentBlockStateMonad r m) where
    type BlockState (PersistentBlockStateMonad r m) = HashedPersistentBlockState
    type UpdatableBlockState (PersistentBlockStateMonad r m) = PersistentBlockState
    type BirkParameters (PersistentBlockStateMonad r m) = PersistentBirkParameters
    type Bakers (PersistentBlockStateMonad r m) = PersistentBakers
    type Account (PersistentBlockStateMonad r m) = PersistentAccount

instance PersistentState r m => BirkParametersOperations (PersistentBlockStateMonad r m) where

    getSeedState bps = return $ _birkSeedState bps

    updateBirkParametersForNewEpoch seedState bps = do
        currentBakers <- makeBufferedRef $ bps ^. birkCurrentBakers
        return $ bps &
            birkSeedState .~ seedState &
            -- use stake distribution saved from the former epoch for leader election
            birkLotteryBakers .~ (bps ^. birkPrevEpochBakers) &
            -- save the stake distribution from the end of the epoch
            birkPrevEpochBakers .~ currentBakers

    getCurrentBakers = return . _birkCurrentBakers

    getLotteryBakers = loadBufferedRef . _birkLotteryBakers

    updateSeedState f bps = return $ bps & birkSeedState %~ f

instance PersistentState r m => BlockStateQuery (PersistentBlockStateMonad r m) where
    getModule = doGetModule . hpbsPointers
    getAccount = doGetAccount . hpbsPointers
    getContractInstance = doGetInstance . hpbsPointers
    getModuleList = doGetModuleList . hpbsPointers
    getAccountList = doAccountList . hpbsPointers
    getContractInstanceList = doContractInstanceList . hpbsPointers
    getBlockBirkParameters = doGetBlockBirkParameters . hpbsPointers
    getRewardStatus = doGetRewardStatus . hpbsPointers
    getTransactionOutcome = doGetTransactionOutcome . hpbsPointers
    getTransactionOutcomesHash = doGetTransactionOutcomesHash . hpbsPointers
    getStateHash = return . hpbsHash
    getSpecialOutcomes = doGetSpecialOutcomes . hpbsPointers
    getOutcomes = doGetOutcomes . hpbsPointers
    getAllIdentityProviders = doGetAllIdentityProvider . hpbsPointers
    getAllAnonymityRevokers = doGetAllAnonymityRevokers . hpbsPointers
    getElectionDifficulty = doGetElectionDifficulty . hpbsPointers
    getNextUpdateSequenceNumber = doGetNextUpdateSequenceNumber . hpbsPointers
    getCurrentElectionDifficulty = doGetCurrentElectionDifficulty . hpbsPointers
    getUpdates = doGetUpdates . hpbsPointers
    getCryptographicParameters = doGetCryptoParams . hpbsPointers

doGetBakerStake :: MonadBlobStore m => PersistentBakers -> BakerId -> m (Maybe Amount)
doGetBakerStake bs bid =
    L.lookup bid (bs ^. bakerMap) >>= \case
      Just (Some (_, s)) -> return (Just s)
      _ -> return Nothing

instance PersistentState r m => BakerQuery (PersistentBlockStateMonad r m) where

  getBakerStake = doGetBakerStake

  getBakerFromKey bs k = return $ bs ^. bakersByKey . at' k

  getTotalBakerStake bs = return $ bs ^. bakerTotalStake

  getBakerInfo bs bid = L.lookup bid (bs ^. bakerMap) >>= \case
    Just (Some (bInfoRef, _)) -> Just <$> loadBufferedRef bInfoRef
    _ -> return Nothing

  getFullBakerInfos PersistentBakers {..} = do
    l <- L.toAscPairList _bakerMap
    Map.fromAscList <$> mapM getFullInfo [(i, x) | (i, Some x) <- l]
    where
      getFullInfo (i, (binfoRef, stake)) = do
        binfo <- loadBufferedRef binfoRef
        return (i, FullBakerInfo binfo stake)

instance PersistentState r m => AccountOperations (PersistentBlockStateMonad r m) where

  getAccountAddress acc = acc ^^. accountAddress

  getAccountAmount acc = return $ acc ^. accountAmount

  getAccountNonce acc = return $ acc ^. accountNonce

  getAccountCredentials acc = acc ^^. accountCredentials

  getAccountMaxCredentialValidTo acc = acc ^^. accountMaxCredentialValidTo

  getAccountVerificationKeys acc = acc ^^. accountVerificationKeys

  getAccountEncryptedAmount acc = loadPersistentAccountEncryptedAmount =<< loadBufferedRef (acc ^. accountEncryptedAmount)

  getAccountEncryptionKey acc = acc ^^. accountEncryptionKey

  getAccountStakeDelegate acc = acc ^^. accountStakeDelegate

  getAccountReleaseSchedule acc = loadBufferedRef (acc ^. accountReleaseSchedule)

  getAccountInstances acc = acc ^^. accountInstances

  createNewAccount cryptoParams _accountVerificationKeys _accountAddress cdv = do
      let pData = PersistingAccountData {
                    _accountEncryptionKey = ID.makeEncryptionKey cryptoParams (ID.regId cdv),
                    _accountCredentials = [cdv],
                    _accountMaxCredentialValidTo = ID.validTo cdv,
                    _accountStakeDelegate = Nothing,
                    _accountInstances = Set.empty,
                    ..
                  }
          _accountNonce = minNonce
          _accountAmount = 0
      accountEncryptedAmountData <- initialPersistentAccountEncryptedAmount
      baseEncryptedAmountData <- loadPersistentAccountEncryptedAmount accountEncryptedAmountData
      _accountEncryptedAmount <- makeBufferedRef accountEncryptedAmountData
      let accountReleaseScheduleData = TransientReleaseSchedule.emptyAccountReleaseSchedule
      _accountReleaseSchedule <- makeBufferedRef accountReleaseScheduleData
      _persistingData <- makeBufferedRef pData
      let _accountHash = makeAccountHash _accountNonce _accountAmount baseEncryptedAmountData accountReleaseScheduleData pData
      return $ PersistentAccount {..}

  updateAccountAmount acc amnt = do
    let newAcc@PersistentAccount{..} = acc & accountAmount .~ amnt
    pData <- loadBufferedRef _persistingData
    encData <- loadPersistentAccountEncryptedAmount =<< loadBufferedRef _accountEncryptedAmount
    rsData <- loadBufferedRef _accountReleaseSchedule
    return $ newAcc & accountHash .~ makeAccountHash _accountNonce amnt encData rsData pData

instance PersistentState r m => BlockStateOperations (PersistentBlockStateMonad r m) where
    bsoGetModule pbs mref = fmap moduleInterface <$> doGetModule pbs mref
    bsoGetAccount = doGetAccount
    bsoGetInstance = doGetInstance
    bsoRegIdExists = doRegIdExists
    bsoPutNewAccount = doPutNewAccount
    bsoPutNewInstance = doPutNewInstance
    bsoPutNewModule = doPutNewModule
    bsoModifyAccount = doModifyAccount
    bsoModifyInstance = doModifyInstance
    bsoNotifyExecutionCost = doNotifyExecutionCost
    bsoNotifyEncryptedBalanceChange = doNotifyEncryptedBalanceChange
    bsoNotifyIdentityIssuerCredential = doNotifyIdentityIssuerCredential
    bsoGetExecutionCost = doGetExecutionCost
    bsoGetBlockBirkParameters = doGetBlockBirkParameters
    bsoAddBaker = doAddBaker
    bsoUpdateBaker = doUpdateBaker
    bsoRemoveBaker = doRemoveBaker
    bsoSetInflation = doSetInflation
    bsoMint = doMint
    bsoDecrementCentralBankGTU = doDecrementCentralBankGTU
    bsoDelegateStake = doDelegateStake
    bsoGetIdentityProvider = doGetIdentityProvider
    bsoGetAnonymityRevokers = doGetAnonymityRevokers
    bsoGetCryptoParams = doGetCryptoParams
    bsoSetTransactionOutcomes = doSetTransactionOutcomes
    bsoAddSpecialTransactionOutcome = doAddSpecialTransactionOutcome
    bsoUpdateBirkParameters = doUpdateBirkParameters
    bsoProcessUpdateQueues = doProcessUpdateQueues
    bsoProcessReleaseSchedule = doProcessReleaseSchedule
    bsoGetCurrentAuthorizations = doGetCurrentAuthorizations
    bsoGetNextUpdateSequenceNumber = doGetNextUpdateSequenceNumber
    bsoEnqueueUpdate = doEnqueueUpdate
    bsoAddReleaseSchedule = doAddReleaseSchedule
    bsoGetEnergyRate = doGetEnergyRate

instance PersistentState r m => BlockStateStorage (PersistentBlockStateMonad r m) where
    thawBlockState HashedPersistentBlockState{..} = do
            bsp <- loadPBS hpbsPointers
            pbsp <- makeBufferedRef bsp {
                        bspBank = bspBank bsp & unhashed . Rewards.executionCost .~ 0 & unhashed . Rewards.identityIssuersRewards .~ HM.empty
                    }
            liftIO $ newIORef $! pbsp

    freezeBlockState pbs = hashBlockState pbs

    dropUpdatableBlockState pbs = liftIO $ writeIORef pbs (error "Block state dropped")

    purgeBlockState pbs = liftIO $ writeIORef (hpbsPointers pbs) (error "Block state purged")

    archiveBlockState HashedPersistentBlockState{..} = do
        inner <- liftIO $ readIORef hpbsPointers
        inner' <- uncacheBuffered inner
        liftIO $ writeIORef hpbsPointers inner'

    saveBlockState HashedPersistentBlockState{..} = do
        inner <- liftIO $ readIORef hpbsPointers
        (inner', ref) <- flushBufferedRef inner
        liftIO $ writeIORef hpbsPointers inner'
        flushStore
        return ref

    loadBlockState hpbsHash ref = do
        hpbsPointers <- liftIO $ newIORef $ BRBlobbed ref
        return HashedPersistentBlockState{..}

    cacheBlockState pbs@HashedPersistentBlockState{..} = do
        bsp <- liftIO $ readIORef hpbsPointers
        bsp' <- cache bsp
        liftIO $ writeIORef hpbsPointers bsp'
        return pbs
