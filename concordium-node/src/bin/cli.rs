#![recursion_limit = "1024"]
#[cfg(not(target_os = "windows"))]
extern crate grpciounix as grpcio;
#[cfg(target_os = "windows")]
extern crate grpciowin as grpcio;
#[macro_use]
extern crate log;

// Explicitly defining allocator to avoid future reintroduction of jemalloc
use p2p_client::connection::network_handler::message_processor::MessageManager;
use std::alloc::System;
#[global_allocator]
static A: System = System;

use byteorder::{NetworkEndian, WriteBytesExt};

use concordium_common::{
    cache::Cache,
    make_atomic_callback, safe_write, spawn_or_die,
    stats_export_service::{StatsExportService, StatsServiceMode},
    write_or_die, PacketType, RelayOrStopEnvelope, RelayOrStopReceiver, RelayOrStopSender,
    RelayOrStopSenderHelper,
};
use concordium_consensus::{consensus, ffi};
use concordium_global_state::{
    common::SerializeToBytes,
    tree::{Skov, ConsensusMessage},
};
use failure::Fallible;
use p2p_client::{
    client::{
        plugins::{self, consensus::*},
        utils as client_utils,
    },
    common::{P2PNodeId, PeerType},
    configuration,
    network::{
        packet::MessageId, request::RequestedElementType, NetworkId, NetworkMessage, NetworkPacket,
        NetworkPacketType, NetworkRequest, NetworkResponse,
    },
    p2p::*,
    rpc::RpcServerImpl,
    stats_engine::StatsEngine,
    utils::{self, get_config_and_logging_setup, load_bans},
};

use rkv::{Manager, Rkv};

use std::{
    net::SocketAddr,
    str,
    sync::{mpsc, Arc, RwLock},
};

fn main() -> Fallible<()> {
    let (conf, mut app_prefs) = get_config_and_logging_setup()?;
    if conf.common.print_config {
        // Print out the configuration
        info!("{:?}", conf);
    }
    let data_dir_path = app_prefs.get_user_app_dir();

    // Retrieving bootstrap nodes
    let dns_resolvers =
        utils::get_resolvers(&conf.connection.resolv_conf, &conf.connection.dns_resolver);
    for resolver in &dns_resolvers {
        debug!("Using resolver: {}", resolver);
    }

    let bootstrap_nodes = utils::get_bootstrap_nodes(
        conf.connection.bootstrap_server.clone(),
        &dns_resolvers,
        conf.connection.dnssec_disabled,
        &conf.connection.bootstrap_node,
    );

    // Instantiate stats export engine
    let stats_export_service =
        client_utils::instantiate_stats_export_engine(&conf, StatsServiceMode::NodeMode)
            .unwrap_or_else(|e| {
                error!(
                    "I was not able to instantiate an stats export service: {}",
                    e
                );
                None
            });

    info!("Debugging enabled: {}", conf.common.debug);

    // Thread #1: instantiate the P2PNode
    let (mut node, pkt_out) = instantiate_node(&conf, &mut app_prefs, &stats_export_service);

    // Create the cli key-value store environment
    let cli_kvs_handle = Manager::singleton()
        .write()
        .unwrap()
        .get_or_create(data_dir_path.as_path(), Rkv::new)
        .unwrap();

    // Load and apply existing bans
    if let Err(e) = load_bans(&mut node, &cli_kvs_handle) {
        error!("{}", e);
    };

    #[cfg(feature = "instrumentation")]
    // Thread #2 (optional): the push gateway to Prometheus
    client_utils::start_push_gateway(&conf.prometheus, &stats_export_service, node.id())?;

    // Start the P2PNode
    //
    // Thread #2 (#3): P2P event loop
    node.spawn();

    // Connect to nodes (args and bootstrap)
    if !conf.cli.no_network {
        info!("Concordium P2P layer, Network disabled");
        create_connections_from_config(&conf.connection, &dns_resolvers, &mut node);
        if !conf.connection.no_bootstrap_dns {
            info!("Attempting to bootstrap");
            bootstrap(&bootstrap_nodes, &mut node);
        }
    }

    let is_baker = conf.cli.baker.baker_id.is_some();

    let mut consensus = if is_baker {
        // Thread #3 (#4): the consensus layer
        plugins::consensus::start_consensus_layer(&conf.cli.baker, &app_prefs)
    } else {
        None // This will not be possible once we have a "do not bake" consensus call
    };

    // Register a handler for sending out a consensus catch-up request by
    // finalization point after the handshake.
    if let Some(ref consensus) = consensus {
        attain_post_handshake_catch_up(&node, consensus)?;
    }

    // Start the RPC server
    let mut rpc_serv = if !conf.cli.rpc.no_rpc_server {
        let mut serv = RpcServerImpl::new(
            node.clone(),
            Arc::clone(&cli_kvs_handle),
            consensus.clone(),
            &conf.cli.rpc,
            &stats_export_service,
        );
        serv.start_server()?;
        Some(serv)
    } else {
        None
    };

    let (skov_sender, skov_receiver) = mpsc::channel::<RelayOrStopEnvelope<ConsensusMessage>>();

    // Connect outgoing messages to be forwarded into the baker and RPC streams.
    //
    // Thread #4 (#5): read P2PNode output
    let higer_process_threads = if let Some(ref mut consensus) = consensus {
        start_consensus_threads(
            &node,
            cli_kvs_handle,
            (&conf, &app_prefs),
            consensus,
            pkt_out,
            (skov_receiver, skov_sender.clone()),
            &stats_export_service,
        )
    } else {
        vec![]
    };

    // Create a listener on baker output to forward to the P2PNode
    //
    // Thread #5 (#6): the Baker thread
    let baker_thread = if is_baker {
        Some(start_baker_thread(skov_sender.clone()))
    } else {
        None
    };

    // Wait for the P2PNode to close
    node.join().expect("The node thread panicked!");

    // Stop the Skov thread
    skov_sender.send_stop()?;

    // Shut down the consensus layer
    if let Some(ref mut consensus) = consensus {
        if conf.cli.baker.baker_id.is_some() {
            consensus.stop_baker()
        };
        ffi::stop_haskell();
    }

    // Wait for the higher process threads to stop
    for th in higer_process_threads {
        th.join().expect("Higher process thread panicked")
    }

    // Close the baker thread
    if let Some(th) = baker_thread {
        th.join().expect("Baker sub-thread panicked")
    }

    // Close the RPC server if present
    if let Some(ref mut serv) = rpc_serv {
        serv.stop_server()?;
    }

    // Close the stats server if present
    client_utils::stop_stats_export_engine(&conf, &stats_export_service);

    Ok(())
}

