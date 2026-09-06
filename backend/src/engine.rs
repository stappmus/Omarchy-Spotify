use std::{
    collections::VecDeque,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use librespot_connect::{
    ConnectConfig, LoadContextOptions, LoadRequest, LoadRequestOptions, Options, PlayingTrack,
    Spirc,
};
use librespot_core::{
    SpotifyUri,
    authentication::Credentials,
    cache::Cache,
    config::{DeviceType, SessionConfig},
    session::Session,
};
use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, PlayerConfig},
    mixer::{self, MixerConfig},
    player::{Player, PlayerEvent, QueueTrack},
};
use sha1::{Digest, Sha1};
use tokio::sync::{mpsc, oneshot, watch};

use crate::{
    config::BackendConfig,
    protocol::{
        BackendState, Command, Lifecycle, PlaybackStatus, ProtocolError, RepeatMode, Track,
    },
    state::StateStore,
};

const INITIAL_VOLUME: u16 = ((u16::MAX as u32 * 90) / 100) as u16;
const ENGINE_QUEUE_CAPACITY: usize = 64;
const RECONNECT_LIMIT: usize = 5;
const RECONNECT_WINDOW: Duration = Duration::from_secs(10 * 60);
// Librespot caps `next_tracks` at 80, so retain no more than it can replay.
const MAX_RECOVERY_NEXT_TRACKS: usize = 80;
const CONTEXT_PROVIDER: &str = "context";
const QUEUE_PROVIDER: &str = "queue";
const AUDIO_KEY_UNAVAILABLE_CODE: &str = "audio_key_unavailable";
const AUDIO_KEY_UNAVAILABLE_MESSAGE: &str = "Spotify did not provide the audio key required to play this track on this computer. Try another Spotify Connect device.";

pub struct EngineRequest {
    pub command: Command,
    pub reply: Option<oneshot::Sender<Result<serde_json::Value, ProtocolError>>>,
}

pub type EngineSender = mpsc::Sender<EngineRequest>;

pub struct EngineRuntime {
    pub commands: EngineSender,
    shutdown: watch::Sender<bool>,
    done: oneshot::Receiver<Result<()>>,
}

impl EngineRuntime {
    pub async fn wait_done(&mut self) -> Result<()> {
        (&mut self.done)
            .await
            .context("playback engine supervisor stopped")?
    }

