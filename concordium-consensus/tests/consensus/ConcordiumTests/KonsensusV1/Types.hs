-- | Testing of 'Concordium.KonsensusV1.Types' and 'Concordium.KonsensusV1.TreeState.Types' modules.
module ConcordiumTests.KonsensusV1.Types where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Serialize
import qualified Data.Vector as Vector
import Data.Word
import System.IO.Unsafe
import Test.HUnit
import Test.Hspec
import Test.QuickCheck

import qualified Concordium.Crypto.BlockSignature as Sig
import qualified Concordium.Crypto.BlsSignature as Bls
import Concordium.Crypto.DummyData
import qualified Concordium.Crypto.SHA256 as Hash
import qualified Concordium.Crypto.SignatureScheme as SigScheme
import qualified Concordium.Crypto.VRF as VRF
import Concordium.Types
import qualified Concordium.Types.DummyData as Dummy
import Concordium.Types.Transactions
import qualified Concordium.Types.Transactions as Transactions
import qualified Data.FixedByteString as FBS

import Concordium.KonsensusV1.TreeState.Types
import Concordium.KonsensusV1.Types
import Concordium.Types.Option

-- | Generate a 'FinalizerSet'. The size parameter determines the size of the committee that
--  the finalizers are (nominally) sampled from.
genFinalizerSet :: Gen FinalizerSet
genFinalizerSet = sized $ \s -> FinalizerSet . fromInteger <$> chooseInteger (0, 2 ^ s)

-- | An arbitrarily-chosen 'Bls.SecretKey'.
someBlsSecretKey :: Bls.SecretKey
someBlsSecretKey = generateBlsSecretKeyFromSeed 123456

-- | Create a bls secret key from the provided seed.
someOtherBlsSecretKey :: Word64 -> Bls.SecretKey
someOtherBlsSecretKey = generateBlsSecretKeyFromSeed . fromIntegral

-- | Generate a 'Bls.Signature' by signing an arbitrary 10-byte string with the 'someBlsSecretKey'.
--  This should generate a representative sample of signatures for serialization purposes.
genBlsSignature :: Gen Bls.Signature
genBlsSignature = flip Bls.sign someBlsSecretKey . BS.pack <$> vector 10

-- | Generate a quorum signature.
genQuorumSignature :: Gen QuorumSignature
genQuorumSignature = QuorumSignature <$> genBlsSignature

-- | Generate a quorum signature.
genTimeoutSignature :: Gen TimeoutSignature
genTimeoutSignature = TimeoutSignature <$> genBlsSignature

-- | Generate a random quorum signature message.
genQuorumSignatureMessage :: Gen QuorumSignatureMessage
genQuorumSignatureMessage = do
    qsmGenesis <- genBlockHash
    qsmBlock <- genBlockHash
    qsmRound <- genRound
    qsmEpoch <- genEpoch
    return QuorumSignatureMessage{..}

-- | Generate a random timeout signature message.
genTimeoutSignatureMessage :: Gen TimeoutSignatureMessage
genTimeoutSignatureMessage = do
    tsmGenesis <- genBlockHash
    tsmRound <- genRound
    tsmQCRound <- genRound
    tsmQCEpoch <- genEpoch
    return TimeoutSignatureMessage{..}

-- | Generate a block hash.
--  This generates an arbitrary hash.
genBlockHash :: Gen BlockHash
genBlockHash = BlockHash . Hash.Hash . FBS.pack <$> vector 32

-- | Generate a quorum certificate in a way that is suitable for testing serialization.
genQuorumCertificate :: Gen QuorumCertificate
genQuorumCertificate = do
    qcBlock <- genBlockHash
    qcRound <- Round <$> arbitrary
    qcEpoch <- arbitrary
    qcAggregateSignature <- genQuorumSignature
    qcSignatories <- genFinalizerSet
    return QuorumCertificate{..}

genQuorumMessage :: Gen QuorumMessage
genQuorumMessage = do
    qmSignature <- genQuorumSignature
    qmBlock <- genBlockHash
    qmFinalizerIndex <- genFinalizerIndex
    qmRound <- genRound
    qmEpoch <- genEpoch
    return QuorumMessage{..}

