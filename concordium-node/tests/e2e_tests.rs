extern crate p2p_client;
extern crate bytes;
extern crate mio;
#[macro_use]
extern crate log;
extern crate env_logger;

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::{thread,time};
    use p2p_client::p2p::*;
    use p2p_client::common::{NetworkPacket,NetworkMessage,NetworkRequest};
    use mio::Events;

    #[test]
    pub fn e2e_000() {
        let (pkt_in_1,pkt_out_1) = mpsc::channel();
        let (pkt_in_2,_pkt_out_2) = mpsc::channel();

        let (sender, receiver) = mpsc::channel();
        let _guard = thread::spawn(move|| {
            loop {
                if let Ok(msg) = receiver.recv() {
                    match msg {
                        P2PEvent::ConnectEvent(ip, port) => info!("Received connection from {}:{}", ip, port),
                        P2PEvent::DisconnectEvent(msg) => info!("Received disconnect for {}", msg),
                        P2PEvent::ReceivedMessageEvent(node_id) => info!("Received message from {:?}", node_id),
                        P2PEvent::SentMessageEvent(node_id) => info!("Sent message to {:?}", node_id),
                        P2PEvent::InitiatingConnection(ip,port) => info!("Initiating connection to {}:{}", ip, port),
                    }
                }
            }
        });

        let node_1 = P2PNode::new(None, 8888, pkt_in_1, Some(sender));

        let mut _th_clone_1 = node_1.clone();

        let _th_1 = thread::spawn(move || {
            let mut events = Events::with_capacity(1024);
            loop {
                _th_clone_1.process(&mut events);
            }
        });

        let mut node_2 = P2PNode::new(None, 8889, pkt_in_2, None);

        let mut _th_clone_2 = node_2.clone();
        
        let _th_1 = thread::spawn(move || {
            let mut events = Events::with_capacity(1024);
            loop {
                _th_clone_2.process(&mut events);
            }
        });

        let msg = String::from("Hello other brother!");

        node_2.connect("127.0.0.1".parse().unwrap(), 8888);

        node_2.send_message(Some(node_1.get_own_id()), msg.clone(), false);

        thread::sleep(time::Duration::from_secs(1));

        match pkt_out_1.try_recv() {
            Ok(NetworkMessage::NetworkRequest(NetworkRequest::Handshake(_),_,_)) => {},
            _ => { panic!("Didn't get handshake"); }
        }

        thread::sleep(time::Duration::from_secs(1));

        match pkt_out_1.try_recv() {
            Ok(NetworkMessage::NetworkPacket(NetworkPacket::DirectMessage(_,_, recv_msg),_,_)) => {
                assert_eq!(msg, recv_msg);
            },
            _ => { panic!("Didn't get message from node_2"); }
        }
    }
}