fn instantiate_node(
    conf: &configuration::Config,
    app_prefs: &mut configuration::AppPreferences,
    stats_export_service: &Option<Arc<RwLock<StatsExportService>>>,
) -> (
    P2PNode,
    mpsc::Receiver<RelayOrStopEnvelope<Arc<NetworkMessage>>>,
) {
    let (pkt_in, pkt_out) = mpsc::channel::<RelayOrStopEnvelope<Arc<NetworkMessage>>>();
    let node_id = conf.common.id.clone().map_or(
        app_prefs.get_config(configuration::APP_PREFERENCES_PERSISTED_NODE_ID),
        |id| {
            if !app_prefs.set_config(
                configuration::APP_PREFERENCES_PERSISTED_NODE_ID,
                Some(id.clone()),
            ) {
                error!("Failed to persist own node id");
            };
            Some(id)
        },
    );
    let arc_stats_export_service = if let Some(ref service) = stats_export_service {
        Some(Arc::clone(service))
    } else {
        None
    };

    // Start the thread reading P2PEvents from P2PNode
    let node = if conf.common.debug {
        let (sender, receiver) = mpsc::channel();
        let _guard = spawn_or_die!("Log loop", move || loop {
            if let Ok(msg) = receiver.recv() {
                info!("{}", msg);
            }
        });
        P2PNode::new(
            node_id,
            &conf,
            pkt_in,
            Some(sender),
            PeerType::Node,
            arc_stats_export_service,
        )
    } else {
        P2PNode::new(
            node_id,
            &conf,
            pkt_in,
            None,
            PeerType::Node,
            arc_stats_export_service,
        )
    };
    (node, pkt_out)
}

