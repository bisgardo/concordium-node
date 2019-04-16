use failure::{bail, Fallible};
use mio::{Event, Poll, Token};
use std::{
    cell::RefCell,
    collections::HashSet,
    mem,
    net::{IpAddr, SocketAddr},
    rc::Rc,
    sync::{mpsc::Sender, Arc, RwLock},
};

use crate::{
    common::{get_current_stamp, ConnectionType, P2PNodeId, P2PPeer, P2PPeerBuilder},
    connection::{Connection, P2PNodeMode},
    network::{NetworkId, NetworkMessage, NetworkRequest},
    prometheus_exporter::PrometheusServer,
};

use crate::p2p::{peer_statistics::PeerStatistic, unreachable_nodes::UnreachableNodes};

use super::fails;

const MAX_FAILED_PACKETS_ALLOWED: u32 = 50;
const MAX_UNREACHABLE_MARK_TIME: u64 = 1000 * 60 * 60 * 24;
const MAX_BOOTSTRAPPER_KEEP_ALIVE: u64 = 300000;
const MAX_NORMAL_KEEP_ALIVE: u64 = 1200000;

/// This class allows to share some information between `TlsServer` and its
/// handler. This concept is similar to `d-Pointer` of C++ but it is used just
/// to facilitate information sharing.
///
/// # Connections
/// Connections are stored in RC in two `hashmap`s in order to improve
/// performance access for specific look-ups.
pub struct TlsServerPrivate {
    connections:             Vec<Rc<RefCell<Connection>>>,
    pub unreachable_nodes:   UnreachableNodes,
    pub banned_peers:        HashSet<P2PPeer>,
    pub networks:            Arc<RwLock<HashSet<NetworkId>>>,
    pub prometheus_exporter: Option<Arc<RwLock<PrometheusServer>>>,
}

impl TlsServerPrivate {
    pub fn new(
        networks: HashSet<NetworkId>,
        prometheus_exporter: Option<Arc<RwLock<PrometheusServer>>>,
    ) -> Self {
        TlsServerPrivate {
            connections: Vec::new(),
            unreachable_nodes: UnreachableNodes::new(),
            banned_peers: HashSet::new(),
            networks: Arc::new(RwLock::new(networks)),
            prometheus_exporter,
        }
    }

    /// It adds new node to the banned peer list.
    pub fn ban_node(&mut self, peer: P2PPeer) -> bool { self.banned_peers.insert(peer) }

    /// It remove a node from the banned peer list.
    pub fn unban_node(&mut self, peer: &P2PPeer) -> bool { self.banned_peers.remove(peer) }

    pub fn is_banned(&self, peer: &P2PPeer) -> bool { self.banned_peers.contains(peer) }

    pub fn addr_is_banned(&self, sockaddr: &SocketAddr) -> Fallible<bool> {
        let p2p_peer = P2PPeerBuilder::default()
            .ip(sockaddr.ip())
            .port(sockaddr.port())
            .connection_type(ConnectionType::Node)
            .build()?;
        Ok(self.banned_peers.contains(&p2p_peer))
    }

    /// It removes this server from `network_id` network.
    /// *Note:* Network list is shared, and this will updated all other
    /// instances.
    pub fn remove_network(&mut self, network_id: NetworkId) -> Fallible<()> {
        safe_write!(self.networks)?.retain(|x| *x == network_id);
        Ok(())
    }

    /// It adds this server to `network_id` network.
    pub fn add_network(&mut self, network_id: NetworkId) -> Fallible<()> {
        safe_write!(self.networks)?.insert(network_id);
        Ok(())
    }

    /// It generates a peer statistic list for each connected peer which belongs
    /// to any of networks in `nids`.
    pub fn get_peer_stats(&self, nids: &[NetworkId]) -> Vec<PeerStatistic> {
        let mut ret = vec![];
        for ref rc_conn in &self.connections {
            let conn = rc_conn.borrow();
            if let Some(ref x) = conn.peer() {
                if nids.len() == 0 || conn.networks().iter().any(|nid| nids.contains(nid)) {
                    ret.push(PeerStatistic::new(
                        x.id().to_string(),
                        x.ip(),
                        x.port(),
                        conn.get_messages_sent(),
                        conn.get_messages_received(),
                        conn.get_last_latency_measured(),
                    ));
                }
            }
        }

        ret
    }

    pub fn find_connection_by_id(&self, id: P2PNodeId) -> Option<&Rc<RefCell<Connection>>> {
        self.connections
            .iter()
            .find(|&conn| conn.borrow().id() == id)
    }

    pub fn find_connection_by_token(&self, token: Token) -> Option<&Rc<RefCell<Connection>>> {
        self.connections
            .iter()
            .find(|&conn| conn.borrow().token() == token)
    }

    pub fn find_connection_by_ip_addr(
        &self,
        ip: IpAddr,
        port: u16,
    ) -> Option<&Rc<RefCell<Connection>>> {
        self.connections.iter().find(|&conn| {
            let borrowed = conn.borrow();
            borrowed.ip() == ip && borrowed.port() == port
        })
    }

