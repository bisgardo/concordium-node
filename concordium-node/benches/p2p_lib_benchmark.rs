#[macro_use]
extern crate criterion;

use concordium_common::UCursor;

use p2p_client::{
    common::{P2PNodeId, P2PPeer, P2PPeerBuilder, PeerType},
    network::{NetworkId, NetworkPacket, NetworkPacketBuilder},
};
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    str::FromStr,
};

pub fn localhost_peer() -> P2PPeer {
    P2PPeerBuilder::default()
        .peer_type(PeerType::Node)
        .addr(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)),
            8888,
        ))
        .build()
        .unwrap()
}

pub fn make_direct_message_header(content_size: usize) -> Vec<u8> {
    let p2p_node_id = P2PNodeId::from_str("000000002dd2b6ed").unwrap();
    let pkt = NetworkPacketBuilder::default()
        .peer(P2PPeer::from(
            PeerType::Node,
            p2p_node_id,
            SocketAddr::new(IpAddr::from_str("127.0.0.1").unwrap(), 8888),
        ))
        .message_id(NetworkPacket::generate_message_id())
        .network_id(NetworkId::from(111u16))
        .message(Box::new(UCursor::from(vec![])))
        .build_direct(P2PNodeId::from_str("100000002dd2b6ed").unwrap())
        .unwrap();

    let mut h = pkt.serialize();

    // chop the last 10 bytes which are the length of the message
    h.truncate(h.len() - 10);
    h.append(&mut format!("{:010}", content_size).into_bytes());
    h
}

#[cfg(any(
    not(feature = "s11n_nom"),
    not(feature = "s11n_capnp"),
    not(feature = "s11n_serde_cbor"),
    not(feature = "s11n_serde_json")
))]
mod common {
    use criterion::Criterion;
    pub fn nop_bench(_c: &mut Criterion) {}
}

mod network {
    pub mod message {
        use crate::make_direct_message_header;
        use concordium_common::{ContainerView, UCursor};
        use p2p_client::{
            common::{P2PPeerBuilder, PeerType, RemotePeer},
            network::NetworkMessage,
        };
        use rand::{distributions::Alphanumeric, thread_rng, Rng};
        use std::{
            io::Write,
            net::{IpAddr, Ipv4Addr, SocketAddr},
        };

        use criterion::Criterion;

        fn make_direct_message_into_disk(content_size: usize) -> UCursor {
            let header = make_direct_message_header(content_size);
            let mut cursor = UCursor::build_from_temp_file().unwrap();
            let _ = cursor.write_all(header.as_slice());

            let mut pending_content_size = content_size;
            while pending_content_size != 0 {
                let chunk: String = thread_rng()
                    .sample_iter(&Alphanumeric)
                    .take(std::cmp::min(4096, pending_content_size))
                    .collect();
                pending_content_size -= chunk.len();

                let _ = cursor.write_all(chunk.as_bytes());
            }

            assert_eq!(cursor.len(), (content_size + header.len()) as u64);
            cursor
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256 * 1024)
        }