fn create_connections_from_config(
    conf: &configuration::ConnectionConfig,
    dns_resolvers: &[String],
    node: &mut P2PNode,
) {
    for connect_to in &conf.connect_to {
        match utils::parse_host_port(&connect_to, &dns_resolvers, conf.dnssec_disabled) {
            Ok(addrs) => {
                for addr in addrs {
                    info!("Connecting to peer {}", &connect_to);
                    node.connect(PeerType::Node, addr, None)
                        .unwrap_or_else(|e| debug!("{}", e));
                }
            }
            Err(err) => error!("Can't parse data for node to connect to {}", err),
        }
    }
}

fn bootstrap(bootstrap_nodes: &Result<Vec<SocketAddr>, &'static str>, node: &mut P2PNode) {
    match bootstrap_nodes {
        Ok(nodes) => {
            for &addr in nodes {
                info!("Found bootstrap node: {}", addr);
                node.connect(PeerType::Bootstrapper, addr, None)
                    .unwrap_or_else(|e| error!("{}", e));
            }
        }
        Err(e) => error!("Couldn't retrieve bootstrap node list! {:?}", e),
    };
}

fn attain_post_handshake_catch_up(
    node: &P2PNode,
    consensus: &consensus::ConsensusContainer,
) -> Fallible<()> {
    let cloned_handshake_response_node = Arc::new(RwLock::new(node.clone()));
    let consensus_clone = consensus.clone();
    let message_handshake_response_handler = &node.message_processor();

    safe_write!(message_handshake_response_handler)?.add_response_action(make_atomic_callback!(
        move |msg: &NetworkResponse| {
            if let NetworkResponse::Handshake(ref remote_peer, ref nets, _) = msg {
                if remote_peer.peer_type() == PeerType::Node {
                    if let Some(net) = nets.iter().next() {
                        let response = consensus_clone.get_finalization_point();
                        let mut locked_cloned_node = write_or_die!(cloned_handshake_response_node);
                        if let Ok(bytes) = response {
                            let mut out_bytes =
                                Vec::with_capacity(PAYLOAD_TYPE_LENGTH as usize + bytes.len());
                            match out_bytes.write_u16::<NetworkEndian>(
                                PacketType::CatchupFinalizationMessagesByPoint as u16,
                            ) {
                                Ok(_) => {
                                    out_bytes.extend(&bytes);
                                    match locked_cloned_node.send_direct_message(
                                        Some(remote_peer.id()),
                                        *net,
                                        None,
                                        out_bytes,
                                    ) {
                                        Ok(_) => info!(
                                            "Peer {} requested finalization messages by point \
                                             from peer {}",
                                            locked_cloned_node.id(),
                                            remote_peer.id()
                                        ),
                                        Err(_) => error!(
                                            "Peer {} couldn't send a catch-up request for \
                                             finalization messages by point!",
                                            locked_cloned_node.id(),
                                        ),
                                    }
                                }
                                Err(_) => error!(
                                    "Can't write type to packet {}",
                                    PacketType::CatchupFinalizationMessagesByPoint
                                ),
                            }
                        }
                    } else {
                        error!("Handshake without network, so can't ask for finalization messages");
                    }
                }
            }

            Ok(())
        }
    ));

    Ok(())
}

