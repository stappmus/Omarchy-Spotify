#!/usr/bin/env bash
set -euo pipefail

config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_file="$config_root/omarchy-spotify/spotifyd.conf"

IFS= read -r device_name
bitrate=""
bitrate_specified=0
if IFS= read -r bitrate; then
  bitrate_specified=1
fi
device=""
IFS= read -r device || true

if [[ -z $device_name || ${#device_name} -gt 64 || $device_name == *'"'* || $device_name == *'\'* ]]; then
  exit 3
fi
if [[ $device_name =~ [^[:print:]] ]]; then
  exit 3
fi
if (( bitrate_specified )) && [[ $bitrate != 96 && $bitrate != 160 && $bitrate != 320 ]]; then
  exit 3
fi
if [[ ${#device} -gt 128 || $device == *'"'* || $device == *'\'* ]]; then
  exit 3
fi
if [[ -n $device && $device =~ [^[:print:]] ]]; then
  exit 3
fi
if [[ ! -f $config_file ]]; then
  exit 4
fi

temporary=$(mktemp "${config_file}.tmp.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
chmod 600 "$temporary"

awk -v name="$device_name" -v rate="$bitrate" -v rate_set="$bitrate_specified" -v device="$device" '
  /^device_name[[:space:]]*=/ {
    print "device_name = \"" name "\""
    found_name = 1
    next
  }
  /^bitrate[[:space:]]*=/ {
    if (rate_set) print "bitrate = " rate
    else print
    found_rate = 1
    next
  }
  /^device[[:space:]]*=/ {
    if (!found_device && device != "") print "device = \"" device "\""
    found_device = 1
    next
  }
  /^autoplay[[:space:]]*=/ {
    print "autoplay = true"
    found_autoplay = 1
    next
  }
  { print }
  END {
    if (!found_name) print "device_name = \"" name "\""
    if (!found_rate && rate_set) print "bitrate = " rate
    if (!found_device && device != "") print "device = \"" device "\""
    if (!found_autoplay) print "autoplay = true"
  }
' "$config_file" >"$temporary"

mv -f -- "$temporary" "$config_file"
trap - EXIT
