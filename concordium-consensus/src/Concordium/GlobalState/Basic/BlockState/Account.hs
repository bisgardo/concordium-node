{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Concordium.GlobalState.Basic.BlockState.Account (
    module Concordium.GlobalState.Account,
    module Concordium.GlobalState.Basic.BlockState.Account,
) where

import Control.Monad
import Data.Coerce
import qualified Data.Map.Strict as Map
import Data.Maybe
import qualified Data.Serialize as S
import GHC.Stack (HasCallStack)
import Lens.Micro.Platform

import qualified Concordium.Crypto.SHA256 as Hash
import Concordium.GlobalState.Account
import Concordium.GlobalState.Basic.BlockState.AccountReleaseSchedule
import Concordium.ID.Parameters
import Concordium.ID.Types
import Concordium.Types.HashableTo
import Concordium.Utils.Serialization

import Concordium.Genesis.Data
import Concordium.Types
import Concordium.Types.Accounts
import Concordium.Types.Migration

-- | Type for how a 'PersistingAccountData' value is stored as part of
--  an account. This is stored with its hash.
type AccountPersisting = Hashed' PersistingAccountDataHash PersistingAccountData

-- | Make an 'AccountPersisting' value from a 'PersistingAccountData' value.
makeAccountPersisting :: PersistingAccountData -> AccountPersisting
makeAccountPersisting = makeHashed
{-# INLINE makeAccountPersisting #-}

-- | An (in-memory) account.
data Account (av :: AccountVersion) = Account
    { -- | Account data that seldom changes. Stored separately for efficient
      --  memory use and hashing.
      _accountPersisting :: !AccountPersisting,
      -- | The next sequence number of a transaction on this account.
      _accountNonce :: !Nonce,
      -- | This account amount contains all the amount owned by the account,
      --  excluding encrypted amounts. In particular, the available amount is
      --  @accountAmount - totalLockedUpBalance accountReleaseSchedule@.
      _accountAmount :: !Amount,
      -- | The encrypted amount
      _accountEncryptedAmount :: !AccountEncryptedAmount,
      -- | Locked-up amounts and their release schedule.
      _accountReleaseSchedule :: !(AccountReleaseSchedule av),
      -- | The baker or delegation associated with the account (if any).
      _accountStaking :: !(AccountStake av)
    }
    deriving (Eq, Show)

makeLenses ''Account

-- | A traversal for accessing the 'AccountBaker' record of an account if it has one.
--  This can be used for getting the baker (e.g. with '(^?)') or updating it (if it already exists)
--  but not for setting it unless the account already has a baker.
accountBaker :: Traversal' (Account av) (AccountBaker av)
accountBaker f = g
  where
    g acct@Account{_accountStaking = AccountStakeBaker bkr} =
        (\bkr' -> acct{_accountStaking = AccountStakeBaker bkr'}) <$> f bkr
    g acct = pure acct

-- | Get the baker from an account, on the basis that it is known to be a baker
unsafeAccountBaker :: (HasCallStack) => SimpleGetter (Account av) (AccountBaker av)
unsafeAccountBaker = singular accountBaker

-- | A traversal for accessing the 'AccountDelegation' record of an account if it has one.
--  This can be used for getting the delegation (e.g. with '(^?)') or updating it (if it already
--  exists) but not for setting it unless the account already has a baker.
accountDelegator :: Traversal' (Account av) (AccountDelegation av)
accountDelegator f = g
  where
    g acct@Account{_accountStaking = AccountStakeDelegate del} =
        (\del' -> acct{_accountStaking = AccountStakeDelegate del'}) <$> f del
    g acct = pure acct

-- | Get the delegator on an account, on the basis that it is known to be a delegator.
unsafeAccountDelegator :: (HasCallStack) => SimpleGetter (Account av) (AccountDelegation av)
unsafeAccountDelegator = singular accountDelegator

instance HasPersistingAccountData (Account av) where
    persistingAccountData = accountPersisting . unhashed

