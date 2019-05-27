use super::fails;
use concordium_common::functor::{Functorable, UnitFunction, UnitFunctor};
use failure::{bail, Fallible};
use mio::{
    net::{TcpListener, TcpStream},
    Event, Poll, Token,
};
use rustls::{ClientConfig, ClientSession, ServerConfig, ServerSession};
use std::{
    collections::HashSet,
    net::SocketAddr,
    rc::Rc,
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::Sender,
        Arc, RwLock,
    },
};
use webpki::DNSNameRef;

use crate::{
    common::{
        get_current_stamp, serialization::serialize_into_memory, P2PNodeId, P2PPeer, PeerType,
        RemotePeer,
    },
    connection::{Connection, ConnectionBuilder, MessageHandler, MessageManager, P2PEvent},
    network::{Buckets, NetworkId, NetworkMessage, NetworkRequest},
    p2p::{
        banned_nodes::BannedNode, peer_statistics::PeerStatistic,
        tls_server_private::TlsServerPrivate,
    },
    stats_export_service::StatsExportService,
};

pub type PreHandshakeCW = UnitFunction<SocketAddr>;
pub type PreHandshake = UnitFunctor<SocketAddr>;

pub struct TlsServerBuilder {
    server:                  Option<TcpListener>,
    server_tls_config:       Option<Arc<ServerConfig>>,
    client_tls_config:       Option<Arc<ClientConfig>>,
    event_log:               Option<Sender<P2PEvent>>,
    self_peer:               Option<P2PPeer>,
    buckets:                 Option<Arc<RwLock<Buckets>>>,
    stats_export_service:    Option<Arc<RwLock<StatsExportService>>>,
    blind_trusted_broadcast: Option<bool>,
    networks:                Option<HashSet<NetworkId>>,
    max_peers:               Option<u16>,
}

impl Default for TlsServerBuilder {
    fn default() -> Self { TlsServerBuilder::new() }
}

impl TlsServerBuilder {
    pub fn new() -> TlsServerBuilder {
        TlsServerBuilder {
            server:                  None,
            server_tls_config:       None,
            client_tls_config:       None,
            event_log:               None,
            self_peer:               None,
            buckets:                 None,
            stats_export_service:    None,
            blind_trusted_broadcast: None,
            networks:                None,
            max_peers:               None,
        }
    }

    pub fn build(self) -> Fallible<TlsServer> {
        if let (
            Some(networks),
            Some(server),
            Some(server_tls_config),
            Some(client_tls_config),
            Some(self_peer),
            Some(buckets),
            Some(blind_trusted_broadcast),
            Some(max_peers),
        ) = (
            self.networks,
            self.server,
            self.server_tls_config,
            self.client_tls_config,
            self.self_peer,
            self.buckets,
            self.blind_trusted_broadcast,
            self.max_peers,
        ) {
            let mdptr = Arc::new(RwLock::new(TlsServerPrivate::new(
                networks,
                self.stats_export_service.clone(),
            )));

            let mut mself = TlsServer {
                server,
                next_id: AtomicUsize::new(2),
                server_tls_config,
                client_tls_config,
                event_log: self.event_log,
                self_peer,
                stats_export_service: self.stats_export_service,
                buckets,
                message_handler: Arc::new(RwLock::new(MessageHandler::new())),
                dptr: mdptr,
                blind_trusted_broadcast,
                prehandshake_validations: PreHandshake::new("TlsServer::Accept"),
                dump_tx: None,
                max_peers,
            };

            mself.add_default_prehandshake_validations();
            mself.setup_default_message_handler();
            Ok(mself)
        } else {
            bail!(fails::MissingFieldsOnTlsServerBuilder)
        }
    }

    pub fn set_server(mut self, s: TcpListener) -> TlsServerBuilder {
        self.server = Some(s);
        self
    }

    pub fn set_server_tls_config(mut self, c: Arc<ServerConfig>) -> TlsServerBuilder {
        self.server_tls_config = Some(c);
        self
    }

    pub fn set_client_tls_config(mut self, c: Arc<ClientConfig>) -> TlsServerBuilder {
        self.client_tls_config = Some(c);
        self
    }

    pub fn set_self_peer(mut self, sp: P2PPeer) -> TlsServerBuilder {
        self.self_peer = Some(sp);
        self
    }

