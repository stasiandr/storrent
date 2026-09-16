//! Narrow facade over librqbit, exported to Swift through UniFFI.
//!
//! The engine owns its own tokio runtime. Async methods spawn onto it and
//! await the join handle, so the foreign executor never needs a tokio context.

use std::{net::Ipv6Addr, path::PathBuf, sync::Arc};

use librqbit::{
    AddTorrent, AddTorrentOptions, ListenerMode, ListenerOptions, Session, SessionOptions,
    SessionPersistenceConfig, TorrentStatsState,
    api::{Api, ApiTorrentListOpts, TorrentDetailsResponse, TorrentIdOrHash},
    dht::DhtPersistenceConfig,
};
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

/// Default BitTorrent listen port (the same one Transmission uses).
const LISTEN_PORT: u16 = 51413;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum EngineError {
    #[error("{message}")]
    Failed { message: String },
}

impl From<anyhow::Error> for EngineError {
    fn from(e: anyhow::Error) -> Self {
        Self::Failed { message: format!("{e:#}") }
    }
}

impl From<std::io::Error> for EngineError {
    fn from(e: std::io::Error) -> Self {
        Self::Failed { message: e.to_string() }
    }
}

impl From<librqbit::ApiError> for EngineError {
    fn from(e: librqbit::ApiError) -> Self {
        Self::Failed { message: e.to_string() }
    }
}

type Result<T> = std::result::Result<T, EngineError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TorrentState {
    Initializing,
    Downloading,
    Seeding,
    Paused,
    Error,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TorrentInfo {
    pub id: u64,
    pub info_hash: String,
    pub name: String,
    pub output_folder: String,
    pub state: TorrentState,
    pub error: Option<String>,
    pub progress_bytes: u64,
    pub total_bytes: u64,
    pub uploaded_bytes: u64,
    /// Bytes per second.
    pub download_speed: u64,
    /// Bytes per second.
    pub upload_speed: u64,
    pub eta_seconds: Option<u64>,
    pub peers_connected: u32,
    pub peers_seen: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FileEntry {
    pub index: u64,
    /// Path inside the torrent, `/`-separated.
    pub path: String,
    pub length: u64,
    pub progress_bytes: u64,
    pub included: bool,
}

#[derive(uniffi::Object)]
pub struct Engine {
    runtime: Runtime,
    api: Api,
}

#[uniffi::export]
impl Engine {
    /// Starts a session. `download_dir` is where torrents are saved,
    /// `state_dir` keeps the session and DHT state between launches.
    #[uniffi::constructor]
    pub fn new(download_dir: String, state_dir: String) -> Result<Arc<Self>> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("storrent-engine")
            .build()
            .map_err(anyhow::Error::from)?;

        let state_dir = PathBuf::from(state_dir);
        std::fs::create_dir_all(&state_dir).map_err(anyhow::Error::from)?;

        let mut opts = SessionOptions {
            fastresume: true,
            persistence: Some(SessionPersistenceConfig::Json {
                folder: Some(state_dir.join("session")),
            }),
            listen: Some(ListenerOptions {
                mode: ListenerMode::TcpAndUtp,
                listen_addr: (Ipv6Addr::UNSPECIFIED, LISTEN_PORT).into(),
                enable_upnp_port_forwarding: true,
                ..Default::default()
            }),
            client_name_and_version: Some(format!("storrent {}", env!("CARGO_PKG_VERSION"))),
            ..Default::default()
        };
        if let Some(dht) = opts.dht.as_mut() {
            dht.persistence = Some(DhtPersistenceConfig {
                config_filename: Some(state_dir.join("dht.json")),
                ..Default::default()
            });
        }

        let session =
            runtime.block_on(Session::new_with_opts(PathBuf::from(download_dir), opts))?;
        Ok(Arc::new(Self { runtime, api: Api::new(session, None) }))
    }

    /// Everything the list view needs, cheap enough to call every second.
    pub fn torrents(&self) -> Vec<TorrentInfo> {
        self.api
            .api_torrent_list_ext(ApiTorrentListOpts { with_stats: true })
            .torrents
            .into_iter()
            .map(info)
            .collect()
    }

    pub fn files(&self, id: u64) -> Result<Vec<FileEntry>> {
        let details = self.api.api_torrent_details(torrent_id(id))?;
        let progress = self.api.api_stats_v1(torrent_id(id))?.file_progress;
        Ok(details
            .files
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(index, f)| FileEntry {
                index: index as u64,
                path: f.components.join("/"),
                length: f.length,
                progress_bytes: progress.get(index).copied().unwrap_or_default(),
                included: f.included,
            })
            .collect())
    }
}

