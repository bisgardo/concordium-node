{-# LANGUAGE
    ScopedTypeVariables #-}
module Concordium.Kontrol.BestBlock(
    bestBlock,
    bestBlockBefore,
    bestBlockOf
) where

import Data.Foldable
import qualified Data.Sequence as Seq
import Lens.Micro.Platform
import Control.Exception (assert)

import Concordium.Types
import Concordium.GlobalState.Block
import Concordium.GlobalState.Parameters
import Concordium.Skov.Monad
import Concordium.Birk.LeaderElection
import Concordium.GlobalState.TreeState(TreeStateMonad, BlockPointer, BlockPointerData(..), bpParent, Branches)

blockLuck :: (SkovQueryMonad m, TreeStateMonad m) => BlockPointer m -> m BlockLuck
blockLuck block = case blockFields block of
        Nothing -> return genesisLuck -- Genesis block has luck 1 by definition
        Just bf -> do
            -- get Birk parameters of the __parent__ block, at the slot of the new block.
            -- These are the parameters which determine valid bakers, election difficulty,
            -- that determine the luck of the block itself.
            parent <- bpParent block
            params <- getBirkParameters (blockSlot block) parent
            case birkEpochBaker (blockBaker bf) params of
                Nothing -> assert False $ return zeroLuck -- This should not happen, since it would mean the block was baked by an invalid baker
                Just (_, lotteryPower) ->
                    return (electionLuck (params ^. birkElectionDifficulty) lotteryPower (blockProof bf))

compareBlocks :: (SkovQueryMonad m, TreeStateMonad m) => BlockPointer m -> (BlockPointer m, Maybe BlockLuck) -> m (BlockPointer m, Maybe BlockLuck)
compareBlocks contender best@(bestb, mbestLuck) =
    case compare (blockSlot bestb) (blockSlot contender) of
        LT -> return (contender, Nothing)
        GT -> return best
        EQ -> do
            luck <- blockLuck contender
            bestLuck <- case mbestLuck of
                Just l -> return l
                Nothing -> blockLuck bestb
            return $ if (bestLuck, bpHash bestb) < (luck, bpHash contender) then (contender, Just luck) else (bestb, Just bestLuck)

bestBlockBranches :: forall m. (SkovQueryMonad m, TreeStateMonad m) => [[BlockPointer m]] -> m (BlockPointer m)
bestBlockBranches [] = lastFinalizedBlock
bestBlockBranches l = bb l
    where
        bb [] = lastFinalizedBlock
        bb (blocks : branches) =
            case blocks of
                [] -> bb branches
                (b : bs) -> fst <$> foldrM compareBlocks (b, Nothing) bs


-- |Get the best block currently in the tree.
bestBlock :: forall m. (SkovQueryMonad m, TreeStateMonad m) => m (BlockPointer m)
bestBlock = bestBlockBranches =<< branchesFromTop

-- |Get the best non-finalized block in the tree with a slot time strictly below the given bound.
-- If there is no such block, the last finalized block is returned.
bestBlockBefore :: forall m. (SkovQueryMonad m, TreeStateMonad m) => Slot -> m (BlockPointer m)
bestBlockBefore slotBound = bestBlockBranches . fmap (filter (\b -> blockSlot b < slotBound)) =<< branchesFromTop

-- |Given some 'Branches', determine the best block.
-- This will always be a block at the greatest height that is non-empty.
bestBlockOf :: (SkovQueryMonad m, TreeStateMonad m) => Branches m -> m (Maybe (BlockPointer m))
bestBlockOf Seq.Empty = return Nothing
bestBlockOf (bs' Seq.:|> tbs) = case tbs of
        [] -> bestBlockOf bs'
        [b] -> return $ Just b
        (b : tbs') -> do
            bb <- fst <$> foldrM compareBlocks (b, Nothing) tbs'
            return $ Just bb
