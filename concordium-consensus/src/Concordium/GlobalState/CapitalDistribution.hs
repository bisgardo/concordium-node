-- | This module contains common types for representing the capital distribution of bakers and
--  delegators.  A snapshot of the capital distribution is taken when the bakers for a payday are
--  calculated.  This is then used to determine how rewards are distributed among the bakers and
--  delegators at the payday.
module Concordium.GlobalState.CapitalDistribution where

import Data.Serialize
import qualified Data.Vector as Vec

import qualified Concordium.Crypto.SHA256 as Hash
import Concordium.Types
import Concordium.Types.HashableTo
import Concordium.Utils.Serialization

import qualified Concordium.GlobalState.Basic.BlockState.LFMBTree as LFMBT

-- | The capital staked by a particular delegator to a pool.
data DelegatorCapital = DelegatorCapital
    { -- | 'DelegatorId' of the delegator
      dcDelegatorId :: !DelegatorId,
      -- | 'Amount' staked by the delegator
      dcDelegatorCapital :: !Amount
    }
    deriving (Show, Eq)

instance Serialize DelegatorCapital where
    put DelegatorCapital{..} = do
        put dcDelegatorId
        put dcDelegatorCapital
    get = do
        dcDelegatorId <- get
        dcDelegatorCapital <- get
        return DelegatorCapital{..}

instance HashableTo Hash.Hash DelegatorCapital where
    getHash = Hash.hash . encode

instance (Monad m) => MHashableTo m Hash.Hash DelegatorCapital

-- | The capital staked to a particular baker pool.
data BakerCapital = BakerCapital
    { -- | 'BakerId' of the pool owner
      bcBakerId :: !BakerId,
      -- | Equity capital of the pool owner
      bcBakerEquityCapital :: !Amount,
      -- | Capital staked by each delegator to this pool, in ascending order of delegator ID.
      bcDelegatorCapital :: !(Vec.Vector DelegatorCapital)
    }
    deriving (Show, Eq)

instance Serialize BakerCapital where
    put BakerCapital{..} = do
        put bcBakerId
        put bcBakerEquityCapital
        putLength (Vec.length bcDelegatorCapital)
        mapM_ put bcDelegatorCapital

    get = do
        bcBakerId <- get
        bcBakerEquityCapital <- get
        bcDelegatorCapital <- flip Vec.generateM (const get) =<< getLength
        return BakerCapital{..}

instance HashableTo Hash.Hash BakerCapital where
    getHash BakerCapital{..} = Hash.hash $
        runPut $ do
            put bcBakerId
            put bcBakerEquityCapital
            put $ LFMBT.hashFromFoldable bcDelegatorCapital

instance (Monad m) => MHashableTo m Hash.Hash BakerCapital

-- | The total capital delegated to the baker.
bcTotalDelegatorCapital :: BakerCapital -> Amount
bcTotalDelegatorCapital = sum . fmap dcDelegatorCapital . bcDelegatorCapital

-- | The distribution of the staked capital among the baker pools and passive delegators.
data CapitalDistribution = CapitalDistribution
    { -- | Capital associated with baker pools in ascending order of baker ID
      bakerPoolCapital :: !(Vec.Vector BakerCapital),
      -- | Capital of passive delegators in ascending order of delegator ID
      passiveDelegatorsCapital :: !(Vec.Vector DelegatorCapital)
    }
    deriving (Show, Eq)

instance Serialize CapitalDistribution where
    put CapitalDistribution{..} = do
        putLength (Vec.length bakerPoolCapital) <> mapM_ put bakerPoolCapital
        putLength (Vec.length passiveDelegatorsCapital) <> mapM_ put passiveDelegatorsCapital

    get = do
        bakerPoolCapital <- flip Vec.generateM (const get) =<< getLength
        passiveDelegatorsCapital <- flip Vec.generateM (const get) =<< getLength
        return CapitalDistribution{..}

instance HashableTo Hash.Hash CapitalDistribution where
    getHash CapitalDistribution{..} =
        Hash.hashOfHashes
            (LFMBT.hashFromFoldable bakerPoolCapital)
            (LFMBT.hashFromFoldable passiveDelegatorsCapital)

instance (Monad m) => MHashableTo m Hash.Hash CapitalDistribution

-- | The empty 'CapitalDistribution', with no bakers or passive delegators.
emptyCapitalDistribution :: CapitalDistribution
emptyCapitalDistribution = CapitalDistribution Vec.empty Vec.empty

-- | Construct a 'CapitalDistribution' from a sorted list of bakers, with their equity capital and
--  delegator capitals, and the passive delegator capitals.  All lists are assumed to be in
--  ascending order of the 'BakerId' or 'DelegatorId', as appropriate.
makeCapitalDistribution :: [(BakerId, Amount, [(DelegatorId, Amount)])] -> [(DelegatorId, Amount)] -> CapitalDistribution
makeCapitalDistribution bakers passive =
    CapitalDistribution
        { bakerPoolCapital = Vec.fromList $ mkBakerCapital <$> bakers,
          passiveDelegatorsCapital = Vec.fromList $ mkDelegatorCapital <$> passive
        }
  where
    mkBakerCapital (bcBakerId, bcBakerEquityCapital, dels) =
        let bcDelegatorCapital = Vec.fromList $ mkDelegatorCapital <$> dels
        in  BakerCapital{..}
    mkDelegatorCapital (dcDelegatorId, dcDelegatorCapital) = DelegatorCapital{..}