    pub fn set_event_log(mut self, el: Option<Sender<P2PEvent>>) -> TlsServerBuilder {
        self.event_log = el;
        self
    }

    pub fn set_buckets(mut self, b: Arc<RwLock<Buckets>>) -> TlsServerBuilder {
        self.buckets = Some(b);
        self
    }

    pub fn set_stats_export_service(
        mut self,
        ses: Option<Arc<RwLock<StatsExportService>>>,
    ) -> TlsServerBuilder {
        self.stats_export_service = ses;
        self
    }

    pub fn set_blind_trusted_broadcast(mut self, btb: bool) -> TlsServerBuilder {
        self.blind_trusted_broadcast = Some(btb);
        self
    }

    pub fn set_networks(mut self, n: HashSet<NetworkId>) -> TlsServerBuilder {
        self.networks = Some(n);
        self
    }

    pub fn set_max_peers(mut self, max_peers: u16) -> TlsServerBuilder {
        self.max_peers = Some(max_peers);
        self
    }
}

pub struct TlsServer {
    server:                   TcpListener,
    next_id:                  AtomicUsize,
    server_tls_config:        Arc<ServerConfig>,
    client_tls_config:        Arc<ClientConfig>,
    event_log:                Option<Sender<P2PEvent>>,
    self_peer:                P2PPeer,
    buckets:                  Arc<RwLock<Buckets>>,
    stats_export_service:     Option<Arc<RwLock<StatsExportService>>>,
    message_handler:          Arc<RwLock<MessageHandler>>,
    dptr:                     Arc<RwLock<TlsServerPrivate>>,
    blind_trusted_broadcast:  bool,
    prehandshake_validations: PreHandshake,
    dump_tx:                  Option<Sender<crate::dumper::DumpItem>>,
    max_peers:                u16,
}

impl TlsServer {
    pub fn log_event(&self, event: P2PEvent) {
        if let Some(ref log) = self.event_log {
            if let Err(e) = log.send(event) {
                error!("Couldn't send error {:?}", e)
            }
        }
    }

    pub fn get_self_peer(&self) -> P2PPeer { self.self_peer.clone() }

    #[inline]
    pub fn networks(&self) -> Arc<RwLock<HashSet<NetworkId>>> {
        Arc::clone(&read_or_die!(self.dptr).networks)
    }

    pub fn remove_network(&mut self, network_id: NetworkId) {
        write_or_die!(self.dptr).remove_network(network_id)
    }

    pub fn add_network(&mut self, network_id: NetworkId) {
        write_or_die!(self.dptr).add_network(network_id)
    }

    /// Returns true if `addr` is in the `unreachable_nodes` list.
    pub fn is_unreachable(&self, addr: SocketAddr) -> bool {
        read_or_die!(self.dptr).unreachable_nodes.contains(addr)
    }

    /// Adds the `addr` to the `unreachable_nodes` list.
    pub fn add_unreachable(&mut self, addr: SocketAddr) -> bool {
        write_or_die!(self.dptr).unreachable_nodes.insert(addr)
    }

    pub fn get_peer_stats(&self, nids: &[NetworkId]) -> Vec<PeerStatistic> {
        write_or_die!(self.dptr).get_peer_stats(nids)
    }

    pub fn ban_node(&mut self, peer: BannedNode) -> bool { write_or_die!(self.dptr).ban_node(peer) }

    pub fn unban_node(&mut self, peer: BannedNode) -> bool {
        write_or_die!(self.dptr).unban_node(peer)
    }

    pub fn get_banlist(&self) -> Vec<BannedNode> { read_or_die!(self.dptr).get_banlist() }

