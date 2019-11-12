use byteorder::{NetworkEndian, ReadBytesExt, WriteBytesExt};
use bytesize::ByteSize;
use failure::{Error, Fallible};
use mio::tcp::TcpStream;
use noiseexplorer_xx::{
    consts::{DHLEN, MAC_LENGTH},
    noisesession::NoiseSession,
    types::Keypair,
};

use super::{
    fails::{MessageTooBigError, StreamWouldBlock},
    Connection, DeduplicationQueues,
};
use crate::{common::counter::TOTAL_MESSAGES_SENT_COUNTER, network::PROTOCOL_MAX_MESSAGE_SIZE};
use concordium_common::hybrid_buf::HybridBuf;

use std::{
    collections::VecDeque,
    io::{Cursor, ErrorKind, Read, Seek, SeekFrom, Write},
    mem,
    pin::Pin,
    sync::{atomic::Ordering, Arc},
};

type PayloadSize = u32;

const PROLOGUE: &[u8] = b"CP2P";
const NOISE_MAX_MESSAGE_LEN: usize = 64 * 1024 - 1; // 65535
const NOISE_AUTH_TAG_LEN: usize = 16;
const NOISE_MAX_PAYLOAD_LEN: usize = NOISE_MAX_MESSAGE_LEN - NOISE_AUTH_TAG_LEN;

/// The result of a socket operation.
#[derive(Debug, Clone)]
pub enum TcpResult<T> {
    /// For socket reads, `T` is the complete read message; for writes it's the
    /// number of written bytes
    Complete(T),
    /// Indicates that a read or write operation is incomplete and will be
    /// requeued
    Incomplete,
    /// A status dedicated to operations whose read/write result is of no
    /// interest or void
    Discarded,
    // The current read/write operation was aborted due to a `WouldBlock` error
    Aborted,
}

/// The single message currently being read from the socket along with its
/// pending length.
#[derive(Default)]
struct IncomingMessage {
    pending_bytes: PayloadSize,
    message:       HybridBuf,
}

pub struct ConnectionLowLevel {
    pub conn_ref: Option<Pin<Arc<Connection>>>,
    pub socket: TcpStream,
    noise_session: NoiseSession,
    buffer: [u8; NOISE_MAX_MESSAGE_LEN],
    incoming_msg: IncomingMessage,
    /// A queue for messages waiting to be written to the socket
    output_queue: VecDeque<Cursor<Vec<u8>>>,
}

impl ConnectionLowLevel {
    pub fn conn(&self) -> &Connection {
        &self.conn_ref.as_ref().unwrap() // safe; always available
    }

    pub fn new(socket: TcpStream, is_initiator: bool) -> Self {
        if let Err(e) = socket.set_linger(Some(std::time::Duration::from_secs(0))) {
            error!(
                "Can't set SOLINGER to 0 for socket {:?} due to {}",
                socket, e
            );
        }

        let keypair = Keypair::default();
        let noise_session = NoiseSession::init_session(is_initiator, PROLOGUE, keypair);

        trace!(
            "Starting a noise session as the {}; handshake mode: XX",
            if is_initiator {
                "initiator"
            } else {
                "responder"
            }
        );

        ConnectionLowLevel {
            conn_ref: None,
            socket,
            noise_session,
            buffer: [0; NOISE_MAX_MESSAGE_LEN],
            incoming_msg: IncomingMessage::default(),
            output_queue: VecDeque::with_capacity(16),
        }
    }

    // handshake

    pub fn initiator_send_message_a(&mut self) -> Fallible<()> {
        trace!("I'm sending message A");
        let mut msg_a = vec![0u8; DHLEN + 16]; // the extra 16B is necessary padding
        self.noise_session.send_message(&mut msg_a)?;
        self.output_queue.push_back(create_frame(&msg_a)?);
        self.flush_socket()?;

        Ok(())
    }

