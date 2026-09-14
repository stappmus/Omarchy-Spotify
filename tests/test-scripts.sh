#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

# Release executables are published separately with exact-commit build
# provenance. The reviewed source snapshot must not contain an opaque ELF.
[[ ! -e $source_root/backend/dist/$(uname -m)/omarchy-spotify-backend ]]
[[ -f $source_root/.github/workflows/release-backend.yml ]]
backend_source_id=$($source_root/scripts/backend-source-id.sh)
[[ $backend_source_id =~ ^[0-9a-f]{64}$ ]]

# A release built from the manifest's version tag remains valid when main has
# moved ahead with UI-only commits. The attestation must stay bound to the
# tagged commit, while any committed backend change must force a source build.
release_source="$test_root/release-source"
release_runtime="$test_root/release-runtime"
release_target="$test_root/release-target"
release_mock_bin="$test_root/release-mock-bin"
release_fixture="$test_root/release-fixture"
release_gh_log="$test_root/release-gh.log"
release_cargo_log="$test_root/release-cargo.log"
mkdir -p "$release_source/scripts" "$release_mock_bin" "$release_fixture"
while IFS= read -r backend_file; do
  mkdir -p "$release_source/$(dirname -- "$backend_file")"
  cp -- "$source_root/$backend_file" "$release_source/$backend_file"
done < <(git -C "$source_root" ls-files backend)
cp -- "$source_root/scripts/build-backend.sh" \
  "$source_root/scripts/backend-source-id.sh" "$release_source/scripts/"
cp -- "$source_root/manifest.json" "$source_root/rust-toolchain.toml" \
  "$release_source/"
git -C "$release_source" init -q
git -C "$release_source" config user.name "Omarchy Spotify tests"
git -C "$release_source" config user.email "tests@example.invalid"
git -C "$release_source" add .
git -C "$release_source" commit -qm "Release source"
git -C "$release_source" tag -a v1.0.4 -m "Release v1.0.4"
release_commit=$(git -C "$release_source" rev-parse 'refs/tags/v1.0.4^{commit}')
printf '%s\n' 'UI-only change after the release' >"$release_source/Panel.qml"
git -C "$release_source" add Panel.qml
git -C "$release_source" commit -qm "Change only the UI"
[[ $(git -C "$release_source" rev-parse HEAD) != "$release_commit" ]]

release_asset_name="omarchy-spotify-backend-$(uname -m)"
release_asset="$release_fixture/$release_asset_name"
release_sums="$release_fixture/SHA256SUMS"
printf '%s\n' 'mock attested release' >"$release_asset"
release_hash=$(sha256sum -- "$release_asset")
printf '%s  %s\n' "${release_hash%% *}" "$release_asset_name" >"$release_sums"

printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'output=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    -o) output=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case $output in' \
  '  */SHA256SUMS) cp -- "${TEST_RELEASE_SUMS:?}" "$output" ;;' \
  '  *) cp -- "${TEST_RELEASE_ASSET:?}" "$output" ;;' \
  'esac' >"$release_mock_bin/curl"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_GH_LOG:?}"' \
  'digest=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case $1 in' \
  '    --source-digest) digest=$2; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[ "$digest" = "${TEST_EXPECTED_DIGEST:?}" ]' >"$release_mock_bin/gh"
printf '%s\n' \
  '#!/bin/sh' \
  'set -eu' \
  'printf "%s\n" "$*" >>"${TEST_CARGO_LOG:?}"' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock changed-source build" >"$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'exit 0' >"$release_mock_bin/cargo"
chmod 755 "$release_mock_bin/curl" "$release_mock_bin/gh" \
  "$release_mock_bin/cargo"
: >"$release_gh_log"
: >"$release_cargo_log"

PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
cmp -s -- "$release_asset" "$release_runtime/omarchy-spotify-backend"
[[ $(<"$release_runtime/backend-origin") == "attested-release:$release_commit" ]]
grep -q -- "--source-digest $release_commit" "$release_gh_log"
[[ ! -s $release_cargo_log ]]