-- | Generate a 'FinalizationEntry' suitable for testing serialization.
--  The result satisfies the invariants.
genFinalizationEntry :: Gen FinalizationEntry
genFinalizationEntry = do
    feFinalizedQuorumCertificate <- genQuorumCertificate
    preQC <- genQuorumCertificate
    feSuccessorProof <- BlockQuasiHash . Hash.Hash . FBS.pack <$> vector 32
    let succRound = qcRound feFinalizedQuorumCertificate + 1
    let sqcEpoch = qcEpoch feFinalizedQuorumCertificate
    let feSuccessorQuorumCertificate =
            preQC
                { qcRound = succRound,
                  qcEpoch = sqcEpoch,
                  qcBlock = successorBlockHash (BlockHeader succRound sqcEpoch (qcBlock feFinalizedQuorumCertificate)) feSuccessorProof
                }
    return FinalizationEntry{..}

-- | Generate a 'FinalizerRounds' map. The number of entries is governed by the size parameter.
--  This satisfies the size invariant, but does guarantee that rounds have different sets of
--  finalizers.
genFinalizerRounds :: Gen FinalizerRounds
genFinalizerRounds =
    FinalizerRounds . Map.fromList
        <$> scale (min (fromIntegral (maxBound :: Word32))) (listOf genRoundFS)
  where
    genRoundFS = do
        r <- Round <$> arbitrary
        fs <- genFinalizerSet
        return (r, fs)

-- | Generate an arbitrary round.
genRound :: Gen Round
genRound = Round <$> arbitrary

-- | Generate an arbitrary epoch.
genEpoch :: Gen Epoch
genEpoch = arbitrary

-- | Generate a timeout certificate.
genTimeoutCertificate :: Gen TimeoutCertificate
genTimeoutCertificate = do
    tcRound <- genRound
    tcMinEpoch <- arbitrary
    tcFinalizerQCRoundsFirstEpoch <- genFinalizerRounds
    tcFinalizerQCRoundsSecondEpoch <-
        if null (theFinalizerRounds tcFinalizerQCRoundsFirstEpoch)
            then return tcFinalizerQCRoundsFirstEpoch
            else genFinalizerRounds
    tcAggregateSignature <- TimeoutSignature <$> genBlsSignature
    return TimeoutCertificate{..}

-- | Generate an arbitrary finalizer index
genFinalizerIndex :: Gen FinalizerIndex
genFinalizerIndex = FinalizerIndex <$> arbitrary

-- | Generate a timeout message body.
genTimeoutMessageBody :: Gen TimeoutMessageBody
genTimeoutMessageBody = do
    tmFinalizerIndex <- genFinalizerIndex
    tmQuorumCertificate <- genQuorumCertificate
    tmRound <-
        oneof
            [ return (qcRound tmQuorumCertificate + 1),
              do
                r <- chooseBoundedIntegral (qcRound tmQuorumCertificate, maxBound - 1)
                return $ r + 1
            ]
    tmAggregateSignature <- TimeoutSignature <$> genBlsSignature
    let tmEpoch = qcEpoch tmQuorumCertificate -- FIXME: is this correct?
    return TimeoutMessageBody{..}

-- | Generate a 'TimeoutMessage' signed by an arbitrarily-generated keypair.
genTimeoutMessage :: Gen TimeoutMessage
genTimeoutMessage = do
    body <- genTimeoutMessageBody
    kp <- genBlockKeyPair
    genesis <- genBlockHash
    return $ signTimeoutMessage body genesis kp

-- | Generate an arbitrary timestamp.
genTimestamp :: Gen Timestamp
genTimestamp = Timestamp <$> arbitrary

-- | Generate an arbitrary 'LeadershipElectionNonce'
genLeadershipElectionNonce :: Gen LeadershipElectionNonce
genLeadershipElectionNonce = Hash.Hash . FBS.pack <$> vector 32

-- | Generate a 'PersistentRoundStatus' suitable for testing serialization.
genPersistentRoundStatus :: Gen PersistentRoundStatus
genPersistentRoundStatus = do
    _prsLastSignedQuorumMessage <- oneof [Present <$> genQuorumMessage, return Absent]
    _prsLastSignedTimeoutMessage <- oneof [Present <$> genTimeoutMessage, return Absent]
    _prsLastBakedRound <- genRound
    _prsLatestTimeout <- oneof [Present <$> genTimeoutCertificate, return Absent]
    return PersistentRoundStatus{..}