    fn responder_got_message_a(&mut self, mut input: HybridBuf) -> Fallible<()> {
        trace!("I got message A");
        let mut msg_a = vec![0u8; input.len()? as usize];
        input.read_exact(&mut msg_a)?;
        self.noise_session.recv_message(&mut msg_a)?;

        trace!("I'm sending message B");
        let mut msg_b = vec![0u8; DHLEN * 2 + MAC_LENGTH * 2];
        self.noise_session.send_message(&mut msg_b)?;
        self.output_queue.push_back(create_frame(&msg_b)?);
        self.flush_socket()?;

        Ok(())
    }

    fn initiator_got_message_b(&mut self, mut input: HybridBuf) -> Fallible<()> {
        trace!("I got message B");
        let mut msg_b = vec![0u8; input.len()? as usize];
        input.read_exact(&mut msg_b)?;
        self.noise_session.recv_message(&mut msg_b.clone())?;

        trace!("I'm sending message C");
        let mut msg_c = vec![0u8; DHLEN + MAC_LENGTH * 2];
        self.noise_session.send_message(&mut msg_c)?;
        self.output_queue.push_back(create_frame(&msg_c)?);
        self.flush_socket()?;

        Ok(())
    }

    fn responder_got_message_c(&mut self, mut input: HybridBuf) -> Fallible<()> {
        trace!("I got message C");
        let mut msg_c = vec![0u8; input.len()? as usize];
        input.read_exact(&mut msg_c)?;
        self.noise_session.recv_message(&mut msg_c)?;

        // send the high-level handshake request
        self.conn().send_handshake_request()?;
        self.flush_socket()?;

        Ok(())
    }

    fn is_post_handshake(&self) -> bool {
        if self.noise_session.is_initiator() {
            self.noise_session.get_message_count() > 1
        } else {
            self.noise_session.get_message_count() > 2
        }
    }

    // input

    /// Keeps reading from the socket as long as there is data to be read.
    #[inline(always)]
    pub fn read_stream(&mut self, deduplication_queues: &DeduplicationQueues) -> Fallible<()> {
        loop {
            match self.read_from_socket() {
                Ok(read_result) => match read_result {
                    TcpResult::Complete(message) => {
                        if let Err(e) = self.conn().process_message(message, deduplication_queues) {
                            bail!("can't process a message: {}", e);
                        }
                    }
                    TcpResult::Discarded => {}
                    TcpResult::Incomplete | TcpResult::Aborted => return Ok(()),
                },
                Err(e) => bail!("can't read from the socket: {}", e),
            }
        }
    }

    /// Attempts to read a complete message from the socket.
    #[inline(always)]
    fn read_from_socket(&mut self) -> Fallible<TcpResult<HybridBuf>> {
        trace!("Attempting to read from the socket");
        let read_result = if self.incoming_msg.pending_bytes == 0 {
            self.read_expected_size()
        } else {
            self.read_payload()
        };

        match read_result {
            Ok(TcpResult::Complete(payload)) => {
                let len = payload.len()?;
                trace!(
                    "A {} message was fully read",
                    ByteSize(len).to_string_as(true)
                );
                self.forward(payload, len as usize)?;

                if self.is_post_handshake() {
                    let decrypted_msg = mem::replace(
                        &mut self.incoming_msg.message,
                        HybridBuf::with_capacity(mem::size_of::<PayloadSize>())?,
                    );

                    Ok(TcpResult::Complete(decrypted_msg))
                } else {
                    Ok(TcpResult::Discarded)
                }
            }
            Ok(TcpResult::Incomplete) => {
                trace!("The current message is incomplete");
                Ok(TcpResult::Incomplete)
            }
            Ok(_) => unreachable!(),
            Err(err) => {
                if err.downcast_ref::<StreamWouldBlock>().is_some() {
                    trace!("Further reads would be blocking; aborting");
                    Ok(TcpResult::Aborted)
                } else {
                    Err(err)
                }
            }
        }
    }