printf '%s\n' '// committed backend change' >>"$release_source/backend/src/main.rs"
git -C "$release_source" add backend/src/main.rs
git -C "$release_source" commit -qm "Change backend after release"
: >"$release_gh_log"
: >"$release_cargo_log"
PATH="$release_mock_bin:$PATH" \
TEST_RELEASE_ASSET="$release_asset" \
TEST_RELEASE_SUMS="$release_sums" \
TEST_EXPECTED_DIGEST="$release_commit" \
TEST_GH_LOG="$release_gh_log" \
TEST_CARGO_LOG="$release_cargo_log" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$release_runtime" \
CARGO_TARGET_DIR="$release_target" \
  "$release_source/scripts/build-backend.sh" >/dev/null
[[ ! -s $release_gh_log ]]
grep -q -- '--locked --release' "$release_cargo_log"
grep -q '^source-build:' "$release_runtime/backend-origin"

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

# A third input line selects the PulseAudio sink librespot opens. An empty
# line restores the system default by dropping the key entirely.
printf '%s\n%s\n%s\n' "Desk speakers" 320 "alsa_output.usb-Mini__Line2__sink" |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device = "alsa_output.usb-Mini__Line2__sink"' "$test_root/config/omarchy-spotify/spotifyd.conf"
grep -qx 'device_name = "Desk speakers"' "$test_root/config/omarchy-spotify/spotifyd.conf"
[[ $(grep -c '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf") -eq 1 ]]

printf '%s\n%s\n%s\n' "Desk speakers" 320 "alsa_output.usb-Mini__Line3__sink" |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
grep -qx 'device = "alsa_output.usb-Mini__Line3__sink"' "$test_root/config/omarchy-spotify/spotifyd.conf"
[[ $(grep -c '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf") -eq 1 ]]

printf '%s\n%s\n\n' "Desk speakers" 320 |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
! grep -q '^device[[:space:]]*=' "$test_root/config/omarchy-spotify/spotifyd.conf"

set +e
printf '%s\n%s\n%s\n' "Desk speakers" 320 'invalid"sink' |
  XDG_CONFIG_HOME="$test_root/config" "$source_root/scripts/configure-spotifyd.sh"
invalid_device_status=$?
set -e
[[ $invalid_device_status -eq 3 ]]
! grep -q 'invalid' "$test_root/config/omarchy-spotify/spotifyd.conf"

# The sink list feeds the Settings picker: one tab-separated name and
# description per sink, and a non-zero exit when PulseAudio is unreachable.
sink_mock_bin="$test_root/sink-mock-bin"
mkdir -p "$sink_mock_bin"
cat >"$sink_mock_bin/pactl" <<'MOCK'
#!/usr/bin/env bash
[[ $* == "-f json list sinks" ]] || exit 64
cat <<'JSON'
[
  {"index": 60, "name": "alsa_output.usb-Mini__Line2__sink", "description": "GoXLR Mini Line 2"},
  {"index": 63, "name": "alsa_output.pci-0000_00_1f.3.analog-stereo", "description": "Built-in Audio"}
]
JSON
MOCK
chmod +x "$sink_mock_bin/pactl"
sink_output=$(PATH="$sink_mock_bin:$PATH" "$source_root/scripts/list-audio-sinks.sh")
[[ $sink_output == "alsa_output.usb-Mini__Line2__sink	GoXLR Mini Line 2
alsa_output.pci-0000_00_1f.3.analog-stereo	Built-in Audio" ]]

cat >"$sink_mock_bin/pactl" <<'MOCK'
#!/usr/bin/env bash
echo "Connection failure: Connection refused" >&2
exit 1
MOCK
chmod +x "$sink_mock_bin/pactl"
set +e
PATH="$sink_mock_bin:$PATH" "$source_root/scripts/list-audio-sinks.sh" >/dev/null 2>&1
sink_failure_status=$?
set -e
[[ $sink_failure_status -ne 0 ]]

# Exercise setup and removal entirely inside the temporary tree. The mock
# spotifyd/systemctl binaries prevent package, service, keyring, or user-config
# changes while still covering the scripts' real file permissions and paths.
mock_bin="$test_root/mock-bin"
runtime_config="$test_root/runtime-config"
runtime_cache="$test_root/runtime-cache"
runtime_state="$test_root/runtime-state"
runtime_session="$test_root/runtime-session"
runtime_backend="$test_root/runtime-lib/omarchy-spotify"
runtime_home="$test_root/runtime-home"
mock_target="$test_root/mock-target"
secret_log="$test_root/secret-tool.log"
systemctl_log="$test_root/systemctl.log"
omarchy_log="$test_root/omarchy.log"
mkdir -p "$mock_bin" "$runtime_config" "$runtime_cache" "$runtime_state" \
  "$runtime_session" "$runtime_backend" "$runtime_home"

printf '%s\n' '#!/bin/sh' 'exit 0' >"$mock_bin/spotifyd"
printf '%s\n' \
  '#!/bin/sh' \
  'mkdir -p "${CARGO_TARGET_DIR:?}/release"' \
  'printf "%s\n" "mock source-built backend" >"$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'chmod 755 "$CARGO_TARGET_DIR/release/omarchy-spotify-backend"' \
  'exit 0' >"$mock_bin/cargo"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ -n "${TEST_SYSTEMCTL_LOG:-}" ]; then printf "%s\n" "$*" >>"$TEST_SYSTEMCTL_LOG"; fi' \
  'if [ "${1:-}" = "--user" ]; then shift; fi' \
  'if [ "${1:-}" = "is-enabled" ]; then exit 1; fi' \
  'if [ "${1:-}" = "is-active" ]; then [ "${TEST_SERVICE_ACTIVE:-0}" = 1 ]; exit; fi' \
  'exit 0' >"$mock_bin/systemctl"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_SECRET_LOG:?}"' \
  'exit 1' >"$mock_bin/secret-tool"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"${TEST_OMARCHY_LOG:?}"' \
  'if [ "$*" = "plugin remove quickshell.spotify --yes" ]; then' \
  '  rm -f -- "$HOME/.config/omarchy/plugins/quickshell.spotify"' \
  'fi' \
  'exit 0' >"$mock_bin/omarchy"
chmod 755 "$mock_bin/cargo" "$mock_bin/spotifyd" "$mock_bin/systemctl" \
  "$mock_bin/secret-tool" "$mock_bin/omarchy"

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

# A clean source install records both the reviewed backend-source fingerprint
# and installed executable hash. The release path writes the same records only
# after its exact-commit attestation succeeds.
rm -f -- "$runtime_backend/omarchy-spotify-backend" \
  "$runtime_backend/backend-source.sha256" \
  "$runtime_backend/backend-binary.sha256" \
  "$runtime_backend/backend-origin"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
CARGO_TARGET_DIR="$mock_target" \
OMARCHY_SPOTIFY_BUILD_FROM_SOURCE=1 \
  "$source_root/scripts/setup.sh" >/dev/null
runtime_backend_unit="$runtime_config/systemd/user/omarchy-spotify.service"
[[ -x $runtime_backend/omarchy-spotify-backend && -f $runtime_backend_unit ]]
[[ $(<"$runtime_backend/backend-source.sha256") == "$backend_source_id" ]]
installed_hash=$(sha256sum -- "$runtime_backend/omarchy-spotify-backend")
[[ $(<"$runtime_backend/backend-binary.sha256") == "${installed_hash%% *}" ]]
[[ $(<"$runtime_backend/backend-origin") == "source-build:$backend_source_id" ]]
[[ $(stat -c '%a' "$runtime_backend/backend-source.sha256") == 600 ]]
[[ $(stat -c '%a' "$runtime_backend/backend-binary.sha256") == 600 ]]

# Existing installations must be checked against their recorded source and
# binary hashes. Re-run setup when the executable or static unit is stale, then
# restart an already-active backend so it immediately uses the replacement.
printf '%s\n' 'stale backend' >"$runtime_backend/omarchy-spotify-backend"
chmod 755 "$runtime_backend/omarchy-spotify-backend"
printf '%s\n' 'stale unit' >"$runtime_backend_unit"
selected_unit=$(PATH="$mock_bin:$PATH" \
  XDG_CONFIG_HOME="$runtime_config" \
  OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/playback-runtime.sh" unit)
[[ $selected_unit == omarchy-spotifyd.service ]]

: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
CARGO_TARGET_DIR="$mock_target" \
OMARCHY_SPOTIFY_BUILD_FROM_SOURCE=1 \
TEST_SERVICE_ACTIVE=1 \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/setup.sh" >/dev/null
installed_hash=$(sha256sum -- "$runtime_backend/omarchy-spotify-backend")
source_build_hash=$(sha256sum -- "$mock_target/release/omarchy-spotify-backend")
[[ ${installed_hash%% *} == "${source_build_hash%% *}" ]]
cmp -s -- "$source_root/systemd/omarchy-spotify.service" "$runtime_backend_unit"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
  "$source_root/scripts/playback-runtime.sh" check
grep -qx -- '--user restart omarchy-spotify.service' "$systemctl_log"

: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
TEST_SERVICE_ACTIVE=1 \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/setup.sh" >/dev/null
! grep -q -- '--user restart omarchy-spotify.service' "$systemctl_log"

mkdir -p "$runtime_config/omarchy-spotify" \
  "$runtime_config/omarchy-spotify.bak.20260827000000" \
  "$runtime_cache/spotifyd" "$runtime_cache/omarchy-spotify/target" \
  "$runtime_session/omarchy-spotify"
cp -- "$source_root/config/spotifyd.conf" "$runtime_config/omarchy-spotify/spotifyd.conf"
printf '%s\n' stale >"$runtime_config/omarchy-spotify.bak.20260827000000/spotifyd.conf"
printf '%s\n' stale >"$runtime_cache/omarchy-spotify/target/build-artifact"
printf '%s\n' stale >"$runtime_session/omarchy-spotify/backend.sock"
: >"$systemctl_log"
PATH="$mock_bin:$PATH" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
XDG_RUNTIME_DIR="$runtime_session" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
TEST_SECRET_LOG="$secret_log" \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null

[[ ! -e $runtime_config/omarchy-spotify && ! -e $runtime_cache/spotifyd ]]
[[ ! -e $runtime_config/omarchy-spotify.bak.20260827000000 ]]
[[ ! -e $runtime_cache/omarchy-spotify ]]
[[ ! -e $runtime_state/omarchy-spotify ]]
[[ ! -e $runtime_session/omarchy-spotify ]]
[[ ! -e $runtime_backend ]]
grep -qx -- '--user disable --now omarchy-spotify.service' "$systemctl_log"
grep -qx -- '--user disable --now omarchy-spotifyd.service' "$systemctl_log"
grep -q 'clear service quickshell-spotify kind refresh-token' "$secret_log"

set +e
PATH="$mock_bin:$PATH" \
XDG_CACHE_HOME="relative-cache" \
  "$source_root/scripts/remove-runtime.sh" --purge >/dev/null 2>&1
unsafe_remove_status=$?
set -e
[[ $unsafe_remove_status -eq 3 ]]

# The top-level uninstaller wraps the runtime purge, removes the plugin through
# Omarchy, clears exact-ID backups, restarts the shell, and remains idempotent.
plugin_dir="$runtime_home/.config/omarchy/plugins/quickshell.spotify"
plugin_backup="$runtime_home/.config/omarchy/plugins/.quickshell.spotify.bak.20260827000000"
mkdir -p "$(dirname -- "$plugin_dir")" "$plugin_backup" \
  "$runtime_config/omarchy-spotify" "$runtime_cache/spotifyd" \
  "$runtime_state/omarchy-spotify" "$runtime_session/omarchy-spotify" \
  "$runtime_backend"
ln -s -- "$source_root" "$plugin_dir"
printf '%s\n' stale >"$runtime_backend/omarchy-spotify-backend"
: >"$omarchy_log"
(
  cd "$test_root"
  PATH="$mock_bin:$PATH" \
  HOME="$runtime_home" \
  XDG_CONFIG_HOME="$runtime_config" \
  XDG_CACHE_HOME="$runtime_cache" \
  XDG_STATE_HOME="$runtime_state" \
  XDG_RUNTIME_DIR="$runtime_session" \
  OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
  TEST_SECRET_LOG="$secret_log" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_OMARCHY_LOG="$omarchy_log" \
    "$source_root/scripts/uninstall.sh" >/dev/null
)
[[ ! -e $plugin_dir && ! -L $plugin_dir && ! -e $plugin_backup ]]
[[ ! -e $runtime_config/omarchy-spotify && ! -e $runtime_cache/spotifyd ]]
[[ ! -e $runtime_state/omarchy-spotify && ! -e $runtime_session/omarchy-spotify ]]
[[ ! -e $runtime_backend ]]
grep -qx 'plugin disable quickshell.spotify' "$omarchy_log"
grep -qx 'plugin remove quickshell.spotify --yes' "$omarchy_log"
grep -qx 'restart shell' "$omarchy_log"

PATH="$mock_bin:$PATH" \
HOME="$runtime_home" \
XDG_CONFIG_HOME="$runtime_config" \
XDG_CACHE_HOME="$runtime_cache" \
XDG_STATE_HOME="$runtime_state" \
XDG_RUNTIME_DIR="$runtime_session" \
OMARCHY_SPOTIFY_RUNTIME_DIR="$runtime_backend" \
TEST_SECRET_LOG="$secret_log" \
TEST_SYSTEMCTL_LOG="$systemctl_log" \
TEST_OMARCHY_LOG="$omarchy_log" \
  "$source_root/scripts/uninstall.sh" >/dev/null
[[ $(grep -c '^plugin remove quickshell.spotify --yes$' "$omarchy_log") -eq 1 ]]

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
[[ -x $source_root/scripts/backend-source-id.sh ]]
[[ -x $source_root/scripts/uninstall.sh ]]
grep -q 'remove-runtime.sh.*--purge' "$source_root/scripts/uninstall.sh"
grep -q 'omarchy plugin remove quickshell.spotify --yes' "$source_root/scripts/uninstall.sh"
grep -q '^## Remove it completely$' "$source_root/README.md"
grep -q 'pkexec /usr/bin/pacman -S --needed --noconfirm spotifyd' \
  "$source_root/scripts/setup-playback.sh"
! grep -q 'sudo' "$source_root/scripts/setup-playback.sh"
grep -q 'exec /usr/bin/spotifyd authenticate' \
  "$source_root/scripts/spotifyd-auth.sh"
grep -q 'omarchy-spotify-backend' "$source_root/scripts/spotifyd-auth.sh"
grep -q -- '--config-path "$config_root/omarchy-spotify/spotifyd.conf"' \
  "$source_root/scripts/spotifyd-auth.sh"
grep -q -- '--oauth-port 8000' "$source_root/scripts/spotifyd-auth.sh"
# OAuth identity stays immutable by default: the shipped client ID is the
# fallback, and only a user-supplied, strictly 32-hex client ID can override
# it — never an arbitrary string from a writable surface. The keyring and OAuth
# redirect stay scoped to that resolved ID. The streaming-only Connect ID stays
# internal (not in the manifest).
grep -q 'property string clientId: "d420a117a32841c2b3474932e49fb54b"' \
  "$source_root/AuthManager.qml"
grep -q 'readonly property string redirectUri: "http://127.0.0.1:"' \
  "$source_root/AuthManager.qml"
grep -q 'resolvedClientId' "$source_root/AuthManager.qml"
grep -q 'customClientId' "$source_root/AuthManager.qml"
grep -qF '[0-9a-f]{32}' "$source_root/AuthManager.qml"
grep -q '"clientId"' "$source_root/manifest.json"
grep -q 'customClientId: settings.clientId' "$source_root/Service.qml"
! grep -q '"oauthPort"' "$source_root/manifest.json"
grep -q 'window.close()' "$source_root/OAuth.js"
grep -q 'gh attestation verify' "$source_root/scripts/build-backend.sh"
grep -q -- '--cert-identity' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-ref' "$source_root/scripts/build-backend.sh"
grep -q -- '--source-digest' "$source_root/scripts/build-backend.sh"
grep -q -- '--deny-self-hosted-runners' "$source_root/scripts/build-backend.sh"
! grep -q 'ALLOW_UNVERIFIED' "$source_root/scripts/build-backend.sh"
if grep -E '^[[:space:]]*uses:' \
    "$source_root/.github/workflows/release-backend.yml" \
    | grep -Ev '@[0-9a-f]{40}([[:space:]]+#.*)?$'; then
  echo "release-backend.yml contains a mutable action reference" >&2
  exit 1
fi
jq -e '.version == "1.0.4"
  and .barWidget.defaultSection == "left"
  and .barWidget.defaults.showMiniPlayer == "On"
  and (.barWidget.schema[] | select(.key == "showMiniPlayer").defaultValue) == "On"
  and .barWidget.defaults.showPausedTrack == "On"
  and (.barWidget.schema[] | select(.key == "showPausedTrack").defaultValue) == "On"
  and .barWidget.defaults.showVinylRecord == "Off"
  and (.barWidget.schema[] | select(.key == "showVinylRecord").defaultValue) == "Off"
  and .barWidget.defaults.shortcutHints == "On"
  and (.barWidget.schema[] | select(.key == "shortcutHints").defaultValue) == "On"
  and .barWidget.defaults.showLyrics == "On"
  and (.barWidget.schema[] | select(.key == "showLyrics").defaultValue) == "On"
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
