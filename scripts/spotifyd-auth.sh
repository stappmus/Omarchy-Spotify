#!/bin/sh
set -eu

# Native login shares a reusable credential with library access and playback.
# Force a private creation mode even when omarchy-shell inherited umask 0022.
umask 077

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
backend="$HOME/.local/lib/omarchy-spotify/omarchy-spotify-backend"
if [ -x "$backend" ]; then
  exec "$backend" authenticate \
    --config-path "$config_root/omarchy-spotify/spotifyd.conf" \
    --oauth-port 8000
fi

exec /usr/bin/spotifyd authenticate \
  --config-path "$config_root/omarchy-spotify/spotifyd.conf" \
  --oauth-port 8000
