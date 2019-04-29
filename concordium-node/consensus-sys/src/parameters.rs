// https://gitlab.com/Concordium/consensus/globalstate-mockup/blob/master/globalstate/src/Concordium/GlobalState/Parameters.hs

use std::collections::HashMap;

use crate::common::*;

pub type BakerId = u64;

pub type LeadershipElectionNonce = Box<[u8]>;
pub type BakerSignVerifyKey = Encoded;
pub type BakerSignPrivateKey = Encoded;
pub type BakerElectionVerifyKey = Encoded;
pub type BakerElectionPrivateKey = Encoded;
pub type LotteryPower = f64;
pub type ElectionDifficulty = f64;

pub type VoterId = u64;
pub type VoterVerificationKey = Encoded;
pub type VoterVRFPublicKey = Encoded;
pub type VoterSignKey = Encoded;
pub type VoterPower = u64;

#[derive(Debug)]
pub struct BakerInfo {
    election_verify_key: BakerElectionVerifyKey,
    signature_verify_key: BakerSignVerifyKey,
    lottery_power: LotteryPower,
}

#[derive(Debug)]
pub struct BirkParameters {
    leadership_election_nonce: Encoded,
    election_difficulty: Encoded,
    bakers: HashMap<BakerId, BakerInfo>,
}

#[derive(Debug)]
pub struct VoterInfo {
    verification_key: VoterVerificationKey,
    public_key: VoterVRFPublicKey,
    voting_power: VoterPower,
}

pub type FinalizationParameters = Box<[VoterInfo]>;

pub type Timestamp = u64;

pub type Duration = u64;

#[derive(Debug)]
pub struct GenesisData {
    creation_time: Timestamp,
    slot_duration: Duration,
    birk_parameters: BirkParameters,
    finalization_parameters: FinalizationParameters,
}
