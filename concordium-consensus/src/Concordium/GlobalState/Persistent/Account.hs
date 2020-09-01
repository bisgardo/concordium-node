{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MonoLocalBinds #-}

module Concordium.GlobalState.Persistent.Account where

import Control.Monad.IO.Class (MonadIO)
import Data.Serialize
import Lens.Micro.Platform

import qualified Concordium.Crypto.SHA256 as Hash
import Concordium.Types.HashableTo
import qualified Concordium.GlobalState.Basic.BlockState.Account as Transient
import Concordium.GlobalState.Persistent.BlobStore
import Concordium.Types
import Concordium.GlobalState.Account

data PersistentAccount = PersistentAccount {
  -- |Next available nonce for this account.
  _accountNonce :: !Nonce
  -- |Current public account balance.
  ,_accountAmount :: !Amount
  -- |List of encrypted amounts on the account.
  -- TODO (MRA) create bufferedref list
  ,_accountEncryptedAmount :: ![EncryptedAmount]
  -- |A pointer to account data that changes rarely
  ,_persistingData :: !(BufferedRef PersistingAccountData)
  -- |A hash of all account data. We store the hash explicitly here because we cannot compute the hash once
  -- the persisting account data is stored behind a pointer
  ,_accountHash :: !Hash.Hash
  } deriving Show

makeLenses ''PersistentAccount

instance MonadBlobStore m => BlobStorable m PersistentAccount where
    storeUpdate PersistentAccount{..} = do
        (pAccData, accData) <- storeUpdate _persistingData
        let persistentAcc = PersistentAccount {
                _persistingData = accData,
                ..
            }
        let putAccs = do
                    put _accountNonce
                    put _accountAmount
                    put _accountEncryptedAmount
                    pAccData
        return (putAccs, persistentAcc)
    store a = fst <$> storeUpdate a
    load = do
        _accountNonce <- get
        _accountAmount <- get
        _accountEncryptedAmount <- get
        mAccDataPtr <- load
        return $ do
          _persistingData <- mAccDataPtr
          pData <- loadBufferedRef _persistingData
          let _accountHash = makeAccountHash _accountNonce _accountAmount _accountEncryptedAmount pData
          return PersistentAccount {..}

instance HashableTo Hash.Hash PersistentAccount where
  getHash = _accountHash

instance Monad m => MHashableTo m Hash.Hash PersistentAccount

-- |Make a 'PersistentAccount' from an 'Transient.Account'.
makePersistentAccount :: MonadIO m => Transient.Account -> m PersistentAccount
makePersistentAccount Transient.Account{..} = do
  let _accountHash = makeAccountHash _accountNonce _accountAmount _accountEncryptedAmount _accountPersisting
  _persistingData <- makeBufferedRef _accountPersisting
  return PersistentAccount {..}

-- |Checks whether the two arguments represent the same account. (Used for testing.)
sameAccount :: MonadBlobStore m => Transient.Account -> PersistentAccount -> m Bool
sameAccount bAcc pAcc@PersistentAccount{..} = do
  _accountPersisting <- loadBufferedRef _persistingData
  return $ sameAccountHash bAcc pAcc && Transient.Account{..} == bAcc

-- |Checks whether the two arguments represent the same account by comparing the account hashes.
-- (Used for testing.)
sameAccountHash :: Transient.Account -> PersistentAccount -> Bool
sameAccountHash bAcc pAcc = getHash bAcc == _accountHash pAcc

-- |Load a field from an account's 'PersistingAccountData' pointer. E.g., @acc ^^. accountAddress@ returns the account's address.
(^^.) :: MonadBlobStore m
      => PersistentAccount
      -> Getting b PersistingAccountData b
      -> m b
acc ^^. l = (^. l) <$> loadBufferedRef (acc ^. persistingData)

{-# INLINE (^^.) #-}
infixl 8 ^^.

-- |Update a field of an account's 'PersistingAccountData' pointer, creating a new pointer.
-- Used to implement '.~~' and '%~~'.
setPAD :: MonadBlobStore m
          => (PersistingAccountData -> PersistingAccountData)
          -> PersistentAccount
          -> m PersistentAccount
setPAD f acc@PersistentAccount{..} = do
  pData <- loadBufferedRef (acc ^. persistingData)
  newPData <- makeBufferedRef $ f pData
  return $ acc & persistingData .~ newPData
               & accountHash .~ makeAccountHash _accountNonce _accountAmount _accountEncryptedAmount pData

-- |Set a field of an account's 'PersistingAccountData' pointer, creating a new pointer.
-- E.g., @acc & accountStakeDelegate .~~ Nothing@ sets the
-- account's stake delegate to 'Nothing'.
(.~~) :: MonadBlobStore m
      => ASetter PersistingAccountData PersistingAccountData a b
      -> b
      -> PersistentAccount
      -> m PersistentAccount
(.~~) l v = setPAD (l .~ v)

{-# INLINE (.~~) #-}
infixr 4 .~~

-- |Modify a field of an account's 'PersistingAccountData' pointer, creating a new pointer.
-- E.g., @acc & accountInstances %~~ Set.insert i@ inserts an instance @i@ to the set of an account's instances.
(%~~) :: MonadBlobStore m
      => ASetter PersistingAccountData PersistingAccountData a b
      -> (a -> b)
      -> PersistentAccount
      -> m PersistentAccount
(%~~) l f = setPAD (l %~ f)

{-# INLINE (%~~) #-}
infixr 4 %~~
