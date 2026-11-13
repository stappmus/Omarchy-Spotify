# Implementation status

Local 1.0.4 implementation, 7 September 2026. This is an implementation and
validation record, not a claim that the corresponding GitHub issues are closed
or that a release has been published. The complete reviewed inventory remains
in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Implemented

- Search: #38 baseline plus #64, #66 and corrected #49. Full Retry-After,
  selected-category requests, empty-result caching, pending-request reuse,
  pagination cancellation, explicit retry target, keyboard Retry and cooldown
  countdown. SearchController has independent asynchronous state tests.
- Transport: finite active/token watchdogs, bounded diagnostics without search
  terms or account identifiers, separate QUOTA_EXCEEDED handling, account-change
  cancellation, and uncertain-outcome messaging for interrupted mutations.
- Authorization: corrected #58, with invalid-ID feedback, identity-change
  draining, immutable keyring command identities, stale-token rejection and
  account-cache clearing. Separate Connect authorization is retained.
- Playback: #65 ownership dispatch; corrected #55 last-play candidate, including
  empty/error throttling; targeted #40 recovery for the already chosen local
  receiver only. No general transfer-on-error behavior.
- Startup: partial #39. Typed invalid-configuration, missing-credential and
  reconnect-budget errors; private atomic startup diagnostics; terminal exit
  statuses; five-start/five-minute service limits; UI latch and explicit recovery.
- Discovery: corrected #54, including partial **bytes** from an actual timed-out
  subprocess.
- Navigation and collections: explicit Search destination, manual pagination
  beyond 200, ID-based artist discography from #26, bounded five-page filter
  scanning, Continue/Cancel, and persistent compact-row Save visibility for #51.
  Filter cancellation stops further scanning; an already shared collection page
  may finish into its cache. It does not cancel another consumer's collection load.
- UI: #44 keybinding documentation, #57 opaque in-panel surfaces, #48 responsive
  layout, #36 bounded artwork retries, #20 master artwork switch, #25 optional
  vinyl, #46 optional lyrics button, #56 fixed bar width, and #62 glyph scaling.
  Artwork requests and vinyl animation are gated by visibility and settings.
- IPC: #53 shared global player handler, focused-monitor routing and stable
  fallback. Explicit local Stop is available from the bar context menu and the
  full player's Devices view. Reopening a panel respects Stop.
- Validation: pinned CI definition, locked Rust checks, transport/search/filter
  tests, and real Quickshell authorization and app smoke tests using actual
  Omarchy imports. Versions are aligned at the unreleased 1.0.4 snapshot.

The artist endpoint parameters follow Spotify's [artist albums reference](https://developer.spotify.com/documentation/web-api/reference/get-an-artists-albums).
Personal-client documentation follows [quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## Still gated or deferred

- #67/#42: the retained-listener [dependency PR](https://github.com/stappmus/librespot/pull/1)
  and #67 remain open (rechecked during implementation). No temporary fork
  override was added. Packaged spotifyd's OAuth path is also outstanding.
- #39's fully typed unsupported-account/authentication reporting requires
  dependency work: the pinned librespot session calls process exit directly
  for non-Premium accounts. Restart limits bound this failure, but the UI
  cannot truthfully identify its exact cause. Audio-key behavior remains the
  existing explicit backend error, not a promise of a Spotify-side fix.
- #37 exact reconnect-context recovery needs the upstream snapshot contract.
  Ownership activation does not restore a lost queue or shuffle context.
- #26 configurable columns, #59 queue launcher, #50 built-in lyrics/zoom, and
  managed Soloist support remain separate optional work. Omasing stays the
  default. No Soloist client/key was provisioned or lossless quality claimed.
- #13 recommendation feedback remains deferred as specified in the plan.

## Validation and limits

`CARGO_TARGET_DIR=$HOME/.cache/omarchy-spotify/target bash scripts/test.sh`
runs Rust formatting/tests/Clippy, plugin validation, qmllint, QML tests, Python
helper tests, installer tests, and real Quickshell smoke tests. Build output stays
outside the installed plugin tree.

On this machine: 188 QML tests, 23 Rust tests, and 19 Python tests passed; script
and real Quickshell checks passed. A locked optimized backend build passed.
When a Wayland display is available, the smoke harness constructs the actual
Panel and BarWidget; headless CI checks the actual Service and authorization
runtime and lints the UI with pinned Omarchy imports. This is not a screenshot
or physical multi-monitor test.

CI has been authored but not run on GitHub. Local Docker execution is unavailable
to this session because access to the daemon socket is denied. Neither workflow
success nor a published release is claimed.

Live authentication switching, Sonos wake, long-playlist scroll restoration,
physical monitor routing, sleep/wake and the complete benchmark matrix still
need live acceptance coverage. Automated fixtures verify race behavior without
using real credentials or changing the user's queue. A brief whole-shell sample
cannot establish Spotify latency or a plugin-only memory improvement.

## Local installation

The installed checkout was fast-forwarded to the tested implementation and the
plugin was reloaded. The optimized 1.0.4 backend is installed, its source identity
check passes, and systemd reports it active with zero restarts. Both units report
StartLimitBurst=5 and StartLimitIntervalSec=300. The built-in unit also excludes
exit codes 75, 77 and 78 from automatic restart. Shared IPC responds, and the live
shell log contains no new QML binding/type/load errors from the update.

Rollback references are the local `backup/pre-reliability-20260907` branch and
`~/.local/state/omarchy-spotify/implementation-backup-20260907/`, which contains
the previous executable/metadata and service units. Credentials were retained.
No branches, tags, issues, PR comments, or release artifacts were published.

Two five-second **observational whole-shell** samples, with no controlled live
search/playback matrix, were:

| Sample | CPU | Scheduler switches/s | Shell RSS | Backend RSS |
| --- | ---: | ---: | ---: | ---: |
| Before | 0.999% | 28.976 | 849528 KiB | 25660 KiB |
| After | 0.200% | 2.998 | 779124 KiB | 23280 KiB |

Hot reload, unrelated plugins, and the backend restart confound attribution.
These numbers are a sanity check, not a measured plugin-specific improvement.

## Publication update, 8 September 2026

The implementation through `c572e63` was pushed to main. All 15 open issue
threads received individual thank-you/status replies, including explicit limits
for partial fixes. No issue was closed and no PR was marked merged.
The first GitHub validation run exposed a missing Qt tools PATH entry in the
container; the workflow now adds `/usr/lib/qt6/bin`. Validation is being rerun.
No version tag or attested release has been published yet.

## Reliability release candidate 13 November 2026

The current candidate fixes public-host directory/settings lookup, initial
identity restoration, missing-client onboarding, callback listener readiness,
Qt 6.12 theme-name resolution, mini-player shortcuts, Omasing state lookup,
QML collection playback and Sonos scheduling/mode/volume reconciliation.
Remote polling is 15 seconds and release verification failures are distinct.

Local validation: 23 Rust tests plus formatting/Clippy, 189 QML tests, 19 Connect
helper tests, 2 real-socket OAuth tests, installer tests and Quickshell identity,
startup and actual Panel/BarWidget smoke tests passed. The smoke host provides
only public barConfig and a sanitized manifest. Sonos queue/mode/freshness tests
exercise the actual components with isolated state, not physical speakers.

Remaining acceptance: live Spotify authorization and saved-token exchange,
physical multi-monitor behavior, Sonos/grouped receiver hardware and Bluetooth
multipoint. Native port-8000 OAuth, typed upstream account errors, exact reconnect
queue restoration and optional features remain tracked separately. No claim of
lossless support or a Spotify-side audio-key fix is made.
