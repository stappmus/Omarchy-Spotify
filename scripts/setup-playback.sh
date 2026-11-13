#!/usr/bin/env bash
set -euo pipefail
source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Account access and playback are one backend. A playback-only fallback cannot
# satisfy first-run sign-in, so surface an install failure instead of looping.
exec "$source_root/scripts/setup.sh" --require-native
