#![recursion_limit = "1024"]

// Force the system allocator on every platform
use std::{alloc::System, sync::Arc};
#[global_allocator]
static A: System = System;

use anyhow::{ensure, Context};
use concordium_base::hashes::BlockHash;
use concordium_node::{
    common::PeerType,
    consensus_ffi::consensus::Regenesis,
    p2p::{maintenance::spawn, *},
    stats_export_service::instantiate_stats_export_engine,
    utils::get_config_and_logging_setup,
};

use concordium_node::stats_export_service::start_push_gateway;
use std::net::SocketAddr;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (mut conf, app_prefs) = get_config_and_logging_setup()?;
    conf.connection.max_allowed_nodes = Some(conf.bootstrapper.max_nodes);
    let data_dir_path = app_prefs.get_data_dir();

    let stats_export_service = instantiate_stats_export_engine(&conf.prometheus)?;

    let fname = conf
        .bootstrapper
        .regenesis_block_hashes
        .clone()
        .unwrap_or_else(|| data_dir_path.join(std::path::Path::new("genesis_hash")));
    let regenesis_hashes_bytes = std::fs::read(&fname)
        .context(format!("Could not open file {} with genesis hashes.", fname.to_string_lossy()))?;
    let regenesis_blocks: Vec<BlockHash> = serde_json::from_slice(&regenesis_hashes_bytes)
        .context("Could not parse genesis hashes.")?;
    let regenesis_arc: Arc<Regenesis> = Arc::new(Regenesis::from_blocks(regenesis_blocks));

    ensure!(
        regenesis_arc.blocks.read().unwrap().len() > 0,
        "Bootstrapper can't run without specifying genesis hashes."
    );

    let (node, server, poll) = P2PNode::new(
        conf.common.id,
        &conf,
        PeerType::Bootstrapper,
        stats_export_service.clone(),
        regenesis_arc,
    )
    .context("Failed to create the network node.")?;

    start_push_gateway(&conf.prometheus, &node.stats, node.id());

    if let Some(plp) = conf.prometheus.prometheus_listen_port {
        // We ignore the receiver since we do not care about graceful shutdown here.
        let (sender, _) = tokio::sync::broadcast::channel(1);
        tokio::spawn(async move {
            stats_export_service
                .start_server(SocketAddr::new(conf.prometheus.prometheus_listen_addr, plp), sender)
                .await
        });
    }

    // Set the startime in the stats.
    node.stats.node_startup_timestamp.set(node.start_time.timestamp_millis());

    spawn(&node, server, poll, None);

    node.join().expect("Node thread panicked!");

    Ok(())
}
