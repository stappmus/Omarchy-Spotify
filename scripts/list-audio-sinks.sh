#!/usr/bin/env bash
set -euo pipefail

# One tab-separated sink name and description per line, for the Settings
# output picker. The name is what librespot opens; the description is shown.
pactl -f json list sinks | jq -r '.[] | [.name, .description] | @tsv'