    fn forward(&mut self, input: HybridBuf, len: usize) -> Fallible<()> {
        match self.noise_session.get_message_count() {
            0 if !self.noise_session.is_initiator() => self.responder_got_message_a(input),
            1 if self.noise_session.is_initiator() => self.initiator_got_message_b(input),
            2 if !self.noise_session.is_initiator() => self.responder_got_message_c(input),
            _ => self.decrypt(input, len),
        }
    }

    /// Reads the number of bytes required to read the frame length
    #[inline]
    fn pending_bytes_to_know_expected_size(&self) -> Fallible<usize> {
        let current_len = self.incoming_msg.message.len()? as usize;

        if current_len < mem::size_of::<PayloadSize>() {
            Ok(mem::size_of::<PayloadSize>() - current_len)
        } else {
            Ok(0)
        }
    }

    /// It first reads the first 4 bytes of the message to determine its size.
    fn read_expected_size(&mut self) -> Fallible<TcpResult<HybridBuf>> {
        // only extract the bytes needed to know the size.
        let min_bytes = self.pending_bytes_to_know_expected_size()?;
        let read_bytes = map_io_error_to_fail!(self.socket.read(&mut self.buffer[..min_bytes]))?;

        self.incoming_msg
            .message
            .write_all(&self.buffer[..read_bytes])?;

        // once the number of bytes needed to read the message size is known, continue
        if self.incoming_msg.message.len()? == mem::size_of::<PayloadSize>() as u64 {
            self.incoming_msg.message.rewind()?;
            let expected_size = self.incoming_msg.message.read_u32::<NetworkEndian>()?;

            // check if the expected size doesn't exceed the protocol limit
            if expected_size > PROTOCOL_MAX_MESSAGE_SIZE as PayloadSize {
                let error = MessageTooBigError {
                    expected_size,
                    protocol_size: PROTOCOL_MAX_MESSAGE_SIZE as PayloadSize,
                };
                return Err(Error::from(error));
            } else {
                trace!(
                    "Expecting a {} message",
                    ByteSize(expected_size as u64).to_string_as(true)
                );
                self.incoming_msg.pending_bytes = expected_size;
            }

            // remove the length from the buffer
            mem::replace(
                &mut self.incoming_msg.message,
                HybridBuf::with_capacity(expected_size as usize)?,
            );

            // Read data next...
            self.read_payload()
        } else {
            // We need more data to determine the message size.
            Ok(TcpResult::Incomplete)
        }
    }

    /// Once we know the message expected size, we can start to receive data.
    fn read_payload(&mut self) -> Fallible<TcpResult<HybridBuf>> {
        while self.incoming_msg.pending_bytes > 0 {
            if self.read_intermediate()? == 0 {
                break;
            }
        }

        if self.incoming_msg.pending_bytes == 0 {
            // The incoming message is complete and ready to be processed further
            self.incoming_msg.message.rewind()?;
            let new_data = std::mem::replace(
                &mut self.incoming_msg.message,
                HybridBuf::with_capacity(mem::size_of::<PayloadSize>())?,
            );

            Ok(TcpResult::Complete(new_data))
        } else {
            Ok(TcpResult::Incomplete)
        }
    }

    fn read_intermediate(&mut self) -> Fallible<usize> {
        let read_size = std::cmp::min(
            self.incoming_msg.pending_bytes as usize,
            NOISE_MAX_MESSAGE_LEN,
        );

        match self.socket.read(&mut self.buffer[..read_size]) {
            Ok(read_bytes) => {
                self.incoming_msg
                    .message
                    .write_all(&self.buffer[..read_bytes])?;
                self.incoming_msg.pending_bytes -= read_bytes as PayloadSize;

                Ok(read_bytes)
            }
            Err(err) => match err.kind() {
                ErrorKind::WouldBlock => {
                    trace!("This read would be blocking; aborting");
                    Ok(0)
                }
                _ => Err(Error::from(err)),
            },
        }
    }