#[uniffi::export]
impl Engine {
    /// Adds a magnet link, an http(s) URL of a .torrent, or a local .torrent path.
    /// For magnets this waits until metadata is fetched from peers.
    pub async fn add(&self, source: String) -> Result<u64> {
        let session = self.api.session().clone();
        self.spawn(async move {
            let add = if source.starts_with('/') {
                AddTorrent::from_bytes(tokio::fs::read(&source).await?)
            } else {
                AddTorrent::from_url(source)
            };
            let opts = AddTorrentOptions { overwrite: true, ..Default::default() };
            let handle = session
                .add_torrent(add, Some(opts))
                .await?
                .into_handle()
                .ok_or_else(|| anyhow::anyhow!("torrent was not added"))?;
            Ok(handle.id() as u64)
        })
        .await
    }

    pub async fn pause(&self, id: u64) -> Result<()> {
        let api = self.api.clone();
        self.spawn(async move { Ok(api.api_torrent_action_pause(torrent_id(id)).await.map(drop)?) })
            .await
    }

    pub async fn resume(&self, id: u64) -> Result<()> {
        let api = self.api.clone();
        self.spawn(async move { Ok(api.api_torrent_action_start(torrent_id(id)).await.map(drop)?) })
            .await
    }

    pub async fn remove(&self, id: u64, delete_files: bool) -> Result<()> {
        let api = self.api.clone();
        self.spawn(async move {
            let res = if delete_files {
                api.api_torrent_action_delete(torrent_id(id)).await
            } else {
                api.api_torrent_action_forget(torrent_id(id)).await
            };
            Ok(res.map(drop)?)
        })
        .await
    }

    pub async fn set_included_files(&self, id: u64, indices: Vec<u64>) -> Result<()> {
        let api = self.api.clone();
        self.spawn(async move {
            let only: std::collections::HashSet<usize> =
                indices.into_iter().map(|i| i as usize).collect();
            Ok(api
                .api_torrent_action_update_only_files(torrent_id(id), &only)
                .await
                .map(drop)?)
        })
        .await
    }
}

impl Engine {
    async fn spawn<T: Send + 'static>(
        &self,
        fut: impl Future<Output = Result<T>> + Send + 'static,
    ) -> Result<T> {
        self.runtime
            .spawn(fut)
            .await
            .map_err(|e| EngineError::Failed { message: format!("engine task failed: {e}") })?
    }
}

fn torrent_id(id: u64) -> TorrentIdOrHash {
    TorrentIdOrHash::Id(id as usize)
}

fn info(t: TorrentDetailsResponse) -> TorrentInfo {
    let stats = t.stats.as_ref();
    let live = stats.and_then(|s| s.live.as_ref());
    let state = match stats.map(|s| (s.state, s.finished)) {
        None | Some((TorrentStatsState::Initializing { .. }, _)) => TorrentState::Initializing,
        Some((TorrentStatsState::Live, true)) => TorrentState::Seeding,
        Some((TorrentStatsState::Live, false)) => TorrentState::Downloading,
        Some((TorrentStatsState::Paused, _)) => TorrentState::Paused,
        Some((TorrentStatsState::Error, _)) => TorrentState::Error,
    };
    let to_bps = |mib: f64| (mib * 1024.0 * 1024.0) as u64;
    let progress_bytes = stats.map_or(0, |s| s.progress_bytes);
    let total_bytes = stats.map_or(0, |s| s.total_bytes);
    let download_speed = live.map_or(0, |l| to_bps(l.download_speed.mbps));
    TorrentInfo {
        id: t.id.unwrap_or_default() as u64,
        name: t.name.unwrap_or_else(|| t.info_hash.clone()),
        info_hash: t.info_hash,
        output_folder: t.output_folder,
        state,
        error: stats.and_then(|s| s.error.clone()),
        progress_bytes,
        total_bytes,
        uploaded_bytes: stats.map_or(0, |s| s.uploaded_bytes),
        download_speed,
        upload_speed: live.map_or(0, |l| to_bps(l.upload_speed.mbps)),
        eta_seconds: (state == TorrentState::Downloading && download_speed > 0)
            .then(|| total_bytes.saturating_sub(progress_bytes) / download_speed),
        peers_connected: live.map_or(0, |l| l.snapshot.peer_stats.live),
        peers_seen: live.map_or(0, |l| l.snapshot.peer_stats.seen),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_with_empty_session() {
        let downloads = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let engine = Engine::new(
            downloads.path().to_string_lossy().into(),
            state.path().to_string_lossy().into(),
        )
        .unwrap();
        assert!(engine.torrents().is_empty());
        assert!(engine.files(0).is_err());
    }
}