        pub fn bench_s11n_001_direct_message_1m(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_4m(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4 * 1024 * 1024)
        }

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) {
            let content: String = thread_rng()
                .sample_iter(&Alphanumeric)
                .take(content_size)
                .collect();

            let mut pkt: Vec<u8> = make_direct_message_header(content.len());
            pkt.append(&mut content.into_bytes());
            let data = ContainerView::from(pkt);

            let local_ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
            let local_peer = P2PPeerBuilder::default()
                .peer_type(PeerType::Node)
                .addr(SocketAddr::new(local_ip, 8888))
                .build()
                .unwrap();
            let bench_id = format!(
                "Benchmark deserialization of Direct Message with {} bytes on payload",
                content_size
            );

            c.bench_function(&bench_id, move |b| {
                let cloned_data = data.clone();
                let peer = RemotePeer::PostHandshake(local_peer.clone());
                let ip = local_ip;

                b.iter(move || {
                    let s11n_cursor = UCursor::build_from_view(cloned_data.clone());
                    NetworkMessage::deserialize(peer.clone(), ip.clone(), s11n_cursor)
                })
            });
        }

        pub fn bench_s11n_001_direct_message_8m(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 8 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_128m(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 128 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256m(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 256 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_512m(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 512 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_1g(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 1024 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_4g(b: &mut Criterion) {
            bench_s11n_001_direct_message_from_disk(b, 4 * 1024 * 1024 * 1024)
        }

        fn bench_s11n_001_direct_message_from_disk(c: &mut Criterion, content_size: usize) {
            // Create serialization data in memory and then move to disk
            let cursor_on_disk = make_direct_message_into_disk(content_size);

            // Local stuff
            let local_ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
            let local_peer = P2PPeerBuilder::default()
                .peer_type(PeerType::Node)
                .addr(SocketAddr::new(local_ip.clone(), 8888))
                .build()
                .unwrap();
            let bench_id = format!(
                "Benchmark deserialization of Direct Message with {} bytes on payload using \
                 temporal files",
                content_size
            );

            c.bench_function(&bench_id, move |b| {
                let cursor = cursor_on_disk.clone();
                let peer = RemotePeer::PostHandshake(local_peer.clone());

                b.iter(move || {
                    let s11n_cursor = cursor.clone();
                    NetworkMessage::deserialize(peer.clone(), local_ip.clone(), s11n_cursor)
                })
            });
        }

    }
}

mod serialization {
    #[cfg(feature = "s11n_serde_cbor")]
    pub mod serde_cbor {
        use crate::localhost_peer;
        use concordium_common::UCursor;
        use p2p_client::{
            common::P2PNodeId,
            network::{
                serialization::cbor::s11n_network_message, NetworkId, NetworkMessage,
                NetworkPacketBuilder,
            },
        };

        use rand::{distributions::Alphanumeric, thread_rng, Rng};
        use std::str::FromStr;

        use criterion::Criterion;
        use serde_cbor::ser;

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) {
            let content: String = thread_rng()
                .sample_iter(&Alphanumeric)
                .take(content_size)
                .collect();

            let dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                    .peer(localhost_peer())
                    .message_id(format!("{:064}", 100))
                    .network_id(NetworkId::from(100u16))
                    .message(Box::new(UCursor::from(content.into_bytes())))
                    .build_direct(P2PNodeId::from_str(&"2A").unwrap())
                    .unwrap(),
                Some(10),
                None,
            );

            let data: Vec<u8> = ser::to_vec(&dm).unwrap();

            let bench_id = format!("Benchmark Serde CBOR using {} bytes", content_size);
            c.bench_function(&bench_id, move |b| {
                let local_data = data.as_slice();
                b.iter(move || s11n_network_message(local_data))
            });
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_serde_json")]
    pub mod serde_json {
        use crate::localhost_peer;
        use concordium_common::UCursor;

        use p2p_client::{
            common::P2PNodeId,
            network::{
                serialization::json::s11n_network_message, NetworkId, NetworkMessage,
                NetworkPacketBuilder,
            },
        };

        use rand::{distributions::Standard, thread_rng, Rng};
        use std::str::FromStr;

        use criterion::Criterion;

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) {
            let content: Vec<u8> = thread_rng()
                .sample_iter(&Standard)
                .take(content_size)
                .collect();
            let content_cursor = UCursor::from(content);

            let dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                    .peer(localhost_peer())
                    .message_id(format!("{:064}", 100))
                    .network_id(NetworkId::from(100u16))
                    .message(Box::new(content_cursor))
                    .build_direct(P2PNodeId::from_str(&"2A").unwrap())
                    .unwrap(),
                Some(10),
                None,
            );

            let data: String = serde_json::to_string(&dm).unwrap();

            let bench_id = format!("Benchmark Serde JSON using {} bytes", content_size);
            c.bench_function(&bench_id, move |b| {
                let data_raw: &str = data.as_str();
                b.iter(move || s11n_network_message(data_raw))
            });
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_nom")]
    pub mod nom {

        use p2p_client::network::serialization::nom::s11n_network_message;

        use crate::make_direct_message_header;

        use rand::{distributions::Alphanumeric, thread_rng, Rng};

        use criterion::Criterion;

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) {
            let content: String = thread_rng()
                .sample_iter(&Alphanumeric)
                .take(content_size)
                .collect();

            let mut pkt = make_direct_message_header(content.len());
            pkt.append(&mut content.into_bytes());

            let bench_id = format!("Benchmark NOM using {} bytes", content_size);
            c.bench_function(&bench_id, move |b| {
                let data = &pkt.clone()[..];
                b.iter(move || s11n_network_message(data));
            });
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_capnp")]
    pub mod capnp {
        use crate::localhost_peer;

        use concordium_common::UCursor;

        use p2p_client::{
            common::{P2PNodeId, P2PPeerBuilder, PeerType},
            network::{
                serialization::cap::{deserialize, save_network_message},
                NetworkId, NetworkMessage, NetworkPacketBuilder,
            },
        };

        use criterion::Criterion;
        use std::str::FromStr;

        use rand::{distributions::Standard, thread_rng, Rng};
        use std::net::{IpAddr, Ipv4Addr, SocketAddr};

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) {
            let content: Vec<u8> = thread_rng()
                .sample_iter(&Standard)
                .take(content_size)
                .collect();
            let content_cursor = UCursor::from(content);

            let local_ip = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1));
            let local_peer = P2PPeerBuilder::default()
                .peer_type(PeerType::Node)
                .addr(SocketAddr::new(local_ip, 8888))
                .build()
                .unwrap();

            let mut dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                    .peer(localhost_peer())
                    .message_id(format!("{:064}", 100))
                    .network_id(NetworkId::from(111u16))
                    .message(Box::new(content_cursor))
                    .build_direct(P2PNodeId::from_str(&"2A").unwrap())
                    .unwrap(),
                Some(10),
                None,
            );

            let data: Vec<u8> = save_network_message(&mut dm);

            let bench_id = format!("Benchmark CAPnP using {} bytes", content_size);
            c.bench_function(&bench_id, move |b| {
                let data_raw: &[u8] = data.as_slice();
                b.iter(|| deserialize(&local_peer, &local_ip, data_raw))
            });
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) {
            bench_s11n_001_direct_message(b, 256 * 1024)
        }

    }
}