    /// It reads the chunk table and decrypts the chunks.
    fn decrypt<R: Read + Seek>(&mut self, mut input: R, len: usize) -> Fallible<()> {
        // calculate the number of full-sized chunks
        let num_full_chunks = len / NOISE_MAX_MESSAGE_LEN;
        // calculate the number of the last, incomplete chunk (if there is one)
        let last_chunk_size = len % NOISE_MAX_MESSAGE_LEN;
        let num_all_chunks = num_full_chunks + if last_chunk_size > 0 { 1 } else { 0 };

        trace!("There are {} chunks to decrypt", num_all_chunks);

        let mut decrypted_msg =
            HybridBuf::with_capacity(NOISE_MAX_MESSAGE_LEN * num_full_chunks + last_chunk_size)?;

        // decrypt the full chunks
        for idx in 0..num_full_chunks {
            self.decrypt_chunk(idx, NOISE_MAX_MESSAGE_LEN, &mut input, &mut decrypted_msg)?;
        }

        // decrypt the incomplete chunk
        if last_chunk_size > 0 {
            self.decrypt_chunk(
                num_full_chunks,
                last_chunk_size,
                &mut input,
                &mut decrypted_msg,
            )?;
        }

        // rewind the decrypted message buffer
        decrypted_msg.rewind()?;

        self.incoming_msg.message = decrypted_msg;

        Ok(())
    }

    fn decrypt_chunk<R: Read + Seek, W: Write>(
        &mut self,
        chunk_idx: usize,
        chunk_size: usize,
        input: &mut R,
        output: &mut W,
    ) -> Fallible<()> {
        debug_assert!(chunk_size <= NOISE_MAX_MESSAGE_LEN);

        input.read_exact(&mut self.buffer[..chunk_size])?;

        match self
            .noise_session
            .recv_message(&mut self.buffer[..chunk_size])
        {
            Ok(()) => {
                let len = chunk_size - MAC_LENGTH;

                debug_assert!(
                    len <= chunk_size,
                    "Chunk {} bytes {} <= size {} fails",
                    chunk_idx,
                    len,
                    chunk_size
                );

                output.write_all(&self.buffer[..len])?;
                Ok(())
            }
            Err(err) => {
                error!("Decryption error: {}", err);
                Err(failure::Error::from(err))
            }
        }
    }

    // output

    #[inline(always)]
    pub fn write_to_socket(&mut self, input: Arc<[u8]>) -> Fallible<TcpResult<usize>> {
        TOTAL_MESSAGES_SENT_COUNTER.fetch_add(1, Ordering::Relaxed);
        self.conn()
            .stats
            .messages_sent
            .fetch_add(1, Ordering::Relaxed);
        if let Some(ref stats) = self.conn().handler().stats_export_service {
            stats.pkt_sent_inc();
        }

        if cfg!(feature = "network_dump") {
            self.conn().send_to_dump(input.clone(), false);
        }

        let encrypted_chunks = self.encrypt(&input)?;
        for chunk in encrypted_chunks {
            self.output_queue.push_back(chunk);
        }

        Ok(TcpResult::Discarded)
    }

    #[inline(always)]
    pub fn flush_socket(&mut self) -> Fallible<TcpResult<usize>> {
        let mut written_bytes = 0;

        while let Some(mut message) = self.output_queue.pop_front() {
            trace!(
                "Writing a {} message to the socket",
                ByteSize(message.get_ref().len() as u64 - message.position()).to_string_as(true)
            );
            written_bytes += partial_copy(&mut message, &mut self.buffer, &mut self.socket)?;

            if message.position() as usize == message.get_ref().len() {
                trace!("Successfully written a message to the socket");
            } else {
                trace!(
                    "Incomplete write ({}B remaining); requeuing",
                    message.get_ref().len() - message.position() as usize
                );
                self.output_queue.push_front(message);
                return Ok(TcpResult::Incomplete);
            }
        }

        Ok(TcpResult::Complete(written_bytes))
    }