    pub fn shutdown(&self) {
        let _ = self.shutdown.send(true);
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct RecoveryQueue {
    context_uri: String,
    current_track: Option<QueueTrack>,
    next_tracks: Vec<QueueTrack>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum RecoveryLoad {
    Context {
        uri: String,
        current_uri: String,
        queued_uris: Vec<String>,
    },
    Tracks(Vec<String>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RecoverySnapshot {
    load: RecoveryLoad,
    position_ms: u32,
    play: bool,
    volume: u16,
    shuffle: bool,
    repeat: RepeatMode,
}

impl RecoverySnapshot {
    fn capture(state: &BackendState, queue: &RecoveryQueue) -> Option<Self> {
        let play = match state.playback {
            PlaybackStatus::Playing | PlaybackStatus::Loading => true,
            PlaybackStatus::Paused => false,
            PlaybackStatus::Stopped => return None,
        };
        let track = state.track.as_ref()?;
        if !is_playable_uri(&track.uri) {
            return None;
        }

        let queue_matches = queue
            .current_track
            .as_ref()
            .is_some_and(|current| current.uri == track.uri);
        let next_tracks: Vec<&QueueTrack> = if queue_matches {
            queue
                .next_tracks
                .iter()
                .filter(|next| is_playable_uri(&next.uri))
                .take(MAX_RECOVERY_NEXT_TRACKS)
                .collect()
        } else {
            Vec::new()
        };

        // Preserve a real Spotify context when its current track belongs to that
        // context. Flatten a shuffled context so recovery uses the captured queue
        // entries instead of resolving the context again before shuffle is restored.
        let load = if !state.shuffle
            && queue_matches
            && queue
                .current_track
                .as_ref()
                .is_some_and(|current| current.provider == CONTEXT_PROVIDER)
            && is_context_uri(&queue.context_uri)
        {
            RecoveryLoad::Context {
                uri: queue.context_uri.clone(),
                current_uri: track.uri.clone(),
                queued_uris: next_tracks
                    .iter()
                    .filter(|next| next.provider == QUEUE_PROVIDER)
                    .map(|next| next.uri.clone())
                    .collect(),
            }
        } else {
            let mut uris = Vec::with_capacity(next_tracks.len() + 1);
            uris.push(track.uri.clone());
            uris.extend(next_tracks.into_iter().map(|next| next.uri.clone()));
            RecoveryLoad::Tracks(uris)
        };

        let position_ms = if track.duration_ms > 0 {
            state.position_ms.min(track.duration_ms.saturating_sub(1))
        } else {
            state.position_ms
        };

        Some(Self {
            load,
            position_ms,
            play,
            volume: state.volume,
            shuffle: state.shuffle,
            repeat: state.repeat,
        })
    }

    fn load_request(&self) -> LoadRequest {
        let playing_track = match &self.load {
            RecoveryLoad::Context { current_uri, .. } => {
                Some(PlayingTrack::Uri(current_uri.clone()))
            }
            RecoveryLoad::Tracks(_) => Some(PlayingTrack::Index(0)),
        };
        let options = LoadRequestOptions {
            start_playing: self.play,
            seek_to: self.position_ms,
            playing_track,
            context_options: Some(LoadContextOptions::Options(Options {
                shuffle: false,
                repeat: self.repeat == RepeatMode::Context,
                repeat_track: self.repeat == RepeatMode::Track,
            })),
        };

        match &self.load {
            RecoveryLoad::Context { uri, .. } => {
                LoadRequest::from_context_uri(uri.clone(), options)
            }
            RecoveryLoad::Tracks(uris) => LoadRequest::from_tracks(uris.clone(), options),
        }
    }
}

fn is_playable_uri(value: &str) -> bool {
    SpotifyUri::from_uri(value).is_ok_and(|uri| uri.is_playable())
}

fn is_context_uri(value: &str) -> bool {
    SpotifyUri::from_uri(value).is_ok_and(|uri| !uri.is_playable())
}

pub async fn start(config: BackendConfig, state: StateStore) -> Result<EngineRuntime> {
    let runtime_cache = open_runtime_cache(&config)?;
    let credentials = load_credentials(&config.credentials_root, &config.cache_root)?;

    let mut session_config = SessionConfig {
        device_id: hex::encode(Sha1::digest(config.device_name.as_bytes())),
        ap_port: Some(443),
        autoplay: Some(config.autoplay),
        ..SessionConfig::default()
    };
    session_config.tmp_dir = std::env::temp_dir();

    let mut player_config = PlayerConfig {
        bitrate: config.bitrate,
        position_update_interval: Some(Duration::from_secs(1)),
        ..PlayerConfig::default()
    };
    player_config.gapless = true;

    let sink_builder = audio_backend::find(Some("pulseaudio".to_string()))
        .ok_or_else(|| anyhow!("pulseaudio backend was not compiled in"))?;
    let mixer_builder = mixer::find(Some("softvol"))
        .ok_or_else(|| anyhow!("soft volume mixer was not compiled in"))?;
    let mixer = mixer_builder(MixerConfig::default()).context("failed to create soft mixer")?;
    let session = Session::new(session_config.clone(), Some(runtime_cache.clone()));
    let audio_device = config.audio_device.clone();
    let player = Player::new(
        player_config,
        session.clone(),
        mixer.get_soft_volume(),
        move || sink_builder(audio_device.clone(), AudioFormat::S16),
    );
    let events = player.get_player_event_channel();

    let connect_config = ConnectConfig {
        name: config.device_name,
        device_type: DeviceType::Computer,
        initial_volume: INITIAL_VOLUME,
        disable_volume: false,
        volume_steps: 64,
        emit_set_queue_events: true,
        ..ConnectConfig::default()
    };
    let (spirc, spirc_task) = Spirc::new(
        connect_config.clone(),
        session.clone(),
        credentials.clone(),
        Arc::clone(&player),
        Arc::clone(&mixer),
    )
    .await
    .context("failed to connect the librespot session")?;
    let spirc = Arc::new(spirc);

    state.update(|current| {
        current.lifecycle = Lifecycle::Ready;
        current.volume = INITIAL_VOLUME;
        current.error_code.clear();
        current.error.clear();
        true
    });

    let (commands, command_rx) = mpsc::channel(ENGINE_QUEUE_CAPACITY);
    let (current_spirc_tx, current_spirc_rx) = watch::channel(Some(Arc::clone(&spirc)));
    let (recovery_queue_tx, recovery_queue_rx) = watch::channel(RecoveryQueue::default());
    tokio::spawn(run_commands(
        command_rx,
        current_spirc_rx,
        Arc::clone(&player),
    ));
    tokio::spawn(run_events(events, state.clone(), recovery_queue_tx));

    let (shutdown, shutdown_rx) = watch::channel(false);
    let (done_tx, done) = oneshot::channel();
    let spirc_task = tokio::spawn(spirc_task);
    tokio::spawn(async move {
        let result = supervise_sessions(
            session_config,
            runtime_cache,
            connect_config,
            credentials,
            player,
            mixer,
            session,
            spirc,
            spirc_task,
            current_spirc_tx,
            recovery_queue_rx,
            state,
            shutdown_rx,
        )
        .await;
        let _ = done_tx.send(result);
    });

    Ok(EngineRuntime {
        commands,
        shutdown,
        done,
    })
}

#[allow(clippy::too_many_arguments)]
async fn supervise_sessions(
    session_config: SessionConfig,
    runtime_cache: Cache,
    connect_config: ConnectConfig,
    credentials: Credentials,
    player: Arc<Player>,
    mixer: Arc<dyn mixer::Mixer>,
    mut session: Session,
    mut spirc: Arc<Spirc>,
    mut spirc_task: tokio::task::JoinHandle<()>,
    current_spirc: watch::Sender<Option<Arc<Spirc>>>,
    recovery_queue: watch::Receiver<RecoveryQueue>,
    state: StateStore,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let mut reconnects = VecDeque::new();

    loop {
        tokio::select! {
            result = &mut spirc_task => {
                result.context("librespot session task failed")?;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    let _ = spirc.shutdown();
                    return Ok(());
                }
                continue;
            }
        }

        let recovery =
            state.with(|current| RecoverySnapshot::capture(current, &recovery_queue.borrow()));
        current_spirc.send_replace(None);
        state.update(|current| {
            current.lifecycle = Lifecycle::Starting;
            current.session_connected = false;
            current.active_client.clear();
            true
        });

        let now = Instant::now();
        if !record_reconnect(&mut reconnects, now) {
            bail!("librespot session ended too often; reconnect limit reached");
        }
        log::warn!("librespot session ended; reconnecting");

        if !session.is_invalid() {
            session.shutdown();
        }
        session = Session::new(session_config.clone(), Some(runtime_cache.clone()));
        player.set_session(session.clone());
        let reconnect = Spirc::new(
            connect_config.clone(),
            session.clone(),
            credentials.clone(),
            Arc::clone(&player),
            Arc::clone(&mixer),
        );
        tokio::pin!(reconnect);
        let (next_spirc, next_task) = tokio::select! {
            result = &mut reconnect => {
                result.context("failed to reconnect the librespot session")?
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Ok(());
                }
                continue;
            }
        };

        spirc = Arc::new(next_spirc);
        spirc_task = tokio::spawn(next_task);
        let restore_error = recovery
            .as_ref()
            .and_then(|snapshot| restore_playback(&spirc, snapshot).err());
        current_spirc.send_replace(Some(Arc::clone(&spirc)));
        state.update(|current| {
            current.lifecycle = Lifecycle::Ready;
            current.error_code.clear();
            if let Some(error) = restore_error.as_ref() {
                current.error =
                    format!("Spotify reconnected, but playback could not be restored: {error}");
            } else {
                current.error.clear();
            }
            true
        });
        if let Some(error) = restore_error {
            log::warn!("reconnected the librespot session without restoring playback: {error}");
        } else if recovery.is_some() {
            log::info!("reconnected the librespot session and queued playback restoration");
        } else {
            log::info!("reconnected the librespot session");
        }
    }
}

enum RecoveryCommand {
    Activate,
    Load(LoadRequest),
    AddToQueue(SpotifyUri),
    Volume(u16),
    Shuffle(bool),
    RepeatTrack(bool),
}

fn restore_playback(spirc: &Spirc, snapshot: &RecoverySnapshot) -> Result<()> {
    restore_playback_with(snapshot, |command| {
        match command {
            RecoveryCommand::Activate => spirc.activate()?,
            RecoveryCommand::Load(request) => spirc.load(request)?,
            RecoveryCommand::AddToQueue(uri) => spirc.add_to_queue(uri)?,
            RecoveryCommand::Volume(volume) => spirc.set_volume(volume)?,
            RecoveryCommand::Shuffle(enabled) => spirc.shuffle(enabled)?,
            RecoveryCommand::RepeatTrack(enabled) => spirc.repeat_track(enabled)?,
        }
        Ok(())
    })
}

fn restore_playback_with(
    snapshot: &RecoverySnapshot,
    mut send: impl FnMut(RecoveryCommand) -> Result<()>,
) -> Result<()> {
    send(RecoveryCommand::Activate)?;
    send(RecoveryCommand::Load(snapshot.load_request()))?;

    if let RecoveryLoad::Context { queued_uris, .. } = &snapshot.load {
        for uri in queued_uris {
            let uri = SpotifyUri::from_uri(uri).context("invalid queued Spotify URI")?;
            if let Err(error) = send(RecoveryCommand::AddToQueue(uri)) {
                log::warn!("could not restore a queued track: {error}");
            }
        }
    }
    if let Err(error) = send(RecoveryCommand::Volume(snapshot.volume)) {
        log::warn!("could not restore playback volume: {error}");
    }
    if let Err(error) = send(RecoveryCommand::Shuffle(snapshot.shuffle)) {
        log::warn!("could not restore shuffle state: {error}");
    }
    // Load applies repeat flags without emitting RepeatChanged. RepeatTrack
    // publishes both current flags without rebuilding the context queue as
    // Spirc::repeat() would. Normal interactive controls still use set_repeat.
    if let Err(error) = send(RecoveryCommand::RepeatTrack(
        snapshot.repeat == RepeatMode::Track,
    )) {
        log::warn!("could not publish restored repeat state: {error}");
    }
    Ok(())
}

fn record_reconnect(attempts: &mut VecDeque<Instant>, now: Instant) -> bool {
    while attempts
        .front()
        .is_some_and(|attempt| now.saturating_duration_since(*attempt) >= RECONNECT_WINDOW)
    {
        attempts.pop_front();
    }
    if attempts.len() >= RECONNECT_LIMIT {
        return false;
    }
    attempts.push_back(now);
    true
}

fn open_runtime_cache(config: &BackendConfig) -> Result<Cache> {
    let credentials = config.credentials_root.join("zeroconf");
    let audio_path = config.audio_cache.then_some(config.cache_root.as_path());
    Cache::new(
        Some(credentials.as_path()),
        Some(config.cache_root.as_path()),
        audio_path,
        config.max_cache_size,
    )
    .context("failed to open the playback cache")
}

fn load_credentials(credentials_root: &Path, legacy_cache_root: &Path) -> Result<Credentials> {
    let oauth_path = credentials_root.join("oauth");
    let oauth_cache = Cache::new(Some(oauth_path.as_path()), None, None, None)
        .context("failed to open the OAuth credential store")?;
    if let Some(credentials) = oauth_cache.credentials() {
        return Ok(credentials);
    }

    let connect_path = credentials_root.join("zeroconf");
    let connect_cache = Cache::new(Some(connect_path.as_path()), None, None, None)
        .context("failed to open the Connect credential store")?;
    if let Some(credentials) = connect_cache.credentials() {
        return Ok(credentials);
    }

    // Releases before 1.0.3 kept authorization below XDG_CACHE_HOME. Accept it
    // once and copy it into durable XDG state so ordinary cache cleanup cannot
    // silently remove this computer from Spotify Connect again.
    for (name, durable_cache) in [("oauth", &oauth_cache), ("zeroconf", &connect_cache)] {
        let legacy_path = legacy_cache_root.join(name);
        let legacy_cache = Cache::new(Some(legacy_path.as_path()), None, None, None)
            .context("failed to open the legacy playback credential cache")?;
        if let Some(credentials) = legacy_cache.credentials() {
            durable_cache.save_credentials(&credentials);
            return Ok(credentials);
        }
    }

    Err(anyhow!(
        "no playback credentials; authenticate from the plugin settings first"
    ))
}

async fn run_commands(
    mut receiver: mpsc::Receiver<EngineRequest>,
    current_spirc: watch::Receiver<Option<Arc<Spirc>>>,
    player: Arc<Player>,
) {
    while let Some(request) = receiver.recv().await {
        let result = match current_spirc.borrow().clone() {
            Some(spirc) => execute(&spirc, &player, request.command)
                .map(|()| serde_json::json!({}))
                .map_err(|error| ProtocolError::new("engine_error", error.to_string())),
            None => Err(ProtocolError::new(
                "engine_reconnecting",
                "playback is reconnecting to Spotify",
            )),
        };
        if let Some(reply) = request.reply {
            let _ = reply.send(result);
        }
    }
}

fn execute(spirc: &Spirc, player: &Player, command: Command) -> Result<()> {
    match command {
        Command::Activate => spirc.activate()?,
        Command::Play => spirc.play()?,
        Command::Pause => spirc.pause()?,
        Command::Toggle => spirc.play_pause()?,
        Command::Stop => spirc.disconnect(false)?,
        Command::Next => spirc.next()?,
        Command::Previous => spirc.prev()?,
        Command::Seek { position_ms } => spirc.set_position_ms(position_ms)?,
        Command::SetVolume { volume } => spirc.set_volume(volume)?,
        Command::SetShuffle { enabled } => spirc.shuffle(enabled)?,
        Command::SetRepeat { mode } => set_repeat(spirc, mode)?,
        Command::Load {
            context_uri,
            uris,
            offset_uri,
            offset_index,
            position_ms,
            play,
        } => {
            let playing_track = offset_uri
                .map(PlayingTrack::Uri)
                .or_else(|| offset_index.map(PlayingTrack::Index));
            let options = LoadRequestOptions {
                start_playing: play,
                seek_to: position_ms,
                playing_track,
                ..LoadRequestOptions::default()
            };
            let request = if let Some(context_uri) = context_uri {
                validate_spotify_uri(&context_uri)?;
                LoadRequest::from_context_uri(context_uri, options)
            } else if !uris.is_empty() {
                for uri in &uris {
                    validate_spotify_uri(uri)?;
                }
                LoadRequest::from_tracks(uris, options)
            } else {
                bail!("load requires context_uri or at least one uri");
            };
            // A local UI request is an explicit choice of this receiver. Acquire
            // Connect ownership before queueing the context so callers do not
            // need to wait for a Web API device transfer first.
            spirc.activate()?;
            spirc.load(request)?;
        }
        Command::AddToQueue { uri } => {
            let uri = SpotifyUri::from_uri(&uri).context("invalid Spotify URI")?;
            spirc.add_to_queue(uri)?;
        }
        Command::Hello | Command::Ping | Command::GetState => {
            bail!("command is handled by the protocol server")
        }
    }

    // Keep the player handle alive for the lifetime of the command task.
    let _ = player;
    Ok(())
}

fn validate_spotify_uri(value: &str) -> Result<()> {
    SpotifyUri::from_uri(value)
        .map(|_| ())
        .with_context(|| format!("invalid Spotify URI {value:?}"))
}

fn set_repeat(spirc: &Spirc, mode: RepeatMode) -> Result<()> {
    match mode {
        RepeatMode::Off => {
            spirc.repeat_track(false)?;
            spirc.repeat(false)?;
        }
        RepeatMode::Context => {
            spirc.repeat_track(false)?;
            spirc.repeat(true)?;
        }
        RepeatMode::Track => {
            spirc.repeat(false)?;
            spirc.repeat_track(true)?;
        }
    }
    Ok(())
}

async fn run_events(
    mut events: tokio::sync::mpsc::UnboundedReceiver<PlayerEvent>,
    state: StateStore,
    recovery_queue: watch::Sender<RecoveryQueue>,
) {
    let mut play_request_id = None;
    while let Some(event) = events.recv().await {
        if let PlayerEvent::PlayRequestIdChanged {
            play_request_id: next,
        } = &event
        {
            play_request_id = Some(*next);
            continue;
        }
        if event_is_stale(play_request_id, &event) {
            log::debug!("discarding stale player event for an earlier play request");
            continue;
        }
        if let Some(queue) = recovery_queue_from_event(&event) {
            recovery_queue.send_replace(queue);
            continue;
        }
        state.update(|current| apply_event(current, event));
    }
}

fn recovery_queue_from_event(event: &PlayerEvent) -> Option<RecoveryQueue> {
    let PlayerEvent::SetQueue {
        context_uri,
        current_track,
        next_tracks,
        ..
    } = event
    else {
        return None;
    };

    Some(RecoveryQueue {
        context_uri: context_uri.clone(),
        current_track: current_track.clone(),
        next_tracks: next_tracks.clone(),
    })
}

fn event_is_stale(play_request_id: Option<u64>, event: &PlayerEvent) -> bool {
    play_request_id
        .zip(event.get_play_request_id())
        .is_some_and(|(current, event)| current != event)
}

fn replace_if_changed<T: PartialEq>(target: &mut T, value: T) -> bool {
    if *target == value {
        false
    } else {
        *target = value;
        true
    }
}

fn replace_error(
    state: &mut crate::protocol::BackendState,
    code: &str,
    message: impl Into<String>,
) -> bool {
    let mut changed = replace_if_changed(&mut state.error_code, code.to_string());
    changed |= replace_if_changed(&mut state.error, message.into());
    changed
}

fn apply_event(state: &mut crate::protocol::BackendState, event: PlayerEvent) -> bool {
    match event {
        PlayerEvent::Stopped { .. } => {
            let mut changed = replace_if_changed(&mut state.playback, PlaybackStatus::Stopped);
            changed |= replace_if_changed(&mut state.position_ms, 0);
            changed |= replace_if_changed(&mut state.track, None);
            changed
        }
        PlayerEvent::Loading { position_ms, .. } => {
            // Keep an already-playing replacement continuous to MPRIS clients.
            // Initial loads still expose Loading until audio actually starts.
            let playback_changed = state.playback == PlaybackStatus::Stopped
                && replace_if_changed(&mut state.playback, PlaybackStatus::Loading);
            let mut changed =
                replace_if_changed(&mut state.position_ms, position_ms) || playback_changed;
            changed |= replace_error(state, "", "");
            changed
        }
        PlayerEvent::Playing { position_ms, .. } => {
            let playback_changed = replace_if_changed(&mut state.playback, PlaybackStatus::Playing);
            replace_if_changed(&mut state.position_ms, position_ms) || playback_changed
        }
        PlayerEvent::Paused { position_ms, .. } => {
            let playback_changed = replace_if_changed(&mut state.playback, PlaybackStatus::Paused);
            replace_if_changed(&mut state.position_ms, position_ms) || playback_changed
        }
        PlayerEvent::Unavailable { track_id, .. } => replace_error(
            state,
            "",
            format!("track unavailable: {}", track_id.to_uri()),
        ),
        PlayerEvent::AudioKeyUnavailable { .. } => replace_error(
            state,
            AUDIO_KEY_UNAVAILABLE_CODE,
            AUDIO_KEY_UNAVAILABLE_MESSAGE,
        ),
        PlayerEvent::VolumeChanged { volume } => replace_if_changed(&mut state.volume, volume),
        PlayerEvent::PositionCorrection { position_ms, .. }
        | PlayerEvent::PositionChanged { position_ms, .. } => {
            replace_if_changed(&mut state.position_ms, position_ms)
        }
        PlayerEvent::Seeked { position_ms, .. } => {
            replace_if_changed(&mut state.position_ms, position_ms);
            state.seek_sequence = state.seek_sequence.wrapping_add(1);
            true
        }
        PlayerEvent::TrackChanged { audio_item } => {
            let mut changed =
                replace_if_changed(&mut state.track, Some(track_from_audio_item(&audio_item)));
            changed |= replace_error(state, "", "");
            changed
        }
        PlayerEvent::SessionConnected { user_name, .. } => {
            let connected = replace_if_changed(&mut state.session_connected, true);
            replace_if_changed(&mut state.username, user_name) || connected
        }
        PlayerEvent::SessionDisconnected { .. } => {
            let disconnected = replace_if_changed(&mut state.session_connected, false);
            replace_if_changed(&mut state.active_client, String::new()) || disconnected
        }
        PlayerEvent::SessionClientChanged { client_name, .. } => {
            replace_if_changed(&mut state.active_client, client_name)
        }
        PlayerEvent::ShuffleChanged { shuffle } => replace_if_changed(&mut state.shuffle, shuffle),
        PlayerEvent::RepeatChanged { context, track } => {
            let repeat = if track {
                RepeatMode::Track
            } else if context {
                RepeatMode::Context
            } else {
                RepeatMode::Off
            };
            replace_if_changed(&mut state.repeat, repeat)
        }
        PlayerEvent::Preloading { .. }
        | PlayerEvent::TimeToPreloadNextTrack { .. }
        | PlayerEvent::EndOfTrack { .. }
        | PlayerEvent::PlayRequestIdChanged { .. }
        | PlayerEvent::AutoPlayChanged { .. }
        | PlayerEvent::FilterExplicitContentChanged { .. }
        | PlayerEvent::SetQueue { .. } => false,
    }
}

fn track_from_audio_item(item: &AudioItem) -> Track {
    let (artists, album, item_type) = match &item.unique_fields {
        UniqueFields::Track { artists, album, .. } => (
            artists.iter().map(|artist| artist.name.clone()).collect(),
            album.clone(),
            "track",
        ),
        UniqueFields::Episode { show_name, .. } => {
            (vec![show_name.clone()], show_name.clone(), "episode")
        }
        UniqueFields::Local { artists, album, .. } => (
            artists.iter().cloned().collect(),
            album.clone().unwrap_or_default(),
            "local",
        ),
    };

    Track {
        uri: item.uri.clone(),
        title: item.name.clone(),
        artists,
        album,
        art_url: item
            .covers
            .first()
            .map(|cover| cover.url.clone())
            .unwrap_or_default(),
        duration_ms: item.duration_ms,
        item_type: item_type.to_string(),
    }
}

pub async fn authenticate(config: &BackendConfig, oauth_port: u16) -> Result<()> {
    const OAUTH_SCOPES: &[&str] = &[
        "app-remote-control",
        "playlist-modify",
        "playlist-modify-private",
        "playlist-modify-public",
        "playlist-read",
        "playlist-read-collaborative",
        "playlist-read-private",
        "streaming",
        "ugc-image-upload",
        "user-follow-modify",
        "user-follow-read",
        "user-library-modify",
        "user-library-read",
        "user-modify",
        "user-modify-playback-state",
        "user-modify-private",
        "user-personalized",
        "user-read-birthdate",
        "user-read-currently-playing",
        "user-read-email",
        "user-read-play-history",
        "user-read-playback-position",
        "user-read-playback-state",
        "user-read-private",
        "user-read-recently-played",
        "user-top-read",
    ];

    let oauth_path = config.credentials_root.join("oauth");
    let cache = Cache::new(Some(oauth_path.as_path()), None, None, None)
        .context("failed to open the OAuth credential store")?;
    let session_config = SessionConfig::default();
    let client = librespot_oauth::OAuthClientBuilder::new(
        &session_config.client_id,
        &format!("http://127.0.0.1:{oauth_port}/login"),
        OAUTH_SCOPES.to_vec(),
    )
    .with_custom_message(
        "<h3 style=\"color: darkgreen\">Authentication successful. You can return to Omarchy Spotify.</h3>",
    )
    .open_in_browser()
    .build()
    .context("failed to create the Spotify OAuth client")?;

    let token = client
        .get_access_token_async()
        .await
        .context("Spotify authorization did not complete")?;
    let session = Session::new(session_config, Some(cache));
    session
        .connect(Credentials::with_access_token(token.access_token), true)
        .await
        .context("failed to save the Spotify playback session")?;
    println!("Playback authentication succeeded.");
    Ok(())
}

pub fn send_without_reply(commands: &EngineSender, command: Command) -> Result<(), ProtocolError> {
    match commands.try_send(EngineRequest {
        command,
        reply: None,
    }) {
        Ok(()) => Ok(()),
        Err(mpsc::error::TrySendError::Full(_)) => Err(ProtocolError::new(
            "engine_busy",
            "playback engine command queue is full",
        )),
        Err(mpsc::error::TrySendError::Closed(_)) => Err(ProtocolError::new(
            "engine_unavailable",
            "playback engine is unavailable",
        )),
    }
}

pub async fn send_with_reply(
    commands: &EngineSender,
    command: Command,
) -> Result<serde_json::Value, ProtocolError> {
    let (reply, receiver) = oneshot::channel();
    commands
        .send(EngineRequest {
            command,
            reply: Some(reply),
        })
        .await
        .map_err(|_| ProtocolError::new("engine_unavailable", "playback engine is unavailable"))?;
    receiver.await.map_err(|_| {
        ProtocolError::new(
            "engine_unavailable",
            "playback engine stopped before replying",
        )
    })?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::BackendState;

    fn test_uri() -> SpotifyUri {
        SpotifyUri::from_uri("spotify:track:14XWXWv5FoCbFzLksawpEe").unwrap()
    }

    fn test_track(uri: &str) -> Track {
        Track {
            uri: uri.to_string(),
            title: "Test track".to_string(),
            artists: vec!["Test artist".to_string()],
            album: "Test album".to_string(),
            art_url: String::new(),
            duration_ms: 240_000,
            item_type: "track".to_string(),
        }
    }

    #[test]
    fn loading_does_not_publish_a_false_stop_during_replacement() {
        let mut state = BackendState {
            playback: PlaybackStatus::Playing,
            position_ms: 42_000,
            ..BackendState::default()
        };
        apply_event(
            &mut state,
            PlayerEvent::Loading {
                play_request_id: 2,
                track_id: test_uri(),
                position_ms: 0,
            },
        );
        assert_eq!(state.playback, PlaybackStatus::Playing);
        assert_eq!(state.position_ms, 0);
    }

    #[test]
    fn stale_status_event_is_recognized_by_play_request() {
        let event = PlayerEvent::Paused {
            play_request_id: 4,
            track_id: test_uri(),
            position_ms: 1_000,
        };
        assert!(event_is_stale(Some(5), &event));
        assert!(!event_is_stale(Some(4), &event));
        assert!(!event_is_stale(None, &event));
    }

    #[test]
    fn repeated_position_events_do_not_publish_duplicate_state() {
        let mut state = BackendState {
            playback: PlaybackStatus::Playing,
            position_ms: 1_000,
            ..BackendState::default()
        };
        let changed = apply_event(
            &mut state,
            PlayerEvent::PositionChanged {
                play_request_id: 1,
                track_id: test_uri(),
                position_ms: 1_000,
            },
        );
        assert!(!changed);
    }

    #[test]
    fn explicit_seek_is_published_even_when_position_is_unchanged() {
        let mut state = BackendState {
            position_ms: 1_000,
            ..BackendState::default()
        };
        let changed = apply_event(
            &mut state,
            PlayerEvent::Seeked {
                play_request_id: 1,
                track_id: test_uri(),
                position_ms: 1_000,
            },
        );
        assert!(changed);
        assert_eq!(state.seek_sequence, 1);
    }

    #[test]
    fn queue_events_are_captured_for_reconnect_without_protocol_state() {
        let current = "spotify:track:14XWXWv5FoCbFzLksawpEe";
        let next = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b";
        let queue = recovery_queue_from_event(&PlayerEvent::SetQueue {
            context_uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M".to_string(),
            current_track: Some(QueueTrack {
                uri: current.to_string(),
                provider: CONTEXT_PROVIDER.to_string(),
            }),
            next_tracks: vec![QueueTrack {
                uri: next.to_string(),
                provider: QUEUE_PROVIDER.to_string(),
            }],
            prev_tracks: Vec::new(),
        })
        .unwrap();

        assert_eq!(queue.current_track.unwrap().uri, current);
        assert_eq!(queue.next_tracks[0].uri, next);
    }

    #[test]
    fn recovery_keeps_context_and_only_requeues_manual_tracks() {
        let current = "spotify:track:14XWXWv5FoCbFzLksawpEe";
        let queued = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b";
        let context_next = "spotify:track:3AJwUDP919kvQ9QcozQPxg";
        let context = "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M";
        let state = BackendState {
            playback: PlaybackStatus::Playing,
            track: Some(test_track(current)),
            position_ms: 42_000,
            volume: 32_000,
            repeat: RepeatMode::Context,
            ..BackendState::default()
        };
        let queue = RecoveryQueue {
            context_uri: context.to_string(),
            current_track: Some(QueueTrack {
                uri: current.to_string(),
                provider: CONTEXT_PROVIDER.to_string(),
            }),
            next_tracks: vec![
                QueueTrack {
                    uri: queued.to_string(),
                    provider: QUEUE_PROVIDER.to_string(),
                },
                QueueTrack {
                    uri: context_next.to_string(),
                    provider: CONTEXT_PROVIDER.to_string(),
                },
            ],
        };

        let snapshot = RecoverySnapshot::capture(&state, &queue).unwrap();
        assert_eq!(
            snapshot.load,
            RecoveryLoad::Context {
                uri: context.to_string(),
                current_uri: current.to_string(),
                queued_uris: vec![queued.to_string()],
            }
        );
        assert_eq!(snapshot.position_ms, 42_000);
        assert!(snapshot.play);
        assert_eq!(snapshot.volume, 32_000);
        assert_eq!(snapshot.repeat, RepeatMode::Context);
    }

    #[test]
    fn recovery_flattens_shuffled_queue_and_keeps_paused_state() {
        let current = "spotify:track:14XWXWv5FoCbFzLksawpEe";
        let first = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b";
        let second = "spotify:track:3AJwUDP919kvQ9QcozQPxg";
        let state = BackendState {
            playback: PlaybackStatus::Paused,
            track: Some(test_track(current)),
            position_ms: 17_000,
            shuffle: true,
            ..BackendState::default()
        };
        let queue = RecoveryQueue {
            context_uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M".to_string(),
            current_track: Some(QueueTrack {
                uri: current.to_string(),
                provider: CONTEXT_PROVIDER.to_string(),
            }),
            next_tracks: vec![
                QueueTrack {
                    uri: first.to_string(),
                    provider: QUEUE_PROVIDER.to_string(),
                },
                QueueTrack {
                    uri: second.to_string(),
                    provider: CONTEXT_PROVIDER.to_string(),
                },
            ],
        };

        let snapshot = RecoverySnapshot::capture(&state, &queue).unwrap();
        assert_eq!(
            snapshot.load,
            RecoveryLoad::Tracks(vec![
                current.to_string(),
                first.to_string(),
                second.to_string(),
            ])
        );
        assert!(!snapshot.play);
        assert!(snapshot.shuffle);
    }

    #[test]
    fn restore_applies_repeat_on_load_and_publishes_it_after_manual_queue() {
        for mode in [RepeatMode::Off, RepeatMode::Context, RepeatMode::Track] {
            let current = "spotify:track:14XWXWv5FoCbFzLksawpEe";
            let queued = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b";
            let snapshot = RecoverySnapshot {
                load: RecoveryLoad::Context {
                    uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M".into(),
                    current_uri: current.into(),
                    queued_uris: vec![queued.into()],
                },
                position_ms: 17_000,
                play: false,
                volume: 32_000,
                shuffle: false,
                repeat: mode,
            };
            let mut context_repeat = false;
            let mut track_repeat = false;
            let mut published_repeat = None;
            let mut manual_queue = Vec::new();
            let mut sequence = Vec::new();
            restore_playback_with(&snapshot, |command| {
                match command {
                    RecoveryCommand::Activate => sequence.push("activate"),
                    RecoveryCommand::Load(request) => {
                        sequence.push("load");
                        assert!(!request.start_playing);
                        assert_eq!(request.seek_to, 17_000);
                        let Some(LoadContextOptions::Options(options)) = &request.context_options
                        else {
                            panic!("repeat options must be applied in the load request");
                        };
                        assert!(!options.shuffle);
                        context_repeat = options.repeat;
                        track_repeat = options.repeat_track;
                        assert_eq!(context_repeat, mode == RepeatMode::Context);
                        assert_eq!(track_repeat, mode == RepeatMode::Track);
                    }
                    RecoveryCommand::AddToQueue(uri) => {
                        sequence.push("queue");
                        manual_queue.push(uri.to_uri());
                    }
                    RecoveryCommand::Volume(volume) => {
                        sequence.push("volume");
                        assert_eq!(volume, 32_000);
                    }
                    RecoveryCommand::Shuffle(enabled) => {
                        sequence.push("shuffle");
                        assert!(!enabled);
                    }
                    RecoveryCommand::RepeatTrack(enabled) => {
                        sequence.push("repeat-event");
                        assert_eq!(enabled, track_repeat);
                        published_repeat = Some((context_repeat, enabled));
                    }
                }
                Ok(())
            })
            .unwrap();
            assert_eq!(manual_queue, vec![queued]);
            assert_eq!(
                published_repeat,
                Some((mode == RepeatMode::Context, mode == RepeatMode::Track))
            );
            assert_eq!(
                sequence,
                vec![
                    "activate",
                    "load",
                    "queue",
                    "volume",
                    "shuffle",
                    "repeat-event"
                ]
            );
        }
    }

    #[test]
    fn recovery_ignores_a_stale_queue_and_caps_position() {
        let current = "spotify:track:14XWXWv5FoCbFzLksawpEe";
        let state = BackendState {
            playback: PlaybackStatus::Playing,
            track: Some(test_track(current)),
            position_ms: 300_000,
            ..BackendState::default()
        };
        let queue = RecoveryQueue {
            current_track: Some(QueueTrack {
                uri: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b".to_string(),
                provider: CONTEXT_PROVIDER.to_string(),
            }),
            next_tracks: vec![QueueTrack {
                uri: "spotify:track:3AJwUDP919kvQ9QcozQPxg".to_string(),
                provider: CONTEXT_PROVIDER.to_string(),
            }],
            ..RecoveryQueue::default()
        };

        let snapshot = RecoverySnapshot::capture(&state, &queue).unwrap();
        assert_eq!(
            snapshot.load,
            RecoveryLoad::Tracks(vec![current.to_string()])
        );
        assert_eq!(snapshot.position_ms, 239_999);
    }

    #[test]
    fn stopped_playback_is_not_recovered() {
        let state = BackendState {
            track: Some(test_track("spotify:track:14XWXWv5FoCbFzLksawpEe")),
            ..BackendState::default()
        };
        assert!(RecoverySnapshot::capture(&state, &RecoveryQueue::default()).is_none());
    }

    #[test]
    fn fire_and_forget_command_queue_is_bounded() {
        let (commands, _receiver) = mpsc::channel(1);
        assert!(send_without_reply(&commands, Command::Play).is_ok());
        let error = send_without_reply(&commands, Command::Pause).unwrap_err();
        assert_eq!(error.code, "engine_busy");
    }

    #[test]
    fn audio_key_rejection_is_distinct_and_clears_on_the_next_load() {
        let mut state = BackendState::default();
        assert!(apply_event(
            &mut state,
            PlayerEvent::AudioKeyUnavailable {
                play_request_id: 1,
                track_id: test_uri(),
            },
        ));
        assert_eq!(state.error_code, AUDIO_KEY_UNAVAILABLE_CODE);
        assert_eq!(state.error, AUDIO_KEY_UNAVAILABLE_MESSAGE);

        assert!(apply_event(
            &mut state,
            PlayerEvent::Loading {
                play_request_id: 2,
                track_id: test_uri(),
                position_ms: 0,
            },
        ));
        assert!(state.error_code.is_empty());
        assert!(state.error.is_empty());
    }

    #[test]
    fn reconnect_budget_expires_old_attempts_and_rejects_bursts() {
        let start = Instant::now();
        let mut attempts = VecDeque::new();

        for offset in 0..RECONNECT_LIMIT {
            assert!(record_reconnect(
                &mut attempts,
                start + Duration::from_secs(offset as u64)
            ));
        }
        assert!(!record_reconnect(
            &mut attempts,
            start + Duration::from_secs(RECONNECT_LIMIT as u64)
        ));
        assert!(record_reconnect(&mut attempts, start + RECONNECT_WINDOW));
    }
}
