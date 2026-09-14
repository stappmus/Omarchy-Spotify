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

# download_verified_release() reports why it gave up. A release that is merely
# unavailable here (no tooling, no network, no matching tag) is routine and
# stays quiet. An artifact that downloaded but then disagreed with the release's
# own SHA256SUMS or attestation is not routine, and saying so is the only way a
# user can tell a missing gh from a substituted binary.
readonly release_unavailable=1
readonly release_unverified=2

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
  local version expected_ref expected_hash checksum_output actual_hash release_base

  for command_name in awk curl gh git python3 sha256sum stat; do
    command -v "$command_name" >/dev/null 2>&1 || return "$release_unavailable"
  done
  [[ -z $(git -C "$source_root" status --porcelain --untracked-files=normal \
    -- backend rust-toolchain.toml 2>/dev/null) ]] || return "$release_unavailable"

  version=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
    "$source_root/manifest.json") || return "$release_unavailable"
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
    || return "$release_unavailable"
  expected_ref="refs/tags/v$version"
  verified_commit=$(git -C "$source_root" rev-parse "$expected_ref^{commit}" \
    2>/dev/null) || return "$release_unavailable"
  [[ $verified_commit =~ ^[0-9a-f]{40}$ ]] || return "$release_unavailable"
  git -C "$source_root" merge-base --is-ancestor "$verified_commit" HEAD \
    2>/dev/null || return "$release_unavailable"
  git -C "$source_root" diff --quiet "$verified_commit" HEAD -- \
    backend rust-toolchain.toml || return "$release_unavailable"

  case $architecture in
    x86_64|aarch64) release_asset="omarchy-spotify-backend-$architecture" ;;
    *) return "$release_unavailable" ;;
  esac
  release_base="https://github.com/$repository/releases/download/v$version"
  download_dir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-spotify-release.XXXXXX")

  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 \
    --connect-timeout 5 --max-time 60 --max-filesize 33554432 \
    -o "$download_dir/$release_asset" "$release_base/$release_asset" \
    || return "$release_unavailable"
  [[ $(stat -c '%s' "$download_dir/$release_asset") -le 33554432 ]] \
    || return "$release_unavailable"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 \
    --connect-timeout 5 --max-time 60 --max-filesize 1048576 \
    -o "$download_dir/SHA256SUMS" "$release_base/SHA256SUMS" \
    || return "$release_unavailable"
  [[ $(stat -c '%s' "$download_dir/SHA256SUMS") -le 1048576 ]] \
    || return "$release_unavailable"

  # A release that does not list this asset is treated as unavailable: an
  # architecture can legitimately be absent from a given release.
  expected_hash=$(awk -v asset="$release_asset" \
    '$2 == asset || $2 == "*" asset { print $1; exit }' \
    "$download_dir/SHA256SUMS")
  [[ $expected_hash =~ ^[0-9a-f]{64}$ ]] || return "$release_unavailable"
  checksum_output=$(sha256sum -- "$download_dir/$release_asset") \
    || return "$release_unavailable"
  actual_hash=${checksum_output%% *}
  if [[ $actual_hash != "$expected_hash" ]]; then
    printf 'Release asset %s does not match the SHA256SUMS published for v%s.\n' \
      "$release_asset" "$version" >&2
    printf 'Published %s, downloaded %s.\n' "$expected_hash" "$actual_hash" >&2
    return "$release_unverified"
  fi

  if ! GH_PROMPT_DISABLED=1 gh attestation verify "$download_dir/$release_asset" \
    --repo "$repository" \
    --cert-identity "$workflow_identity@$expected_ref" \
    --source-ref "$expected_ref" \
    --source-digest "$verified_commit" \
    --deny-self-hosted-runners >/dev/null 2>&1; then
    printf 'Release asset %s failed attestation verification for %s.\n' \
      "$release_asset" "$expected_ref" >&2
    return "$release_unverified"
  fi

  verified_release="$download_dir/$release_asset"
}

if [[ ${OMARCHY_SPOTIFY_BUILD_FROM_SOURCE:-0} != 1 ]]; then
  verification_status=0
  download_verified_release || verification_status=$?
  if (( verification_status == 0 )); then
    install_backend "$verified_release" "attested-release:$verified_commit"
    printf 'Installed verified playback backend: %s\n' "$destination"
    exit 0
  fi
  if (( verification_status == release_unverified )); then
    echo "Discarding the downloaded release asset: it did not verify." >&2
    echo "A corrupted download or an unreachable attestation API looks the same" >&2
    echo "as a substituted binary from here, so do not install it by hand." >&2
    echo "Building from the locked source tree, already matched to the tag." >&2
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
