mod config;
mod engine;
mod mpris;
mod protocol;
mod socket;
mod state;

use std::{path::PathBuf, process::ExitCode};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use protocol::{BackendState, Lifecycle};
use tokio::sync::watch;

use crate::{config::BackendConfig, state::StateStore};

#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
    #[arg(long, global = true)]
    config_path: Option<PathBuf>,
    #[arg(long, global = true)]
    socket_path: Option<PathBuf>,
    /// Override the configured Connect device name (useful for parallel A/B testing).
    #[arg(long, global = true)]
    device_name: Option<String>,
    #[command(subcommand)]
    action: Option<Action>,
}

#[derive(Debug, Subcommand)]
enum Action {
    /// Validate configuration without connecting to Spotify.
    Check,
    /// Authorize local playback and store a private reusable credential.
    Authenticate {
        #[arg(long, default_value_t = 8000)]
        oauth_port: u16,
    },
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<ExitCode> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let cli = Cli::parse();
    let config_path = cli.config_path.unwrap_or_else(config::default_config_path);
    let mut config = BackendConfig::load(&config_path)?;
    if let Some(device_name) = cli.device_name {
        let device_name = device_name.trim();
        if device_name.is_empty()
            || device_name.len() > 64
            || device_name.chars().any(char::is_control)
        {
            anyhow::bail!("device name override must contain 1 to 64 printable characters");
        }
        config.device_name = device_name.to_string();
    }

    match cli.action {
        Some(Action::Check) => {
            println!("{}", serde_json::to_string(&config.summary())?);
            return Ok(ExitCode::SUCCESS);
        }
        Some(Action::Authenticate { oauth_port }) => {
            return authentication_result(engine::authenticate(&config, oauth_port).await);
        }
        None => {}
    }

    run(
        config,
        cli.socket_path.unwrap_or_else(config::default_socket_path),
    )
    .await
    .map(|()| ExitCode::SUCCESS)
}

async fn run(config: BackendConfig, socket_path: PathBuf) -> Result<()> {
    let state = StateStore::new(BackendState::default());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let mut runtime = match engine::start(config, state.clone()).await {
        Ok(runtime) => runtime,
        Err(error) => {
            state.update(|current| {
                current.lifecycle = Lifecycle::Error;
                current.error = error.to_string();
                true
            });
            return Err(error);
        }
    };

    let _socket_guard = socket::serve(
        socket_path,
        state.clone(),
        runtime.commands.clone(),
        shutdown_rx.clone(),
    )
    .await?;
    let mut mpris_task = tokio::spawn(mpris::serve(
        state.clone(),
        runtime.commands.clone(),
        shutdown_tx.clone(),
    ));

    let mut requested_shutdown = shutdown_rx.clone();
    tokio::select! {
        signal = tokio::signal::ctrl_c() => {
            signal.context("failed to wait for termination signal")?;
        }
        _ = requested_shutdown.changed() => {}
        result = runtime.wait_done() => {
            result.context("librespot engine stopped")?;
            anyhow::bail!("librespot engine stopped unexpectedly");
        }
        result = &mut mpris_task => {
            match result {
                Ok(Ok(())) => anyhow::bail!("MPRIS server ended unexpectedly"),
                Ok(Err(error)) => return Err(error).context("MPRIS server failed"),
                Err(error) => return Err(error).context("MPRIS task failed"),
            }
        }
    }

    let _ = shutdown_tx.send(true);
    runtime.shutdown();
    state.update(|current| {
        current.lifecycle = Lifecycle::Stopped;
        current.playback = crate::protocol::PlaybackStatus::Stopped;
        true
    });
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), mpris_task).await;
    Ok(())
}

// Keep this code aligned with Api.playbackAuthenticationError. Only classify
// the typed listener error, never arbitrary authentication output or URLs.
const OAUTH_PORT_IN_USE_EXIT: u8 = 21;

fn authentication_result(result: Result<()>) -> Result<ExitCode> {
    match result {
        Err(error) => match error.downcast_ref::<librespot_oauth::OAuthError>() {
            Some(librespot_oauth::OAuthError::AuthCodeListenerBind { addr, e })
                if e.kind() == std::io::ErrorKind::AddrInUse =>
            {
                eprintln!(
                    "Playback authorization port {} is already in use. Stop the application using it, then try again.",
                    addr.port()
                );
                Ok(ExitCode::from(OAUTH_PORT_IN_USE_EXIT))
            }
            _ => Err(error),
        },
        Ok(()) => Ok(ExitCode::SUCCESS),
    }
}

#[cfg(test)]
mod authentication_tests {
    use super::*;
    use std::{io, net::TcpListener};

    #[test]
    fn occupied_callback_port_has_a_distinct_exit_code_through_context() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let e = TcpListener::bind(addr).unwrap_err();
        let error =
            anyhow::Error::new(librespot_oauth::OAuthError::AuthCodeListenerBind { addr, e })
                .context("Spotify authorization did not complete");
        assert_eq!(
            authentication_result(Err(error)).unwrap(),
            ExitCode::from(21)
        );
    }

    #[test]
    fn other_bind_and_authentication_failures_are_not_port_conflicts() {
        let error = librespot_oauth::OAuthError::AuthCodeListenerBind {
            addr: "127.0.0.1:8000".parse().unwrap(),
            e: io::Error::from(io::ErrorKind::PermissionDenied),
        };
        assert!(authentication_result(Err(error.into())).is_err());
        assert!(authentication_result(Err(anyhow::anyhow!("authentication failed"))).is_err());
        assert_eq!(authentication_result(Ok(())).unwrap(), ExitCode::SUCCESS);
    }
}
