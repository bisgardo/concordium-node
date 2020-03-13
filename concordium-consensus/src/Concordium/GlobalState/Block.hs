{-# LANGUAGE MultiParamTypeClasses, StandaloneDeriving, RecordWildCards, TypeFamilies, FlexibleContexts, TypeSynonymInstances, FunctionalDependencies, DerivingVia, ScopedTypeVariables, FlexibleInstances, UndecidableInstances #-}
module Concordium.GlobalState.Block where

import Data.Time
import Data.Serialize

import Concordium.Types
import Concordium.Types.Transactions
import Concordium.Types.HashableTo
import Concordium.GlobalState.Parameters
import Concordium.Crypto.SHA256 as Hash
import qualified Concordium.Crypto.BlockSignature as Sig

hashGenesisData :: GenesisData -> Hash
hashGenesisData genData = Hash.hashLazy . runPutLazy $ put genesisSlot >> put genData

instance HashableTo BlockHash BakedBlock where
    getHash b = Hash.hashLazy . runPutLazy $ blockBody b >> put (bbSignature b)

instance HashableTo BlockHash Block where
    getHash (GenesisBlock genData) = hashGenesisData genData
    getHash (NormalBlock bb) = getHash bb

-- * Block type classes

-- |Accessors for the metadata of a baked (i.e. non-genesis) block.
class BlockMetadata d where
    -- |The hash of the parent block
    blockPointer :: d -> BlockHash
    -- |The identifier of the block's baker
    blockBaker :: d -> BakerId
    -- |The proof that the baker was entitled to bake this block
    blockProof :: d -> BlockProof
    -- |The block nonce
    blockNonce :: d -> BlockNonce
    -- |The hash of the last finalized block when this block was baked
    blockLastFinalized :: d -> BlockHash

-- |For a type @b@ representing a block, the type @BlockFieldType b@
-- represents the block metadata associated with a block.  Typically,
-- @BlockFieldType b@ is an instance of 'BlockMetadata'.
type family BlockFieldType (b :: *) :: *

-- |The 'BlockData' class provides an interface for the pure data associated
-- with a block.
class (BlockMetadata (BlockFieldType b)) => BlockData b where
    -- |The slot number of the block (0 for genesis block)
    blockSlot :: b -> Slot
    -- |The fields of a block, if it was baked; @Nothing@ for the genesis block.
    blockFields :: b -> Maybe (BlockFieldType b)
    -- |The transactions in a block in the variant they are currently stored in the block.
    blockTransactions :: b -> [Transaction]
    blockSignature :: b -> Maybe BlockSignature
    -- |Determine if the block is signed by the given key
    -- (always 'True' for genesis block)
    verifyBlockSignature :: Sig.VerifyKey -> b -> Bool
    -- |Provides a pure serialization of the block.
    --
    -- This means that if some IO is needed for serializing the block (as
    -- in the case of the Persistent blocks), it will not be done and we
    -- would just serialize the hashes of the transactions. This is useful in order
    -- to get the serialized version of the block that we want to write into the disk.
    putBlock :: b -> Put

class (BlockMetadata b, BlockData b, HashableTo BlockHash b, Show b) => BlockPendingData b where
    -- |Time at which the block was received
    blockReceiveTime :: b -> UTCTime

-- * Block types

-- |The fields of a baked block.
data BlockFields = BlockFields {
    -- |The 'BlockHash' of the parent block
    bfBlockPointer :: !BlockHash,
    -- |The identity of the block baker
    bfBlockBaker :: !BakerId,
    -- |The proof that the baker was entitled to bake this block
    bfBlockProof :: !BlockProof,
    -- |The block nonce
    bfBlockNonce :: !BlockNonce,
    -- |The 'BlockHash' of the last finalized block when the block was baked
    bfBlockLastFinalized :: !BlockHash
} deriving (Show)

instance BlockMetadata BlockFields where
    blockPointer = bfBlockPointer
    {-# INLINE blockPointer #-}
    blockBaker = bfBlockBaker
    {-# INLINE blockBaker #-}
    blockProof = bfBlockProof
    {-# INLINE blockProof #-}
    blockNonce = bfBlockNonce
    {-# INLINE blockNonce #-}
    blockLastFinalized = bfBlockLastFinalized
    {-# INLINE blockLastFinalized #-}

-- |A baked (i.e. non-genesis) block.
--
-- The type parameter @t@ is the type of the transaction
-- in the block.
--
-- All instances of this type will implement automatically:
--
-- * BlockFieldType & BlockTransactionType
-- * BlockMetadata
-- * BlockData
data BakedBlock = BakedBlock {
    -- |Slot number (must be >0)
    bbSlot :: !Slot,
    -- |Block fields
    bbFields :: !BlockFields,
    -- |Block transactions
    bbTransactions :: ![Transaction],
    -- |Block signature
    bbSignature :: BlockSignature
} deriving (Show)

type instance BlockFieldType BakedBlock = BlockFields

instance BlockMetadata BakedBlock where
    blockPointer = bfBlockPointer . bbFields
    {-# INLINE blockPointer #-}
    blockBaker = bfBlockBaker . bbFields
    {-# INLINE blockBaker #-}
    blockProof = bfBlockProof . bbFields
    {-# INLINE blockProof #-}
    blockNonce = bfBlockNonce . bbFields
    {-# INLINE blockNonce #-}
    blockLastFinalized = bfBlockLastFinalized . bbFields
    {-# INLINE blockLastFinalized #-}

blockBody :: (BlockMetadata b, BlockData b) => b -> Put
blockBody b = do
        put (blockSlot b)
        put (blockPointer b)
        put (blockBaker b)
        put (blockProof b)
        put (blockNonce b)
        put (blockLastFinalized b)
        putListOf put $ map trBareTransaction $ blockTransactions b

instance BlockData BakedBlock where
    blockSlot = bbSlot
    {-# INLINE blockSlot #-}
    blockFields = Just . bbFields
    {-# INLINE blockFields #-}
    blockTransactions = bbTransactions
    blockSignature = Just . bbSignature
    verifyBlockSignature key b = Sig.verify key (runPut (blockBody b)) (bbSignature b)
    putBlock b = blockBody b >> put (bbSignature b)

-- |Representation of a block
--
-- All instances of this type will implement automatically:
--
-- * BlockFieldType & BlockTransactionType
-- * BlockData
data Block
    = GenesisBlock !GenesisData
    -- ^A genesis block
    | NormalBlock !BakedBlock
    -- ^A baked (i.e. non-genesis) block
    deriving (Show)

type instance BlockFieldType Block = BlockFieldType BakedBlock

instance BlockData Block where
    blockSlot GenesisBlock{} = 0
    blockSlot (NormalBlock bb) = blockSlot bb

    blockFields GenesisBlock{} = Nothing
    blockFields (NormalBlock bb) = blockFields bb

    blockTransactions GenesisBlock{} = []
    blockTransactions (NormalBlock bb) = blockTransactions bb

    blockSignature GenesisBlock{} = Nothing
    blockSignature (NormalBlock bb) = blockSignature bb

    verifyBlockSignature _ GenesisBlock{} = True
    verifyBlockSignature key (NormalBlock bb) = verifyBlockSignature key bb

    putBlock (GenesisBlock gd) = put genesisSlot >> put gd
    putBlock (NormalBlock bb) = blockBody bb

    {-# INLINE blockSlot #-}
    {-# INLINE blockFields #-}
    {-# INLINE blockTransactions #-}
    {-# INLINE putBlock #-}

-- |A baked block, pre-hashed with its arrival time.
--
-- All instances of this type will implement automatically:
--
-- * BlockFieldType & BlockTransactionType
-- * BlockMetadata
-- * BlockData
-- * BlockPendingData
-- * HashableTo BlockHash
data PendingBlock = PendingBlock {
    pbHash :: !BlockHash,
    pbBlock :: !BakedBlock,
    pbReceiveTime :: !UTCTime
}

type instance BlockFieldType PendingBlock = BlockFieldType BakedBlock

instance Eq PendingBlock where
    pb1 == pb2 = pbHash pb1 == pbHash pb2

instance Show PendingBlock where
    show pb = show (pbHash pb) ++ " (" ++ show (blockBaker $ bbFields $ pbBlock pb) ++ ")"

instance BlockMetadata PendingBlock where
    blockPointer = bfBlockPointer . bbFields . pbBlock
    {-# INLINE blockPointer #-}
    blockBaker = bfBlockBaker . bbFields . pbBlock
    {-# INLINE blockBaker #-}
    blockProof = bfBlockProof . bbFields . pbBlock
    {-# INLINE blockProof #-}
    blockNonce = bfBlockNonce . bbFields . pbBlock
    {-# INLINE blockNonce #-}
    blockLastFinalized = bfBlockLastFinalized . bbFields . pbBlock
    {-# INLINE blockLastFinalized #-}

instance BlockData PendingBlock where
    blockSlot = blockSlot . pbBlock
    blockFields = blockFields . pbBlock
    blockTransactions = blockTransactions . pbBlock
    blockSignature = blockSignature . pbBlock
    verifyBlockSignature key = verifyBlockSignature key . pbBlock
    putBlock = putBlock . pbBlock
    {-# INLINE blockSlot #-}
    {-# INLINE blockFields #-}
    {-# INLINE blockTransactions #-}
    {-# INLINE putBlock #-}

instance BlockPendingData PendingBlock where
    blockReceiveTime = pbReceiveTime

instance HashableTo BlockHash PendingBlock where
  getHash = pbHash


-- |Deserialize a block.
-- NB: This does not check transaction signatures.
getBlock :: TransactionTime -> Get Block
getBlock arrivalTime = do
  sl <- get
  if sl == 0 then GenesisBlock <$> get
  else do
    bfBlockPointer <- get
    bfBlockBaker <- get
    bfBlockProof <- get
    bfBlockNonce <- get
    bfBlockLastFinalized <- get
    bbTransactions <- getListOf (getUnverifiedTransaction arrivalTime)
    bbSignature <- get
    return $ NormalBlock (BakedBlock{bbSlot = sl, bbFields = BlockFields{..}, ..})

makePendingBlock :: BakedBlock -> UTCTime -> PendingBlock
makePendingBlock pbBlock pbReceiveTime = PendingBlock{pbHash = getHash pbBlock,..}

-- |Generate a baked block.
signBlock :: BakerSignPrivateKey           -- ^Key for signing the new block
    -> Slot                       -- ^Block slot (must be non-zero)
    -> BlockHash                  -- ^Hash of parent block
    -> BakerId                    -- ^Identifier of block baker
    -> BlockProof                 -- ^Block proof
    -> BlockNonce                 -- ^Block nonce
    -> BlockHash                  -- ^Hash of last finalized block
    -> [Transaction]                        -- ^List of transactions
    -> BakedBlock
signBlock key slot parent baker proof bnonce lastFin transactions
    | slot == 0 = error "Only the genesis block may have slot 0"
    | otherwise = do
        let sig = Sig.sign key . runPut $ blockBody (preBlock undefined)
        preBlock sig
    where
        preBlock = BakedBlock slot (BlockFields parent baker proof bnonce lastFin) transactions
