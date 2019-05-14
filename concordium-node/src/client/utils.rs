use super::seen_transmissions_list::SeenTransmissionsList;
use crate::{
    configuration,
    stats_export_service::{StatsExportService, StatsServiceMode},
};
use concordium_consensus::{block::BakedBlock, finalization::FinalizationRecord};
use failure::Fallible;
use std::sync::{Arc, RwLock};

cfg_if! {
    if #[cfg(feature = "instrumentation")] {
        use crate::common::P2PNodeId;
        use std::net::SocketAddr;
    }
}

lazy_static! {
    static ref SEEN_TRANSMISSIONS_LIST_BLOCKS: SeenTransmissionsList<BakedBlock> =
        { SeenTransmissionsList::<BakedBlock>::new(0, 5_000u64) };
    static ref SEEN_TRANSMISSIONS_LIST_FINALIZATION_RECORDS: SeenTransmissionsList<FinalizationRecord> =
        { SeenTransmissionsList::<FinalizationRecord>::new(0, 5_000u64) };
}

pub fn add_block_to_seenlist<T>(
    seen_at: u64,
    block: BakedBlock,
) -> Fallible<bool> {
    SEEN_TRANSMISSIONS_LIST_BLOCKS.add_transmission(seen_at, block)
}

pub fn add_record_to_seenlist<T>(
    seen_at: u64,
    rec: FinalizationRecord,
) -> Fallible<bool> {
    SEEN_TRANSMISSIONS_LIST_FINALIZATION_RECORDS.add_transmission(seen_at, rec)
}

pub fn get_blocks_since_from_seenlist(
    since_stamp: u64,
) -> Fallible<Vec<Box<[u8]>>> {
    SEEN_TRANSMISSIONS_LIST_BLOCKS.get_transmissions_since(since_stamp)
}

pub fn get_recs_since_from_seenlist(
    since_stamp: u64,
) -> Fallible<Vec<Box<[u8]>>> {
    SEEN_TRANSMISSIONS_LIST_FINALIZATION_RECORDS.get_transmissions_since(since_stamp)
}

#[cfg(feature = "instrumentation")]
pub fn instantiate_stats_export_engine(
    conf: &configuration::Config,
    mode: StatsServiceMode,
) -> Fallible<Option<Arc<RwLock<StatsExportService>>>> {
    let prom = if conf.prometheus.prometheus_server {
        info!("Enabling prometheus server");
        let mut srv = StatsExportService::new(mode)?;
        srv.start_server(SocketAddr::new(
            conf.prometheus.prometheus_listen_addr.parse()?,
            conf.prometheus.prometheus_listen_port,
        ));
        Some(Arc::new(RwLock::new(srv)))
    } else if let Some(ref push_gateway) = conf.prometheus.prometheus_push_gateway {
        info!("Enabling prometheus push gateway at {}", push_gateway);
        let srv = StatsExportService::new(mode)?;
        Some(Arc::new(RwLock::new(srv)))
    } else {
        None
    };
    Ok(prom)
}

#[cfg(not(feature = "instrumentation"))]
pub fn instantiate_stats_export_engine(
    _: &configuration::Config,
    mode: StatsServiceMode,
) -> Fallible<Option<Arc<RwLock<StatsExportService>>>> {
    Ok(Some(Arc::new(RwLock::new(StatsExportService::new(mode)?))))
}

#[cfg(feature = "instrumentation")]
pub fn start_push_gateway(
    conf: &configuration::PrometheusConfig,
    stats_export_service: &Option<Arc<RwLock<StatsExportService>>>,
    id: P2PNodeId,
) -> Fallible<()> {
    if let Some(ref service) = stats_export_service {
        if let Some(ref prom_push_addy) = conf.prometheus_push_gateway {
            let instance_name = if let Some(ref instance_id) = conf.prometheus_instance_name {
                instance_id.clone()
            } else {
                id.to_string()
            };
            safe_read!(service)?.start_push_to_gateway(
                prom_push_addy.clone(),
                conf.prometheus_push_interval,
                conf.prometheus_job_name.clone(),
                instance_name,
                conf.prometheus_push_username.clone(),
                conf.prometheus_push_password.clone(),
            )
        }
    }
    Ok(())
}

#[cfg(feature = "instrumentation")]
pub fn stop_stats_export_engine(
    conf: &configuration::Config,
    srv: &Option<Arc<RwLock<StatsExportService>>>,
) {
    if conf.prometheus.prometheus_server {
        if let Some(srv) = srv {
            info!("Stopping prometheus server");
            if let Ok(mut locked) = srv.write() {
                locked.stop_server();
            }
        }
    }
}

#[cfg(not(feature = "instrumentation"))]
pub fn stop_stats_export_engine(
    _: &configuration::Config,
    _: &Option<Arc<RwLock<StatsExportService>>>,
) {
}
