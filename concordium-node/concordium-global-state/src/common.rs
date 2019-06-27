use base58::ToBase58;
use byteorder::{ByteOrder, NetworkEndian, WriteBytesExt};
use digest::Digest;
use failure::{format_err, Fallible};
use sha2::Sha224;

use std::{
    convert::TryFrom,
    fmt,
    io::{Cursor, Read, Write},
    mem::size_of,
    num::NonZeroU64,
    ops::Deref,
};

pub use concordium_common::{HashBytes, SHA256};
pub use ec_vrf_ed25519 as vrf;
pub use ec_vrf_ed25519::{Proof, Sha256, PROOF_LENGTH};
pub use eddsa_ed25519 as sig;

pub const ALLOCATION_LIMIT: usize = 4096;

use crate::block::{BakerId, BlockHash};

pub type ContractIndex = u64;
pub type ContractSubIndex = u64;

#[derive(Debug, Clone, Copy)]
pub struct ContractAddress {
    index:    ContractIndex,
    subindex: ContractSubIndex,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for ContractAddress {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let index = NetworkEndian::read_u64(&read_ty!(cursor, ContractIndex));
        let subindex = NetworkEndian::read_u64(&read_ty!(cursor, ContractSubIndex));

        let contract_address = ContractAddress { index, subindex };

        Ok(contract_address)
    }

    fn serialize(&self) -> Box<[u8]> {
        let mut cursor = create_serialization_cursor(size_of::<ContractAddress>());

        let _ = cursor.write_u64::<NetworkEndian>(self.index);
        let _ = cursor.write_u64::<NetworkEndian>(self.subindex);

        cursor.into_inner()
    }
}

#[derive(Debug, Clone, Copy)]
pub enum SchemeId {
    Cl = 0,
    Ed25519,
}

impl TryFrom<u8> for SchemeId {
    type Error = failure::Error;

    fn try_from(id: u8) -> Fallible<Self> {
        match id {
            0 => Ok(SchemeId::Cl),
            1 => Ok(SchemeId::Ed25519),
            _ => Err(format_err!("Unsupported SchemeId ({})!", id)),
        }
    }
}

#[derive(PartialEq, Eq, Hash)]
pub struct AccountAddress(pub [u8; 21]);

impl From<(&[u8], SchemeId)> for AccountAddress {
    fn from((verification_key, scheme_id): (&[u8], SchemeId)) -> Self {
        let mut buf = [0u8; size_of::<AccountAddress>()];
        let hash_len = size_of::<AccountAddress>() - 1;

        buf[0] = scheme_id as u8;
        buf[1..].copy_from_slice(&Sha224::digest(verification_key)[0..hash_len]);

        Self(buf)
    }
}

impl fmt::Debug for AccountAddress {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", ToBase58::to_base58(&self.0[..]))
    }
}

impl fmt::Display for AccountAddress {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{:?}", self) }
}

#[derive(Debug)]
pub struct Account {
    address:           AccountAddress,
    nonce:             Nonce,
    amount:            Amount,
    encrypted_amounts: Box<[ByteString]>,
    encryption_key:    Option<ByteString>,
    verification_key:  ByteString,
    signature_scheme:  SchemeId,
    credentials:       Box<[Encoded]>,
    stake_delegate:    Option<BakerId>,
    instances:         Box<[ContractAddress]>,
}

impl<'a, 'b: 'a> SerializeToBytes<'a, 'b> for Account {
    type Source = &'a mut Cursor<&'b [u8]>;

    fn deserialize(cursor: Self::Source) -> Fallible<Self> {
        let address = AccountAddress(read_ty!(cursor, AccountAddress));

        let nonce_raw = NetworkEndian::read_u64(&read_ty!(cursor, Nonce));
        let nonce = Nonce::try_from(nonce_raw)?;

        let amount = NetworkEndian::read_u64(&read_ty!(cursor, Amount));

        let encrypted_amounts = read_multiple!(
            cursor,
            "encrypted amounts",
            read_bytestring(cursor, "encrypted amount's length")?
        );

        let encryption_key = read_maybe!(cursor, read_bytestring(cursor, "encrypted key's length")?);

        let verification_key = read_bytestring(cursor, "verification key's length")?;

        let signature_scheme = SchemeId::try_from(read_ty!(cursor, SchemeId)[0])?;

        let credentials = read_multiple!(
            cursor,
            "credentials",
            read_bytestring(cursor, "encrypted amount's length")?
        );

        let stake_delegate = read_maybe!(cursor, NetworkEndian::read_u64(&read_ty!(cursor, BakerId)));

        let instances = read_multiple!(
            cursor,
            "instances",
            ContractAddress::deserialize(cursor)?
        );

        let account = Account {
            address,
            nonce,
            amount,
            encrypted_amounts,
            encryption_key,
            verification_key,
            signature_scheme,
            credentials,
            stake_delegate,
            instances,
        };

        Ok(account)
    }

    fn serialize(&self) -> Box<[u8]> {
        fn serialized_bs_list_len(bs_list: &[ByteString]) -> usize {
            bs_list
                .iter()
                .map(|bs| size_of::<u64>() + bs.len())
                .sum::<usize>()
        }

        let encryption_key_len = self
            .encryption_key
            .iter()
            .next()
            .map(|k| k.len())
            .unwrap_or(0);

        let stake_delegate_len = self.stake_delegate.map(|_| size_of::<BakerId>()).unwrap_or(0);

        let mut cursor = create_serialization_cursor(
            size_of::<AccountAddress>()
                + size_of::<Nonce>()
                + size_of::<Amount>()
                + size_of::<u64>()
                + serialized_bs_list_len(&self.encrypted_amounts)
                + size_of::<u8>()
                + encryption_key_len
                + size_of::<u64>()
                + self.verification_key.len()
                + size_of::<SchemeId>()
                + size_of::<u64>()
                + serialized_bs_list_len(&self.credentials)
                + size_of::<u8>()
                + stake_delegate_len
                + size_of::<u64>()
                + self.instances.len() * size_of::<ContractAddress>(),
        );

        let _ = cursor.write_all(&self.address.0);
        let _ = cursor.write_u64::<NetworkEndian>(self.nonce.0.get());
        let _ = cursor.write_u64::<NetworkEndian>(self.amount);
        write_multiple!(&mut cursor, self.encrypted_amounts, write_bytestring);
        write_maybe!(&mut cursor, self.encryption_key, write_bytestring);
        write_bytestring(&mut cursor, &self.verification_key);
        let _ = cursor.write(&[self.signature_scheme as u8]);
        write_multiple!(&mut cursor, self.credentials, write_bytestring);

        if let Some(baker_id) = self.stake_delegate {
            let _ = cursor.write(&[1]);
            let _ = cursor.write_u64::<NetworkEndian>(baker_id);
        } else {
            let _ = cursor.write(&[0]);
        }

        let _ = cursor.write_u64::<NetworkEndian>(self.instances.len() as u64);
        for instance in &*self.instances {
            let _ = cursor.write_all(&ContractAddress::serialize(instance));
        }

        cursor.into_inner()
    }
}

