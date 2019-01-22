{-# LANGUAGE LambdaCase, TupleSections, ScopedTypeVariables #-}
module Concordium.Kontrol.BestBlock where

import Data.Foldable

import Concordium.Types
import Concordium.Kontrol.Monad
import Concordium.Birk.LeaderElection
-- import Concordium.Kontrol.VerifyBlock

blockLuck :: (KontrolMonad m) => BlockHash -> Block -> m Double
blockLuck bh block = do
        gbh <- genesisBlockHash
        if bh == gbh then
            return 1
        else do
            params <- getBirkParameters bh
            case birkBaker (blockBaker block) params of
                Nothing -> return 0 -- This should not happen, since it would mean the block was baked by an invalid baker
                Just baker ->
                    return (electionLuck (birkElectionDifficulty params) (bakerLotteryPower baker) (blockProof block))

{-
bestBlock :: forall m. (KontrolMonad m) => m BlockHash
bestBlock = getCurrentHeight >>= bb
    where
        bb h = do
            blocks <- getBlocksAtHeight h
            bestBlock <- foldrM compareBlocks Nothing blocks
            case bestBlock of
                Nothing -> bb (h - 1)
                Just (bh, _) -> return bh
        compareBlocks :: BlockHash -> Maybe (BlockHash, Maybe (Block, Maybe Double)) -> m (Maybe (BlockHash, Maybe (Block, Maybe Double)))
        compareBlocks bh Nothing = do
            valid <- validateBlock bh
            return $ if valid then Just (bh, Nothing) else Nothing
        compareBlocks bh br@(Just (bhr, binfo)) = do
            valid <- validateBlock bh
            if valid then do
                (Just block) <- resolveBlock bh
                (goodBlock, l) <- case binfo of
                    Just j -> return j
                    Nothing -> do
                        Just goodBlock <- resolveBlock bhr
                        return (goodBlock, Nothing)
                case compare (blockSlot goodBlock) (blockSlot block) of
                    LT -> return $ Just (bh, Just (block, Nothing))
                    GT -> return $ Just (bhr, Just (goodBlock, l))
                    EQ -> do
                        luck <- blockLuck bh block
                        goodLuck <- case l of
                            Just goodLuck -> return goodLuck
                            Nothing -> blockLuck bhr goodBlock
                        case compare (goodLuck, bhr) (luck, bh) of
                            LT -> return $ Just (bh, Just (block, Just luck))
                            GT -> return $ Just (bhr, Just (goodBlock, Just goodLuck))
                            EQ -> return $ Just (bh, Just (block, Just luck))
            else
                return br
-}

bestBlockBefore :: forall m. (KontrolMonad m) => Slot -> m BlockHash
bestBlockBefore slotBound = branchesFromTop >>= bb
    where
        bb [] = finalizationBlockPointer <$> lastFinalizedBlock
        bb (blocks : branches) = do
            rblocks <- mapM (\bh -> (bh,) <$> resolveBlock bh) blocks
            let filteredBlocks = [(bh, b) | (bh, Just b) <- rblocks, blockSlot b < slotBound]
            bestBlock <- foldrM compareBlocks Nothing filteredBlocks
            case bestBlock of
                Nothing -> bb branches
                Just (bh, _, _) -> return bh
        compareBlocks :: (BlockHash, Block) -> Maybe (BlockHash, Block, Maybe Double) -> m (Maybe (BlockHash, Block, Maybe Double))
        compareBlocks (bh, b) Nothing = return $ Just (bh, b, Nothing)
        compareBlocks (bh, b) best@(Just (bestbh, bestb, mbestLuck)) =
            case compare (blockSlot bestb) (blockSlot b) of
                LT -> return $ Just (bh, b, Nothing)
                GT -> return best
                EQ -> do
                    luck <- blockLuck bh b
                    bestLuck <- case mbestLuck of
                        Just l -> return l
                        Nothing -> blockLuck bestbh bestb
                    return $ Just $ if (bestLuck, bestbh) < (luck, bh) then (bh, b, Just luck) else (bestbh, bestb, Just bestLuck)
