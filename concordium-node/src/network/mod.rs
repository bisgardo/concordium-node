macro_rules! serialize_message {
    ($msg_type:expr, $content:expr) => {
        format!(
            "{}{}{}{}{}",
            crate::network::PROTOCOL_NAME,
            crate::network::PROTOCOL_VERSION,
            crate::common::get_current_stamp_b64(),
            $msg_type,
            $content
        )
        .into_bytes()
    };
}

pub mod buckets;
pub mod message;
pub mod packet;
pub mod protocol_message_type;
pub mod request;
pub mod response;
pub mod serialization;
pub mod network_id;

pub use self::{
    buckets::Buckets,
    message::NetworkMessage,
    packet::{NetworkPacket, NetworkPacketBuilder, NetworkPacketType},
    protocol_message_type::{ProtocolMessageType, AsProtocolMessageType, PROTOCOL_MESSAGE_TYPE_LENGTH},
    request::NetworkRequest,
    response::NetworkResponse,
    network_id::NetworkId
};

pub const PROTOCOL_NAME: &str = "CONCORDIUMP2P";
pub const PROTOCOL_VERSION: &str = "001";
pub const PROTOCOL_VERSION_2: u16 = 1;
pub const PROTOCOL_SENT_TIMESTAMP_LENGTH: usize = 12;
pub const PROTOCOL_HEADER_LENGTH: usize = 13 + 3 + PROTOCOL_SENT_TIMESTAMP_LENGTH;
pub const PROTOCOL_NODE_ID_LENGTH: usize = 16;
pub const PROTOCOL_SINCE_TIMESTAMP_LENGTH: usize = 16;
pub const PROTOCOL_PORT_LENGTH: usize = 5;
pub const PROTOCOL_MESSAGE_ID_LENGTH: usize = 64;
pub const PROTOCOL_NETWORK_ID_LENGTH: usize = 5;
pub const PROTOCOL_NETWORK_CONTENT_SIZE_LENGTH: usize = 10;
pub const PROTOCOL_MESSAGE_LENGTH: usize = PROTOCOL_HEADER_LENGTH
    + PROTOCOL_NODE_ID_LENGTH
    + PROTOCOL_PORT_LENGTH
    + PROTOCOL_MESSAGE_ID_LENGTH
    + PROTOCOL_NETWORK_ID_LENGTH
    + PROTOCOL_NETWORK_CONTENT_SIZE_LENGTH
    + PROTOCOL_MESSAGE_TYPE_LENGTH;

pub const PROTOCOL_WHOLE_PACKET_SIZE: usize = 4;
pub const PROTOCOL_MAX_MESSAGE_SIZE: usize = 268_435_456;

#[cfg(test)]
// panics with "attempt to subtract with overflow" when the assertion is broken
const_assert!(protocol_message_length; PROTOCOL_MESSAGE_LENGTH == 130);