pub type Amount = u64;

#[derive(PartialEq, Eq, Hash, Clone)]
pub struct Nonce(pub NonZeroU64);

impl TryFrom<u64> for Nonce {
    type Error = failure::Error;

    fn try_from(raw: u64) -> Fallible<Self> {
        Ok(Nonce(NonZeroU64::new(raw).ok_or_else(|| {
            return format_err!("A zero nonce was received!");
        })?))
    }
}

impl fmt::Debug for Nonce {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{}", self.0) }
}

impl fmt::Display for Nonce {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{:?}", self) }
}

pub type Slot = u64;

pub type Energy = u64;

pub type Incarnation = u64;

#[derive(Debug, PartialEq, Eq, Hash, Clone)]
pub struct SessionId {
    genesis_block: BlockHash,
    incarnation:   u64,
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result { write!(f, "{}", self.incarnation) }
}

impl SessionId {
    pub fn deserialize(bytes: &[u8]) -> Fallible<Self> {
        let mut cursor = Cursor::new(bytes);

        let genesis_block = HashBytes::from(read_ty!(&mut cursor, HashBytes));
        let incarnation = NetworkEndian::read_u64(&read_ty!(&mut cursor, Incarnation));

        let sess = SessionId {
            genesis_block,
            incarnation,
        };

        check_serialization!(sess, cursor);

        Ok(sess)
    }

    pub fn serialize(&self) -> Box<[u8]> {
        let mut cursor =
            create_serialization_cursor(size_of::<BlockHash>() + size_of::<Incarnation>());

        let _ = cursor.write_all(&self.genesis_block);
        let _ = cursor.write_u64::<NetworkEndian>(self.incarnation);

        cursor.into_inner()
    }
}

// a type used for objects we only need to store, but not handle
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Encoded(Box<[u8]>);

impl Encoded {
    pub fn new(bytes: &[u8]) -> Self { Encoded(Box::from(bytes)) }
}

impl Deref for Encoded {
    type Target = [u8];

    fn deref(&self) -> &Self::Target { &self.0 }
}

impl fmt::Debug for Encoded {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{:?} ({}B)", sha256(&self.0), self.0.len())
    }
}

// we don't need to handle it in any special way for now, but we might like to
// know that it's prefixed with a u64 length of the rest of it
pub type ByteString = Encoded;

pub fn create_serialization_cursor(size: usize) -> Cursor<Box<[u8]>> {
    let buf = vec![0; size];

    Cursor::new(buf.into_boxed_slice())
}

pub fn read_bytestring(input: &mut Cursor<&[u8]>, object_name: &str) -> Fallible<ByteString> {
    let object_length = safe_get_len!(input, object_name);

    Ok(Encoded(read_sized!(input, object_length)))
}

pub fn write_bytestring(target: &mut Cursor<Box<[u8]>>, bytes: &[u8]) {
    let _ = target.write_u64::<NetworkEndian>(bytes.len() as u64);
    let _ = target.write_all(&bytes);
}

pub fn serialize_list<'a, 'b, T: SerializeToBytes<'a, 'b>>(list: &'a [T]) -> Vec<Box<[u8]>> {
    list.iter().map(|elem| elem.serialize()).collect()
}

pub fn list_len<T: AsRef<[u8]>>(list: &[T]) -> usize {
    list.iter().map(|elem| elem.as_ref().len()).sum()
}

pub fn sha256(bytes: &[u8]) -> HashBytes { HashBytes::new(&Sha256::digest(bytes)) }

pub trait SerializeToBytes<'a, 'b>
where
    Self: Sized, {
    type Source; // either a byte slice or a mutable cursor (when total size is unknown)

    fn deserialize(source: Self::Source) -> Fallible<Self>;
    fn serialize(&self) -> Box<[u8]>;
}