    pub fn accept(&mut self, poll: &mut Poll, self_peer: P2PPeer) -> Fallible<()> {
        let (socket, addr) = self.server.accept()?;
        debug!(
            "Accepting new connection from {:?} to {:?}:{}",
            addr,
            self_peer.ip(),
            self_peer.port()
        );

        if let Err(e) = self.prehandshake_validations.run_callbacks(&addr) {
            bail!(e);
        }

        if self_peer.peer_type() == PeerType::Node {
            let current_peer_count = read_or_die!(self.dptr).connections_count();
            if current_peer_count <= self.max_peers {
                bail!(fails::MaxmimumAmountOfPeers {
                    max_peers:       self.max_peers,
                    amount_of_peers: current_peer_count,
                });
            }
        }

        self.log_event(P2PEvent::ConnectEvent(addr));

        let tls_session = ServerSession::new(&self.server_tls_config);
        let token = Token(self.next_id.fetch_add(1, Ordering::SeqCst));

        let networks = self.networks();

        let conn = ConnectionBuilder::new()
            .set_socket(socket)
            .set_token(token)
            .set_server_session(Some(tls_session))
            .set_client_session(None)
            .set_local_peer(self_peer)
            .set_remote_peer(RemotePeer::PreHandshake(PeerType::Node, addr))
            .set_stats_export_service(self.stats_export_service.clone())
            .set_event_log(self.event_log.clone())
            .set_local_end_networks(networks)
            .set_buckets(Arc::clone(&self.buckets))
            .set_blind_trusted_broadcast(self.blind_trusted_broadcast);
        let mut conn = if let Some(d) = &self.dump_tx {
            conn.set_dump_tx(d.clone())
        } else {
            conn
        }
        .build()?;

        self.register_message_handlers(&mut conn);

        let register_status = conn.register(poll);
        safe_write!(self.dptr)?.add_connection(conn);

        register_status
    }

    pub fn connect(
        &mut self,
        peer_type: PeerType,
        poll: &mut Poll,
        addr: SocketAddr,
        peer_id_opt: Option<P2PNodeId>,
        self_peer: &P2PPeer,
    ) -> Fallible<()> {
        if peer_type == PeerType::Node {
            let current_peer_count = read_or_die!(self.dptr).connections_count();
            if current_peer_count <= self.max_peers {
                bail!(fails::MaxmimumAmountOfPeers {
                    max_peers:       self.max_peers,
                    amount_of_peers: current_peer_count,
                });
            }
        }

        if peer_type == PeerType::Node && self.is_unreachable(addr) {
            error!("Node marked as unreachable, so not allowing the connection");
            bail!(fails::UnreachablePeerError);
        }

        // Avoid duplicate ip+port peers
        if self_peer.addr == addr {
            bail!(fails::DuplicatePeerError { peer_id_opt, addr });
        }

        // Avoid duplicate Id entries
        if let Some(peer_id) = peer_id_opt {
            if safe_read!(self.dptr)?
                .find_connection_by_id(peer_id)
                .is_some()
            {
                bail!(fails::DuplicatePeerError { peer_id_opt, addr });
            }
        }

        // Avoid duplicate ip+port connections
        if safe_read!(self.dptr)?
            .find_connection_by_ip_addr(addr)
            .is_some()
        {
            bail!(fails::DuplicatePeerError { peer_id_opt, addr });
        }

        match TcpStream::connect(&addr) {
            Ok(socket) => {
                if let Some(ref service) = &self.stats_export_service {
                    safe_write!(service)?.conn_received_inc();
                };
                let tls_session = ClientSession::new(
                    &self.client_tls_config,
                    DNSNameRef::try_from_ascii_str(&"node.concordium.com")
                        .unwrap_or_else(|e| panic!("The error is: {:?}", e)),
                );

                let token = Token(self.next_id.fetch_add(1, Ordering::SeqCst));

                let networks = self.networks();
                let conn = ConnectionBuilder::new()
                    .set_socket(socket)
                    .set_token(token)
                    .set_server_session(None)
                    .set_client_session(Some(tls_session))
                    .set_local_peer(self_peer.clone())
                    .set_remote_peer(RemotePeer::PreHandshake(peer_type, addr))
                    .set_stats_export_service(self.stats_export_service.clone())
                    .set_event_log(self.event_log.clone())
                    .set_local_end_networks(Arc::clone(&networks))
                    .set_buckets(Arc::clone(&self.buckets))
                    .set_blind_trusted_broadcast(self.blind_trusted_broadcast);
                let mut conn = if let Some(d) = &self.dump_tx {
                    conn.set_dump_tx(d.clone())
                } else {
                    conn
                }
                .build()?;

                self.register_message_handlers(&mut conn);
                conn.register(poll)?;

                safe_write!(self.dptr)?.add_connection(conn);
                self.log_event(P2PEvent::ConnectEvent(addr));
                debug!("Requesting handshake from new peer {}", addr,);
                let self_peer = self.get_self_peer();

                if let Some(ref rc_conn) = safe_read!(self.dptr)?.find_connection_by_token(token) {
                    let handshake_request = NetworkMessage::NetworkRequest(
                        NetworkRequest::Handshake(self_peer, safe_read!(networks)?.clone(), vec![]),
                        Some(get_current_stamp()),
                        None,
                    );
                    let handshake_request_data = serialize_into_memory(&handshake_request, 256)?;

                    let mut conn = rc_conn.borrow_mut();
                    conn.serialize_bytes(&handshake_request_data)?;
                    conn.set_measured_handshake_sent();
                }
                Ok(())
            }
            Err(e) => {
                if peer_type == PeerType::Node && !self.add_unreachable(addr) {
                    error!("Can't insert unreachable peer!");
                }
                into_err!(Err(e))
            }
        }
    }

