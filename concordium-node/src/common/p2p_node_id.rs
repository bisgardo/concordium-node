//! The node identifier.

use byteorder::{ReadBytesExt, WriteBytesExt};
use failure::Fallible;
use rand::distributions::{Distribution, Uniform};

use concordium_common::network_types::PeerId;
use crypto_common::{Buffer, Deserial, Serial};

use std::fmt;

/// The basic identifier of a node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[cfg_attr(feature = "s11n_serde", derive(Serialize, Deserialize))]
pub struct P2PNodeId(pub PeerId);

impl Default for P2PNodeId {
    fn default() -> Self {
        let mut rng = rand::thread_rng();
        let n = Uniform::from(0..PeerId::max_value()).sample(&mut rng);
        P2PNodeId(n)
    }
}

impl fmt::Display for P2PNodeId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{:016x}", self.0) }
}

impl std::str::FromStr for P2PNodeId {
    type Err = failure::Error;

    fn from_str(s: &str) -> Fallible<Self> {
        match PeerId::from_str_radix(s, 16) {
            Ok(n) => Ok(P2PNodeId(n)),
            Err(e) => bail!("Invalid Node Id ({})", e),
        }
    }
}

impl Serial for P2PNodeId {
    fn serial<W: Buffer + WriteBytesExt>(&self, target: &mut W) { self.0.serial(target); }
}

impl Deserial for P2PNodeId {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<Self> {
        Ok(P2PNodeId(u64::deserial(source)?))
    }
}

impl P2PNodeId {
    /// Obtain the integer behind the node id.
    pub fn as_raw(self) -> PeerId { self.0 }
}