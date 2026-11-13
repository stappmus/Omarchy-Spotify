#!/usr/bin/env bash
set -euo pipefail
source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
cp "$source_root/"{AuthManager.qml,Api.js,OAuth.js} "$test_root/"
sed 's|import "../.." as Plugin|import "." as Plugin|' \
  "$source_root/tests/integration/AuthIdentity.qml" > "$test_root/shell.qml"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 15s \
  qs --no-color -p "$test_root" > "$test_root/output" 2>&1 || {
  cat "$test_root/output"
  exit 1
}
rg -q AUTH_IDENTITY_PASS "$test_root/output" || {
  cat "$test_root/output"
  exit 1
}
echo 'Quickshell authorization integration passed.'

mkdir -p "$test_root/bin"
printf '#!/bin/sh\nexit 1\n' > "$test_root/bin/secret-tool"
chmod +x "$test_root/bin/secret-tool"
sed 's|import "../.." as Plugin|import "." as Plugin|' \
  "$source_root/tests/integration/AuthStartup.qml" > "$test_root/shell.qml"
env -u WAYLAND_DISPLAY PATH="$test_root/bin:$PATH" QT_QPA_PLATFORM=offscreen timeout 15s \
  qs --no-color -p "$test_root" > "$test_root/startup-output" 2>&1 || {
  cat "$test_root/startup-output"
  exit 1
}
rg -q AUTH_STARTUP_PASS "$test_root/startup-output" || {
  cat "$test_root/startup-output"
  exit 1
}
echo 'Quickshell startup identity integration passed.'

mkdir -p "$test_root/scripts"
cp "$source_root/NativeSession.qml" "$test_root/"
cp "$source_root/tests/fixtures/native-session.py" "$test_root/scripts/native-session.sh"
chmod +x "$test_root/scripts/native-session.sh"
cp "$source_root/tests/integration/NativeSession.qml" "$test_root/shell.qml"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 10s \
  qs --no-color -p "$test_root" > "$test_root/native-output" 2>&1 || {
  cat "$test_root/native-output"
  exit 1
}
rg -q NATIVE_SESSION_PASS "$test_root/native-output" || {
  cat "$test_root/native-output"
  exit 1
}
echo 'Quickshell native login, cancellation and logout integration passed.'

cp "$source_root/SpotifyConnectManager.qml" "$test_root/"
printf '#!/usr/bin/env python3\nimport sys, time\nfor _ in range(3): sys.stdin.readline()\ntime.sleep(0.02)\n' > "$test_root/scripts/spotify-connect-device.py"
chmod +x "$test_root/scripts/spotify-connect-device.py"
cp "$source_root/tests/integration/ConnectControls.qml" "$test_root/shell.qml"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 10s \
  qs --no-color -p "$test_root" > "$test_root/controls-output" 2>&1 || {
  cat "$test_root/controls-output"
  exit 1
}
rg -q CONNECT_CONTROLS_PASS "$test_root/controls-output" || {
  cat "$test_root/controls-output"
  exit 1
}
echo 'Quickshell asynchronous speaker control integration passed.'

mkdir -p "$test_root/app/plugin" "$test_root/state"
cp "$source_root/"*.qml "$source_root/"*.js "$test_root/app/plugin/"
cp -r /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui "$test_root/app/"
cp "$source_root/tests/integration/AppSmoke.qml" "$test_root/app/shell.qml"
if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
  # Service/authentication tests still use real Quickshell without a compositor.
  sed -i '/Plugin.Panel {/d; /Plugin.BarWidget {/d; /panel.primaryNavigationItems()/,+1d' "$test_root/app/shell.qml"
  app_platform=offscreen
else
  app_platform=wayland
fi
env QT_QPA_PLATFORM="$app_platform" QT_QPA_PLATFORMTHEME=generic NO_AT_BRIDGE=1 XDG_STATE_HOME="$test_root/state" \
  timeout 15s dbus-run-session -- qs --no-color -p "$test_root/app" > "$test_root/app-output" 2>&1 || {
  cat "$test_root/app-output"
  exit 1
}
rg -q APP_SMOKE_PASS "$test_root/app-output" || {
  cat "$test_root/app-output"
  exit 1
}
if rg -i 'ReferenceError|TypeError|binding loop|Cannot assign|Unable to assign|Failed to load configuration' "$test_root/app-output"; then
  exit 1
fi
echo 'Quickshell app smoke test passed.'
