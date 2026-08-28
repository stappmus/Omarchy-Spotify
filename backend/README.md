# Omarchy Spotify backend

This crate owns the plugin's local Spotify Connect runtime. It deliberately
does not reimplement Spotify's private wire protocol: it embeds a commit-pinned
librespot revision behind an interface owned by this project.

The process provides:

- PulseAudio/PipeWire playback with durable XDG-state authorization and a 1 GB
  disposable audio cache;
- Spotify Connect state and controls through librespot;
- an MPRIS player for Quickshell and other desktop media controls; and
- a versioned newline-delimited JSON protocol on an owner-only Unix socket.

The project fork's librespot revision is pinned in both `Cargo.toml` and
`Cargo.lock`. It contains the manual-track-switch smoothing submitted as
[librespot PR #1740](https://github.com/librespot-org/librespot/pull/1740) and
stops cleanly when Spotify refuses an audio key instead of skipping through the
queue. Updating the revision requires the full test suite and a live switch
test; a floating branch is intentionally never used.

Release tags build the backend on GitHub-hosted native runners with a pinned
Rust toolchain and immutable action revisions. GitHub records build-provenance
attestations for the exact raw executables. The installer accepts a release
binary only when `gh attestation verify` binds it to this repository, the
release workflow, the exact version tag, and the checkout's source commit.
Checksums committed beside a binary are deliberately not treated as source
provenance, and no ELF executable is stored in this repository.

The production process uses a current-thread Tokio control runtime. Librespot's
separate blocking player runtime is capped at two workers by the systemd unit;
one worker was deliberately not used because fetching, preloading, and decoding
must remain able to overlap. Player position is published once per second,
matching the UI timer while Quickshell interpolates between updates. Backend
state is held in one watch channel, unchanged events are discarded, commands
are bounded, and MPRIS emits `Seeked` only for an actual seek event. MPRIS uses
the library-recommended PID-qualified instance name so a stray second backend
cannot take the supervised process's bus ownership.

If librespot's session task ends, the backend replaces only its Session and
Spirc pair. The socket, MPRIS name, player, and command queue remain alive.
Five reconnects are allowed in ten minutes; exceeding that limit exits so
systemd can perform the existing clean restart. An active or paused track is
restored at its last position together with its remaining queue and playback
settings. Queue snapshots stay internal to the engine and are not published on
the local protocol.

## Future work

- [ ] Add Spotify Lossless only when Spotify exposes a supported third-party
  playback path. Live HiFi-capability probes on 2026-08-16 across six varied
  catalog tracks returned only `OGG_VORBIS_320`; librespot's maintainers report
  that FLAC is absent from the normal metadata endpoint and that Spotify asked
  the project not to circumvent its technical protections through extended
  metadata. Keep 320 kbps as the stable maximum until that changes.

Build and verify from the repository root:

```bash
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo test --manifest-path backend/Cargo.toml --locked
cargo clippy --manifest-path backend/Cargo.toml --locked --all-targets -- -D warnings
OMARCHY_SPOTIFY_BUILD_FROM_SOURCE=1 ./scripts/build-backend.sh
```

By default, `scripts/build-backend.sh` first tries the exact-commit attested
release. `OMARCHY_SPOTIFY_BUILD_FROM_SOURCE=1` forces an auditable local build
into `$XDG_CACHE_HOME/omarchy-spotify/target` (override with
`CARGO_TARGET_DIR`). Omarchy hot-reloads plugins on any write inside their
directory, so building to a cache path outside the plugin prevents the shell's
recursive watcher from reloading the plugin and killing the build.

See [the protocol reference](../docs/BACKEND_PROTOCOL.md) for the compatibility
contract and [release process](../docs/RELEASING.md) for the artifact-provenance
requirements. The legacy `omarchy-spotifyd.service` remains installable as a
fallback and conflicts with the primary unit so two local receivers cannot run
accidentally with the same device identity.