    fn remove_connection(&mut self, to_remove: &Connection) {
        self.connections
            .retain(|conn| conn.borrow().token() != to_remove.token());
    }

    pub fn add_connection(&mut self, conn: Connection) {
        // if this connection already exists, we assume the old one is stale and replace
        // it
        if let Some(con) = self
            .connections
            .iter_mut()
            .find(|c| c.borrow().token() == conn.token())
        {
            mem::replace(con, Rc::new(RefCell::new(conn)));
        } else {
            self.connections.push(Rc::new(RefCell::new(conn)));
        }
    }

    pub fn conn_event(
        &mut self,
        poll: &mut Poll,
        event: &Event,
        packet_queue: &Sender<Arc<NetworkMessage>>,
    ) -> Fallible<()> {
        let token = event.token();
        let mut rc_conn_to_be_removed: Option<_> = None;

        if let Some(rc_conn) = self.find_connection_by_token(token) {
            let mut conn = rc_conn.borrow_mut();
            conn.ready(poll, event, packet_queue)?;

            if conn.is_closed() {
                rc_conn_to_be_removed = Some(Rc::clone(rc_conn));
            }
        } else {
            bail!(fails::PeerNotFoundError)
        }

        if let Some(rc_conn) = rc_conn_to_be_removed {
            let conn = rc_conn.borrow();
            self.remove_connection(&conn);
        }

        Ok(())
    }

    pub fn cleanup_connections(&mut self, mode: P2PNodeMode, mut poll: &mut Poll) -> Fallible<()> {
        let curr_stamp = get_current_stamp();

        if mode == P2PNodeMode::BootstrapperMode {
            for rc_conn in self.connections.iter() {
                let mut conn = rc_conn.borrow_mut();
                if conn.last_seen() + MAX_BOOTSTRAPPER_KEEP_ALIVE < curr_stamp {
                    panic!("# Miguel: Close connection by timeout 1");
                    conn.close(&mut poll)?;
                }
            }
        } else {
            for rc_conn in self.connections.iter() {
                let mut conn = rc_conn.borrow_mut();
                if (conn.last_seen() + MAX_NORMAL_KEEP_ALIVE < curr_stamp
                    && conn.connection_type() == ConnectionType::Node)
                    || conn.failed_pkts() >= MAX_FAILED_PACKETS_ALLOWED
                {
                    panic!("# Miguel: Close connection by timeout 2");
                    conn.close(&mut poll)?;
                }
            }

            self.unreachable_nodes
                .cleanup(curr_stamp - MAX_UNREACHABLE_MARK_TIME);
        }

        // Kill banned connections
        for peer in self.banned_peers.iter() {
            if let Some(rc_conn) = self.find_connection_by_id(peer.id()) {
                panic!("# Miguel: Close connection by ban");
                rc_conn.borrow_mut().close(&mut poll)?;
            }
        }

        // Remove connections which status is 'closing'.
        let closing_conns: Vec<_> = self
            .connections
            .iter()
            .filter(|ref rc_conn| rc_conn.borrow().closing)
            .map(|ref rc_conn| Rc::clone(rc_conn))
            .collect();

        if let Some(ref prom) = &self.prometheus_exporter {
            let closing_with_peer = closing_conns
                .iter()
                .filter(|ref rc_conn| rc_conn.borrow().peer().is_some())
                .count();
            safe_write!(prom)?.peers_dec_by(closing_with_peer as i64)?;
        }

        for rc_conn in closing_conns.iter() {
            let conn = rc_conn.borrow();
            self.remove_connection(&conn);
        }

        Ok(())
    }

    pub fn liveness_check(&mut self) -> Fallible<()> {
        let curr_stamp = get_current_stamp();

        self.connections
            .iter()
            .filter(|ref rc_conn| {
                let conn = rc_conn.borrow();
                conn.last_seen() + 120000 < curr_stamp
                    || conn.get_last_ping_sent() + 300000 < curr_stamp
            })
            .for_each(|ref rc_conn| {
                let mut conn = rc_conn.borrow_mut();

                let self_peer = conn.get_self_peer().to_owned();
                conn.serialize_bytes(&NetworkRequest::Ping(self_peer).serialize())
                    .map_err(|e| error!("{}", e))
                    .ok();
                conn.set_measured_ping_sent();
                conn.set_last_ping_sent();
            });

        Ok(())
    }

    /// It sends `data` message over all filtered connections.
    ///
    /// # Arguments
    /// * `data` - Raw message.
    /// * `filter_conn` - It will send using all connection, where this function
    ///   returns `true`.
    /// * `send_status` - It will called after each sent, to notify the result
    ///   of the operation.
    pub fn send_over_all_connections(
        &mut self,
        data: &[u8],
        filter_conn: &dyn Fn(&Connection) -> bool,
        send_status: &dyn Fn(&Connection, Fallible<usize>),
    ) {
        for rc_conn in self.connections.iter() {
            let mut conn = rc_conn.borrow_mut();
            if filter_conn(&conn) {
                let status = conn.serialize_bytes(data);
                send_status(&conn, status)
            }
        }
    }
}