fn start_consensus_threads(
    node: &P2PNode,
    kvs_handle: Arc<RwLock<Rkv>>,
    (conf, app_prefs): (&configuration::Config, &configuration::AppPreferences),
    baker: &mut consensus::ConsensusContainer,
    pkt_out: RelayOrStopReceiver<Arc<NetworkMessage>>,
    (skov_receiver, skov_sender): (RelayOrStopReceiver<ConsensusMessage>, RelayOrStopSender<ConsensusMessage>),
    stats: &Option<Arc<RwLock<StatsExportService>>>,
) -> Vec<std::thread::JoinHandle<()>> {
    let _no_trust_bans = conf.common.no_trust_bans;
    let _desired_nodes_clone = conf.connection.desired_nodes;
    let _test_runner_url = conf.cli.test_runner_url.clone();
    let mut _stats_engine = StatsEngine::new(&conf.cli);
    let mut _msg_count = 0;
    let (_tps_test_enabled, _tps_message_count) = tps_setup_process_output(&conf.cli);
    let transactions_cache = Cache::default();
    let _network_id = NetworkId::from(conf.common.network_ids[0]); // defaulted so there's always first()
    let data_dir_path = app_prefs.get_user_app_dir();
    let stats_clone = stats.clone();

    let mut node_clone = node.clone();
    let mut baker_clone = baker.clone();
    let global_state_thread = spawn_or_die!("Process global state requests", {
        // Open the Skov-exclusive k-v store environment
        let skov_kvs_handle = Manager::singleton()
            .write()
            .expect("Can't write to the kvs manager for Skov purposes!")
            .get_or_create(data_dir_path.as_ref(), Rkv::new)
            .expect("Can't load the Skov kvs environment!");

        let skov_kvs_env = skov_kvs_handle
            .read()
            .expect("Can't unlock the kvs env for Skov!");

        let mut skov = baker_clone
            .baker
            .read()
            .map(|optional_baker| {
                optional_baker
                    .as_ref()
                    .map(|baker| Skov::new(&baker.genesis_data, &skov_kvs_env))
            })
            .expect("Could not instantiate Skov!")
            .expect("Could not instantiate Skov!");

        loop {
            match skov_receiver.recv() {
                Ok(RelayOrStopEnvelope::Relay(request)) => {
                    if let Err(e) = handle_global_state_request(
                        &mut node_clone,
                        _network_id,
                        &mut baker_clone,
                        request,
                        &mut skov,
                        &stats_clone,
                    ) {
                        error!("There's an issue with a global state request: {}", e);
                    }
                }
                Ok(RelayOrStopEnvelope::Stop) => break,
                _ => panic!("Can't receive global state requests! Another thread must have died."),
            }
        }
    });

    let mut baker_clone = baker.clone();
    let mut node_ref = node.clone();
    let guard_pkt = spawn_or_die!("Higher queue processing", {
        while let Ok(RelayOrStopEnvelope::Relay(full_msg)) = pkt_out.recv() {
            match *full_msg {
                NetworkMessage::NetworkRequest(
                    NetworkRequest::BanNode(ref peer, peer_to_ban),
                    ..
                ) => {
                    utils::ban_node(
                        &mut node_ref,
                        peer,
                        peer_to_ban,
                        &kvs_handle,
                        _no_trust_bans,
                    );
                }
                NetworkMessage::NetworkRequest(
                    NetworkRequest::UnbanNode(ref peer, peer_to_ban),
                    ..
                ) => {
                    utils::unban_node(
                        &mut node_ref,
                        peer,
                        peer_to_ban,
                        &kvs_handle,
                        _no_trust_bans,
                    );
                }
                NetworkMessage::NetworkResponse(
                    NetworkResponse::PeerList(ref peer, ref peers),
                    ..
                ) => {
                    debug!("Received PeerList response, attempting to satisfy desired peers");
                    let mut new_peers = 0;
                    let peer_count = node_ref
                        .get_peer_stats(&[])
                        .iter()
                        .filter(|x| x.peer_type == PeerType::Node)
                        .count();
                    for peer_node in peers {
                        debug!(
                            "Peer {}/{}/{} sent us peer info for {}/{}/{}",
                            peer.id(),
                            peer.ip(),
                            peer.port(),
                            peer_node.id(),
                            peer_node.ip(),
                            peer_node.port()
                        );
                        if node_ref
                            .connect(PeerType::Node, peer_node.addr, Some(peer_node.id()))
                            .map_err(|e| debug!("{}", e))
                            .is_ok()
                        {
                            new_peers += 1;
                        }
                        if new_peers + peer_count as u8 >= _desired_nodes_clone {
                            break;
                        }
                    }
                }
                NetworkMessage::NetworkPacket(ref pac, ..) => {
                    match pac.packet_type {
                        NetworkPacketType::DirectMessage(..) => {
                            if _tps_test_enabled {
                                _stats_engine.add_stat(pac.message.len() as u64);
                                _msg_count += 1;

                                if _msg_count == _tps_message_count {
                                    info!(
                                        "TPS over {} messages is {}",
                                        _tps_message_count,
                                        _stats_engine.calculate_total_tps_average()
                                    );
                                    _msg_count = 0;
                                    _stats_engine.clear();
                                }
                            };
                        }
                        NetworkPacketType::BroadcastedMessage => {
                            if let Some(ref testrunner_url) = _test_runner_url {
                                send_packet_to_testrunner(&node_ref, testrunner_url, &pac);
                            };
                        }
                    };

                    let is_broadcast = pac.packet_type == NetworkPacketType::BroadcastedMessage;

                    if let Err(e) = handle_pkt_out(
                        &mut baker_clone,
                        pac.peer.id(),
                        pac.message.clone(),
                        &skov_sender,
                        &transactions_cache,
                        is_broadcast,
                    ) {
                        error!("There's an issue with an outbound packet: {}", e);
                    }
                }
                NetworkMessage::NetworkRequest(ref pac @ NetworkRequest::Retransmit(..), ..) => {
                    if let NetworkRequest::Retransmit(requester, element_type, since, nid) = pac {
                        match element_type {
                            RequestedElementType::Transaction => {
                                let transactions = transactions_cache.get_since(*since);
                                transactions.iter().for_each(|transaction| {
                                    if let Err(e) = node_ref.send_direct_message(
                                        Some(requester.id()),
                                        *nid,
                                        None,
                                        transaction.serialize().into_vec(),
                                    ) {
                                        error!(
                                            "Couldn't send transaction in response to a \
                                             retransmit request: {}",
                                            e
                                        )
                                    }
                                })
                            }
                            _ => error!(
                                "Received request for unknown element type in a Retransmit request"
                            ),
                        }
                    }
                }

                _ => {}
            }
        }
    });

    info!(
        "Concordium P2P layer. Network disabled: {}",
        conf.cli.no_network
    );

    vec![global_state_thread, guard_pkt]
}