-- | Generate an arbitrary vrf key pair.
someVRFKeyPair :: VRF.KeyPair
{-# NOINLINE someVRFKeyPair #-}
someVRFKeyPair = unsafePerformIO VRF.newKeyPair

-- | Generate an arbitrary block nonce.
genBlockNonce :: Gen BlockNonce
genBlockNonce = do
    let kp = someVRFKeyPair
        proof = VRF.prove kp BS.empty
    return proof

-- | An arbitrary account key pair.
someAccountKeyPair :: SigScheme.KeyPair
{-# NOINLINE someAccountKeyPair #-}
someAccountKeyPair = unsafePerformIO $ SigScheme.newKeyPair SigScheme.Ed25519

-- | Generate a vector of simple transfer transactions. The length of the vector is determined by the
--  size parameter.
--  Each transaction is signed by 'someAccountKeyPair', with the sender, receiver, amount and nonce
--  generated arbitrarily. The arrival times are all set to @TransactionTime maxBound@.
genTransactions :: Gen (Vector.Vector BlockItem)
genTransactions = Vector.fromList <$> listOf trans
  where
    trans = do
        sender <- Dummy.accountAddressFrom <$> arbitrary
        receiver <- Dummy.accountAddressFrom <$> arbitrary
        amt <- arbitrary
        nonce <- Nonce <$> arbitrary `suchThat` (> 0)
        return $ Dummy.makeTransferTransaction (someAccountKeyPair, sender) receiver amt nonce

-- | Generate an arbitrary baked block with no transactions.
--  The baker of the block is number 42.
genBakedBlock :: Gen BakedBlock
genBakedBlock = do
    bbRound <- genRound
    bbEpoch <- genEpoch
    bbTimestamp <- genTimestamp
    bbQuorumCertificate <- genQuorumCertificate
    bbNonce <- genBlockNonce
    bbStateHash <- StateHashV0 . Hash.Hash . FBS.pack <$> vector 32
    bbTransactions <- genTransactions
    return
        BakedBlock
            { bbTimeoutCertificate = Absent,
              bbEpochFinalizationEntry = Absent,
              bbTransactionOutcomesHash = Transactions.emptyTransactionOutcomesHashV1,
              bbBaker = 42,
              ..
            }

-- | Generate an arbitrary signed block with no transactions.
--  The signer of the block is chosen among the arbitrary signers.
--  The baker of the block is number 42.
--  This generator is suitable for testing serialization.
genSignedBlock :: Gen SignedBlock
genSignedBlock = do
    kp <- genBlockKeyPair
    bBlock <- genBakedBlock
    genesisHash <- genBlockHash
    return $! signBlock kp genesisHash bBlock

-- | Check that serialization followed by deserialization gives the identity.
serCheck :: (Eq a, Serialize a, Show a) => a -> Property
serCheck a = decode (encode a) === Right a

-- | Test that serializing then deserializing a finalizer set is the identity.
propSerializeFinalizerSet :: Property
propSerializeFinalizerSet = forAll genFinalizerSet serCheck

-- | Test that serializing then deserializing a quorum certificate is the identity.
propSerializeQuorumCertificate :: Property
propSerializeQuorumCertificate = forAll genQuorumCertificate serCheck

propSerializationQuorumMessage :: Property
propSerializationQuorumMessage = forAll genQuorumMessage serCheck

-- | Test that serializing then deserializing a finalization entry is the identity.
propSerializeFinalizationEntry :: Property
propSerializeFinalizationEntry = forAll genFinalizationEntry serCheck

-- | Test that serializing then deserializing a timeout certificate is the identity.
propSerializeTimeoutCertificate :: Property
propSerializeTimeoutCertificate = forAll genTimeoutCertificate serCheck

-- | Test that serializing then deserializing a timeout message body is the identity.
propSerializeTimeoutMessageBody :: Property
propSerializeTimeoutMessageBody = forAll genTimeoutMessageBody serCheck

-- | Test that serializing then deserializing a timeout message is the identity.
propSerializeTimeoutMessage :: Property
propSerializeTimeoutMessage = forAll genTimeoutMessage serCheck

-- | Test that serializing then deserializing a baked block is the identity.
propSerializeBakedBlock :: Property
propSerializeBakedBlock =
    forAll genBakedBlock $ \bb ->
        case runGet (getBakedBlock SP6 (TransactionTime 42)) $! runPut (putBakedBlock bb) of
            Left _ -> False
            Right bb' -> bb == bb'

-- | Test that serializing then deserializing a signed block is the identity.
propSerializeSignedBlock :: Property
propSerializeSignedBlock =
    forAll genSignedBlock $ \sb ->
        case runGet (getSignedBlock SP6 (TransactionTime 42)) $! runPut (putSignedBlock sb) of
            Left _ -> False
            Right sb' -> sb == sb'

propSerializePersistentRoundStatus :: Property
propSerializePersistentRoundStatus = forAll genPersistentRoundStatus serCheck

-- | Check that a signing a timeout message produces a timeout message that verifies with the key.
propSignTimeoutMessagePositive :: Property
propSignTimeoutMessagePositive =
    forAll genTimeoutMessageBody $ \body ->
        forAll genBlockKeyPair $ \kp ->
            forAll genBlockHash $ \genesis ->
                checkTimeoutMessageSignature (Sig.verifyKey kp) genesis (signTimeoutMessage body genesis kp)

-- | Check that a signing a timeout message produces a timeout message that does not verify with a
--  different key.
propSignTimeoutMessageDiffKey :: Property
propSignTimeoutMessageDiffKey =
    forAll genTimeoutMessageBody $ \body ->
        forAll genBlockKeyPair $ \kp1 ->
            forAll genBlockKeyPair $ \kp2 ->
                forAll genBlockHash $ \genesis ->
                    (kp1 /= kp2) ==>
                        not (checkTimeoutMessageSignature (Sig.verifyKey kp2) genesis (signTimeoutMessage body genesis kp1))

-- | Check that signing a timeout message and changing the body to something different produces a
--  timeout message that does not verify with the key.
propSignTimeoutMessageDiffBody :: Property
propSignTimeoutMessageDiffBody =
    forAll genTimeoutMessageBody $ \body1 ->
        forAll genTimeoutMessageBody $ \body2 ->
            forAll genBlockHash $ \genesis ->
                (body1 /= body2) ==>
                    forAll genBlockKeyPair $
                        \kp ->
                            not (checkTimeoutMessageSignature (Sig.verifyKey kp) genesis (signTimeoutMessage body1 genesis kp){tmBody = body2})

-- | Check that signing a quorum signature message produces a quorum signature that can be verified with the corresponding public key.
propSignQuorumSignatureMessageSingle :: Property
propSignQuorumSignatureMessageSingle =
    forAll genQuorumSignatureMessage $ \qsm ->
        (checkQuorumSignatureSingle qsm (Bls.derivePublicKey someBlsSecretKey) (signQuorumSignatureMessage qsm someBlsSecretKey))

-- | Check that signing a quorum signature message produces a quorum signature that cannot be verified with a different public key.
propSignQuorumSignatureMessageDiffKeySingle :: Property
propSignQuorumSignatureMessageDiffKeySingle =
    forAll genQuorumSignatureMessage $ \qsm ->
        not (checkQuorumSignatureSingle qsm (Bls.derivePublicKey someBlsSecretKey) (signQuorumSignatureMessage qsm (someOtherBlsSecretKey 0)))

-- | Check that signing a quorum signature message produces a quorum signature that cannot be verified with different contents.
propSignQuorumSignatureMessageDiffBodySingle :: Property
propSignQuorumSignatureMessageDiffBodySingle =
    forAll genQuorumSignatureMessage $ \qsm1 ->
        forAll genQuorumSignatureMessage $ \qsm2 ->
            (qsm1 /= qsm2) ==>
                not (checkQuorumSignatureSingle qsm1 (Bls.derivePublicKey someBlsSecretKey) (signQuorumSignatureMessage qsm2 someBlsSecretKey))

-- | Check that signing a quorum signature message produces a quorum signature that can be verified with the corresponding public key.
propSignQuorumSignatureMessage :: Property
propSignQuorumSignatureMessage =
    forAll genQuorumSignatureMessage $ \qsm ->
        let qs = signQuorumSignatureMessage qsm someBlsSecretKey
            qs' = signQuorumSignatureMessage qsm (someOtherBlsSecretKey 0) <> qs
            pubKeys = [(Bls.derivePublicKey someBlsSecretKey), (Bls.derivePublicKey (someOtherBlsSecretKey 0))]
        in  checkQuorumSignature qsm pubKeys qs'

-- | Check that signing a quorum signature message produces a quorum signature that cannot be verified with a different public key.
propSignQuorumSignatureMessageDiffKey :: Property
propSignQuorumSignatureMessageDiffKey =
    forAll genQuorumSignatureMessage $ \qsm ->
        let qs = signQuorumSignatureMessage qsm someBlsSecretKey
            qs' = signQuorumSignatureMessage qsm (someOtherBlsSecretKey 0) <> qs
            pubKeys = [(Bls.derivePublicKey someBlsSecretKey), (Bls.derivePublicKey (someOtherBlsSecretKey 1))]
        in  not (checkQuorumSignature qsm pubKeys qs')

-- | Check that signing a quorum signature message produces a quorum signature that cannot be verified with different contents.
propSignQuorumSignatureMessageDiffBody :: Property
propSignQuorumSignatureMessageDiffBody =
    forAll genQuorumSignatureMessage $ \qsm1 ->
        forAll genQuorumSignatureMessage $ \qsm2 ->
            (qsm1 /= qsm2) ==>
                let qs = signQuorumSignatureMessage qsm1 someBlsSecretKey
                    qs' = signQuorumSignatureMessage qsm2 (someOtherBlsSecretKey 0) <> qs
                    pubKeys = [(Bls.derivePublicKey someBlsSecretKey), (Bls.derivePublicKey (someOtherBlsSecretKey 1))]
                in  not (checkQuorumSignature qsm1 pubKeys qs')

propSignBakedBlock :: Property
propSignBakedBlock =
    forAll genBakedBlock $ \bb ->
        forAll genBlockHash $ \genesisHash ->
            forAll genBlockKeyPair $ \kp@(Sig.KeyPair _ pk) ->
                (verifyBlockSignature pk genesisHash (signBlock kp genesisHash bb))

propSignBakedBlockDiffKey :: Property
propSignBakedBlockDiffKey =
    forAll genBakedBlock $ \bb ->
        forAll genBlockHash $ \genesisHash ->
            forAll genBlockKeyPair $ \kp ->
                forAll genBlockKeyPair $ \(Sig.KeyPair _ pk1) ->
                    not (verifyBlockSignature pk1 genesisHash (signBlock kp genesisHash bb))

propFinalizerListIsInverseOfFinalizerSet :: Property
propFinalizerListIsInverseOfFinalizerSet =
    forAll genFinalizerSet $ \fis ->
        assertEqual
            "The FinalizerSets should be equal"
            fis
            (finalizerSet $ finalizerList fis)

tests :: Spec
tests = describe "KonsensusV1.Types" $ do
    it "FinalizerSet serialization" propSerializeFinalizerSet
    it "QuorumMessage serialization" propSerializationQuorumMessage
    it "QuorumCertificate serialization" propSerializeQuorumCertificate
    it "FinalizationEntry serialization" propSerializeFinalizationEntry
    it "TimeoutCertificate serialization" propSerializeTimeoutCertificate
    it "TimeoutMessageBody serialization" propSerializeTimeoutMessageBody
    it "TimeoutMessage serialization" propSerializeTimeoutMessage
    it "BakedBlock serialization" propSerializeBakedBlock
    it "SignedBlock serialization" propSerializeSignedBlock
    it "RoundStatus serialization" propSerializePersistentRoundStatus
    it "TimeoutMessage signature check positive" propSignTimeoutMessagePositive
    it "TimeoutMessage signature check fails with different key" propSignTimeoutMessageDiffKey
    it "TimeoutMessage signature check fails with different body" propSignTimeoutMessageDiffBody
    it "QuorumSignatureMessage signature check (single) positive" propSignQuorumSignatureMessageSingle
    it "QuorumSignatureMessage signature check (single) fails with different key" propSignQuorumSignatureMessageDiffKeySingle
    it "QuorumSignatureMessage signature check (single) fails with different body" propSignQuorumSignatureMessageDiffBodySingle
    it "QuorumSignatureMessage signature check positive" propSignQuorumSignatureMessage
    it "QuorumSignatureMessage signature check fails with different key" propSignQuorumSignatureMessageDiffKey
    it "QuorumSignatureMessage signature check fails with different body" propSignQuorumSignatureMessageDiffBody
    it "SignedBlock signature check positive" propSignBakedBlock
    it "SignedBlock signature fails with different key" propSignBakedBlockDiffKey
    it "Conversion to and from FinalizerSet" propFinalizerListIsInverseOfFinalizerSet
