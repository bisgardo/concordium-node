//! Peer ban handling.

use byteorder::{ReadBytesExt, WriteBytesExt};
use failure::{self, Fallible};
use rkv::{StoreOptions, Value};

use crate::{
    common::P2PNodeId, connection::ConnChange, find_conn_by_id, find_conns_by_ip, p2p::P2PNode,
};
use crypto_common::{Buffer, Deserial, Serial};

use std::net::{IpAddr, SocketAddr};

const BAN_STORE_NAME: &str = "bans";

#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "s11n_serde", derive(Serialize, Deserialize))]
/// A node can be banned either by its id node or
/// by its address - IP or IP+port.
pub enum BanId {
    NodeId(P2PNodeId),
    Ip(IpAddr),
    Socket(SocketAddr),
}

impl Serial for BanId {
    fn serial<W: Buffer + WriteBytesExt>(&self, target: &mut W) {
        match self {
            BanId::NodeId(id) => {
                target.write_u8(0).unwrap(); // writing to memory is infallible
                id.serial(target);
            }
            BanId::Ip(addr) => {
                target.write_u8(1).unwrap(); // ditto
                addr.serial(target);
            }
            _ => unimplemented!("Serializing a socket address ban is not supported"),
        }
    }
}

impl Deserial for BanId {
    fn deserial<R: ReadBytesExt>(source: &mut R) -> Fallible<Self> {
        let bn = match source.read_u8()? {
            0 => BanId::NodeId(P2PNodeId::deserial(source)?),
            1 => BanId::Ip(IpAddr::deserial(source)?),
            _ => bail!("Unsupported type of `BanNode`"),
        };

        Ok(bn)
    }
}

impl P2PNode {
    /// Adds a new node to the banned list and closes its connection if there is
    /// one.
    pub fn ban_node(&self, peer: BanId) -> Fallible<()> {
        info!("Banning node {:?}", peer);

        let mut store_key = Vec::new();
        peer.serial(&mut store_key);
        {
            let ban_kvs_env = safe_read!(self.kvs)?;
            let ban_store = ban_kvs_env.open_single(BAN_STORE_NAME, StoreOptions::create())?;
            let mut writer = ban_kvs_env.write()?;
            // TODO: insert ban expiry timestamp as the Value
            ban_store.put(&mut writer, store_key, &Value::U64(0))?;
            writer.commit()?;
        }

        match peer {
            BanId::NodeId(id) => {
                if let Some(conn) = find_conn_by_id!(self, id) {
                    self.register_conn_change(ConnChange::Removal(conn.token));
                }
            }
            BanId::Ip(addr) => {
                for conn in find_conns_by_ip!(self, addr) {
                    self.register_conn_change(ConnChange::Removal(conn.token));
                }
            }
            _ => unimplemented!("Socket address bans don't persist"),
        }

        if !self.config.no_trust_bans {
            self.send_ban(peer);
        }

        Ok(())
    }

    /// It removes a node from the banned peer list.
    pub fn unban_node(&self, peer: BanId) -> Fallible<()> {
        info!("Unbanning node {:?}", peer);

        let mut store_key = Vec::new();
        peer.serial(&mut store_key);
        {
            let ban_kvs_env = safe_read!(self.kvs)?;
            let ban_store = ban_kvs_env.open_single(BAN_STORE_NAME, StoreOptions::create())?;
            let mut writer = ban_kvs_env.write()?;
            // TODO: insert ban expiry timestamp as the Value
            ban_store.delete(&mut writer, store_key)?;
            writer.commit()?;
        }

        if !self.config.no_trust_bans {
            self.send_unban(peer);
        }

        Ok(())
    }

    /// Checks whether a specified id has been banned.
    pub fn is_banned(&self, peer: BanId) -> Fallible<bool> {
        let ban_kvs_env = safe_read!(self.kvs)?;
        let ban_store = ban_kvs_env.open_single(BAN_STORE_NAME, StoreOptions::create())?;

        let ban_reader = ban_kvs_env.read()?;
        let mut store_key = Vec::new();
        peer.serial(&mut store_key);

        Ok(ban_store.get(&ban_reader, store_key)?.is_some())
    }

    /// Obtains the list of banned nodes.
    pub fn get_banlist(&self) -> Fallible<Vec<BanId>> {
        let ban_kvs_env = safe_read!(self.kvs)?;
        let ban_store = ban_kvs_env.open_single(BAN_STORE_NAME, StoreOptions::create())?;

        let ban_reader = ban_kvs_env.read()?;
        let ban_iter = ban_store.iter_start(&ban_reader)?;

        let mut banlist = Vec::new();
        for entry in ban_iter {
            let (mut id_bytes, _expiry) = entry?;
            let node_to_ban = BanId::deserial(&mut id_bytes)?;
            banlist.push(node_to_ban);
        }

        Ok(banlist)
    }

    /// Lifts all existing bans.
    pub fn clear_bans(&self) -> Fallible<()> {
        let kvs_env = safe_read!(self.kvs)?;
        let ban_store = kvs_env.open_single(BAN_STORE_NAME, StoreOptions::create())?;
        let mut writer = kvs_env.write()?;
        ban_store.clear(&mut writer)?;
        into_err!(writer.commit())
    }
}