criterion_group!(
    s11n_custom_benches,
    network::message::bench_s11n_001_direct_message_256,
    network::message::bench_s11n_001_direct_message_512,
    network::message::bench_s11n_001_direct_message_1k,
    network::message::bench_s11n_001_direct_message_4k,
    network::message::bench_s11n_001_direct_message_32k,
    network::message::bench_s11n_001_direct_message_64k,
    network::message::bench_s11n_001_direct_message_256k,
    network::message::bench_s11n_001_direct_message_1m,
    network::message::bench_s11n_001_direct_message_4m,
    network::message::bench_s11n_001_direct_message_8m,
    network::message::bench_s11n_001_direct_message_128m,
    network::message::bench_s11n_001_direct_message_256m,
    network::message::bench_s11n_001_direct_message_512m,
    network::message::bench_s11n_001_direct_message_1g,
    network::message::bench_s11n_001_direct_message_4g,
);

#[cfg(feature = "s11n_serde_cbor")]
criterion_group!(
    s11n_cbor_benches,
    serialization::serde_cbor::bench_s11n_001_direct_message_256,
    serialization::serde_cbor::bench_s11n_001_direct_message_512,
    serialization::serde_cbor::bench_s11n_001_direct_message_1k,
    serialization::serde_cbor::bench_s11n_001_direct_message_4k,
    serialization::serde_cbor::bench_s11n_001_direct_message_32k,
    serialization::serde_cbor::bench_s11n_001_direct_message_64k,
    serialization::serde_cbor::bench_s11n_001_direct_message_256k,
);
#[cfg(not(feature = "s11n_serde_cbor"))]
criterion_group!(s11n_cbor_benches, common::nop_bench);

#[cfg(feature = "s11n_serde_json")]
criterion_group!(
    s11n_json_benches,
    serialization::serde_json::bench_s11n_001_direct_message_256,
    serialization::serde_json::bench_s11n_001_direct_message_512,
    serialization::serde_json::bench_s11n_001_direct_message_1k,
    serialization::serde_json::bench_s11n_001_direct_message_4k,
    serialization::serde_json::bench_s11n_001_direct_message_32k,
    serialization::serde_json::bench_s11n_001_direct_message_64k,
    serialization::serde_json::bench_s11n_001_direct_message_256k,
);
#[cfg(not(feature = "s11n_serde_json"))]
criterion_group!(s11n_json_benches, common::nop_bench);

#[cfg(feature = "s11n_nom")]
criterion_group!(
    s11n_nom_benches,
    serialization::nom::bench_s11n_001_direct_message_256,
    serialization::nom::bench_s11n_001_direct_message_512,
    serialization::nom::bench_s11n_001_direct_message_1k,
    serialization::nom::bench_s11n_001_direct_message_4k,
    serialization::nom::bench_s11n_001_direct_message_32k,
    serialization::nom::bench_s11n_001_direct_message_64k,
    serialization::nom::bench_s11n_001_direct_message_256k,
);
#[cfg(not(feature = "s11n_nom"))]
criterion_group!(s11n_nom_benches, common::nop_bench);

#[cfg(feature = "s11n_capnp")]
criterion_group!(
    s11n_capnp_benches,
    serialization::capnp::bench_s11n_001_direct_message_256,
    serialization::capnp::bench_s11n_001_direct_message_512,
    serialization::capnp::bench_s11n_001_direct_message_1k,
    serialization::capnp::bench_s11n_001_direct_message_4k,
    serialization::capnp::bench_s11n_001_direct_message_32k,
    serialization::capnp::bench_s11n_001_direct_message_64k,
    serialization::capnp::bench_s11n_001_direct_message_256k,
);
#[cfg(not(feature = "s11n_capnp"))]
criterion_group!(s11n_capnp_benches, common::nop_bench);

criterion_main!(
    s11n_custom_benches,
    s11n_cbor_benches,
    s11n_json_benches,
    s11n_nom_benches,
    s11n_capnp_benches
);
