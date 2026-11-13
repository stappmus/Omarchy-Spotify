#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$source_root/backend/Cargo.toml"
runtime_dir=${OMARCHY_SPOTIFY_RUNTIME_DIR:-"$HOME/.local/lib/omarchy-spotify"}
destination="$runtime_dir/omarchy-spotify-backend"
source_id_file="$runtime_dir/backend-source.sha256"
binary_hash_file="$runtime_dir/backend-binary.sha256"
origin_file="$runtime_dir/backend-origin"
architecture=$(uname -m)
repository=stappmus/Omarchy-Spotify
workflow_identity="https://github.com/$repository/.github/workflows/release-backend.yml"

# Build outside the plugin directory: Omarchy hot-reloads a plugin whenever any
# file inside it changes, so an in-place backend/target/ makes its recursive
# watcher unload and reload the plugin for every Cargo write, killing the build.
cache_root=${XDG_CACHE_HOME:-"$HOME/.cache"}
target_dir=${CARGO_TARGET_DIR:-"$cache_root/omarchy-spotify/target"}
temporary=""
download_dir=""
release_asset=""
verified_release=""
verified_commit=""

cleanup() {
  [[ -z $temporary ]] || rm -f -- "$temporary"
  if [[ -n $download_dir ]]; then
    [[ -z $release_asset ]] || rm -f -- "$download_dir/$release_asset"
    rm -f -- "$download_dir/SHA256SUMS"
    rmdir -- "$download_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

write_atomic() {
  local destination_file=$1 value=$2

  temporary=$(mktemp "$runtime_dir/.omarchy-spotify-metadata.XXXXXX")
  printf '%s\n' "$value" >"$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$destination_file"
  temporary=""
}

install_backend() {
  local source=$1 origin=$2 binary_hash

  install -d -m 700 -- "$runtime_dir"
  temporary=$(mktemp "$runtime_dir/.omarchy-spotify-backend.XXXXXX")
  install -m 755 -- "$source" "$temporary"
  mv -f -- "$temporary" "$destination"
  temporary=""
  binary_hash=$(sha256sum -- "$destination")
  write_atomic "$source_id_file" "$source_id"
  write_atomic "$binary_hash_file" "${binary_hash%% *}"
  write_atomic "$origin_file" "$origin"
}

source_id=$("$source_root/scripts/backend-source-id.sh")

download_verified_release() {
  local version expected_ref checksum_line expected_hash actual_hash release_base

  for command_name in awk curl gh git python3 sha256sum stat; do
    command -v "$command_name" >/dev/null 2>&1 || return 1
  done
  [[ -z $(git -C "$source_root" status --porcelain --untracked-files=normal \
    -- backend rust-toolchain.toml 2>/dev/null) ]] || return 1

  version=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
    "$source_root/manifest.json") || return 1
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || return 1
  expected_ref="refs/tags/v$version"
  verified_commit=$(git -C "$source_root" rev-parse "$expected_ref^{commit}" \
    2>/dev/null) || return 1
  [[ $verified_commit =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$source_root" merge-base --is-ancestor "$verified_commit" HEAD \
    2>/dev/null || return 1
  git -C "$source_root" diff --quiet "$verified_commit" HEAD -- \
    backend rust-toolchain.toml || return 1

  case $architecture in
    x86_64|aarch64) release_asset="omarchy-spotify-backend-$architecture" ;;
    *) return 1 ;;
  esac
  release_base="https://github.com/$repository/releases/download/v$version"
  download_dir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-spotify-release.XXXXXX")

  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 \
    --connect-timeout 5 --max-time 60 --max-filesize 33554432 \
    -o "$download_dir/$release_asset" "$release_base/$release_asset" || return 1
  [[ $(stat -c '%s' "$download_dir/$release_asset") -le 33554432 ]] || return 1
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 \
    --connect-timeout 5 --max-time 60 --max-filesize 1048576 \
    -o "$download_dir/SHA256SUMS" "$release_base/SHA256SUMS" || return 1
  [[ $(stat -c '%s' "$download_dir/SHA256SUMS") -le 1048576 ]] || return 1

  checksum_line=$(awk -v asset="$release_asset" \
    '$2 == asset || $2 == "*" asset { print $1; exit }' \
    "$download_dir/SHA256SUMS")
  [[ $checksum_line =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_hash=$(sha256sum -- "$download_dir/$release_asset") || return 1
  expected_hash=${actual_hash%% *}
  [[ $expected_hash == "$checksum_line" ]] || {
    echo "Release checksum did not match for $release_asset; discarding download." >&2
    return 2
  }

  GH_PROMPT_DISABLED=1 gh attestation verify "$download_dir/$release_asset" \
    --repo "$repository" \
    --cert-identity "$workflow_identity@$expected_ref" \
    --source-ref "$expected_ref" \
    --source-digest "$verified_commit" \
    --deny-self-hosted-runners >/dev/null 2>&1 || {
    echo "Release attestation could not be verified for $release_asset; discarding download." >&2
    return 2
  }

  verified_release="$download_dir/$release_asset"
}

if [[ ${OMARCHY_SPOTIFY_BUILD_FROM_SOURCE:-0} != 1 ]]; then
  if download_verified_release; then
    install_backend "$verified_release" "attested-release:$verified_commit"
    printf 'Installed verified playback backend: %s\n' "$destination"
    exit 0
  else
    verification_status=$?
  fi
  if (( verification_status == 2 )); then
    echo "Downloaded release was not verified; trying a locked source build. No downloaded executable was run." >&2
  else
    echo "Verified playback release unavailable; trying a locked source build." >&2
  fi
fi

command -v cargo >/dev/null 2>&1 || {
  echo "build-backend.sh: verified release unavailable and cargo is missing" >&2
  exit 30
}

source_date_epoch=$(git -C "$source_root" log -1 --format=%ct 2>/dev/null || printf '0')
(
  cd "$source_root"
  SOURCE_DATE_EPOCH="$source_date_epoch" \
  CARGO_INCREMENTAL=0 \
  CARGO_TARGET_DIR="$target_dir" \
    cargo build --locked --release --manifest-path "$manifest"
)
install_backend "$target_dir/release/omarchy-spotify-backend" "source-build:$source_id"
printf 'Built and installed playback backend: %s\n' "$destination"
