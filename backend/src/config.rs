use std::{env, fs, path::PathBuf};

use anyhow::{Context, Result, bail};
use librespot_playback::config::Bitrate;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Default)]
struct ConfigFile {
    #[serde(default)]
    global: GlobalConfig,
}

#[derive(Clone, Debug, Deserialize, Default)]
struct GlobalConfig {
    device_name: Option<String>,
    bitrate: Option<u16>,
    autoplay: Option<bool>,
    backend: Option<String>,
    device: Option<String>,
    no_audio_cache: Option<bool>,
    max_cache_size: Option<u64>,
    cache_path: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct BackendConfig {
    pub device_name: String,
    pub bitrate: Bitrate,
    pub bitrate_kbps: u16,
    pub autoplay: bool,
    pub audio_device: Option<String>,
    pub audio_cache: bool,
    pub max_cache_size: Option<u64>,
    pub cache_root: PathBuf,
    pub credentials_root: PathBuf,
}

#[derive(Clone, Debug, Serialize)]
pub struct ConfigSummary<'a> {
    pub device_name: &'a str,
    pub bitrate_kbps: u16,
    pub autoplay: bool,
    pub audio_cache: bool,
    pub max_cache_size: Option<u64>,
    pub cache_root: &'a std::path::Path,
    pub credentials_root: &'a std::path::Path,
}

impl BackendConfig {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("failed to read configuration at {}", path.display()))?;
        let parsed: ConfigFile = toml::from_str(&content)
            .with_context(|| format!("failed to parse configuration at {}", path.display()))?;
        let global = parsed.global;

        let device_name = global
            .device_name
            .unwrap_or_else(|| "Omarchy Spotify".to_string());
        let device_name = device_name.trim().to_string();
        if device_name.is_empty()
            || device_name.len() > 64
            || device_name.chars().any(char::is_control)
        {
            bail!("device_name must contain 1 to 64 printable characters");
        }

        let bitrate_kbps = global.bitrate.unwrap_or(320);
        let bitrate = match bitrate_kbps {
            96 => Bitrate::Bitrate96,
            160 => Bitrate::Bitrate160,
            320 => Bitrate::Bitrate320,
            value => bail!("unsupported bitrate {value}; expected 96, 160, or 320"),
        };

        let backend = global.backend.unwrap_or_else(|| "pulseaudio".to_string());
        if backend != "pulseaudio" {
            bail!("unsupported audio backend {backend:?}; expected \"pulseaudio\"");
        }

        let cache_root = global.cache_path.unwrap_or_else(default_cache_root);
        let credentials_root = default_credentials_root();

        Ok(Self {
            device_name,
            bitrate,
            bitrate_kbps,
            autoplay: global.autoplay.unwrap_or(true),
            audio_device: global.device.filter(|value| !value.trim().is_empty()),
            audio_cache: !global.no_audio_cache.unwrap_or(false),
            max_cache_size: global.max_cache_size.or(Some(1_000_000_000)),
            cache_root,
            credentials_root,
        })
    }

    pub fn summary(&self) -> ConfigSummary<'_> {
        ConfigSummary {
            device_name: &self.device_name,
            bitrate_kbps: self.bitrate_kbps,
            autoplay: self.autoplay,
            audio_cache: self.audio_cache,
            max_cache_size: self.max_cache_size,
            cache_root: &self.cache_root,
            credentials_root: &self.credentials_root,
        }
    }
}

pub fn default_config_path() -> PathBuf {
    config_home().join("omarchy-spotify/spotifyd.conf")
}

pub fn default_socket_path() -> PathBuf {
    let runtime = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc_getuid() })));
    runtime.join("omarchy-spotify/backend.sock")
}

fn config_home() -> PathBuf {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_else(|| PathBuf::from(".config"))
}

fn default_cache_root() -> PathBuf {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .unwrap_or_else(|| PathBuf::from(".cache"))
        .join("spotifyd")
}

fn default_credentials_root() -> PathBuf {
    env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| PathBuf::from(".local/state"))
        .join("omarchy-spotify")
}

#[cfg(unix)]
unsafe fn libc_getuid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}

#[cfg(not(unix))]
unsafe fn libc_getuid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn reads_existing_spotifyd_shape() {
        let dir = std::env::temp_dir().join(format!(
            "omarchy-spotify-config-test-{}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("spotifyd.conf");
        let mut file = fs::File::create(&path).unwrap();
        writeln!(
            file,
            "[global]\ndevice_name=\"Test Device\"\nbackend=\"pulseaudio\"\nbitrate=320\nautoplay=true\nno_audio_cache=false\nmax_cache_size=42"
        )
        .unwrap();

        let config = BackendConfig::load(&path).unwrap();
        assert_eq!(config.device_name, "Test Device");
        assert_eq!(config.bitrate_kbps, 320);
        assert!(config.audio_cache);
        assert_eq!(config.max_cache_size, Some(42));
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn reads_the_selected_output_sink() {
        let dir = std::env::temp_dir().join(format!(
            "omarchy-spotify-device-test-{}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("spotifyd.conf");
        let mut file = fs::File::create(&path).unwrap();
        writeln!(
            file,
            "[global]\ndevice_name=\"Test Device\"\nbackend=\"pulseaudio\"\ndevice=\"alsa_output.usb-Mini__Line2__sink\""
        )
        .unwrap();

        let config = BackendConfig::load(&path).unwrap();
        assert_eq!(
            config.audio_device.as_deref(),
            Some("alsa_output.usb-Mini__Line2__sink")
        );

        let mut file = fs::File::create(&path).unwrap();
        writeln!(
            file,
            "[global]\ndevice_name=\"Test Device\"\nbackend=\"pulseaudio\"\ndevice=\"   \""
        )
        .unwrap();
        assert_eq!(BackendConfig::load(&path).unwrap().audio_device, None);

        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}