-- | Serialize an account. The serialization format may depend on the protocol version.
--
--  This format allows accounts to be stored in a reduced format by
--  eliding (some) data that can be inferred from context, or is
--  the default value.  Note that there can be multiple representations
--  of the same account.
serializeAccount :: (IsAccountVersion av) => GlobalContext -> S.Putter (Account av)
serializeAccount cryptoParams acct@Account{..} = do
    S.put flags
    when asfExplicitAddress $ S.put _accountAddress
    when asfExplicitEncryptionKey $ S.put _accountEncryptionKey
    unless asfThresholdIsOne $ S.put (aiThreshold _accountVerificationKeys)
    putCredentials
    when asfHasRemovedCredentials $ S.put (_accountRemovedCredentials ^. unhashed)
    S.put _accountNonce
    S.put _accountAmount
    when asfExplicitEncryptedAmount $ S.put _accountEncryptedAmount
    when asfExplicitReleaseSchedule $ serializeAccountReleaseSchedule _accountReleaseSchedule
    when asfHasBakerOrDelegation $ serializeAccountStake _accountStaking
  where
    PersistingAccountData{..} = acct ^. persistingAccountData
    flags = AccountSerializationFlags{..}
    initialCredId =
        credId
            ( Map.findWithDefault
                (error "Account missing initial credential")
                initialCredentialIndex
                _accountCredentials
            )
    asfExplicitAddress = _accountAddress /= addressFromRegIdRaw initialCredId
    -- There is an opportunity for improvement here. We do not have to convert
    -- the raw key to a structured one. We can check the equality directly on
    -- the byte representation (in fact equality is defined on those). However
    -- that requires a bit of work to expose the right raw values from
    -- cryptographic parameters.
    asfExplicitEncryptionKey = unsafeEncryptionKeyFromRaw _accountEncryptionKey /= makeEncryptionKey cryptoParams (unsafeCredIdFromRaw initialCredId)
    (asfMultipleCredentials, putCredentials) = case Map.toList _accountCredentials of
        [(i, cred)] | i == initialCredentialIndex -> (False, S.put cred)
        _ -> (True, putSafeMapOf S.put S.put _accountCredentials)
    asfExplicitEncryptedAmount = _accountEncryptedAmount /= initialAccountEncryptedAmount
    asfExplicitReleaseSchedule = _accountReleaseSchedule /= emptyAccountReleaseSchedule
    asfHasBakerOrDelegation = _accountStaking /= AccountStakeNone
    asfThresholdIsOne = aiThreshold _accountVerificationKeys == 1
    asfHasRemovedCredentials = _accountRemovedCredentials ^. unhashed /= EmptyRemovedCredentials

-- | Deserialize an account.
--  The serialization format may depend on the protocol version, and maybe migrated from one version
--  to another, using the 'StateMigrationParameters' provided.
deserializeAccount ::
    forall oldpv pv.
    (IsProtocolVersion oldpv, IsProtocolVersion pv) =>
    StateMigrationParameters oldpv pv ->
    GlobalContext ->
    S.Get (Account (AccountVersionFor pv))
deserializeAccount migration cryptoParams = do
    AccountSerializationFlags{..} <- S.get
    preAddress <- if asfExplicitAddress then Just <$> S.get else return Nothing
    preEncryptionKey <- if asfExplicitEncryptionKey then Just <$> S.get else return Nothing
    threshold <- if asfThresholdIsOne then return 1 else S.get
    let getCredentials
            | asfMultipleCredentials = do
                creds <- getSafeMapOf S.get S.get
                case Map.lookup initialCredentialIndex creds of
                    Nothing -> fail $ "Account has no credential with index " ++ show initialCredentialIndex
                    Just cred -> return (creds, credId cred)
            | otherwise = do
                cred <- S.get
                return (Map.singleton initialCredentialIndex cred, credId cred)
    (_accountCredentials, initialCredId) <- getCredentials
    _accountRemovedCredentials <- if asfHasRemovedCredentials then makeHashed <$> S.get else return emptyHashedRemovedCredentials
    let _accountVerificationKeys = getAccountInformation threshold _accountCredentials
    let _accountAddress = fromMaybe (addressFromRegIdRaw initialCredId) preAddress
        -- There is an opportunity for improvement here. We do not have to convert
        -- the raw credId to a structured one. We can directly construct the
        -- However that requires a bit of work to expose the right raw values from
        -- cryptographic parameters.
        _accountEncryptionKey = fromMaybe (toRawEncryptionKey (makeEncryptionKey cryptoParams (unsafeCredIdFromRaw initialCredId))) preEncryptionKey
    _accountNonce <- S.get
    _accountAmount <- S.get
    _accountEncryptedAmount <-
        if asfExplicitEncryptedAmount
            then S.get
            else return initialAccountEncryptedAmount
    _accountReleaseSchedule <-
        if asfExplicitReleaseSchedule
            then deserializeAccountReleaseSchedule (accountVersion @(AccountVersionFor oldpv))
            else return emptyAccountReleaseSchedule
    _accountStaking <-
        if asfHasBakerOrDelegation
            then migrateAccountStake migration <$> deserializeAccountStake
            else return AccountStakeNone
    let _accountPersisting = makeAccountPersisting PersistingAccountData{..}
    return Account{..}