    #[inline]
    pub fn conn_event(&mut self, event: &Event) -> Fallible<()> {
        write_or_die!(self.dptr).conn_event(event)
    }

    pub fn cleanup_connections(&self, poll: &mut Poll) -> Fallible<()> {
        write_or_die!(self.dptr).cleanup_connections(self.peer_type(), poll)
    }

    pub fn liveness_check(&self) -> Fallible<()> { write_or_die!(self.dptr).liveness_check() }

    /// It sends `data` message over all filtered connections.
    ///
    /// # Arguments
    /// * `data` - Raw message.
    /// * `filter_conn` - It will send using all connection, where this function
    ///   returns `true`.
    /// * `send_status` - It will called after each sent, to notify the result
    ///   of the operation.
    ///  # Returns
    /// * connections the packet was written to
    pub fn send_over_all_connections(
        &self,
        data: &[u8],
        filter_conn: &dyn Fn(&Connection) -> bool,
        send_status: &dyn Fn(&Connection, Fallible<usize>),
    ) -> usize {
        write_or_die!(self.dptr).send_over_all_connections(data, filter_conn, send_status)
    }

    #[inline]
    pub fn peer_type(&self) -> PeerType { self.self_peer.peer_type() }

    #[inline]
    pub fn blind_trusted_broadcast(&self) -> bool { self.blind_trusted_broadcast }

    /// It setups default message handler at TLSServer level.
    fn setup_default_message_handler(&mut self) {
        let cloned_dptr = Arc::clone(&self.dptr);
        let banned_nodes = Rc::clone(&read_or_die!(cloned_dptr).banned_peers);
        let to_disconnect = Rc::clone(&read_or_die!(cloned_dptr).to_disconnect);
        write_or_die!(self.message_handler).add_request_callback(make_atomic_callback!(
            move |req: &NetworkRequest| {
                if let NetworkRequest::Handshake(ref peer, ..) = req {
                    if banned_nodes.borrow().is_id_banned(peer.id()) {
                        to_disconnect.borrow_mut().push_back(peer.id());
                    }
                }
                Ok(())
            }
        ));
    }

    /// It adds all message handler callback to this connection.
    fn register_message_handlers(&self, conn: &mut Connection) {
        let mh = &read_or_die!(self.message_handler);
        Rc::clone(&conn.common_message_handler)
            .borrow_mut()
            .merge(mh);
    }

    fn add_default_prehandshake_validations(&mut self) {
        self.prehandshake_validations
            .add_callback(self.make_check_banned());
    }

    fn make_check_banned(&self) -> PreHandshakeCW {
        let cloned_dptr = Arc::clone(&self.dptr);
        make_atomic_callback!(move |sockaddr: &SocketAddr| {
            if safe_read!(cloned_dptr)?.addr_is_banned(*sockaddr) {
                bail!(fails::BannedNodeRequestedConnectionError);
            }
            Ok(())
        })
    }

    pub fn dump_start(&mut self, dump_tx: Sender<crate::dumper::DumpItem>) {
        let to_private = dump_tx.clone();
        self.dump_tx.replace(dump_tx);
        write_or_die!(self.dptr).dump_all_connections(to_private);
    }

    pub fn dump_stop(&mut self) {
        self.dump_tx.take();
        write_or_die!(self.dptr).dump_stop_all_connections();
    }
}

#[cfg(test)]
impl TlsServer {
    pub fn get_private_tls(&self) -> Arc<RwLock<TlsServerPrivate>> { Arc::clone(&self.dptr) }
}

impl MessageManager for TlsServer {
    fn message_handler(&self) -> Arc<RwLock<MessageHandler>> { Arc::clone(&self.message_handler) }
}
