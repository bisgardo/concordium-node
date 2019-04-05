#[macro_use] extern crate criterion;

use p2p_client::common::{ P2PPeer, P2PPeerBuilder, ConnectionType };
use std::net::{ IpAddr, Ipv4Addr };

pub fn localhost_peer() -> P2PPeer {
    P2PPeerBuilder::default()
        .connection_type( ConnectionType::Node)
        .ip( IpAddr::V4(Ipv4Addr::new(127,0,0,1)))
        .port( 8888)
        .build().unwrap()
}

mod common {
    use failure::{ Fallible };
    use criterion::Criterion;

    pub fn nop_bench( _c: &mut Criterion) -> Fallible<()> {
        Ok(())
    }

    pub mod ucursor {
        use p2p_client::common::{ ContainerView, UCursor };

        use rand::{ thread_rng, Rng };
        use rand::distributions::{ Standard };
        use criterion::Criterion;

        fn make_content_with_size( content_size: usize) -> Vec<u8>
        {
            thread_rng().sample_iter( &Standard)
                .take( content_size).collect::<Vec<u8>>()
        }

        pub fn from_memory_to_file_1m(b: &mut Criterion) {
            from_memory_to_file( 1024 * 1024, b)
        }

        pub fn from_memory_to_file_4m(b: &mut Criterion) {
            from_memory_to_file( 4* 1024 * 1024, b)
        }

        pub fn from_memory_to_file_32m(b: &mut Criterion) {
            from_memory_to_file( 32 * 1024 * 1024, b)
        }

        fn from_memory_to_file( content_size: usize, c: &mut Criterion) {
            let content = make_content_with_size( content_size);
            let view = ContainerView::from(content);
            let bench_id = format!( "Benchmark from memory to file using {} bytes", content_size);

            c.bench_function(
                bench_id.as_str(),
                move |b| {
                    let cloned_view = view.clone();
                    b.iter( || {
                        let mut cur = UCursor::build_from_view( cloned_view.clone());
                        cur.to_file()
                    })
                });
        }
    }
}

mod network {
    pub mod message {
        use p2p_client::common::{ ContainerView, UCursor, P2PPeerBuilder, ConnectionType };
        use p2p_client::network::{
            NetworkMessage,
            PROTOCOL_NAME, PROTOCOL_VERSION, PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE };

        use std::net::{ IpAddr, Ipv4Addr };
        use std::io::Write;
        use rand::distributions::{ Alphanumeric };
        use rand::{ thread_rng, Rng };

        use failure::{ Fallible };
        use criterion::Criterion;

        fn make_direct_message_into_disk( content_size: usize) -> Fallible<UCursor>
        {
            let header = format!("{}{:03}{:016X}{:03}{:064X}{:064}{:05}{:010}",
                                 PROTOCOL_NAME, PROTOCOL_VERSION, 10,
                                 PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE,
                                 42, 100, 111, content_size).as_bytes().to_vec();

            let mut cursor = UCursor::build_from_temp_file()?;
            cursor.write_all( header.as_slice())?;

            let mut pending_content_size = content_size;
            while pending_content_size != 0 {
                let chunk :String = thread_rng()
                    .sample_iter( &Alphanumeric)
                    .take( std::cmp::min( 4096, pending_content_size))
                    .collect();
                pending_content_size -= chunk.len();

                cursor.write_all( chunk.as_bytes())?;
            }

            assert_eq!( cursor.len(), (content_size + header.len()) as u64);
            Ok(cursor)
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 256 * 1024)
        }

