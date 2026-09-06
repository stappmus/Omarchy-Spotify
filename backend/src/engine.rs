use std::{
    collections::VecDeque,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
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
    player::{Player, PlayerEvent},
};
use sha1::{Digest, Sha1};
use tokio::sync::{mpsc, oneshot, watch};

use crate::{
    config::BackendConfig,
    protocol::{Command, Lifecycle, PlaybackStatus, ProtocolError, RepeatMode, Track},
    state::StateStore,
};

const INITIAL_VOLUME: u16 = ((u16::MAX as u32 * 90) / 100) as u16;
const ENGINE_QUEUE_CAPACITY: usize = 64;
const RECONNECT_LIMIT: usize = 5;
const RECONNECT_WINDOW: Duration = Duration::from_secs(10 * 60);
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
    tokio::spawn(run_commands(
        command_rx,
        current_spirc_rx,
        Arc::clone(&player),
    ));
    tokio::spawn(run_events(events, state.clone()));

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
        current_spirc.send_replace(Some(Arc::clone(&spirc)));
        state.update(|current| {
            current.lifecycle = Lifecycle::Ready;
            current.error_code.clear();
            current.error.clear();
            true
        });
        log::info!("reconnected the librespot session");
    }
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
    dispatch_local_command(command, |command| {
        execute_spirc_command(spirc, player, command)
    })
}

fn dispatch_local_command(
    command: Command,
    mut send: impl FnMut(Command) -> Result<()>,
) -> Result<()> {
    // Socket and MPRIS controls share this FIFO. Enqueue ownership and the
    // transport action together, so a delayed activation cannot overtake Pause.
    if matches!(
        &command,
        Command::Play | Command::Toggle | Command::Next | Command::Previous
    ) {
        send(Command::Activate)?;
    }
    send(command)
}

fn execute_spirc_command(spirc: &Spirc, player: &Player, command: Command) -> Result<()> {
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
        state.update(|current| apply_event(current, event));
    }
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

#[cfg(test)]
mod local_control_tests {
    use super::*;

    // Models dispatch to a receiver with retained playback. A stopped Spirc
    // without a loaded context still needs separate queue restoration.
    #[derive(Default)]
    struct Receiver {
        active: bool,
        playing: bool,
        index: i32,
        commands: Vec<Command>,
    }

    impl Receiver {
        fn send(&mut self, command: Command) -> Result<()> {
            self.commands.push(command.clone());
            match command {
                Command::Activate => self.active = true,
                Command::Play if self.active => self.playing = true,
                Command::Pause if self.active => self.playing = false,
                Command::Toggle if self.active => self.playing = !self.playing,
                Command::Next if self.active => self.index += 1,
                Command::Previous if self.active => self.index -= 1,
                _ => {}
            }
            Ok(())
        }

        fn dispatch(&mut self, command: Command) {
            dispatch_local_command(command, |command| self.send(command)).unwrap();
        }
    }

    #[test]
    fn play_then_pause_cannot_be_reordered_by_activation() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Play);
        receiver.dispatch(Command::Pause);
        assert!(receiver.active);
        assert!(!receiver.playing);
        assert_eq!(
            receiver.commands,
            vec![Command::Activate, Command::Play, Command::Pause]
        );
    }

    #[test]
    fn repeated_skips_and_previous_keep_every_action_in_order() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Next);
        receiver.dispatch(Command::Next);
        assert_eq!(receiver.index, 2);
        receiver.dispatch(Command::Previous);
        assert_eq!(receiver.index, 1);
        assert_eq!(
            receiver.commands,
            vec![
                Command::Activate,
                Command::Next,
                Command::Activate,
                Command::Next,
                Command::Activate,
                Command::Previous,
            ]
        );
    }

    #[test]
    fn toggle_acquires_ownership_before_toggling_retained_playback() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Toggle);
        assert!(receiver.active);
        assert!(receiver.playing);
        receiver.dispatch(Command::Toggle);
        assert!(!receiver.playing);
    }

    #[test]
    fn play_is_idempotent_for_active_playback() {
        let mut receiver = Receiver {
            active: true,
            playing: true,
            ..Receiver::default()
        };
        receiver.dispatch(Command::Play);
        assert!(receiver.playing);
    }

    #[test]
    fn pause_and_other_nontransport_commands_do_not_take_ownership() {
        let mut receiver = Receiver::default();
        let commands = vec![
            Command::Pause,
            Command::Stop,
            Command::Seek { position_ms: 1000 },
            Command::SetVolume { volume: 100 },
            Command::SetShuffle { enabled: true },
            Command::SetRepeat {
                mode: RepeatMode::Track,
            },
        ];
        for command in &commands {
            receiver.dispatch(command.clone());
        }
        assert!(!receiver.active);
        assert_eq!(receiver.commands, commands);
    }

    #[test]
    fn failed_activation_does_not_dispatch_transport_action() {
        let mut commands = Vec::new();
        let result = dispatch_local_command(Command::Next, |command| {
            commands.push(command);
            bail!("receiver closed")
        });
        assert!(result.is_err());
        assert_eq!(commands, vec![Command::Activate]);
    }

    #[test]
    fn transport_error_is_returned_after_successful_activation() {
        let mut commands = Vec::new();
        let result = dispatch_local_command(Command::Play, |command| {
            commands.push(command.clone());
            if command == Command::Play {
                bail!("receiver closed");
            }
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(commands, vec![Command::Activate, Command::Play]);
    }
}
