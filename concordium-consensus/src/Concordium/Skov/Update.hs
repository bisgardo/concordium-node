{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies, DerivingStrategies, DerivingVia, UndecidableInstances, TemplateHaskell, StandaloneDeriving #-}
{-# LANGUAGE LambdaCase, ScopedTypeVariables, ViewPatterns, RecordWildCards, FlexibleContexts, FlexibleInstances, MultiParamTypeClasses #-}
module Concordium.Skov.Update where

import Control.Monad
import Control.Monad.RWS
import qualified Data.Sequence as Seq
import Lens.Micro.Platform
import Data.Foldable

import GHC.Stack

import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.GlobalState.TreeState
import Concordium.GlobalState.BlockState
import Concordium.GlobalState.Block
import Concordium.GlobalState.Finalization
import Concordium.GlobalState.Transactions
import Concordium.GlobalState.Parameters
import Concordium.GlobalState.Bakers

import Concordium.Scheduler.TreeStateEnvironment(executeFrom)


import Concordium.Skov.Monad
import Concordium.Birk.LeaderElection
import Concordium.Afgjort.Finalize
import Concordium.Afgjort.Buffer
import Concordium.Logger
import Concordium.TimeMonad
import Concordium.Skov.Statistics

-- |An instance of 'FinalizationEvent' can be constructed from a
-- 'FinalizationOutputEvent'.  These events are generated by finalization.
class FinalizationEvent w where
    embedFinalizationEvent :: FinalizationOutputEvent -> w

-- |An instance of 'MissingEvent' can be constructed to indicate
-- either a missing block (by 'BlockHash') or a missing finalization
-- record (by 'BlockHash' or by 'FinalizationIndex').
class MissingEvent w where
    -- |Given a block hash and a height delta, request a missing block
    -- that is descended from the given block by the delta.  When the
    -- delta is 0, this is just a request for the block itself.
    missingBlockEvent :: BlockHash -> BlockHeight -> w
    missingFinalizationEvent :: Either BlockHash FinalizationIndex -> w

class FinalizationEvent w => BufferedFinalizationEvent w where
    embedNotifyEvent :: NotifyEvent -> w

data SkovMissingEvent
    = SkovMissingBlock BlockHash BlockHeight
    | SkovMissingFinalization (Either BlockHash FinalizationIndex)

instance MissingEvent (Endo [SkovMissingEvent]) where
    missingBlockEvent bh delta = Endo (SkovMissingBlock bh delta :)
    missingFinalizationEvent = Endo . (:) . SkovMissingFinalization


-- |The output events that may arise from consensus and finalization.
-- These are finalization events and missing block/record events.
data SkovFinalizationEvent
    = SkovFinalization FinalizationOutputEvent
    | SkovMissing SkovMissingEvent

instance FinalizationEvent (Endo [SkovFinalizationEvent]) where
    embedFinalizationEvent = Endo . (:) . SkovFinalization

instance MissingEvent (Endo [SkovFinalizationEvent]) where
    missingBlockEvent bh delta = Endo (SkovMissing (SkovMissingBlock bh delta) :)
    missingFinalizationEvent = Endo . (:) . SkovMissing . SkovMissingFinalization

data BufferedSkovFinalizationEvent
    = BufferedEvent SkovFinalizationEvent
    | BufferNotification NotifyEvent

instance FinalizationEvent (Endo [BufferedSkovFinalizationEvent]) where
    embedFinalizationEvent = Endo . (:) . BufferedEvent . SkovFinalization

instance MissingEvent (Endo [BufferedSkovFinalizationEvent]) where
    missingBlockEvent bh delta = Endo (BufferedEvent (SkovMissing $ SkovMissingBlock bh delta) :)
    missingFinalizationEvent = Endo . (:) . BufferedEvent . SkovMissing . SkovMissingFinalization

instance BufferedFinalizationEvent (Endo [BufferedSkovFinalizationEvent]) where
    embedNotifyEvent = Endo . (:) . BufferNotification

-- |Notify of a missing block.
notifyMissingBlock :: (MonadWriter w m, MissingEvent w) => BlockHash -> BlockHeight -> m ()
notifyMissingBlock bh delta = tell $ missingBlockEvent bh delta

-- |Notify of a missing finalization record.
notifyMissingFinalization :: (MonadWriter w m, MissingEvent w) => Either BlockHash FinalizationIndex -> m ()
notifyMissingFinalization = tell . missingFinalizationEvent

-- |Determine if one block is an ancestor of another.
-- A block is considered to be an ancestor of itself.
isAncestorOf :: BlockPointerData bp => bp -> bp -> Bool
isAncestorOf b1 b2 = case compare (bpHeight b1) (bpHeight b2) of
        GT -> False
        EQ -> b1 == b2
        LT -> isAncestorOf b1 (bpParent b2)

-- |Update the focus block, together with the pending transaction table.
updateFocusBlockTo :: (TreeStateMonad m) => BlockPointer m -> m ()
updateFocusBlockTo newBB = do
        oldBB <- getFocusBlock
        pts <- getPendingTransactions
        putPendingTransactions (updatePTs oldBB newBB [] pts)
        putFocusBlock newBB
    where
        updatePTs oBB nBB forw pts = case compare (bpHeight oBB) (bpHeight nBB) of
                LT -> updatePTs oBB (bpParent nBB) (nBB : forw) pts
                EQ -> if oBB == nBB then
                            foldl (flip (forwardPTT . blockTransactions)) pts forw
                        else
                            updatePTs (bpParent oBB) (bpParent nBB) (nBB : forw) (reversePTT (blockTransactions oBB) pts)
                GT -> updatePTs (bpParent oBB) nBB forw (reversePTT (blockTransactions oBB) pts)

{-
-- |An instance of 'SkovListeners' defines callbacks for finalization.
-- The implementations of the basic Skov update operations are parametrised
-- by 'SkovListeners'.  This allows the events to be hooked for finalization
-- if a node is participating in finalization, or simply ignored if a node
-- is not participating.
data SkovListeners m = SkovListeners {
    onBlock :: BlockPointer m -> m (),
    onFinalize :: FinalizationRecord -> BlockPointer m -> m ()
}
-}

class OnSkov m where
    onBlock :: BlockPointer m -> m ()
    onFinalize :: FinalizationRecord -> BlockPointer m -> m ()


-- |Handle a block arriving that is dead.  That is, the block has never
-- been in the tree before, and now it never can be.  Any descendents of
-- this block that have previously arrived cannot have been added to the
-- tree, and we purge them recursively from '_skovPossiblyPendingTable'.
blockArriveDead :: (HasCallStack, TreeStateMonad m, LoggerMonad m) => BlockHash -> m ()
blockArriveDead cbp = do
        markDead cbp
        logEvent Skov LLDebug $ "Block " ++ show cbp ++ " arrived dead"
        children <- map getHash <$> takePendingChildren cbp
        forM_ children blockArriveDead

-- |Purge pending blocks with slot numbers predating the last finalized slot.
purgePending :: (HasCallStack, TreeStateMonad m, LoggerMonad m) => m ()
purgePending = do
        lfSlot <- getLastFinalizedSlot
        let purgeLoop = takeNextPendingUntil lfSlot >>= \case
                            Nothing -> return ()
                            Just (getHash -> pb) -> do
                                pbStatus <- getBlockStatus pb
                                let
                                    isPending Nothing = True
                                    isPending (Just BlockPending{}) = True
                                    isPending _ = False
                                when (isPending pbStatus) $ blockArriveDead pb
                                purgeLoop
        purgeLoop

-- |Process the blocks that are pending the finalization of their nominal
-- last-finalized block.  This is invoked when a block is newly finalized,
-- and simply tries to add all blocks with last finalized blocks no higher
-- than the newly finalized blocks.  At this point, we can determined for
-- certain if such a block has a valid last-finalized block.
processAwaitingLastFinalized :: (HasCallStack, TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w, OnSkov m) => m ()
processAwaitingLastFinalized = do
        lastFinHeight <- getLastFinalizedHeight
        takeAwaitingLastFinalizedUntil lastFinHeight >>= \case
            Nothing -> return ()
            Just pb -> do
                -- This block is awaiting its last final block to be finalized.
                -- At this point, it should be or it never will.
                _ <- addBlock pb
                processAwaitingLastFinalized

-- |Process the available finalization records to determine if a block can be finalized.
-- If finalization is sucessful, then progress finalization.
-- If not, any remaining finalization records at the current next finalization index
-- will be valid proofs, but their blocks have not yet arrived.
processFinalizationPool :: forall w m. (HasCallStack, TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w, OnSkov m) => m ()
processFinalizationPool = do
        nextFinIx <- getNextFinalizationIndex
        frs <- getFinalizationPoolAtIndex nextFinIx
        unless (null frs) $ do
            logEvent Skov LLTrace $ "Processing " ++ show (length frs) ++ " finalization records at index " ++ show nextFinIx
            lastFinHeight <- getLastFinalizedHeight
            finParams <- getFinalizationParameters
            genHash <- getHash <$> getGenesisBlockPointer
            let
                finSessId = FinalizationSessionId genHash 0 -- FIXME: Don't hard-code this!
                goodFin finRec@FinalizationRecord{..} =
                    finalizationIndex == nextFinIx -- Should always be true
                    && verifyFinalProof finSessId (makeFinalizationCommittee finParams) finRec
                checkFin finRec lp = getBlockStatus (finalizationBlockPointer finRec) >>= return . \case
                    -- If the block is not present, the finalization record is pending
                    Nothing -> (finRec :) <$> lp
                    -- If we've received the block, but it is pending, then the finalization record is also pending
                    Just (BlockPending _) -> (finRec :) <$> lp
                    -- If the block is alive and the finalization proof checks out,
                    -- we can use this for finalization
                    Just (BlockAlive bp) -> if goodFin finRec then Left (finRec, bp) else lp
                    -- Otherwise, the finalization record is dead because the block is
                    -- either dead or already finalized
                    Just _ -> lp
            foldrM checkFin (Right []) frs >>= \case
                -- We got a valid finalization proof, so progress finalization
                Left (finRec, newFinBlock) -> do
                    logEvent Skov LLInfo $ "Block " ++ show (bpHash newFinBlock) ++ " is finalized at height " ++ show (theBlockHeight $ bpHeight newFinBlock)
                    updateFinalizationStatistics
                    -- Check if the focus block is a descendent of the block we are finalizing
                    focusBlockSurvives <- (isAncestorOf newFinBlock) <$> getFocusBlock
                    -- If not, update the focus to the new finalized block.
                    -- This is to ensure that the focus block is always a live (or finalized) block.
                    unless focusBlockSurvives $ updateFocusBlockTo newFinBlock
                    putFinalizationPoolAtIndex nextFinIx []
                    addFinalization newFinBlock finRec
                    oldBranches <- getBranches
                    let pruneHeight = fromIntegral (bpHeight newFinBlock - lastFinHeight)
                    let
                        pruneTrunk :: BlockPointer m -> Branches m -> m ()
                        pruneTrunk _ Seq.Empty = return ()
                        pruneTrunk keeper (brs Seq.:|> l) = do
                            forM_ l $ \bp -> if bp == keeper then do
                                                markFinalized (getHash bp) finRec
                                                logEvent Skov LLDebug $ "Block " ++ show bp ++ " marked finalized"
                                            else do
                                                markDead (getHash bp)
                                                logEvent Skov LLDebug $ "Block " ++ show bp ++ " marked dead"
                            pruneTrunk (bpParent keeper) brs
                            finalizeTransactions (blockTransactions keeper)
                    pruneTrunk newFinBlock (Seq.take pruneHeight oldBranches)
                    -- Prune the branches
                    let
                        pruneBranches _ Seq.Empty = return Seq.empty
                        pruneBranches parents (brs Seq.:<| rest) = do
                            survivors <- foldrM (\bp l ->
                                if bpParent bp `elem` parents then
                                    return (bp:l)
                                else do
                                    markDead (bpHash bp)
                                    logEvent Skov LLDebug $ "Block " ++ show (bpHash bp) ++ " marked dead"
                                    return l)
                                [] brs
                            rest' <- pruneBranches survivors rest
                            return (survivors Seq.<| rest')
                    unTrimmedBranches <- pruneBranches [newFinBlock] (Seq.drop pruneHeight oldBranches)
                    -- This removes empty lists at the end of branches which can result in finalizing on a
                    -- block not in the current best local branch
                    let 
                        trimBranches Seq.Empty = return Seq.Empty
                        trimBranches prunedbrs@(xs Seq.:|> x) = do
                            case x of
                                [] -> trimBranches xs
                                _ -> return prunedbrs
                    newBranches <- trimBranches unTrimmedBranches
                    putBranches newBranches
                    -- purge pending blocks with slot numbers predating the last finalized slot
                    purgePending
                    onFinalize finRec newFinBlock
                    -- handle blocks in skovBlocksAwaitingLastFinalized
                    processAwaitingLastFinalized
                    processFinalizationPool
                Right frs' -> do
                    -- In this case, we have a list of finalization records that are missing
                    -- their blocks.  We filter these down to only valid records, and only
                    -- keep one valid record per block.  (If finalization is not corrupted,
                    -- then there should be at most one block with a valid finalization.)
                    let
                        acc fr l = if finalizationBlockPointer fr `notElem` (finalizationBlockPointer <$> l) && goodFin fr then fr : l else l
                        frs'' = foldr acc [] frs'
                    putFinalizationPoolAtIndex nextFinIx $! frs''

-- |Given a block that is marked as pending, generate a notify event
notifyBlocker :: (TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w) => PendingBlock -> m UpdateResult
notifyBlocker pb =
        getBlockStatus parent >>= \case
            Nothing -> do
                logEvent Skov LLDebug $ "... pending missing parent (" ++ show parent ++ ")"
                notifyMissingBlock parent 0
                return ResultPendingBlock
            Just (BlockPending pb') -> do
                logEvent Skov LLDebug $ "... pending pending parent (" ++ show parent ++ ") ..."
                notifyBlocker pb'
            Just BlockDead -> do
                -- This should not be possible;
                -- if the parent was or became dead, then this
                -- block should have already arrived dead.
                logEvent Skov LLError $ "... pending dead block (" ++ show parent ++ ")"
                blockArriveDead (getHash pb)
                return ResultStale
            _ -> do
                -- The parent is alive; we must be pending a finalization.
                notifyMissingFinalization (Left $ blockLastFinalized bf)
                logEvent Skov LLDebug $ "... pending finalization of last finalized block (" ++ show (blockLastFinalized bf) ++ ")"
                return ResultPendingFinalization
    where
        bf = bbFields (pbBlock pb)
        parent = blockPointer bf


-- |Try to add a block to the tree.  There are three possible outcomes:
--
-- 1. The block is determined to be invalid in the current tree.
--    In this case, the block is marked dead.
-- 2. The block is pending the arrival of its parent block, or
--    the finalization of its last finalized block.  In this case
--    it is added to the appropriate pending queue.  'addBlock'
--    should be called again when the pending criterion is fulfilled.
-- 3. The block is determined to be valid and added to the tree.
addBlock :: forall w m. (HasCallStack, TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w, OnSkov m) => PendingBlock -> m UpdateResult
addBlock block = do
        lfs <- getLastFinalizedSlot
        -- The block must be later than the last finalized block
        if lfs >= blockSlot block then deadBlock else do
            parentStatus <- getBlockStatus parent
            case parentStatus of
                Nothing -> do
                    addPendingBlock block
                    markPending block
                    notifyMissingBlock parent 0
                    logEvent Skov LLDebug $ "Block " ++ show block ++ " is pending its parent (" ++ show parent ++ ")"
                    -- Check also if the block's last finalized block has been finalized
                    getBlockStatus (blockLastFinalized bf) >>= \case
                        Just (BlockFinalized _ _) -> return ()
                        _ -> notifyMissingFinalization (Left $ blockLastFinalized bf)
                    return ResultPendingBlock
                Just (BlockPending pb) -> do
                    addPendingBlock block
                    markPending block
                    logEvent Skov LLDebug $ "Block " ++ show block ++ " is pending..."
                    notifyBlocker pb
                Just BlockDead -> deadBlock
                Just (BlockAlive parentP) -> tryAddLiveParent parentP
                Just (BlockFinalized parentP _) -> do
                    (lfb, _) <- getLastFinalized
                    -- If the parent is finalized, it had better be the last finalized, or else the block is already dead
                    if parentP /= lfb then deadBlock else tryAddLiveParent parentP
    where
        deadBlock :: m UpdateResult
        deadBlock = do
            blockArriveDead $ getHash block
            return ResultStale
        invalidBlock :: m UpdateResult
        invalidBlock = do
            logEvent Skov LLWarning $ "Block is not valid: " ++ show block
            blockArriveDead $ getHash block
            return ResultInvalid
        bf = bbFields (pbBlock block)
        parent = blockPointer bf
        check q a = if q then a else invalidBlock
        tryAddLiveParent :: BlockPointer m -> m UpdateResult
        tryAddLiveParent parentP = do -- The parent block must be Alive or Finalized
            let lf = blockLastFinalized bf
            -- Check that the blockSlot is beyond the parent slot
            check (blockSlot (bpBlock parentP) < blockSlot block) $ do
                lfStatus <- getBlockStatus lf
                case lfStatus of
                    -- If the block's last finalized block is live, but not finalized yet,
                    -- add this block to the queue at the appropriate point
                    Just (BlockAlive lfBlockP) -> do
                        addAwaitingLastFinalized (bpHeight lfBlockP) block
                        notifyMissingFinalization (Left lf)
                        logEvent Skov LLDebug $ "Block " ++ show block ++ " is pending finalization of block " ++ show (bpHash lfBlockP) ++ " at height " ++ show (theBlockHeight $ bpHeight lfBlockP)
                        return ResultPendingFinalization
                    -- If the block's last finalized block is finalized, we can proceed with validation.
                    -- Together with the fact that the parent is alive, we know that the new node
                    -- is a descendent of the finalized block.
                    Just (BlockFinalized lfBlockP finRec) ->
                        -- The last finalized pointer must be to the block that was actually finalized.
                        -- (Blocks can be implicitly finalized when a descendent is finalized.)
                        check (finalizationBlockPointer finRec == lf) $
                        -- We need to know that the slot numbers of the last finalized blocks are ordered.
                        -- If the parent block is the genesis block then its last finalized pointer is to
                        -- itself and so the test will pass.
                        check (blockSlot lfBlockP >= blockSlot (bpLastFinalized parentP)) $ do
                            -- get Birk parameters from the __parent__ block. The baker must have existed in that
                            -- block's state in order that the current block is valid
                            bps@BirkParameters{..} <- getBirkParameters (bpState parentP)
                            case birkBaker (blockBaker bf) bps of
                                Nothing -> invalidBlock
                                Just (BakerInfo{..}, lotteryPower) ->
                                    -- Check the block proof
                                    check (verifyProof
                                                _birkLeadershipElectionNonce
                                                _birkElectionDifficulty
                                                (blockSlot block)
                                                _bakerElectionVerifyKey
                                                lotteryPower
                                                (blockProof bf)) $
                                    -- The block nonce
                                    check (verifyBlockNonce
                                                _birkLeadershipElectionNonce
                                                (blockSlot block)
                                                _bakerElectionVerifyKey
                                                (blockNonce bf)) $
                                    -- And the block signature
                                    check (verifyBlockSignature _bakerSignatureVerifyKey block) $ do
                                        let ts = blockTransactions block
                                        executeFrom (blockSlot block) parentP lfBlockP (blockBaker . bbFields . pbBlock $ block) ts >>= \case
                                            Left err -> do
                                                logEvent Skov LLWarning ("Block execution failure: " ++ show err)
                                                invalidBlock
                                            Right gs -> do
                                                -- Add the block to the tree
                                                blockP <- blockArrive block parentP lfBlockP gs
                                                -- Notify of the block arrival (for finalization)
                                                onBlock blockP
                                                -- Process finalization records
                                                processFinalizationPool
                                                -- Handle any blocks that are waiting for this one
                                                children <- takePendingChildren (getHash block)
                                                forM_ children $ \childpb -> do
                                                    childStatus <- getBlockStatus (getHash childpb)
                                                    let
                                                        isPending Nothing = True
                                                        isPending (Just (BlockPending _)) = True
                                                        isPending _ = False
                                                    when (isPending childStatus) $ void $ addBlock childpb
                                                return ResultSuccess
                    -- If the block's last finalized block is dead, then the block arrives dead.
                    -- If the block's last finalized block is pending then it can't be an ancestor,
                    -- so the block is invalid and it arrives dead.
                    _ -> invalidBlock

-- |Add a valid, live block to the tree.
-- This is used by 'addBlock' and 'doStoreBakedBlock', and should not
-- be called directly otherwise.
blockArrive :: (HasCallStack, TreeStateMonad m, SkovMonad m) 
        => PendingBlock     -- ^Block to add
        -> BlockPointer m     -- ^Parent pointer
        -> BlockPointer m    -- ^Last finalized pointer
        -> BlockState m      -- ^State
        -> m (BlockPointer m)
blockArrive block parentP lfBlockP gs = do
        let height = bpHeight parentP + 1
        curTime <- currentTime
        blockP <- makeLiveBlock block parentP lfBlockP gs curTime
        logEvent Skov LLInfo $ "Block " ++ show block ++ " arrived"
        -- Update the statistics
        updateArriveStatistics blockP
        -- Add to the branches
        finHght <- getLastFinalizedHeight
        brs <- getBranches
        let branchLen = fromIntegral $ Seq.length brs
        let insertIndex = height - finHght - 1
        if insertIndex < branchLen then
            putBranches $ brs & ix (fromIntegral insertIndex) %~ (blockP:)
        else
            if (insertIndex == branchLen) then
                putBranches $ brs Seq.|> [blockP]
            else do
                -- This should not be possible, since the parent block should either be
                -- the last finalized block (in which case insertIndex == 0)
                -- or the child of a live block (in which case insertIndex <= branchLen)
                let errMsg = "Attempted to add block at invalid height (" ++ show (theBlockHeight height) ++ ") while last finalized height is " ++ show (theBlockHeight finHght)
                logEvent Skov LLError errMsg
                error errMsg
        return blockP

-- |Store a block (as received from the network) in the tree.
-- This checks for validity of the block, and may add the block
-- to a pending queue if its prerequisites are not met.
doStoreBlock :: (TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w, OnSkov m) => BakedBlock -> m UpdateResult
{-# INLINE doStoreBlock #-}
doStoreBlock = \block0 -> do
    curTime <- currentTime
    let pb = makePendingBlock block0 curTime
    let cbp = getHash pb
    oldBlock <- getBlockStatus cbp
    case oldBlock of
        Nothing -> do
            -- The block is new, so we have some work to do.
            logEvent Skov LLDebug $ "Received block " ++ show pb
            updateReceiveStatistics pb
            forM_ (blockTransactions pb) $ \tr -> doReceiveTransaction tr (blockSlot pb)
            addBlock pb
        Just _ -> return ResultDuplicate

-- |Store a block that is baked by this node in the tree.  The block
-- is presumed to be valid.
doStoreBakedBlock :: (TreeStateMonad m, SkovMonad m, OnSkov m)
        => PendingBlock     -- ^Block to add
        -> BlockPointer m    -- ^Parent pointer
        -> BlockPointer m     -- ^Last finalized pointer
        -> BlockState m      -- ^State
        -> m (BlockPointer m)
{-# INLINE doStoreBakedBlock #-}
doStoreBakedBlock = \pb parent lastFin st -> do
        bp <- blockArrive pb parent lastFin st
        onBlock bp
        return bp

-- |Add a new finalization record to the finalization pool.
doFinalizeBlock :: (TreeStateMonad m, SkovMonad m, MonadWriter w m, MissingEvent w, OnSkov m) => FinalizationRecord -> m UpdateResult
{-# INLINE doFinalizeBlock #-}
doFinalizeBlock = \finRec -> do
    let thisFinIx = finalizationIndex finRec
    nextFinIx <- getNextFinalizationIndex
    case compare thisFinIx nextFinIx of
        LT -> return ResultStale -- Already finalized at that index
        EQ -> do 
                addFinalizationRecordToPool finRec
                processFinalizationPool
                newFinIx <- getNextFinalizationIndex
                if newFinIx == nextFinIx then do
                    -- Finalization did not complete, which suggests
                    -- that the finalized block has not yet arrived.
                    frs <- getFinalizationPoolAtIndex nextFinIx
                    -- All records still in the pool at this index are valid.
                    -- Under normal circumstances, there should be
                    -- at most one.
                    if null frs then
                        return ResultInvalid
                    else do
                        let notifyFinalizationBlocker FinalizationRecord{..} = do
                                getBlockStatus finalizationBlockPointer >>= \case
                                    Just (BlockPending bp) -> do
                                        logEvent Skov LLDebug $ "Finalization at index " ++ show thisFinIx ++ " is pending pending block (" ++ show finalizationBlockPointer ++ ")..."
                                        notifyBlocker bp
                                    _ -> do -- This should only apply if the block is absent
                                        logEvent Skov LLDebug $ "Finalization at index " ++ show thisFinIx ++ " is pending block (" ++ show finalizationBlockPointer ++ ")"
                                        notifyMissingBlock finalizationBlockPointer 0
                                        return ResultPendingBlock
                        mapM_ notifyFinalizationBlocker frs
                        return ResultPendingBlock
                else return ResultSuccess
        GT -> do
                let finIxBefore z 
                        | z <= nextFinIx = return nextFinIx
                        | otherwise = getFinalizationPoolAtIndex z >>= \case
                                [] -> return z
                                _ -> finIxBefore (z-1)
                reqFinIx <- finIxBefore (thisFinIx - 1)
                logEvent Skov LLDebug $ "Requesting finalization at index " ++ show reqFinIx ++ "."
                notifyMissingFinalization (Right $ reqFinIx)
                addFinalizationRecordToPool finRec
                return ResultPendingFinalization

-- |Add a transaction to the transaction table.  The 'Slot' should be
-- the slot number of the block that the transaction was received with,
-- and 0 if the transaction was received separately from a block.
-- This returns 'ResultSuccess' if the transaction is freshly added.
-- Otherwise, it returns 'ResultDuplicate', which indicates that either
-- the transaction is a duplicate, or a transaction with the same sender
-- and nonce has already been finalized.
doReceiveTransaction :: (TreeStateMonad m) => Transaction -> Slot -> m UpdateResult
doReceiveTransaction tr slot = do
        added <- addCommitTransaction tr slot
        if added then do
            ptrs <- getPendingTransactions
            focus <- getFocusBlock
            macct <- getAccount (bpState focus) (transactionSender tr)
            let nextNonce = maybe minNonce _accountNonce macct
            -- If a transaction with this nonce has already been run by
            -- the focus block, then we do not need to add it to the
            -- pending transactions.  Otherwise, we do.
            when (nextNonce <= transactionNonce tr) $
                putPendingTransactions $ extendPendingTransactionTable nextNonce tr ptrs
            return ResultSuccess
        else
            return ResultDuplicate