        pub fn bench_s11n_001_direct_message_1m(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_4m(b: &mut Criterion) -> Fallible<()>  {
            bench_s11n_001_direct_message( b, 4 * 1024 * 1024)
        }

        fn bench_s11n_001_direct_message( c: &mut Criterion, content_size: usize) -> Fallible<()>
        {
            let content: String = thread_rng().sample_iter( &Alphanumeric)
                .take( content_size).collect();

            let data_str = format!("{}{:03}{:016X}{:03}{:064X}{:064}{:05}{:010}{}",
                                   PROTOCOL_NAME, PROTOCOL_VERSION, 10,
                                   PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE,
                                   42, 100, 111, content.len(), content);
            let data = ContainerView::from( Vec::from( data_str));

            let local_ip = IpAddr::V4( Ipv4Addr::new(127,0,0,1));
            let local_peer = P2PPeerBuilder::default()
                .connection_type( ConnectionType::Node)
                .ip( local_ip)
                .port(8888)
                .build()?;
            let bench_id = format!( "Benchmark deserialization of Direct Message with {} bytes on payload", content_size);


            c.bench_function(
                &bench_id,
                move |b| {
                    let cloned_data = data.clone();
                    let peer = Some(local_peer.clone());
                    let ip = local_ip;

                    b.iter( move ||{
                        let s11n_cursor = UCursor::build_from_view( cloned_data.clone());
                        NetworkMessage::deserialize(
                            peer.clone(),
                            ip.clone(),
                            s11n_cursor)
                    })
                }
            );

            Ok(())
        }


        pub fn bench_s11n_001_direct_message_8m(b: &mut Criterion) -> Fallible<()>{
            bench_s11n_001_direct_message_from_disk( b, 8 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_128m(b: &mut Criterion) -> Fallible<()>{
            bench_s11n_001_direct_message_from_disk( b, 128 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256m(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message_from_disk( b, 256 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_512m(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message_from_disk( b, 512 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_1g(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message_from_disk( b, 1024 * 1024 * 1024)
        }

        pub fn bench_s11n_001_direct_message_4g(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message_from_disk( b, 4* 1024 * 1024 * 1024)
        }

        fn bench_s11n_001_direct_message_from_disk(c: &mut Criterion, content_size: usize) -> Fallible<()>
        {
            // Create serialization data in memory and then move to disk
            let cursor_on_disk = make_direct_message_into_disk( content_size)?;

            // Local stuff
            let local_ip = IpAddr::V4( Ipv4Addr::new(127,0,0,1));
            let local_peer = P2PPeerBuilder::default()
                .connection_type( ConnectionType::Node)
                .ip( local_ip.clone())
                .port(8888)
                .build()?;
            let bench_id = format!("Benchmark deserialization of Direct Message with {} bytes on payload using temporal files",
                            content_size);

            c.bench_function(
                &bench_id,
                move |b| {
                    let cursor = cursor_on_disk.clone();
                    let peer = Some(local_peer.clone());

                    b.iter( move || {
                        let s11n_cursor = cursor.clone();
                        NetworkMessage::deserialize(
                            peer.clone(),
                            local_ip.clone(),
                            s11n_cursor)
                    })
                }
            );

            Ok(())
        }

    }
}

mod serialization {
    #[cfg(feature = "s11n_serde_cbor")]
    pub mod serde_cbor {
        use crate::localhost_peer;

        use p2p_client::common::{ UCursor, P2PNodeId };
        use p2p_client::network::{ NetworkMessage, NetworkPacketBuilder };
        use p2p_client::network::serialization::cbor::{ s11n_network_message };

        use rand::{ thread_rng, Rng };
        use rand::distributions::{ Alphanumeric };

        use serde_cbor::ser;
        use criterion::Criterion;
        use failure::{ Fallible };

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) -> Fallible<()>
        {
            let content: String = thread_rng().sample_iter( &Alphanumeric)
                .take( content_size).collect();

            let dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                .peer( localhost_peer())
                .message_id( format!("{:064}",100))
                .network_id( 111)
                .message( UCursor::from( content.into_bytes()))
                .build_direct( P2PNodeId::from_string("2A")?)?,
                Some(10), None);

            let data: Vec<u8> = ser::to_vec( &dm)?;

            let bench_id = format!( "Benchmark Serde CBOR using {} bytes", content_size);
            c.bench_function(
                &bench_id,
                move |b| {
                    let local_data = data.as_slice();
                    b.iter( move ||{
                        s11n_network_message( local_data)
                    })
                }
            );

            Ok(())
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_serde_json")]
    pub mod serde_json {
        use crate::localhost_peer;

        use p2p_client::common::{ UCursor, P2PNodeId };
        use p2p_client::network::{ NetworkMessage, NetworkPacketBuilder };
        use p2p_client::network::serialization::json::{ s11n_network_message };

        use rand::{ thread_rng, Rng };
        use rand::distributions::{ Standard };

        use criterion::Criterion;
        use failure::{ Fallible };

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) -> Fallible<()> {
            let content: Vec<u8> = thread_rng().sample_iter( &Standard)
                .take( content_size).collect();
            let content_cursor = UCursor::from( content);

            let dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                .peer( localhost_peer())
                .message_id( format!("{:064}",100))
                .network_id( 111)
                .message( content_cursor)
                .build_direct( P2PNodeId::from_string("2A")?)?,
                Some(10), None);

            let data: String = serde_json::to_string( &dm)?;

            let bench_id = format!( "Benchmark Serde JSON using {} bytes", content_size);
            c.bench_function(
                &bench_id,
                move |b| {
                    let data_raw: &str = data.as_str();
                    b.iter( move ||{
                        s11n_network_message( data_raw)
                    })
                });

            Ok(())
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_nom")]
    pub mod nom {
        use p2p_client::network::{ PROTOCOL_NAME, PROTOCOL_VERSION, PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE };

        use p2p_client::network::serialization::nom::{ s11n_network_message };
       
        use rand::{ thread_rng, Rng };
        use rand::distributions::{ Alphanumeric };

        use criterion::Criterion;
        use failure::{ Fallible };

        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) -> Fallible<()> {

            let content: String = thread_rng().sample_iter( &Alphanumeric)
                .take( content_size).collect();

            let data_str = format!("{}{:03}{:016X}{:03}{:064X}{:064}{:05}{:010}{}",
                                   PROTOCOL_NAME, PROTOCOL_VERSION, 10,
                                   PROTOCOL_MESSAGE_TYPE_DIRECT_MESSAGE,
                                   42, 100, 111, content.len(), content);

            let bench_id = format!( "Benchmark NON using {} bytes", content_size);
            c.bench_function(
                &bench_id,
                move |b| {
                    let data = data_str.as_bytes();

                    b.iter( move ||{
                        s11n_network_message( data)
                    });
                });

            Ok(())
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256 * 1024)
        }
    }

    #[cfg(feature = "s11n_capnp")]
    pub mod capnp {
        use crate::localhost_peer;

        use p2p_client::common::{ UCursor, P2PNodeId, P2PPeerBuilder, ConnectionType };
        use p2p_client::network::{ NetworkMessage, NetworkPacketBuilder };
        use p2p_client::network::serialization::cap::{ save_network_message, deserialize };

        use criterion::Criterion;
        use failure::{ Fallible };
   
        use rand::{ thread_rng, Rng };
        use rand::distributions::{ Standard };
        use std::net::{ IpAddr, Ipv4Addr };
       
        fn bench_s11n_001_direct_message(c: &mut Criterion, content_size: usize) -> Fallible<()> {
            let content: Vec<u8> = thread_rng().sample_iter( &Standard)
                .take( content_size).collect();
            let content_cursor = UCursor::from( content);

            let local_ip = IpAddr::V4( Ipv4Addr::new(127,0,0,1));
            let local_peer = P2PPeerBuilder::default()
                .connection_type( ConnectionType::Node)
                .ip( local_ip)
                .port( 8888)
                .build().unwrap();

            let mut dm = NetworkMessage::NetworkPacket(
                NetworkPacketBuilder::default()
                .peer( localhost_peer())
                .message_id( format!("{:064}",100))
                .network_id( 111)
                .message( content_cursor)
                .build_direct( P2PNodeId::from_string("2A").unwrap()).unwrap(),
                Some(10), None);

            let data: Vec<u8> = save_network_message( &mut dm);

            let bench_id = format!( "Benchmark CAPnP using {} bytes", content_size);
            c.bench_function(
                &bench_id,
                move |b| {
                    let data_raw: &[u8]= data.as_slice();
                    b.iter( ||{
                        deserialize( &local_peer, &local_ip, data_raw)
                    })
                });

            Ok(())
        }

        pub fn bench_s11n_001_direct_message_256(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256)
        }

        pub fn bench_s11n_001_direct_message_512(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 512)
        }

        pub fn bench_s11n_001_direct_message_1k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 1024)
        }

        pub fn bench_s11n_001_direct_message_4k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 4096)
        }

        pub fn bench_s11n_001_direct_message_32k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 32 * 1024)
        }

        pub fn bench_s11n_001_direct_message_64k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 64 * 1024)
        }

        pub fn bench_s11n_001_direct_message_256k(b: &mut Criterion) -> Fallible<()> {
            bench_s11n_001_direct_message( b, 256 * 1024)
        }

    }
}

criterion_group!(
    ucursor_benches,
    common::ucursor::from_memory_to_file_1m,
    common::ucursor::from_memory_to_file_4m,
    common::ucursor::from_memory_to_file_32m);

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
criterion_group!( s11n_cbor_benches, common::nop_bench);

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
criterion_group!( s11n_json_benches, common::nop_bench);

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
criterion_group!( s11n_nom_benches, common::nop_bench);

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
criterion_group!( s11n_capnp_benches, common::nop_bench);



criterion_main!(
    ucursor_benches,
    s11n_custom_benches,
    s11n_cbor_benches,
    s11n_json_benches,
    s11n_nom_benches,
    s11n_capnp_benches
);
