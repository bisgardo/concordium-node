{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |This module implements the 'TransactionVerifier' for consensus protocol V1.
module Concordium.KonsensusV1.TransactionVerifier where

import Control.Monad.Trans
import Data.Maybe (isJust)
import Lens.Micro.Platform

import qualified Concordium.ID.Types as ID
import Concordium.Types
import Concordium.Types.Parameters hiding (getChainParameters)

import qualified Concordium.GlobalState.BlockState as BS
import qualified Concordium.GlobalState.Persistent.BlockState as PBS
import Concordium.GlobalState.Types
import qualified Concordium.GlobalState.Types as GSTypes
import Concordium.KonsensusV1.TreeState.Implementation
import qualified Concordium.TransactionVerification as TVer

-- |Where a received transaction stems from.
-- A transaction is either received as part of a block or it
-- has been submitted individually to the consensus.
data TransactionOrigin = Block | Individual
    deriving (Eq, Show)

-- |Context for verifying a transaction.
data Context pv = Context
    { -- |The 'SkovData' to use for verifying a transaction.
      _ctxSkovData :: !(SkovData pv),
      -- |The block state to verify the transaction within.
      _ctxBlockState :: !(PBS.HashedPersistentBlockState pv),
      -- |Whether the transaction was received from a block or individually.
      _ctxTransactionOrigin :: !TransactionOrigin
    }

makeLenses ''Context

-- |A specialized transaction verifier for the consensus v1 protocol which
-- makes use of the 'Context pv' defined here.
newtype ConsensusV1TransactionVerifier m a = ConsensusV1TransactionVerifier (TVer.TransactionVerifierT' (Context (MPV m)) m a)
    deriving (Functor, Applicative, Monad, MonadTrans)

instance
    ( IsConsensusV1 (MPV m),
      MonadProtocolVersion m,
      BS.BlockStateQuery m,
      GSTypes.BlockState m ~ PBS.HashedPersistentBlockState (MPV m),
      r ~ Context (MPV m)
    ) =>
    TVer.TransactionVerifier (ConsensusV1TransactionVerifier m)
    where
    {-# INLINE getIdentityProvider #-}
    getIdentityProvider ipId = do
        bs <- view ctxBlockState
        lift $ BS.getIdentityProvider bs ipId
    {-# INLINE getAnonymityRevokers #-}
    getAnonymityRevokers arrIds = do
        bs <- view ctxBlockState
        lift $ BS.getAnonymityRevokers bs arrIds
    {-# INLINE getCryptographicParameters #-}
    getCryptographicParameters = do
        bs <- view ctxBlockState
        lift $ BS.getCryptographicParameters bs
    {-# INLINE registrationIdExists #-}
    registrationIdExists regId = do
        bs <- view ctxBlockState
        lift $ isJust <$> BS.getAccountByCredId bs (ID.toRawCredRegId regId)
    {-# INLINE getAccount #-}
    getAccount aaddr = do
        bs <- view ctxBlockState
        fmap snd <$> lift (BS.getAccount bs aaddr)
    {-# INLINE getNextUpdateSequenceNumber #-}
    getNextUpdateSequenceNumber uType = do
        bs <- view ctxBlockState
        lift $ BS.getNextUpdateSequenceNumber bs uType
    {-# INLINE getUpdateKeysCollection #-}
    getUpdateKeysCollection = do
        bs <- view ctxBlockState
        lift $ BS.getUpdateKeysCollection bs
    {-# INLINE getAccountAvailableAmount #-}
    getAccountAvailableAmount = lift . BS.getAccountAvailableAmount
    {-# INLINE getNextAccountNonce #-}
    getNextAccountNonce acc = do
        ctx <- ask
        -- If the transaction was received as part of a block
        -- then we check the account nonce from the `BlockState` in the context
        -- Otherwise if the transaction was received individually then we
        -- check the transaction table for the nonce.
        view ctxTransactionOrigin >>= \case
            Block -> lift (BS.getAccountNonce acc)
            Individual -> do
                aaddr <- lift $ BS.getAccountCanonicalAddress acc
                return $! fst $! doGetNextAccountNonce (accountAddressEmbed aaddr) (ctx ^. ctxSkovData)
    {-# INLINE getAccountVerificationKeys #-}
    getAccountVerificationKeys = lift . BS.getAccountVerificationKeys
    {-# INLINE energyToCcd #-}
    energyToCcd v = do
        bs <- view ctxBlockState
        rate <- lift $ _erEnergyRate <$> BS.getExchangeRates bs
        return $! computeCost rate v
    {-# INLINE getMaxBlockEnergy #-}
    getMaxBlockEnergy = do
        bs <- view ctxBlockState
        chainParams <- lift $ BS.getChainParameters bs
        return $! chainParams ^. cpConsensusParameters . cpBlockEnergyLimit
    {-# INLINE checkExactNonce #-}
    checkExactNonce = asks ((== Individual) . _ctxTransactionOrigin)
