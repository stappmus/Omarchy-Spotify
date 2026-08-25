#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Plugin releases must carry the backend because Omarchy does not run install
# hooks while cloning a plugin and end users should not need a Rust toolchain.
release_arch=$(uname -m)
release_backend="$source_root/backend/dist/$release_arch/omarchy-spotify-backend"
[[ -x $release_backend ]]

pkce_output=$("$source_root/scripts/pkce.sh")
IFS=$'\t' read -r verifier challenge state <<<"$pkce_output"

[[ $verifier =~ ^[A-Za-z0-9._~-]{43,128}$ ]]
[[ $challenge =~ ^[A-Za-z0-9_-]{43,128}$ ]]
[[ $state =~ ^[A-Fa-f0-9]{32,128}$ ]]

expected_challenge=$(printf '%s' "$verifier" |
  openssl dgst -sha256 -binary |
  openssl base64 -A |
  tr '+/' '-_' |
  tr -d '=')
[[ $challenge == "$expected_challenge" ]]

mkdir -p "$test_root/config/omarchy-spotify"
cp -- "$source_root/config/spotifyd.conf" "$test_root/config/omarchy-spotify/spotifyd.conf"
printf '%s\n' 'device = "legacy_output"' >>"$test_root/config/omarchy-spotify/spotifyd.conf"
printf '%s\n%s\n' "Desk speakers" 320 |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device_name = "Desk speakers"' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'bitrate = 320' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'no_audio_cache = false' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'max_cache_size = 1000000000' "$test_root/config/omarchy-spotify/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'autoplay = true' "$test_root/config/omarchy-spotify/spotifyd.conf"

printf '%s\n' "Renamed speakers" |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device_name = "Renamed speakers"' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'bitrate = 320' "$test_root/config/omarchy-spotify/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf"

printf '%s\n%s\n\n' "Desk speakers" 96 |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'bitrate = 96' "$test_root/config/omarchy-spotify/spotifyd.conf"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf"

set +e
printf '%s\n' 'invalid"name' |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
invalid_status=$?
set -e
[[ $invalid_status -eq 3 ]]

# Exercise setup and removal entirely inside the temporary tree. The mock
# spotifyd/systemctl binaries prevent package, service, keyring, or user-config
# changes while still covering the scripts' real file permissions and paths.
mock_bin="$test_root/mock-bin"
runtime_config="$test_root/runtime-config"
runtime_cache="$test_root/runtime-cache"
runtime_state="$test_root/runtime-state"
runtime_backend="$test_root/runtime-backend"
secret_log="$test_root/secret-tool.log"
mkdir -p "$mock_bin" "$runtime_config" "$runtime_cache" "$runtime_state" "$runtime_backend"

printf '%s\n' '#!/bin/sh' 'exit 0' >"$mock_bin/spotifyd"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--user" ]; then shift; fi' \
  'if [ "${1:-}" = "is-enabled" ]; then exit 1; fi' \
  'exit 0' >"$mock_bin/systemctl"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_SECRET_LOG:?}"' \
  'exit 1' >"$mock_bin/secret-tool"
chmod 755 "$mock_bin/spotifyd" "$mock_bin/systemctl" "$mock_bin/secret-tool"

[[ -x $source_root/scripts/spotify-connect-device.py ]]
"$source_root/scripts/spotify-connect-device.py" self-test |
  jq -e '.status == "ok"' >/dev/null

PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1 \
  "$source_root/scripts/setup.sh" --device-name "Test speakers" >/dev/null

runtime_spotify_config="$runtime_config/omarchy-spotify/spotifyd.conf"
runtime_unit="$runtime_config/systemd/user/omarchy-spotifyd.service"
[[ -f $runtime_spotify_config && -f $runtime_unit ]]
[[ $(stat -c '%a' "$runtime_spotify_config") == 600 ]]
[[ $(stat -c '%a' "$runtime_unit") == 644 ]]
grep -qx 'device_name = "Test speakers"' "$runtime_spotify_config"
grep -qx 'no_audio_cache = false' "$runtime_spotify_config"
grep -qx 'max_cache_size = 1000000000' "$runtime_spotify_config"
grep -qx 'Environment=PULSE_LATENCY_MSEC=30' "$runtime_unit"

PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/remove-runtime.sh" >/dev/null

[[ ! -e $runtime_unit && ! -e $runtime_config/omarchy-spotify ]]
find "$runtime_config" -maxdepth 1 -type d -name 'omarchy-spotify.bak.*' \
  | grep -q .

# The in-app first-run wrapper must complete the unprivileged setup directly
# when spotifyd is already present.
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
OMARCHY_SPOTIFY_SKIP_BACKEND_BUILD=1 \
  "$source_root/scripts/setup-playback.sh" >/dev/null
[[ -f $runtime_spotify_config && -f $runtime_unit ]]
grep -qx 'device_name = "Omarchy Spotify"' "$runtime_spotify_config"

# A clean release install must prefer the bundled backend without Cargo or
# package installation. This is the path used after an enabled plugin loads.
rm -f -- "$runtime_backend/omarchy-spotify-backend"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/setup.sh" >/dev/null
runtime_backend_unit="$runtime_config/systemd/user/omarchy-spotify.service"
[[ -x $runtime_backend/omarchy-spotify-backend && -f $runtime_backend_unit ]]

mkdir -p "$runtime_config/omarchy-spotify" "$runtime_cache/spotifyd"
cp -- "$source_root/config/spotifyd.conf" "$runtime_config/omarchy-spotify/spotifyd.conf"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
TEST_SECRET_LOG="$secret_log" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null

[[ ! -e $runtime_config/omarchy-spotify && ! -e $runtime_cache/spotifyd ]]
[[ ! -e $runtime_state/omarchy-spotify ]]
grep -q 'clear service quickshell-spotify kind refresh-token' "$secret_log"

mkdir -p "$runtime_state/omarchy-spotify/oauth" "$runtime_cache/spotifyd/oauth"
printf '%s\n' '{"mock":"credential"}' \
  >"$runtime_state/omarchy-spotify/oauth/credentials.json"
printf '%s\n' '{"mock":"legacy-credential"}' \
  >"$runtime_cache/spotifyd/oauth/credentials.json"
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
  "$source_root/scripts/playback-runtime.sh" credentials
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
  "$source_root/scripts/spotifyd-logout.sh"
[[ ! -e $runtime_state/omarchy-spotify/oauth/credentials.json ]]
[[ ! -e $runtime_cache/spotifyd/oauth/credentials.json ]]
if XDG_CACHE_HOME="$runtime_cache" XDG_STATE_HOME="$runtime_state" \
    "$source_root/scripts/playback-runtime.sh" credentials; then
  echo "playback-runtime.sh reported removed credentials" >&2
  exit 1
fi

set +e
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="relative-cache" \
  "$source_root/scripts/spotifyd-logout.sh" >/dev/null 2>&1
unsafe_logout_status=$?
set -e
[[ $unsafe_logout_status -eq 3 ]]

handoff_hypr_log="$test_root/handoff-hypr.log"
handoff_shell_log="$test_root/handoff-shell.log"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "clients" ]; then printf "%s\n" "${TEST_CLIENTS_JSON:?}"; exit 0; fi' \
  'printf "%s\n" "$*" >>"${TEST_HYPR_LOG:?}"' \
  'exit 0' >"$mock_bin/hyprctl"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_SHELL_LOG:?}"' \
  'exit 0' >"$mock_bin/omarchy-shell"
chmod 755 "$mock_bin/hyprctl" "$mock_bin/omarchy-shell"

TEST_CLIENTS_JSON='[{"address":"0xabc","class":"chromium","title":"127.0.0.1:8000/login?code=mock - Chromium"},{"address":"0xdef","class":"org.quickshell","title":"Omarchy Spotify"}]' \
TEST_HYPR_LOG="$handoff_hypr_log" \
TEST_SHELL_LOG="$handoff_shell_log" \
PATH="$mock_bin:$PATH" \
  "$source_root/scripts/return-from-auth.sh"
