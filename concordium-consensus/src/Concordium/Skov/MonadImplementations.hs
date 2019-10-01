{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies, DerivingStrategies, DerivingVia, FlexibleInstances, MultiParamTypeClasses, UndecidableInstances, StandaloneDeriving #-}
{-# LANGUAGE LambdaCase, RecordWildCards, TupleSections #-}
{-# LANGUAGE TemplateHaskell, CPP #-}
module Concordium.Skov.MonadImplementations where

import Control.Monad
import Control.Monad.Trans.State.Strict hiding (gets)
import Control.Monad.State.Class
import Control.Monad.State.Strict
import Control.Monad.RWS.Strict
import Lens.Micro.Platform
import Data.Time.Clock (NominalDiffTime)
import Data.Semigroup

import Concordium.GlobalState.Finalization
import Concordium.GlobalState.BlockState
import Concordium.GlobalState.TreeState
import Concordium.GlobalState.Parameters
import qualified Concordium.GlobalState.Implementation.TreeState as Impl
import qualified Concordium.GlobalState.Implementation.Block as Impl
import qualified Concordium.GlobalState.Implementation.BlockState as Impl
import qualified Concordium.GlobalState.Implementation as Impl
import Concordium.Skov.Monad
import Concordium.Skov.Query
import Concordium.Skov.Update
import Concordium.Skov.Hooks
import Concordium.Logger
import Concordium.TimeMonad
import Concordium.Afgjort.Finalize
import Concordium.Afgjort.Buffer

data FinalizationOutputEvent
    = BroadcastFinalizationMessage !FinalizationMessage
    | BroadcastFinalizationRecord !FinalizationRecord

-- |An instance of 'FinalizationEvent' can be constructed from a
-- 'FinalizationOutputEvent'.  These events are generated by finalization.
class FinalizationEvent w where
    embedFinalizationEvent :: FinalizationOutputEvent -> w
    embedCatchUpTimerEvent :: Maybe NominalDiffTime -> w
    extractFinalizationOutputEvents :: w -> [FinalizationOutputEvent]
    extractCatchUpTimer :: w -> Maybe (Maybe NominalDiffTime)

class FinalizationEvent w => BufferedFinalizationEvent w where
    embedNotifyEvent :: NotifyEvent -> w
    extractNotifyEvents :: w -> [NotifyEvent]

newtype SkovFinalizationEvents = SkovFinalizationEvents (Endo [FinalizationOutputEvent], Maybe (Maybe (Min NominalDiffTime)))
    deriving (Semigroup, Monoid)

instance FinalizationEvent SkovFinalizationEvents where
    embedFinalizationEvent = SkovFinalizationEvents . (, mempty) . Endo . (:)
    embedCatchUpTimerEvent = SkovFinalizationEvents . (mempty, ) . Just . fmap Min
    extractFinalizationOutputEvents (SkovFinalizationEvents (Endo f, _)) = f []
    extractCatchUpTimer (SkovFinalizationEvents (_, z)) = fmap (fmap getMin) z

newtype BufferedSkovFinalizationEvents = BufferedSkovFinalizationEvents (Endo [FinalizationOutputEvent], Maybe (Maybe (Min NominalDiffTime)), Endo [NotifyEvent])
    deriving (Semigroup, Monoid)

instance FinalizationEvent BufferedSkovFinalizationEvents where
    embedFinalizationEvent = BufferedSkovFinalizationEvents . (, mempty, mempty) . Endo . (:)
    embedCatchUpTimerEvent = BufferedSkovFinalizationEvents . (mempty, , mempty) . Just . fmap Min
    extractFinalizationOutputEvents (BufferedSkovFinalizationEvents (Endo f, _, _)) = f []
    extractCatchUpTimer (BufferedSkovFinalizationEvents (_, z, _)) = fmap (fmap getMin) z

instance BufferedFinalizationEvent BufferedSkovFinalizationEvents where
    embedNotifyEvent = BufferedSkovFinalizationEvents . (mempty, mempty, ) . Endo . (:)
    extractNotifyEvents (BufferedSkovFinalizationEvents (_, _, Endo f)) = f []



-- |This wrapper endows a monad that implements 'TreeStateMonad' with
-- an instance of 'SkovQueryMonad'.
newtype TSSkovWrapper m a = TSSkovWrapper {runTSSkovWrapper :: m a}
    deriving (Functor, Applicative, Monad, BlockStateOperations, BlockStateQuery, TreeStateMonad, TimeMonad, LoggerMonad)
type instance BlockPointer (TSSkovWrapper m) = BlockPointer m
type instance UpdatableBlockState (TSSkovWrapper m) = UpdatableBlockState m
type instance PendingBlock (TSSkovWrapper m) = PendingBlock m

instance (TreeStateMonad m) => SkovQueryMonad (TSSkovWrapper m) where
    {-# INLINE resolveBlock #-}
    resolveBlock = doResolveBlock
    {-# INLINE isFinalized #-}
    isFinalized = doIsFinalized
    {-# INLINE lastFinalizedBlock #-}
    lastFinalizedBlock = fst <$> getLastFinalized
    {-# INLINE getBirkParameters #-}
    getBirkParameters = doGetBirkParameters
    {-# INLINE getGenesisData #-}
    getGenesisData = Concordium.GlobalState.TreeState.getGenesisData
    {-# INLINE genesisBlock #-}
    genesisBlock = getGenesisBlockPointer
    {-# INLINE getCurrentHeight #-}
    getCurrentHeight = doGetCurrentHeight
    {-# INLINE branchesFromTop #-}
    branchesFromTop = doBranchesFromTop
    {-# INLINE getBlocksAtHeight #-}
    getBlocksAtHeight = doGetBlocksAtHeight

newtype TSSkovUpdateWrapper s m a = TSSkovUpdateWrapper {runTSSkovUpdateWrapper :: m a}
    deriving (Functor, Applicative, Monad, BlockStateOperations,
            BlockStateQuery, TreeStateMonad, TimeMonad, LoggerMonad,
            MonadState s, MonadIO)
    deriving SkovQueryMonad via (TSSkovWrapper m)
type instance BlockPointer (TSSkovUpdateWrapper s m) = BlockPointer m
type instance UpdatableBlockState (TSSkovUpdateWrapper s m) = UpdatableBlockState m
type instance PendingBlock (TSSkovUpdateWrapper s m) = PendingBlock m

instance (Monad m, OnSkov m) => OnSkov (TSSkovUpdateWrapper s m) where
  {-# INLINE onBlock #-}
  onBlock bp = TSSkovUpdateWrapper (onBlock bp)
  {-# INLINE onFinalize #-}
  onFinalize fin bp = TSSkovUpdateWrapper (onFinalize fin bp)
  {-# INLINE logTransfer #-}
  logTransfer = TSSkovUpdateWrapper $ do
    logTransfer >>= \case
      Nothing -> return Nothing
      Just lm -> return (Just (\bh slot reason -> TSSkovUpdateWrapper (lm bh slot reason)))

instance (TimeMonad m, LoggerMonad m, TreeStateMonad m, MonadIO m,
        MonadState s m, OnSkov m)
            => SkovMonad (TSSkovUpdateWrapper s m) where
    storeBlock = doStoreBlock
    storeBakedBlock = doStoreBakedBlock
    receiveTransaction tr = doReceiveTransaction tr 0
    finalizeBlock = doFinalizeBlock

-- |The 'SkovQueryM' wraps 'StateT' to provide an instance of 'SkovQueryMonad'
-- when the state implements 'SkovLenses'.
newtype SkovQueryM s m a = SkovQueryM {runSkovQueryM :: StateT s m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState s)
    deriving BlockStateQuery via (Impl.SkovTreeState s (StateT s m))
    deriving BlockStateOperations via (Impl.SkovTreeState s (StateT s m))
    deriving TreeStateMonad via (Impl.SkovTreeState s (StateT s m))
    deriving SkovQueryMonad via (TSSkovWrapper (Impl.SkovTreeState s (StateT s m)))
-- UndecidableInstances is required to allow these type instance declarations.
type instance BlockPointer (SkovQueryM s m) = BlockPointer (Impl.SkovTreeState s (StateT s m))
type instance UpdatableBlockState (SkovQueryM s m) = UpdatableBlockState (Impl.SkovTreeState s (StateT s m))
type instance PendingBlock (SkovQueryM s m) = PendingBlock (Impl.SkovTreeState s (StateT s m))



-- |Evaluate an action in the 'SkovQueryM'.  This is intended for
-- running queries against the state (i.e. with no updating side-effects).
evalSkovQueryM :: (Monad m) => SkovQueryM s m a -> s -> m a
evalSkovQueryM (SkovQueryM a) st = evalStateT a st

-- * Without transaction hooks

-- |Skov state without finalizion.
data SkovPassiveState = SkovPassiveState {
    _spsSkov :: !Impl.SkovData,
    _spsFinalization :: !PassiveFinalizationState
}
makeLenses ''SkovPassiveState

instance Impl.SkovLenses SkovPassiveState where
    skov = spsSkov
instance PassiveFinalizationStateLenses SkovPassiveState where
    pfinState = spsFinalization

#ifdef RUST
initialSkovPassiveState :: RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> IO SkovPassiveState
initialSkovPassiveState rtParams gen initBS gsptr = do
  _spsSkov <- Impl.initialSkovData rtParams gen initBS gsptr
  let _spsFinalization = initialPassiveFinalizationState (bpHash (Impl._skovGenesisBlockPointer _spsSkov))
  return SkovPassiveState{..}
#else
initialSkovPassiveState :: RuntimeParameters -> GenesisData -> Impl.BlockState -> IO SkovPassiveState
initialSkovPassiveState rtParams gen initBS = do
  let _spsSkov = Impl.initialSkovData rtParams gen initBS
      _spsFinalization = initialPassiveFinalizationState (bpHash (Impl._skovGenesisBlockPointer _spsSkov))
  return SkovPassiveState{..}
#endif

newtype SkovPassiveM m a = SkovPassiveM {unSkovPassiveM :: StateT SkovPassiveState m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovPassiveState, MonadIO)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovPassiveState (SkovPassiveM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovPassiveState (SkovPassiveM m))
type instance UpdatableBlockState (SkovPassiveM m) = Impl.BlockState
type instance BlockPointer (SkovPassiveM m) = Impl.BlockPointer
type instance PendingBlock (SkovPassiveM m) = Impl.PendingBlock

instance Monad m => OnSkov (SkovPassiveM m) where
    {-# INLINE onBlock #-}
    onBlock _ = return ()
    {-# INLINE onFinalize #-}
    onFinalize fr _ = spsFinalization %= execState (passiveNotifyBlockFinalized fr)
    {-# INLINE logTransfer #-}
    logTransfer = return Nothing

#ifdef RUST
evalSkovPassiveM :: (MonadIO m) => SkovPassiveM m a -> RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> m a
evalSkovPassiveM (SkovPassiveM a) rtParams gd bs0 gsptr = do
  initialState <- liftIO $ initialSkovPassiveState rtParams gd bs0 gsptr
  evalStateT a initialState
#else
evalSkovPassiveM :: (MonadIO m) => SkovPassiveM m a -> RuntimeParameters -> GenesisData -> Impl.BlockState -> m a
evalSkovPassiveM (SkovPassiveM a) rtParams gd bs0 = do
  initialState <- liftIO $ initialSkovPassiveState rtParams gd bs0
  evalStateT a initialState
#endif


runSkovPassiveM :: SkovPassiveM m a -> SkovPassiveState -> m (a, SkovPassiveState)
runSkovPassiveM (SkovPassiveM a) s = runStateT a s


-- |Skov state with active finalization.
data SkovActiveState = SkovActiveState {
    _sasSkov :: !Impl.SkovData,
    _sasFinalization :: !FinalizationState
}
makeLenses ''SkovActiveState

instance Impl.SkovLenses SkovActiveState where
    skov = sasSkov
instance FinalizationStateLenses SkovActiveState where
    finState = sasFinalization

#ifdef RUST
initialSkovActiveState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> IO SkovActiveState
initialSkovActiveState finInst rtParams gen initBS gsptr = do
  _sasSkov <- Impl.initialSkovData rtParams gen initBS gsptr
  let _sasFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sasSkov)) (genesisFinalizationParameters gen)
  return SkovActiveState{..}
#else
initialSkovActiveState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> IO SkovActiveState
initialSkovActiveState finInst rtParams gen initBS = do
  let _sasSkov = Impl.initialSkovData rtParams gen initBS
      _sasFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sasSkov)) (genesisFinalizationParameters gen)
  return SkovActiveState{..}
#endif

newtype SkovActiveM m a = SkovActiveM {unSkovActiveM :: RWST FinalizationInstance SkovFinalizationEvents SkovActiveState m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovActiveState, MonadReader FinalizationInstance, MonadWriter SkovFinalizationEvents, MonadIO)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovActiveState (SkovActiveM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovActiveState (SkovActiveM m) )
type instance UpdatableBlockState (SkovActiveM m) = Impl.BlockState
type instance BlockPointer (SkovActiveM m) = Impl.BlockPointer
type instance PendingBlock (SkovActiveM m) = Impl.PendingBlock
instance (TimeMonad m, LoggerMonad m, MonadIO m) => OnSkov (SkovActiveM m) where
    {-# INLINE onBlock #-}
    onBlock = notifyBlockArrival
    {-# INLINE onFinalize #-}
    onFinalize = notifyBlockFinalized
    {-# INLINE logTransfer #-}
    logTransfer = return Nothing

instance (TimeMonad m, LoggerMonad m, MonadIO m)
            => FinalizationMonad SkovActiveState (SkovActiveM m) where
    broadcastFinalizationMessage = tell . embedFinalizationEvent . BroadcastFinalizationMessage
    broadcastFinalizationRecord = tell . embedFinalizationEvent . BroadcastFinalizationRecord
    getFinalizationInstance = ask
    resetCatchUpTimer = tell . embedCatchUpTimerEvent

runSkovActiveM :: SkovActiveM m a -> FinalizationInstance -> SkovActiveState -> m (a, SkovActiveState, SkovFinalizationEvents)
runSkovActiveM (SkovActiveM a) fi fs = runRWST a fi fs

-- |Skov state with buffered finalization.
data SkovBufferedState = SkovBufferedState {
    _sbsSkov :: !Impl.SkovData,
    _sbsFinalization :: !FinalizationState,
    _sbsBuffer :: !FinalizationBuffer
}
makeLenses ''SkovBufferedState

instance Impl.SkovLenses SkovBufferedState where
    skov = sbsSkov
instance FinalizationStateLenses SkovBufferedState where
    finState = sbsFinalization
instance FinalizationBufferLenses SkovBufferedState where
    finBuffer = sbsBuffer

#ifdef RUST
initialSkovBufferedState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> IO SkovBufferedState
initialSkovBufferedState finInst rtParams gen initBS gsptr = do
  _sbsSkov <- Impl.initialSkovData rtParams gen initBS gsptr
  let _sbsFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sbsSkov)) (genesisFinalizationParameters gen)
  return SkovBufferedState{..}
    where
        _sbsBuffer = emptyFinalizationBuffer
#else
initialSkovBufferedState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> IO SkovBufferedState
initialSkovBufferedState finInst rtParams gen initBS = do
  let _sbsSkov = Impl.initialSkovData rtParams gen initBS
      _sbsFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sbsSkov)) (genesisFinalizationParameters gen)
  return SkovBufferedState{..}
    where
        _sbsBuffer = emptyFinalizationBuffer
#endif

newtype SkovBufferedM m a = SkovBufferedM {unSkovBufferedM :: RWST FinalizationInstance BufferedSkovFinalizationEvents SkovBufferedState m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovBufferedState, MonadReader FinalizationInstance, MonadWriter BufferedSkovFinalizationEvents, MonadIO)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovBufferedState (SkovBufferedM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovBufferedState (SkovBufferedM m))
type instance UpdatableBlockState (SkovBufferedM m) = Impl.BlockState
type instance BlockPointer (SkovBufferedM m) = Impl.BlockPointer
type instance PendingBlock (SkovBufferedM m) = Impl.PendingBlock
instance (TimeMonad m, LoggerMonad m, MonadIO m) => OnSkov (SkovBufferedM m) where
    {-# INLINE onBlock #-}
    onBlock = notifyBlockArrival
    {-# INLINE onFinalize #-}
    onFinalize = notifyBlockFinalized
    {-# INLINE logTransfer #-}
    logTransfer = return Nothing

instance (TimeMonad m, LoggerMonad m, MonadIO m)
            => FinalizationMonad SkovBufferedState (SkovBufferedM m) where
    broadcastFinalizationMessage msg = bufferFinalizationMessage msg >>= \case
            Left n -> tell $ embedNotifyEvent n
            Right msgs -> forM_ msgs $ tell . embedFinalizationEvent . BroadcastFinalizationMessage
    broadcastFinalizationRecord = tell . embedFinalizationEvent . BroadcastFinalizationRecord
    getFinalizationInstance = ask
    resetCatchUpTimer = tell . embedCatchUpTimerEvent

runSkovBufferedM :: SkovBufferedM m a -> FinalizationInstance -> SkovBufferedState -> m (a, SkovBufferedState, BufferedSkovFinalizationEvents)
runSkovBufferedM (SkovBufferedM a) fi fs = runRWST a fi fs


-- * With transaction hooks

-- |Skov state with passive finalizion and transaction hooks.
-- This keeps finalization messages, but does not process them.
data SkovPassiveHookedState = SkovPassiveHookedState {
    _sphsSkov :: !Impl.SkovData,
    _sphsFinalization :: !PassiveFinalizationState,
    _sphsHooks :: !TransactionHooks
}
makeLenses ''SkovPassiveHookedState

instance Impl.SkovLenses SkovPassiveHookedState where
    skov = sphsSkov
instance PassiveFinalizationStateLenses SkovPassiveHookedState where
    pfinState = sphsFinalization
instance TransactionHookLenses SkovPassiveHookedState where
    hooks = sphsHooks

#ifdef RUST
initialSkovPassiveHookedState :: RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> IO SkovPassiveHookedState
initialSkovPassiveHookedState rtParams gen initBS gsptr = do
  _sphsSkov <- Impl.initialSkovData rtParams gen initBS gsptr
  let _sphsFinalization = initialPassiveFinalizationState (bpHash (Impl._skovGenesisBlockPointer _sphsSkov))
  return SkovPassiveHookedState{..}
  where
        _sphsHooks = emptyHooks
#else
initialSkovPassiveHookedState :: RuntimeParameters -> GenesisData -> Impl.BlockState -> IO SkovPassiveHookedState
initialSkovPassiveHookedState rtParams gen initBS = do
  let _sphsSkov = Impl.initialSkovData rtParams gen initBS
      _sphsFinalization = initialPassiveFinalizationState (bpHash (Impl._skovGenesisBlockPointer _sphsSkov))
  return SkovPassiveHookedState{..}
  where
        _sphsHooks = emptyHooks
#endif

newtype SkovPassiveHookedM m a = SkovPassiveHookedM {unSkovPassiveHookedM :: StateT SkovPassiveHookedState m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovPassiveHookedState, MonadIO)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovPassiveHookedState (SkovPassiveHookedM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovPassiveHookedState (SkovPassiveHookedM m))
type instance UpdatableBlockState (SkovPassiveHookedM m) = Impl.BlockState
type instance BlockPointer (SkovPassiveHookedM m) = Impl.BlockPointer
type instance PendingBlock (SkovPassiveHookedM m) = Impl.PendingBlock

instance (TimeMonad m, MonadIO m, LoggerMonad m) => OnSkov (SkovPassiveHookedM m) where
    {-# INLINE onBlock #-}
    onBlock bp = hookOnBlock bp
    {-# INLINE onFinalize #-}
    onFinalize fr bp = do
        sphsFinalization %= execState (passiveNotifyBlockFinalized fr)
        hookOnFinalize fr bp
    {-# INLINE logTransfer #-}
    logTransfer = return Nothing

#ifdef RUST
evalSkovPassiveHookedM :: (MonadIO m) => SkovPassiveHookedM m a -> RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> m a
evalSkovPassiveHookedM (SkovPassiveHookedM a) rtParams gd bs0 gsptr = do
  initialState <- liftIO $ initialSkovPassiveHookedState rtParams gd bs0 gsptr
  evalStateT a initialState
#else
evalSkovPassiveHookedM :: (MonadIO m) => SkovPassiveHookedM m a -> RuntimeParameters -> GenesisData -> Impl.BlockState -> m a
evalSkovPassiveHookedM (SkovPassiveHookedM a) rtParams gd bs0 = do
  initialState <- liftIO $ initialSkovPassiveHookedState rtParams gd bs0
  evalStateT a initialState
#endif
runSkovPassiveHookedM :: SkovPassiveHookedM m a -> SkovPassiveHookedState -> m (a, SkovPassiveHookedState)
runSkovPassiveHookedM (SkovPassiveHookedM a) s = runStateT a s

-- |Skov state with buffered finalization and transaction hooks.
data SkovBufferedHookedState = SkovBufferedHookedState {
    _sbhsSkov :: !Impl.SkovData,
    _sbhsFinalization :: !FinalizationState,
    _sbhsBuffer :: !FinalizationBuffer,
    _sbhsHooks :: !TransactionHooks
}
makeLenses ''SkovBufferedHookedState

instance Impl.SkovLenses SkovBufferedHookedState where
    skov = sbhsSkov
instance FinalizationStateLenses SkovBufferedHookedState where
    finState = sbhsFinalization
instance FinalizationBufferLenses SkovBufferedHookedState where
    finBuffer = sbhsBuffer
instance TransactionHookLenses SkovBufferedHookedState where
    hooks = sbhsHooks

#ifdef RUST
initialSkovBufferedHookedState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> Impl.GlobalStatePtr -> IO SkovBufferedHookedState
initialSkovBufferedHookedState finInst rtParams gen initBS gsptr = do
  _sbhsSkov <- Impl.initialSkovData rtParams gen initBS gsptr
  let _sbhsFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sbhsSkov)) (genesisFinalizationParameters gen)
  return SkovBufferedHookedState{..}
  where
        _sbhsBuffer = emptyFinalizationBuffer
        _sbhsHooks = emptyHooks
#else
initialSkovBufferedHookedState :: FinalizationInstance -> RuntimeParameters -> GenesisData -> Impl.BlockState -> IO SkovBufferedHookedState
initialSkovBufferedHookedState finInst rtParams gen initBS = do
  let _sbhsSkov = Impl.initialSkovData rtParams gen initBS
      _sbhsFinalization = initialFinalizationState finInst (bpHash (Impl._skovGenesisBlockPointer _sbhsSkov)) (genesisFinalizationParameters gen)
  return SkovBufferedHookedState{..}
  where
        _sbhsBuffer = emptyFinalizationBuffer
        _sbhsHooks = emptyHooks
#endif

newtype SkovBufferedHookedM m a = SkovBufferedHookedM {unSkovBufferedHookedM :: RWST FinalizationInstance BufferedSkovFinalizationEvents SkovBufferedHookedState m a}
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovBufferedHookedState, MonadReader FinalizationInstance, MonadWriter BufferedSkovFinalizationEvents, MonadIO)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovBufferedHookedState (SkovBufferedHookedM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovBufferedHookedState (SkovBufferedHookedM m) )
type instance UpdatableBlockState (SkovBufferedHookedM m) = Impl.BlockState
type instance BlockPointer (SkovBufferedHookedM m) = Impl.BlockPointer
type instance PendingBlock (SkovBufferedHookedM m) = Impl.PendingBlock
instance (TimeMonad m, LoggerMonad m, MonadIO m) => OnSkov (SkovBufferedHookedM m) where
    {-# INLINE onBlock #-}
    onBlock bp = do
        notifyBlockArrival bp
        hookOnBlock bp
    {-# INLINE onFinalize #-}
    onFinalize bp fr = do
        notifyBlockFinalized bp fr
        hookOnFinalize bp fr
    {-# INLINE logTransfer #-}
    logTransfer = return Nothing

instance (TimeMonad m, LoggerMonad m, MonadIO m)
            => FinalizationMonad SkovBufferedHookedState (SkovBufferedHookedM m) where
    broadcastFinalizationMessage msg = bufferFinalizationMessage msg >>= \case
            Left n -> tell $ embedNotifyEvent n
            Right msgs -> forM_ msgs $ tell . embedFinalizationEvent . BroadcastFinalizationMessage
    broadcastFinalizationRecord = tell . embedFinalizationEvent . BroadcastFinalizationRecord
    getFinalizationInstance = ask
    resetCatchUpTimer = tell . embedCatchUpTimerEvent

runSkovBufferedHookedM :: SkovBufferedHookedM m a -> FinalizationInstance -> SkovBufferedHookedState -> m (a, SkovBufferedHookedState, BufferedSkovFinalizationEvents)
runSkovBufferedHookedM (SkovBufferedHookedM a) fi fs = runRWST a fi fs


newtype SkovBufferedHookedLoggedM m a = SkovBufferedHookedLoggedM {
  unSkovBufferedHookedLoggedM :: RWST (FinalizationInstance, Maybe (LogTransferMethod IO)) BufferedSkovFinalizationEvents SkovBufferedHookedState m a
  }
    deriving (Functor, Applicative, Monad, TimeMonad, LoggerMonad, MonadState SkovBufferedHookedState, MonadReader (FinalizationInstance, Maybe (LogTransferMethod IO)), MonadWriter BufferedSkovFinalizationEvents, MonadIO, ATLMonad)
    deriving (BlockStateQuery, BlockStateOperations, TreeStateMonad) via (Impl.SkovTreeState SkovBufferedHookedState (SkovBufferedHookedLoggedM m))
    deriving (SkovQueryMonad, SkovMonad) via (TSSkovUpdateWrapper SkovBufferedHookedState (SkovBufferedHookedLoggedM m) )
type instance UpdatableBlockState (SkovBufferedHookedLoggedM m) = Impl.BlockState
type instance BlockPointer (SkovBufferedHookedLoggedM m) = Impl.BlockPointer
type instance PendingBlock (SkovBufferedHookedLoggedM m) = Impl.PendingBlock
instance (TimeMonad m, LoggerMonad m, MonadIO m) => OnSkov (SkovBufferedHookedLoggedM m) where
    {-# INLINE onBlock #-}
    onBlock bp = do
        notifyBlockArrival bp
        hookOnBlock bp
    {-# INLINE onFinalize #-}
    onFinalize bp fr = do
        notifyBlockFinalized bp fr
        hookOnFinalize bp fr

    {-# INLINE logTransfer #-}
    logTransfer =
      asks snd >>= \case
        Nothing -> return Nothing
        Just lm -> return (Just (\bh slot reason -> liftIO (lm bh slot reason)))


instance (TimeMonad m, LoggerMonad m, MonadIO m)
            => FinalizationMonad SkovBufferedHookedState (SkovBufferedHookedLoggedM m) where
    broadcastFinalizationMessage msg = bufferFinalizationMessage msg >>= \case
            Left n -> tell $ embedNotifyEvent n
            Right msgs -> forM_ msgs $ tell . embedFinalizationEvent . BroadcastFinalizationMessage
    broadcastFinalizationRecord = tell . embedFinalizationEvent . BroadcastFinalizationRecord
    getFinalizationInstance = asks fst
    resetCatchUpTimer = tell . embedCatchUpTimerEvent

runSkovBufferedHookedLoggedM :: SkovBufferedHookedLoggedM m a -> FinalizationInstance -> Maybe (LogTransferMethod IO) -> SkovBufferedHookedState -> m (a, SkovBufferedHookedState, BufferedSkovFinalizationEvents)
runSkovBufferedHookedLoggedM (SkovBufferedHookedLoggedM a) fi tlog fs = do
  runRWST a (fi, tlog) fs