-- | Generate hash inputs from an account for 'AccountV0' and 'AccountV1'.
accountHashInputsV0 :: (IsAccountVersion av, AccountStructureVersionFor av ~ 'AccountStructureV0) => Account av -> AccountHashInputsV0 av
accountHashInputsV0 Account{..} =
    AccountHashInputsV0
        { ahiNextNonce = _accountNonce,
          ahiAccountAmount = _accountAmount,
          ahiAccountEncryptedAmount = _accountEncryptedAmount,
          ahiAccountReleaseScheduleHash = getHash _accountReleaseSchedule,
          ahiPersistingAccountDataHash = getHash _accountPersisting,
          ahiAccountStakeHash = getAccountStakeHash _accountStaking
        }

-- | Generate hash inputs from an account for 'AccountV2'.
accountHashInputsV2 :: Account 'AccountV2 -> AccountHashInputsV2 'AccountV2
accountHashInputsV2 Account{..} =
    AccountHashInputsV2
        { ahi2NextNonce = _accountNonce,
          ahi2AccountBalance = _accountAmount,
          ahi2StakedBalance = stakedBalance,
          ahi2MerkleHash = getHash merkleInputs
        }
  where
    stakedBalance = case _accountStaking of
        AccountStakeNone -> 0
        AccountStakeBaker AccountBaker{..} -> _stakedAmount
        AccountStakeDelegate AccountDelegationV1{..} -> _delegationStakedAmount
    merkleInputs :: AccountMerkleHashInputs 'AccountV2
    merkleInputs =
        AccountMerkleHashInputsV2
            { amhi2PersistingAccountDataHash = getHash _accountPersisting,
              amhi2AccountStakeHash = getHash _accountStaking :: AccountStakeHash 'AccountV2,
              amhi2EncryptedAmountHash = getHash _accountEncryptedAmount,
              amhi2AccountReleaseScheduleHash = getHash _accountReleaseSchedule
            }

instance (IsAccountVersion av) => HashableTo (AccountHash av) (Account av) where
    getHash acc = makeAccountHash $ case accountVersion @av of
        SAccountV0 -> AHIV0 (accountHashInputsV0 acc)
        SAccountV1 -> AHIV1 (accountHashInputsV0 acc)
        SAccountV2 -> AHIV2 (accountHashInputsV2 acc)

instance forall av. (IsAccountVersion av) => HashableTo Hash.Hash (Account av) where
    getHash = coerce @(AccountHash av) . getHash

-- | Create an empty account with the given public key, address and credentials.
newAccountMultiCredential ::
    forall av.
    (IsAccountVersion av) =>
    -- | Cryptographic parameters, needed to derive the encryption key from the credentials.
    GlobalContext ->
    -- | The account threshold, how many credentials need to sign..
    AccountThreshold ->
    -- | Address of the account to be created.
    AccountAddress ->
    -- | Initial credentials on the account. NB: It is assumed that this map has a value at index 'initialCredentialIndex' (0).
    Map.Map CredentialIndex AccountCredential ->
    Account av
newAccountMultiCredential cryptoParams threshold _accountAddress cs =
    Account
        { _accountPersisting =
            makeAccountPersisting
                PersistingAccountData
                    { _accountEncryptionKey = toRawEncryptionKey (makeEncryptionKey cryptoParams (credId (cs Map.! initialCredentialIndex))),
                      _accountCredentials = toRawAccountCredential <$> cs,
                      _accountVerificationKeys = getAccountInformation threshold cs,
                      _accountRemovedCredentials = emptyHashedRemovedCredentials,
                      ..
                    },
          _accountNonce = minNonce,
          _accountAmount = 0,
          _accountEncryptedAmount = initialAccountEncryptedAmount,
          _accountReleaseSchedule = emptyAccountReleaseSchedule,
          _accountStaking = AccountStakeNone
        }

-- | Create an empty account with the given public key, address and credential.
newAccount :: (IsAccountVersion av) => GlobalContext -> AccountAddress -> AccountCredential -> Account av
newAccount cryptoParams _accountAddress credential =
    newAccountMultiCredential cryptoParams 1 _accountAddress (Map.singleton initialCredentialIndex credential)