grep -q 'send_shortcut.*address:0xabc' "$handoff_hypr_log"
grep -q 'focus.*address:0xdef' "$handoff_hypr_log"
grep -q 'shell summon quickshell.spotify' "$handoff_shell_log"

printf '' >"$handoff_hypr_log"
TEST_CLIENTS_JSON='[{"address":"0xabc","class":"chromium","title":"Unrelated tab - Chromium"},{"address":"0xdef","class":"org.quickshell","title":"Omarchy Spotify"}]' \
TEST_HYPR_LOG="$handoff_hypr_log" \
TEST_SHELL_LOG="$handoff_shell_log" \
PATH="$mock_bin:$PATH" \
  "$source_root/scripts/return-from-auth.sh"
! grep -q 'send_shortcut' "$handoff_hypr_log"

grep -qx 'umask 077' "$source_root/scripts/spotifyd-auth.sh"
[[ -x $source_root/scripts/setup-playback.sh ]]
grep -q 'pkexec /usr/bin/pacman -S --needed --noconfirm spotifyd' \
  "$source_root/scripts/setup-playback.sh"
! grep -q 'sudo' "$source_root/scripts/setup-playback.sh"
grep -q 'exec /usr/bin/spotifyd authenticate' \
  "$source_root/scripts/spotifyd-auth.sh"
grep -q 'omarchy-spotify-backend' "$source_root/scripts/spotifyd-auth.sh"
grep -q -- '--config-path "$config_root/omarchy-spotify/spotifyd.conf"' \
  "$source_root/scripts/spotifyd-auth.sh"
grep -q -- '--oauth-port 8000' "$source_root/scripts/spotifyd-auth.sh"
grep -q 'property string clientId: "d420a117a32841c2b3474932e49fb54b"' \
  "$source_root/AuthManager.qml"
grep -q 'readonly property string redirectUri: "http://127.0.0.1:"' \
  "$source_root/AuthManager.qml"
! grep -q '"clientId"' "$source_root/manifest.json"
! grep -q '"oauthPort"' "$source_root/manifest.json"
grep -q 'window.close()' "$source_root/OAuth.js"
jq -e '.version == "1.0.2"
  and .barWidget.defaultSection == "left"
  and .barWidget.defaults.showMiniPlayer == "On"
  and (.barWidget.schema[] | select(.key == "showMiniPlayer").defaultValue) == "On"
  and .barWidget.defaults.showVinylRecord == "Off"
  and (.barWidget.schema[] | select(.key == "showVinylRecord").defaultValue) == "Off"
  and .barWidget.defaults.shortcutHints == "On"
  and (.barWidget.schema[] | select(.key == "shortcutHints").defaultValue) == "On"
  and .barWidget.defaults.maxBarTextWidth == "240"
  and (.barWidget.schema[] | select(.key == "maxBarTextWidth").defaultValue) == "240"
  and .barWidget.defaults.audioQuality == "320 kbps"
  and (.barWidget.schema[] | select(.key == "audioQuality").defaultValue) == "320 kbps"' \
  "$source_root/manifest.json" >/dev/null
grep -qx 'section=left' "$source_root/scripts/install-local.sh"
grep -qx 'bitrate = 320' "$source_root/config/spotifyd.conf"
grep -qx 'no_audio_cache = false' "$source_root/config/spotifyd.conf"
grep -qx 'max_cache_size = 1000000000' "$source_root/config/spotifyd.conf"
grep -qx 'Conflicts=omarchy-spotifyd.service' \
  "$source_root/systemd/omarchy-spotify.service"
grep -qx 'Environment=PULSE_LATENCY_MSEC=30' \
  "$source_root/systemd/omarchy-spotify.service"
grep -qx 'Environment=TOKIO_WORKER_THREADS=2' \
  "$source_root/systemd/omarchy-spotify.service"

echo "Script tests passed."