    /// It splits `input` into chunks of `NOISE_MAX_PAYLOAD_LEN` and encrypts
    /// each of them.
    fn encrypt_chunks<R: Read + Seek>(
        &mut self,
        input: &mut R,
        chunks: &mut Vec<Cursor<Vec<u8>>>,
    ) -> Fallible<usize> {
        let mut written = 0;

        let mut curr_pos = input.seek(SeekFrom::Current(0))?;
        let eof = input.seek(SeekFrom::End(0))?;
        input.seek(SeekFrom::Start(curr_pos))?;

        while curr_pos != eof {
            let chunk_size = std::cmp::min(NOISE_MAX_PAYLOAD_LEN, (eof - curr_pos) as usize);
            input.read_exact(&mut self.buffer[..chunk_size])?;
            let encrypted_len = chunk_size + MAC_LENGTH;

            self.noise_session
                .send_message(&mut self.buffer[..encrypted_len])?;

            let mut chunk = Vec::with_capacity(encrypted_len);
            let wrote = chunk.write(&self.buffer[..encrypted_len])?;

            chunks.push(Cursor::new(chunk));

            written += wrote;

            curr_pos = input.seek(SeekFrom::Current(0))?;
        }

        Ok(written)
    }

    /// It encrypts `input` and returns the encrypted chunks preceded by the
    /// length
    fn encrypt(&mut self, input: &[u8]) -> Fallible<Vec<Cursor<Vec<u8>>>> {
        trace!("Commencing encryption");

        let num_full_chunks = input.len() / NOISE_MAX_MESSAGE_LEN;
        let num_incomplete_chunks = if input.len() % NOISE_MAX_MESSAGE_LEN == 0 {
            0
        } else {
            1
        };
        let num_chunks = num_full_chunks + num_incomplete_chunks;

        // the extra 1 is for the message length
        let mut chunks = Vec::with_capacity(1 + num_chunks);

        // create the metadata chunk
        let metadata = Vec::with_capacity(mem::size_of::<PayloadSize>());
        chunks.push(Cursor::new(metadata));

        let encrypted_len = self.encrypt_chunks(&mut Cursor::new(input), &mut chunks)?;

        // write the message size
        chunks[0].write_u32::<NetworkEndian>(encrypted_len as PayloadSize)?;
        chunks[0].seek(SeekFrom::Start(0))?;

        trace!(
            "Encrypted a frame of {}B",
            mem::size_of::<PayloadSize>() + encrypted_len,
        );

        Ok(chunks)
    }
}

/// It tries to copy as much as possible from `input` to `output` in a
/// streaming fashion. It is used with `socket` that blocks them when
/// their output buffers are full. Written bytes are consumed from `input`.
fn partial_copy<W: Write>(
    input: &mut Cursor<Vec<u8>>,
    buffer: &mut [u8],
    output: &mut W,
) -> Fallible<usize> {
    let mut total_written_bytes = 0;

    while input.get_ref().len() != input.position() as usize {
        let offset = input.position();

        let chunk_size = std::cmp::min(
            NOISE_MAX_MESSAGE_LEN,
            input.get_ref().len() - offset as usize,
        );
        input.read_exact(&mut buffer[..chunk_size])?;

        match output.write(&buffer[..chunk_size]) {
            Ok(written_bytes) => {
                total_written_bytes += written_bytes;
                if written_bytes != chunk_size {
                    // Fix the offset because read data was not written completely.
                    input.seek(SeekFrom::Start(offset + written_bytes as u64))?;
                }
            }
            Err(io_err) => {
                input.seek(SeekFrom::Start(offset))?;
                match io_err.kind() {
                    std::io::ErrorKind::WouldBlock => break,
                    _ => return Err(failure::Error::from(io_err)),
                }
            }
        }
    }

    Ok(total_written_bytes)
}

/// It prefixes `data` with its length, encoded as `u32` in `NetworkEndian`.
fn create_frame(data: &[u8]) -> Fallible<Cursor<Vec<u8>>> {
    let mut frame = Vec::with_capacity(data.len() + std::mem::size_of::<PayloadSize>());
    frame.write_u32::<NetworkEndian>(data.len() as u32)?;
    frame.extend_from_slice(data);

    Ok(Cursor::new(frame))
}