fn start_baker_thread(skov_sender: RelayOrStopSender<ConsensusMessage>) -> std::thread::JoinHandle<()> {
    spawn_or_die!("Process consensus messages", {
        loop {
            match consensus::CALLBACK_QUEUE.recv_message() {
                Ok(RelayOrStopEnvelope::Relay(mut msg)) => {
                    msg.source = None;
                    if let Err(e) = skov_sender.send(RelayOrStopEnvelope::Relay(msg)) {
                        error!("Error passing a message from the consensus layer: {}", e)
                    }
                }
                Ok(RelayOrStopEnvelope::Stop) => break,
                Err(e) => error!("Error receiving a message from the consensus layer: {}", e),
            }
        }
    })
}

#[cfg(feature = "benchmark")]
fn tps_setup_process_output(cli: &configuration::CliConfig) -> (bool, u64) {
    (cli.tps.enable_tps_test, cli.tps.tps_message_count)
}

#[cfg(not(feature = "benchmark"))]
fn tps_setup_process_output(_: &configuration::CliConfig) -> (bool, u64) { (false, 0) }

#[cfg(feature = "instrumentation")]
fn send_packet_to_testrunner(node: &P2PNode, test_runner_url: &str, pac: &NetworkPacket) {
    debug!("Sending information to test runner");
    match reqwest::get(&format!(
        "{}/register/{}/{:?}",
        test_runner_url,
        node.id(),
        pac.message_id
    )) {
        Ok(ref mut res) if res.status().is_success() => {
            info!("Registered packet received with test runner")
        }
        _ => error!("Couldn't register packet received with test runner"),
    }
}

#[cfg(not(feature = "instrumentation"))]
fn send_packet_to_testrunner(_: &P2PNode, _: &str, _: &NetworkPacket) {}

fn _send_retransmit_packet(
    node: &mut P2PNode,
    receiver: P2PNodeId,
    network_id: NetworkId,
    message_id: &MessageId,
    payload_type: u16,
    data: &[u8],
) {
    let mut out_bytes = Vec::with_capacity(2 + data.len());
    match out_bytes.write_u16::<NetworkEndian>(payload_type as u16) {
        Ok(_) => {
            out_bytes.extend(data);
            match node.send_direct_message(
                Some(receiver),
                network_id,
                Some(message_id.to_owned()),
                out_bytes,
            ) {
                Ok(_) => debug!("Retransmitted packet of type {}", payload_type),
                Err(_) => error!("Couldn't retransmit packet of type {}!", payload_type),
            }
        }
        Err(_) => error!("Can't write payload type, so failing retransmit of packet"),
    }
}
