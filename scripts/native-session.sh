#!/bin/sh
set -eu
umask 077
runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
export RUST_LOG=error
exec "$runtime_dir/omarchy-spotify-backend" session --config-path "$config_root/omarchy-spotify/spotifyd.conf"
