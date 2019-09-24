use byteorder::{ReadBytesExt, WriteBytesExt};

use crate::{
    common::{P2PNodeId, P2PPeer},
    network::{AsProtocolPacketType, NetworkId, ProtocolPacketType},
};
use concordium_common::{hybrid_buf::HybridBuf, HashBytes, Serial};

use crate::{failure::Fallible, utils};
use rand::RngCore;
use std::convert::TryFrom;

#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "s11n_serde", derive(Serialize, Deserialize))]
pub enum NetworkPacketType {
    DirectMessage(P2PNodeId),
    BroadcastedMessage(Vec<P2PNodeId>),
}

impl AsProtocolPacketType for NetworkPacketType {
    fn protocol_packet_type(&self) -> ProtocolPacketType {
        match self {
            NetworkPacketType::DirectMessage(..) => ProtocolPacketType::Direct,
            NetworkPacketType::BroadcastedMessage(..) => ProtocolPacketType::Broadcast,
        }
    }
}

impl Serial for NetworkPacketType {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<Self> {
        let protocol_type = ProtocolPacketType::try_from(source.read_u8()?)?;

        match protocol_type {
            ProtocolPacketType::Direct => Ok(NetworkPacketType::DirectMessage(
                P2PNodeId::deserial(source)?,
            )),
            ProtocolPacketType::Broadcast => Ok(NetworkPacketType::BroadcastedMessage(vec![])),
        }
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        target.write_u8(self.protocol_packet_type() as u8)?;

        match self {
            NetworkPacketType::DirectMessage(ref receiver) => receiver.serial(target),
            NetworkPacketType::BroadcastedMessage(..) => Ok(()),
        }
    }
}

pub type MessageId = HashBytes;

/// This is not *thread-safe* but this ensures it temporarily
#[derive(Clone, Builder, Debug)]
#[cfg_attr(feature = "s11n_serde", derive(Serialize, Deserialize))]
pub struct NetworkPacket {
    pub packet_type: NetworkPacketType,
    pub peer:        P2PPeer,
    pub network_id:  NetworkId,
    pub message:     HybridBuf,
}

impl NetworkPacket {
    pub fn generate_message_id() -> MessageId {
        let mut secure_bytes = vec![0u8; 256];
        let mut rng = rand::thread_rng();

        rng.fill_bytes(&mut secure_bytes);

        MessageId::new(&utils::sha256_bytes(&secure_bytes))
    }
}

impl Serial for NetworkPacket {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<Self> {
        Ok(NetworkPacket {
            packet_type: NetworkPacketType::deserial(source)?,
            peer:        P2PPeer::deserial(source)?,
            network_id:  NetworkId::deserial(source)?,
            message:     HybridBuf::deserial(source)?,
        })
    }

    fn serial<W: WriteBytesExt>(&self, target: &mut W) -> Fallible<()> {
        self.packet_type.serial(target)?;
        self.network_id.serial(target)?;
        self.message.serial(target)
    }
}
