# Omarchy Spotify implementation plan

Updated 13 November 2026. Fix installation and authentication first, publish a verifiable release, then repair playback and finish optional features. Do not merge the backlog wholesale: many PRs duplicate one another or contain work already implemented on main.

## Authentication direction superseded, 13 November 2026

The user rejected personal Developer app setup. W2.4 and the separate-grant
onboarding in this historical plan are superseded by a repository-owned native
session with one browser pairing login. The implementation lives under
`backend/src/spotify/` and `NativeSession.qml`; the existing pinned librespot
library is retained. There is no spotatui build/runtime dependency or proxy.
Fresh login, saved-session restart, library/search, playlist edits and actual
player startup are release gates. Do not represent a playback-only fallback as
a complete installation. See `IMPLEMENTATION_STATUS.md` for observed evidence.

## Scope and baseline

The GitHub inventory contains **63 issues (38 open, 25 closed)** and **61 PRs (32 open, 11 merged, 18 closed without a merge)**. Every item has a disposition below. The review includes issue/PR metadata, available discussions and reviews, open-PR file inventories, targeted patches, local source, Actions and releases. This is a backlog implementation plan, not approval of every line in every proposed patch or an exhaustive audit of external forks and attachment prototypes. GitHub Discussions is disabled.

Local main and GitHub main both point to `e7371f38f79e3bf52bd6e3542ea54859f6dc082b`. The manifest advertises unreleased 1.0.4; the latest published release is [v1.0.3](https://github.com/stappmus/Omarchy-Spotify/releases/tag/v1.0.3). Main's [latest validation run](https://github.com/stappmus/Omarchy-Spotify/actions/runs/34750377034) succeeded. Recent contributor runs include `action_required` and failures; these are not evidence that their patches passed or failed functional tests. Inspect job logs and approval/runner state before diagnosing CI failures.

The existing [implementation status](IMPLEMENTATION_STATUS.md) records September work, including search caching, artwork settings, local Stop, IPC consolidation and partial playback recovery. Preserve that work; it does not establish that all related reports are resolved. This review reran the offscreen QML suite: **188 passed, 0 failed**. Rust, installer, Quickshell integration and live hardware acceptance were not rerun during planning.

## Delivery order

| Stage | Work | Dependency | Completion gate | Indicative effort |
| --- | --- | --- | --- | --- |
| A | W1 host compatibility and W2 identity lifecycle | None | Third-party fresh install and saved-session restart work | 3–5 engineering days |
| B | W3 OAuth listeners and W4 release/install reliability | A for end-to-end setup | Supported sign-in paths, green CI and attested release | 3–6 days plus dependency turnaround |
| C | W5 Sonos, W6 collections/quota, W7 recovery diagnostics | A; W4 for backend delivery | Targeted regressions and real playback matrix pass | 5–9 days plus upstream recovery work |
| D | W8 panel/UI and W9 optional features | A–C stable; independent features may follow separately | Feature-specific acceptance and resource budgets | 5–10 days plus product/dependency decisions |
| E | W10 backlog reconciliation | Each delivered stage | Every report links to evidence or an explicit remaining blocker | 1–2 days spread across delivery |

These are planning ranges for one engineer with the required test hardware, not delivery commitments. Exact queue restoration, dependency changes and lossless investigation have no defensible fixed completion date. Do not hold the startup hotfix for optional features or blocked upstream work. Ship the first coherent A/B subset as soon as its advertised paths pass; document remaining path-specific limitations.

## W1 Restore the public host integration contract

**Priority P0.** Files: `Service.qml`, `DaemonManager.qml`, `BarWidget.qml`, `Api.js`, `tests/integration/AppSmoke.qml`; new focused host-contract tests.

1. Use #75 as the canonical directory fix. Resolve the loaded QML directory, require a local file URL, decode URL escapes and normalize the trailing slash. Do not hardcode a home-directory install path or depend on private `__sourceDir`. Check paths with spaces, `%`, `#`, Unicode and a relocated checkout. Retire duplicate patches after delivery, preserving contributor attribution.
2. Combine the public `barConfig` fallback and change subscription from #81/#119 with #124's enumeration of all layout sections. Normalize QML array-like values with the existing array helper. Preserve legacy `shellConfig` support and explicit settings precedence. A standalone plugin absent from the public bar configuration needs a supported settings provider or an actionable unsupported-host state; the fallback alone cannot expose withheld `config.plugins`.
3. Extract the empty-settings-push fix from #78. Distinguish configuration not yet available from an explicit reset. A transient `{}` from a second monitor must not wipe settings; an intentional reset must still work. Preserve loaded settings across monitor sleep/rebuild and test removal/re-addition separately.
4. Make readiness finite. Missing scripts, a failed process start, missing dependencies or unavailable service references must end in a specific recoverable error, not permanent “Checking local playback”. Distinguish credentials not checked from credentials absent before dispatching Play. Cancel must terminate actual work and clear pending intent.
5. Integrate #113 with focused-monitor routing, popup focus and mini/full handoff tests. Audit deferred callbacks for teardown. For #97, separately reproduce replacement-bar service lookup: its follow-up reports a null `bar.shell.serviceFor`, which a directory fix cannot repair. Prefer injected service references or supported host APIs; show an explicit unavailable state when neither exists. Retest #114 after these fixes without assuming it is the same root cause.
6. Take #104's teardown guard and examine sibling asynchronous handlers for the same lifecycle issue. Do not claim the narrow original race is reproducible merely because a guard is present.
7. Revise #105 for Omasing detection. Use the host's supported plugin-state interface where available; otherwise use XDG-aware manifest discovery plus authoritative enabled/launch state. A file existing is not proof a plugin is enabled, and absence from the bar is not necessarily proof it is disabled. Cover user/system installs, custom XDG paths, fresh installation, enable/disable and all layout sections. Keep installation polling bounded. Separate opening Omasing without a current track from the detection repair.

**Acceptance:** real service instantiated with a sanitized manifest and public bar API; settings survive three restarts and a two-monitor rebuild; both player shortcut modes work; missing dependencies produce a usable error; no teardown exception; Omasing installed/enabled/disabled/missing states agree with actual launch behavior. Update release instructions to require a full shell restart where the host retains the old service instance.

## W2 Make authentication initialization deterministic

**Priority P0.** Files: `AuthManager.qml`, `Service.qml`, `tests/integration/AuthIdentity.qml`, OAuth tests, settings UI.

1. Replace implicit initialization ordering with explicit settings-loading, identity-ready, restoring, signed-out and authenticated states. Start identity restoration exactly once after usable settings arrive. Queue token requests while initialization is pending, then resolve every waiter on success, failure, cancellation or timeout.
2. Revise #86 rather than merging it unchanged. Its `shellConfig`-only readiness condition excludes current third-party hosts, and it does not provide the complete queued-token/startup-restoration behavior. A three-second timer alone is not proof that the correct identity has arrived; timeouts should expose retryable configuration failure rather than silently authorizing the wrong app.
3. Address #110 independently of #85: a valid unchanged identity still needs startup session lookup. Missing or locked keyring must finish the check. Initial loading of a saved ID must not emit logout; an actual later user identity change must retain existing draining, generation checks, cache clearing and client-scoped keyring isolation.
4. Resolve #120 with a personal Developer app as the immediate supported Web API identity. Remove the borrowed ncspot identity as the automatic Web API fallback, add a clear client-ID-required state and reachable setup controls, and adapt #122's README/manifest/technical copy. Do not change the callback to ncspot's private path. Audit the separate Connect-auth instance so a Web API identity change does not break its independent grant.
5. Preserve existing client-scoped credentials during migration; do not delete unrelated keyring entries. Explain that selecting a different app requires authorization. A future project-owned app is a separate operational choice, not a prerequisite for this repair.

**Acceptance:** saved custom ID arriving before/after component completion; no configured ID; invalid ID; no/locked keyring; concurrent token requests; explicit A→B switch during lookup, refresh, write and login; reload during each stage; independent Connect identity. No startup logout for an unchanged configured identity, no wrong-app token delivery and no permanent busy state.

Development apps require a Premium owner and allowlisted users, and have quota/endpoint restrictions. A personal ID is not a promise of unrestricted Spotify access. [Spotify quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## W3 Bind OAuth callbacks before opening the browser

**Priority P0 for unusable sign-in, P1 for configurable redirects.** Files: `AuthManager.qml`, `OAuth.js`, `DaemonManager.qml`, OAuth scripts, `backend/src/main.rs`, dependency pin and tests.

1. For Web API login (#118), replace process-start plus a 120 ms delay with a listener-ready handshake. Retain ownership of the socket through the callback. Classify address-in-use, unavailable executable, listener timeout, denial and token-exchange failure separately. Bind only the intended loopback address; cancel closes the listener and invalidates its state.
2. Reproduce #115 before declaring the documented URI universally rejected. Reports conflict: later #120 comments confirm the same URI works on newly created apps. Spotify still documents explicit loopback HTTP and dynamic ports. Preserve exact callback paths; omission of a port does not imply arbitrary callback paths are accepted. [Spotify redirect rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
3. Add a validated advanced callback port/path option if fixed-port apps need it, displaying the exact URI users must register. Prefer dynamic ports only after proving the registered redirect and token exchange work together. Freeze the selected URI throughout one auth attempt and retain state/PKCE checks. Avoid arbitrary non-loopback redirect configuration.
4. For native playback (#42/#67), integrate the retained-listener dependency change from [stappmus/librespot#1](https://github.com/stappmus/librespot/pull/1), still open at review time. Replace #67's temporary OAuth-only fork override with the reviewed dependency revision and update the lockfile. Test packaged spotifyd separately; the native fix does not repair its dependency.
5. Review #87 against both runtimes. The backend's auth URL is currently consumed by the daemon output handler, but adding `xdg-open` on every “Browse to” line can duplicate an existing browser launch or open before binding. Establish one browser owner per runtime, open once after readiness, validate the expected authorization URL, and never retain OAuth URLs/tokens in logs.

**Acceptance:** preoccupy ports 8989 and 8000, including wildcard listeners; no browser opens and the error names the conflict. Test immediate callback, invalid state/path, denial, timeout, cancellation, missing browser handler and retry. Prove native and packaged runtime behavior separately with isolated state. Do not use a bind-and-close preflight as the final race fix.

## W4 Make installs and releases reproducible

**Priority P0.** Files: installer scripts, `.github/workflows/validate.yml`, `.github/workflows/release-backend.yml`, `docs/RELEASING.md`, version files and changelog.

1. Publish a release matching the final tested version and backend inputs. 1.0.4 is currently unpublished; use it only if still unused at release time. Align manifest, Cargo manifest/lock and changelog. Follow the existing immutable-tag, two-architecture attestation procedure. Never move a published tag or lower the advertised version merely to select an incompatible binary.
2. Integrate #79's distinction between unavailable and unverified downloads, with fixture coverage. Correct its unconditional claim that fallback source was matched to a tag: failures before tag/source validation cannot support that claim. Keep checksums, repository/workflow/tag/source-digest provenance checks and fail-closed installation behavior.
3. Make missing tag/assets, network/tooling failure, checksum mismatch, attestation failure and missing source-build prerequisites distinguishable. Document the locked source-build and packaged fallback paths. Test GitHub CLI verification on a fresh machine without assuming an authenticated developer environment.
4. Restore useful contributor CI: investigate historical failures and pending approvals, rerun reviewed heads using ordinary unprivileged PR jobs, and keep credentials out of fork jobs. Add explicit job/step timeouts and resource diagnostics. Do not treat the displayed multi-week failed runs as proven test hangs without job evidence.
5. Expand pinned host validation to include the sanitized third-party contract and current supported host behavior, including 4.5 layout sections. Keep a legacy compatibility fixture. Existing passing tests missed these public-host boundary failures.

**Acceptance:** exact-tag download and attestation on x86_64/aarch64; clean install without Rust; local build fallback; spotifyd fallback; corrupt asset; missing verification/tooling; backend-input mismatch; UI-only commit after tag; upgrade from 1.0.3; full uninstall; rollback without credential deletion. Update the historical status document only with newly observed results. A green source test run alone does not close #74/#88: the published artifact path must work.

## W5 Repair Sonos command and state consistency

**Priority P1.** Files: `SpotifyConnectManager.qml`, `Service.qml`, `Api.js`, `scripts/spotify-connect-device.py`; add manager-level asynchronous tests.

1. #101 has two drop points: `sendSonosControl()` skips the manager when busy and reports true; `control()` also silently returns. Give dispatch an explicit accepted/queued/rejected result. Maintain a bounded scheduler with per-device intent generations. Coalesce latest volume, seek and absolute play-mode state by action; preserve ordered Next/Previous commands. A single last-command slot would lose unrelated actions. Drain after control and activation complete, and clear stale work on target/account changes and teardown. Report rejection without causing an unintended Web API command on another device.
2. #100 needs one six-mode conversion table in both directions. The current outbound `sonosPlayMode()` also discards shuffle when repeat is track. Round-trip NORMAL, REPEAT_ALL, REPEAT_ONE, SHUFFLE_NOREPEAT, SHUFFLE and SHUFFLE_REPEAT_ONE. Reconcile against the speaker's reported resulting mode.
3. #102 needs per-device volume provenance/freshness. Pending accepted commands hold their optimistic value for a bounded interval; fresh receiver reads then win; Web API values apply only when meaningful; discovery cache is fallback. `mergeConnectDevices()` must not reapply older discovery volume. Refresh the selected restricted device on a bounded cadence while controls are visible, and accept external volume changes.

**Acceptance:** slow/failing helper, rapid mixed seek/volume/mode commands, repeated Next, activation in progress, target switch, account switch, queue overflow, all six modes, external hardware/app volume changes, and stale discovery completion. Verify on actual Sonos including grouped/coordinator behavior; fixtures alone do not establish receiver compatibility.

## W6 Preserve collection playback and reduce API work

**Priority P1.** Files: `Api.js`, `Panel.qml`, `MediaCollection.qml`, `Service.qml`, search/transport tests.

1. Reproduce #117 through the actual Liked Songs row path. `playbackBody()` currently uses `Array.isArray(sourceItems)` while the project already has `Api.arrayValues()` for QML sequence values. This is a plausible cause, not yet a live reproduction. Normalize at the boundary and verify every collection activation passes its displayed source list. Preserve clicked duplicate occurrence, sort/filter order, playable-item filtering, wrap behavior and the existing 100-item bound. Do not fabricate an unsupported Liked Songs context URI or promise the entire unloaded library is queued.
2. Adapt #116's 15-second remote polling, keeping foreground commands responsive with one coalesced follow-up refresh. Follow-up requests must obey auth/account generation, rate-limit cooldowns, loading deduplication and target changes. Stop obsolete timers on logout or teardown. Preserve local MPRIS/socket updates and explicit optimistic controls. Test request counts and stale-state reconciliation, not just timer constants.
3. Verify September's integrated #49/#54/#40 and #20 behavior before retiring those PRs. Preserve empty-result caches, request cancellation, Retry-After, quota-exceeded handling, partial discovery output and targeted local wake. Do not reintroduce original defects by merging stale versions.
4. Recheck #51's row Save visibility and action behavior with a personal development app. Distinguish unsupported/restricted data from a genuinely empty collection. Retain closed #70's API-limitation disposition; do not promise personalized playlists that the supported endpoint does not expose.

**Acceptance:** QML array-like and real component-boundary list input; first/middle/last clicked song; duplicate occurrences; >100 loaded tracks; unloaded pages; next/shuffle behavior on local and remote targets; rapid commands during cooldown; no cross-account search cache; no hidden local-playback polling increase.

## W7 Complete playback failure and recovery behavior

**Priority P1, with dependency-blocked subprojects.** Files: backend engine/failure/state/protocol, `BackendClient.qml`, `DaemonManager.qml`, systemd units and helper scripts.

1. #39/#28: preserve existing finite restart limits, but finish typed unsupported-account reporting through the dependency rather than guessing from every credential failure. Keep terminal auth/configuration errors distinct from network retry budgets. The pinned dependency's process exit remains a limitation; avoid presenting reconnect as a cure for a Free account.
2. #16/#45/#63: collect redacted runtime version/source identity and classified failures; distinguish rejected audio key, decoder failure, obsolete runtime, socket unavailable and setup failure. Show an actionable error and avoid rapid skip/restart loops. Audio-key server compatibility requires upstream investigation; do not claim a local UI patch guarantees playback.
3. #61/#53: retain implemented local ownership dispatch and shared IPC, then test phone-initiated Connect activation independently. Draft #37 requires a dependency-owned exact playback snapshot: duplicate occurrences, original/shuffled order, queue cursor/continuation, repeat, position and paused intent. Do not take ownership back if the user selected another receiver during reconnect. Finish load/restore acknowledgement rather than treating command enqueueing as confirmed playback.
4. Revisit closed #71's native watchdog as a focused, bounded recovery proposal if its reported failure remains reproducible; retain its historical closed status. Distinguish live-but-stalled process/socket from disconnected session and intentional local Stop. Recovery must not restart after Stop or steal remote playback.
5. Review #92 as a separate Bluetooth recovery change. Its helper parks every stream on the affected sink and toggles its profile, which can affect other applications. Prefer the narrowest recovery that proves necessary, with cooldowns, maximum attempts, cancellation and restoration after helper crashes. Preserve selected codec, system default, user routing changes and unrelated outputs. Test both backend runtimes and interaction with #78 before enabling automatic recovery.

**Acceptance:** offline/online, sleep/wake, server disconnect, socket restart, phone transfer, remote selection during reconnect, paused versus stopped state, Free-account fixture, audio-key failure fixture, and Bluetooth multipoint hardware. Exact shuffled context recovery and actual audio-key compatibility remain open until their own evidence exists.

## W8 Improve panel behavior without losing the resource budget

**Priority P2.** Files: `manifest.json`, `Panel.qml`, `BarWidget.qml`, benchmark documentation.

1. Evaluate #121 after lifecycle fixes. Its reported opening-time improvement trades about 18 MB of shell memory on one contributor's setup; reproduce cold/warm opening, hints on/off, memory and hidden work before choosing `keepLoaded`. Verify host semantics for panel/service retention and plugin update/reload. Keep hidden animations, polling, artwork retries and future optional processes stopped. Record actual results instead of copying contributor numbers into universal changelog claims.
2. Adapt #91's compact playlist rail with keyboard focus, tooltips/accessibility names, scrolling, scaling and a usable text/glyph fallback when artwork is disabled. Preserve wide layout and playlist scroll restoration.
3. Finish #26's configurable artist columns only as a separate feature after confirming the already-integrated discography correctness. Use array-like pagination normalization, explicit ordering and bounded requests. Do not merge unrelated row-action behavior with personalization.
4. Retain all closed visual and interaction fixes in the inventory as regression gates. Keep the documented manual Music-keybinding requirement and local Stop behavior.

**Acceptance:** narrow/wide layout, 100/150/200% scaling, light/dark/translucent themes, keyboard-only navigation, artwork off, hints on/off, repeated open/close, monitor removal, hidden idle and long-playlist return. Compare the same workload and distinguish whole-shell RSS from plugin-attributable cost.

## W9 Deliver optional features as independent changes

**Priority P2/P3.** These are implementation paths, not requirements for the reliability release.

| Feature | Proposed scope | Required acceptance |
| --- | --- | --- |
| #78 per-app output | Extract W1 prerequisites first; add persisted sink-name selection with System default; validate values and support both runtime configs | Missing/hotplugged sink, failed enumeration, next-start semantics, no global default change, #92 routing interaction, uninstall |
| #59 queue launcher | Rebase on shared IPC and current search state; isolate launcher query; replace blind bursts of Next with bounded acknowledged progression or a clear unsupported action | Duplicate occurrence selection, rapid queue changes, Sonos/remote target, cooldown, focus/close, artwork off, no closed-view polling |
| #50 lyrics and zoom | Split optional synced lyrics from artwork zoom; retain Omasing as the default integration; bounded provider requests/caches and explicit failures | Missing/instrumental lyrics, seek/pause/track switch, stale callback, provider failure, metadata mismatch, no hidden polling or artwork downloads when disabled |
| #84 expanded now-playing | Port prototype separately from compatibility fixes; prefer optional cava first, owned only while the view is visible and local playback is selected | Missing/installing cava, logout while open, E/Esc/navigation, stream replacement, no capture of unrelated app audio, theme changes and process cleanup |
| #41 lossless | Investigate an independently installed compatible Connect target and current supported provider/runtime path before managed integration | Demonstrated decoded format and audible playback path, credential/lifecycle review, resource cost; no cosmetic “lossless” option without actual support |

Follow existing maintainer requests to split #26/#50/#59 and preserve supported behavior. Do not treat code in another fork as reviewed or automatically reusable merely because a comment links it.

## W10 Reconcile the backlog and protect the release

After each delivered fix, link affected reports to the exact commit, released version and acceptance evidence. Close duplicate PRs as superseded rather than merging repeated patches. Give original contributors credit when adapting their work. A partially implemented issue stays open with its remaining subcase named. Support reports #63/#97/#114 require follow-up evidence after the release; do not close them solely on similarity of wording.

Future PR communication must begin with a brief thank you, use the fewest accurate words and avoid em dashes or double hyphens, per `AGENTS.md`. This plan does not post comments, change issue states, merge PRs or publish a release.

### Test and release gates

- Each behavior fix starts with the failing regression closest to the real boundary: sanitized host service, asynchronous auth, QML sequence crossing, helper scheduling or socket lifecycle. Pure helper tests alone are insufficient for the failures found here.
- Run `scripts/test.sh` on each integrated release candidate, including locked Rust formatting/tests/Clippy, manifest validation, QML lint/unit tests, Python/installer tests and actual Quickshell integration. Keep build output outside the registered plugin directory.
- Test current supported Omarchy and the compatibility fixture; native and packaged runtimes; single/multiple monitors; fresh install, upgrade and restart. Maintain a redacted acceptance record with version, source ID, steps, observed result and remaining limitation.
- Publish immutable artifacts and verify them as a clean user on both architectures before advertising the release. Preserve rollback to a compatible binary/checkout and credentials. Do not widen capabilities or disable provenance checks to make installation pass.
- No stage is complete merely because all PRs have been merged. Completion means the reported behavior works, required regression coverage passes, artifacts are available where needed, and each remaining external blocker is explicitly tracked.

## Complete inventory

Snapshot state is GitHub state on 13 November 2026. “Verify and retire” means equivalent work is recorded on main but still needs a focused comparison/acceptance check before closure. Closed items remain closed unless reproduction shows a regression. PR head IDs make the reviewed proposals identifiable; re-review changed heads before integration.

### Open issues

| Item | Snapshot | Disposition |
| --- | --- | --- |
| [#16 Songs not playing](https://github.com/stappmus/Omarchy-Spotify/issues/16) | Open | W7: retain audio-key compatibility investigation and bounded failure behavior. |
| [#28 Playback not working, maybe signup issue](https://github.com/stappmus/Omarchy-Spotify/issues/28) | Open | W7: reporter Free-account case; precise unsupported-account message and finite retry acceptance. |
| [#39 Free-account failure is retried forever, degrading a clear error into a misleading "Bad credentials"](https://github.com/stappmus/Omarchy-Spotify/issues/39) | Open | W7: restart limits implemented; finish typed unsupported-account dependency behavior. |
| [#41 Plans to integrate Lossless?](https://github.com/stappmus/Omarchy-Spotify/issues/41) | Open | W9: compatibility/quality investigation before lossless UI or managed runtime. |
| [#42 Playback OAuth silently fails when port 8000 is already in use](https://github.com/stappmus/Omarchy-Spotify/issues/42) | Open | W3: native retained-listener dependency plus separate packaged spotifyd path. |
| [#45 Local playback fails when Spotify audio key is unavailable](https://github.com/stappmus/Omarchy-Spotify/issues/45) | Open | W7: audio-key/decoder failure classification and upstream reproduction; no guaranteed local cure. |
| [#51 Likes not being displayed.](https://github.com/stappmus/Omarchy-Spotify/issues/51) | Open | W6: Save visibility fix recorded; verify row actions and capability errors before closing. |
| [#52 Shared client ID causes API rate-limit errors independent of per-user usage](https://github.com/stappmus/Omarchy-Spotify/issues/52) | Open | W2/W6: supported personal identity plus reduced polling; quotas remain external constraints. |
| [#53 Bar widget stays blank on Spotify Connect activation race; duplicate IpcHandler on multi-monitor bars](https://github.com/stappmus/Omarchy-Spotify/issues/53) | Open | W1/W7: shared IPC implemented; verify multiple monitors and independently diagnose phone activation. |
| [#61 Transport controls are dropped after a librespot reconnect (SpircCommand::Play ignored while Not Active)](https://github.com/stappmus/Omarchy-Spotify/issues/61) | Open | W7: ownership commands implemented; exact reconnect context remains #37 dependency work. |
| [#63 not working after reconnecting maybe needs an update](https://github.com/stappmus/Omarchy-Spotify/issues/63) | Open | W7: request current classified/redacted evidence after release; root cause remains undetermined. |
| [#68 Quit omarchy-spotify?](https://github.com/stappmus/Omarchy-Spotify/issues/68) | Open | W8/W10: Stop already recorded on main; verify stop/reopen/remote intent then document and close. |
| [#69 pluginDir is empty on Omarchy 4.0.3 — bundled scripts fail with /scripts/…](https://github.com/stappmus/Omarchy-Spotify/issues/69) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#72 Panel stuck on "Checking local playback..." because manifest.__sourceDir is empty](https://github.com/stappmus/Omarchy-Spotify/issues/72) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#73 Lyrics button always reports Omasing as not installed](https://github.com/stappmus/Omarchy-Spotify/issues/73) | Open | W1: revise #105 for authoritative Omasing state under scoped registry. |
| [#74 manifest.json declares 1.0.4 but no v1.0.4 tag exists, so the attested release path can never resolve](https://github.com/stappmus/Omarchy-Spotify/issues/74) | Open | W4: canonical missing version-tag/artifact tracker. |
| [#80 Widget settings reset to defaults on every shell start because PluginShellApi exposes barConfig, not shellConfig](https://github.com/stappmus/Omarchy-Spotify/issues/80) | Open | W1/W2: public settings, empty-push handling and initialization ordering. |
| [#84 Proposal: expanded now-playing view with a themed live equalizer](https://github.com/stappmus/Omarchy-Spotify/issues/84) | Open | W9: separate optional now-playing/cava feature; prototype not yet reviewed line by line. |
| [#85 Personal client ID forces re-login on every startup (startup race in AuthManager)](https://github.com/stappmus/Omarchy-Spotify/issues/85) | Open | W2: correct #86 initialization gate, token waiters and saved-session restore. |
| [#88 manifest.json version (1.0.4) has no matching git tag/release, so every fresh install of main fails local-playback backend verification](https://github.com/stappmus/Omarchy-Spotify/issues/88) | Open | W4: duplicate of #74 release gap; verify published binary installation. |
| [#89 Local playback stuck on checking playback support](https://github.com/stappmus/Omarchy-Spotify/issues/89) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#93 Local playback permanently unavailable on Omarchy 4.0.3: `pluginDir` resolves empty](https://github.com/stappmus/Omarchy-Spotify/issues/93) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#97 Login button not shown / connect flow unreachable on Quickshell 0.3.1 (Omarchy 4.0.0.r2158)](https://github.com/stappmus/Omarchy-Spotify/issues/97) | Open | W1: directory issue plus distinct replacement-bar service lookup; reproduce both. |
| [#98 Plugin stuck on "Checking local playback" due to manifest.__sourceDir being stripped for third-party plugins](https://github.com/stappmus/Omarchy-Spotify/issues/98) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#100 Sonos play mode SHUFFLE_REPEAT_ONE maps to shuffle=false, repeat=off — toggles spring back](https://github.com/stappmus/Omarchy-Spotify/issues/100) | Open | W5: six-mode mapping in both directions and authoritative reconciliation. |
| [#101 control() silently drops a command while a helper run is in flight, and sendSonosControl() reports success anyway](https://github.com/stappmus/Omarchy-Spotify/issues/101) | Open | W5: accepted/queued/rejected dispatch and bounded action-aware scheduling. |
| [#102 Sonos volume slider goes stale: the discovery-cached volume is preferred over newer values and re-applied on every merge](https://github.com/stappmus/Omarchy-Spotify/issues/102) | Open | W5: fresh receiver volume outranks discovery cache; bound optimistic hold. |
| [#103 Service.qml: TypeError reading sessionFileReady of null when ensureStateDir exits after a plugin reload](https://github.com/stappmus/Omarchy-Spotify/issues/103) | Open | W1: #104 teardown guard and delayed-completion regression. |
| [#106 Service stuck on "Checking local playback" — pluginDir empty because Omarchy hands third-party services a manifest with __sourceDir stripped](https://github.com/stappmus/Omarchy-Spotify/issues/106) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#107 Omarchy 4.0.4 plugin sandboxing: stuck on "Checking local playback" (empty pluginDir) and Omasing never detected](https://github.com/stappmus/Omarchy-Spotify/issues/107) | Open | W1: directory repair plus separate Omasing detection repair; do not close after only one. |
| [#110 Default client ID never checks the saved session on startup](https://github.com/stappmus/Omarchy-Spotify/issues/110) | Open | W2: initialize session lookup for unchanged valid identities; settle absent-session path. |
| [#111 Plugin does nothing on Omarchy 4.0.4: pluginDir is empty](https://github.com/stappmus/Omarchy-Spotify/issues/111) | Open | W1: canonical directory fix via #75; verify readiness and restart before closing duplicate reports. |
| [#114 Missing something](https://github.com/stappmus/Omarchy-Spotify/issues/114) | Open | W1/W2: retest after host/auth fixes; retain as support case until actual failure is identified. |
| [#115 The documented redirect URI is now rejected by Spotify, and there is no way to configure a different one](https://github.com/stappmus/Omarchy-Spotify/issues/115) | Open | W3: reconcile conflicting dashboard reports; validate exact redirect and configurable callback. |
| [#117 Clicking a song in Library → Songs (Liked Songs) plays only that track, then stops](https://github.com/stappmus/Omarchy-Spotify/issues/117) | Open | W6: reproduce QML sequence boundary and restore displayed-list playback. |
| [#118 Spotify sign-in fails with a misleading error when port 8989 is in use (Sonarr's default port)](https://github.com/stappmus/Omarchy-Spotify/issues/118) | Open | W3: retained Web API listener and specific port-conflict error. |
| [#120 Sign-in with the shipped client ID fails with "redirect_uri: Not matching configuration" (ncspot changed its callback path)](https://github.com/stappmus/Omarchy-Spotify/issues/120) | Open | W2: retire borrowed Web API identity, provide personal-app setup and migration. |
| [#123 Settings in the new centerBegin/centerEnd bar sections are ignored (custom clientId falls back to shipped ID)](https://github.com/stappmus/Omarchy-Spotify/issues/123) | Open | W1: combine #124 with public settings fallback; test every layout section. |

### Open pull requests

| Item | Snapshot | Disposition |
| --- | --- | --- |
| [#20 Add settings option to disable artwork download and display](https://github.com/stappmus/Omarchy-Spotify/pull/20) | Open; `79f62329` | W6 verify implemented master artwork switch and schema behavior, then retire stale PR. |
| [#26 Fetch the real artist discography, and let the artist page be personalized](https://github.com/stappmus/Omarchy-Spotify/pull/26) | Open; `5d7700fb` | W8 discography core already recorded on main; split remaining configurable columns. |
| [#37 Restore playback state after session reconnects](https://github.com/stappmus/Omarchy-Spotify/pull/37) | Draft; `ea6939bc` | W7 draft, blocked on exact dependency-owned queue/shuffle snapshot contract. |
| [#40 Wake idle local playback instead of sending NO_ACTIVE_DEVICE](https://github.com/stappmus/Omarchy-Spotify/pull/40) | Open; `699fc8fb` | W6/W7 targeted local wake already recorded; verify current intent/target guards, then retire. |
| [#44 Restore the bindings.lua instructions for Super+Shift+M](https://github.com/stappmus/Omarchy-Spotify/pull/44) | Open; `63842cc1` | W8 manual keybinding documentation already present; verify and retire. |
| [#49 Cache Spotify search results by type](https://github.com/stappmus/Omarchy-Spotify/pull/49) | Open; `e033ff92` | W6 corrected search caching/cancellation already recorded; verify and retire. |
| [#50 feat: built-in synced lyrics and album art zoom](https://github.com/stappmus/Omarchy-Spotify/pull/50) | Open; `14fb6d80` | W9 split optional lyrics/zoom; preserve Omasing and finish lifecycle/provider tests. |
| [#54 Keep nearby Connect speakers when Avahi resolve is slow](https://github.com/stappmus/Omarchy-Spotify/pull/54) | Open; `7372dcd7` | W6 partial discovery bytes handling already recorded; verify and retire. |
| [#59 Add keyboard-first Spotify queue launcher](https://github.com/stappmus/Omarchy-Spotify/pull/59) | Open; `9c644f2b` | W9 rebase/split; acknowledged queue progression, isolated search and current IPC. |
| [#67 Report playback OAuth port conflicts before authorization](https://github.com/stappmus/Omarchy-Spotify/pull/67) | Draft; `da29a91f` | W3 draft, dependency-blocked; replace temporary fork pin and test packaged path independently. |
| [#75 Resolve plugin directory without private manifest fields](https://github.com/stappmus/Omarchy-Spotify/pull/75) | Open; `0db356e3` | W1 canonical directory patch; add sanitized-host integration and escaped-path tests. |
| [#78 Add a local playback output selector](https://github.com/stappmus/Omarchy-Spotify/pull/78) | Open; `fb1cb8e8` | W1 extract settings prerequisite; W9 output selector after host/runtime validation. |
| [#79 Distinguish unverified release assets from unavailable ones](https://github.com/stappmus/Omarchy-Spotify/pull/79) | Open; `a32adf2d` | W4 adapt diagnostic classification; add committed tests and correct fallback-source claim. |
| [#81 Read widget settings from barConfig when shellConfig is absent](https://github.com/stappmus/Omarchy-Spotify/pull/81) | Open; `271dc5d6` | W1 canonical settings fallback candidate; equivalent to #119, integrate once with #124. |
| [#82 Fix third-party service script path](https://github.com/stappmus/Omarchy-Spotify/pull/82) | Open; `66d33455` | W1 duplicate directory patch; use #75 once, retain attribution and close as superseded after delivery. |
| [#83 Resolve plugin dir and settings without first-party host internals](https://github.com/stappmus/Omarchy-Spotify/pull/83) | Open; `4ea5ce81` | W1 split/supersede with canonical path/settings fixes; current path helper omits URL decoding. |
| [#86 Fix personal client ID forcing re-login after every restart](https://github.com/stappmus/Omarchy-Spotify/pull/86) | Open; `1c584a22` | W2 revise: public-config readiness, waiters and startup restore are incomplete. |
| [#87 fix: open the local-playback authorization URL instead of discarding it](https://github.com/stappmus/Omarchy-Spotify/pull/87) | Open; `b7bbfacf` | W3 investigate browser ownership/readiness across both runtimes; do not blindly open every URL line. |
| [#90 Fix third-party plugin script path resolution](https://github.com/stappmus/Omarchy-Spotify/pull/90) | Open; `9da6e38b` | W1 duplicate directory patch; use #75 once, retain attribution and close as superseded after delivery. |
| [#91 feat(sidebar): show a usable library in the compact rail](https://github.com/stappmus/Omarchy-Spotify/pull/91) | Open; `5cc58aa8` | W8 adapt compact rail; verify artwork-off, keyboard and scaling behavior. |
| [#92 Recover Spotify after Bluetooth transport stalls](https://github.com/stappmus/Omarchy-Spotify/pull/92) | Open; `042ebdd4` | W7 separate hardware recovery review; constrain affected streams and test restoration. |
| [#94 Fall back to the QML file directory when the shell strips manifest.__sourceDir](https://github.com/stappmus/Omarchy-Spotify/pull/94) | Open; `4a5853a2` | W1 duplicate directory patch; use #75 once, retain attribution and close as superseded after delivery. |
| [#99 fix(service): fallback pluginDir resolution when manifest.__sourceDir is stripped](https://github.com/stappmus/Omarchy-Spotify/pull/99) | Open; `dd63fe02` | W1 duplicate directory patch; use #75 once, retain attribution and close as superseded after delivery. |
| [#104 fix(service): guard ensureStateDir.onExited after teardown](https://github.com/stappmus/Omarchy-Spotify/pull/104) | Open; `6c0aa50a` | W1 small guard candidate; add teardown acceptance without overstating reproducibility. |
| [#105 fix(service): detect and launch Omasing lyrics under host shell isolation](https://github.com/stappmus/Omarchy-Spotify/pull/105) | Open; `83a0dad8` | W1 revise XDG paths and installed/enabled truth; split no-track lyrics behavior. |
| [#112 Fix setup stalling at "Checking local playback" when the host strips __sourceDir](https://github.com/stappmus/Omarchy-Spotify/pull/112) | Open; `501ce365` | W1 duplicate directory patch; use #75 once, retain attribution and close as superseded after delivery. |
| [#113 Fix the keyboard shortcut doing nothing when shortcutPlayer is "Mini player"](https://github.com/stappmus/Omarchy-Spotify/pull/113) | Open; `4d437e05` | W1 candidate with popup focus, monitor routing and teardown checks. |
| [#116 Reduce "Spotify is busy" errors by polling playback less often](https://github.com/stappmus/Omarchy-Spotify/pull/116) | Open; `e435a4da` | W6 revise follow-up polling lifecycle, quota behavior and deduplication. |
| [#119 Read settings from barConfig when the host withholds shellConfig](https://github.com/stappmus/Omarchy-Spotify/pull/119) | Open; `71bec41b` | W1 equivalent to #81; retain attribution and close redundant proposal after integrated fix. |
| [#121 Keep the full player loaded between opens](https://github.com/stappmus/Omarchy-Spotify/pull/121) | Open; `338424d0` | W8 conditional candidate: measure latency, retained memory and hidden work before adoption. |
| [#122 Document that sign-in needs a personal Spotify Developer app](https://github.com/stappmus/Omarchy-Spotify/pull/122) | Open; `2e456cfd` | W2 adapt docs with actual missing-ID UX and working settings/session lifecycle. |
| [#124 Find settings in every bar layout section (Omarchy 4.5 centerBegin/centerEnd)](https://github.com/stappmus/Omarchy-Spotify/pull/124) | Open; `fc223c08` | W1 candidate with #81/#119; test future/array-like layout sections. |

### Closed issues and regression coverage

| Item | Snapshot | Disposition |
| --- | --- | --- |
| [#1 Spotify Premium](https://github.com/stappmus/Omarchy-Spotify/issues/1) | Closed | Retain clear Premium requirement; W7 runtime classification. |
| [#4 Keyboard shortcuts for opening mini/full player?](https://github.com/stappmus/Omarchy-Spotify/issues/4) | Closed | Retain shortcuts; W1 public-bar API regression. |
| [#5 Volume and Playback slider visual position resets to original position after changing volume or playback](https://github.com/stappmus/Omarchy-Spotify/issues/5) | Closed | Retain optimistic seek/volume reconciliation; W5 remote freshness regression. |
| [#6 The "Like" button should also be included in the mini widget and the now-playing bar.](https://github.com/stappmus/Omarchy-Spotify/issues/6) | Closed | Retain current-track Save controls; distinguish #51 row behavior. |
| [#8 Backend socket never connects after fresh install — track playback falls back to Web API and takes ~10s](https://github.com/stappmus/Omarchy-Spotify/issues/8) | Closed | Retain Socket recreation/retry on fresh install and backend restart. |
| [#9 Multiple errors](https://github.com/stappmus/Omarchy-Spotify/issues/9) | Closed | Retain cooldown and empty/error collection distinctions; W6 regression. |
| [#11 Not playing songs](https://github.com/stappmus/Omarchy-Spotify/issues/11) | Closed | Retain two-stage setup and credentials migration. |
| [#13 Skip/Ban button feature request](https://github.com/stappmus/Omarchy-Spotify/issues/13) | Closed | No supported recommendation-feedback implementation planned; retain deferred disposition. |
| [#14 Playlist does not load all songs](https://github.com/stappmus/Omarchy-Spotify/issues/14) | Closed | Retain playlist pagination beyond 200 entries. |
| [#15 Sort from new to old date added feature request](https://github.com/stappmus/Omarchy-Spotify/issues/15) | Closed | Retain date-added sorting and unknown-date handling. |
| [#18 session state stored in shell.json](https://github.com/stappmus/Omarchy-Spotify/issues/18) | Closed | Retain session state outside shell.json and migration. |
| [#19 api disconnects and music stops.](https://github.com/stappmus/Omarchy-Spotify/issues/19) | Closed | Retain session supervisor; W7 covers remaining recovery. |
| [#23 Playlist playback ignores the displayed sort order](https://github.com/stappmus/Omarchy-Spotify/issues/23) | Closed | Retain displayed sort order and duplicate occurrence playback; W6 regression. |
| [#24 "Stop Music" Button](https://github.com/stappmus/Omarchy-Spotify/issues/24) | Closed | Retain paused-label preferences; local Stop is distinct #68. |
| [#27 High CPU usage after latest update](https://github.com/stappmus/Omarchy-Spotify/issues/27) | Closed | Retain build/runtime resource distinction and verified-install path; W4. |
| [#33 Install command???](https://github.com/stappmus/Omarchy-Spotify/issues/33) | Closed | Retain prominent install instructions. |
| [#34 build-backend.sh pins --source-digest to HEAD, so attested release never verifies when main is ahead of the version tag](https://github.com/stappmus/Omarchy-Spotify/issues/34) | Closed | Retain tag-bound source digest; distinct missing-tag failure is #74. |
| [#35 [Bug] Spotify doesn't remember playlist state after closing - have to click "Show more" every time](https://github.com/stappmus/Omarchy-Spotify/issues/35) | Closed | Retain collection depth/scroll across close/reopen; W8 regression. |
| [#43 Super+Shift+M player setting is not wired to Omarchy's stock Music keybinding](https://github.com/stappmus/Omarchy-Spotify/issues/43) | Closed | Manual keybinding instructions present; verify #44 equivalence, no automatic dotfile edit. |
| [#47 Fix responsive layout overflow and compact navigation alignment](https://github.com/stappmus/Omarchy-Spotify/issues/47) | Closed | Responsive layout already addressed; W8 compact rail is additional work. |
| [#60 Transport controls are dropped after a librespot reconnect (SpircCommand::Play ignored while Not Active)](https://github.com/stappmus/Omarchy-Spotify/issues/60) | Closed | Closed duplicate; remaining recovery tracked in #61. |
| [#62 Bar icon (fa-spotify U+F1BC) renders taller than the rest of the Omarchy bar icons](https://github.com/stappmus/Omarchy-Spotify/issues/62) | Closed | Retain optical glyph sizing across fonts/scaling. |
| [#70 Discover tab hides the user's own Made For You playlists (Discover Weekly, Daily Mixes, daylist)](https://github.com/stappmus/Omarchy-Spotify/issues/70) | Closed | Retain API-limitation disposition; no promise that personal Made For You data is available. |
| [#76 Would you accept a per-app output selector for local playback?](https://github.com/stappmus/Omarchy-Spotify/issues/76) | Closed | Closed proposal moved to #78; feature remains planned in W9. |
| [#108 Local playback always reports "Approve playback" on Omarchy 4.0.4: pluginDir empty because __sourceDir is stripped](https://github.com/stappmus/Omarchy-Spotify/issues/108) | Closed | Closed duplicate; W1 fixes remaining main-branch directory failure. |

### Merged and closed pull requests

| Item | Snapshot | Disposition |
| --- | --- | --- |
| [#2 Use theme accent for bar icon while playing](https://github.com/stappmus/Omarchy-Spotify/pull/2) | Merged; `7262b2de` | Retain theme-accent playback indicator. |
| [#3 Add configurable artist and scrolling text to Spotify bar](https://github.com/stappmus/Omarchy-Spotify/pull/3) | Merged; `af1b54fb` | Retain independent title/artist and scrolling preferences. |
| [#7 Build plugin backend outside the plugin directory to stop hot-reload crashes](https://github.com/stappmus/Omarchy-Spotify/pull/7) | Merged; `a7bf203b` | Retain external build directory to prevent hot reload during builds. |
| [#10 Add a Quit action to the mini player](https://github.com/stappmus/Omarchy-Spotify/pull/10) | Closed; `dba924ee` | Closed unmerged; preserve implemented local Stop without reviving rejected footer placement. |
| [#12 Expose Spotify volume controls over shell IPC](https://github.com/stappmus/Omarchy-Spotify/pull/12) | Merged; `b33959d0` | Retain volume IPC names and step sizes through shared handler. |
| [#17 Fix bar label clipping and make the bar text width adjustable](https://github.com/stappmus/Omarchy-Spotify/pull/17) | Merged; `fdf75dec` | Retain clipping and bar-width normalization. |
| [#21 Fix Spotify widget colors on transparent bar](https://github.com/stappmus/Omarchy-Spotify/pull/21) | Merged; `622bd7a1` | Retain transparent-theme contrast. |
| [#22 Improve Spotify search reliability and navigation](https://github.com/stappmus/Omarchy-Spotify/pull/22) | Closed; `d643771e` | Closed unmerged split request; transport merged and caching/navigation subsequently recorded on main. |
| [#25 Add optional spinning vinyl artwork to the mini-player](https://github.com/stappmus/Omarchy-Spotify/pull/25) | Closed; `a34bf639` | Closed unmerged; corrected optional vinyl implementation recorded on main. Preserve artwork master gating. |
| [#29 Align Spotify controls with the Omarchy icon grid](https://github.com/stappmus/Omarchy-Spotify/pull/29) | Merged; `d9ecc02b` | Retain shared transport targets and icon alignment. |
| [#30 Keep paused Spotify sessions advertised and resumable](https://github.com/stappmus/Omarchy-Spotify/pull/30) | Merged; `e43a3c98` | Retain paused metadata and resumability; do not confuse Pause with Stop. |
| [#31 Apply volume live while dragging the slider](https://github.com/stappmus/Omarchy-Spotify/pull/31) | Merged; `b575be65` | Retain live coalesced volume and final value; release-only seek. |
| [#32 Make Omarchy Spotify fully uninstallable](https://github.com/stappmus/Omarchy-Spotify/pull/32) | Merged; `785def5a` | Retain complete removal; expand inventory for new optional helpers. |
| [#36 Retry artwork downloads after transient network failures](https://github.com/stappmus/Omarchy-Spotify/pull/36) | Closed; `7f06e7a2` | Closed unmerged; bounded RetryImage behavior recorded on main; retain hidden/off gating. |
| [#38 Harden Spotify API request transport](https://github.com/stappmus/Omarchy-Spotify/pull/38) | Merged; `5163a46c` | Merged transport baseline; preserve queue/timeout/cancellation behavior. |
| [#46 Add a setting to hide the lyrics button](https://github.com/stappmus/Omarchy-Spotify/pull/46) | Closed; `59784a54` | Closed unmerged; optional lyrics setting recorded on main; preserve shortcut/UI consistency. |
| [#48 Fix responsive layout at narrow panel widths](https://github.com/stappmus/Omarchy-Spotify/pull/48) | Closed; `37f3ca5e` | Closed unmerged; responsive work recorded on main; W8 regression. |
| [#55 Keep the last played song loaded for Play](https://github.com/stappmus/Omarchy-Spotify/pull/55) | Closed; `6c48da66` | Closed unmerged; corrected last-track candidate recorded; retain empty/error throttles. |
| [#56 Add a fixed bar width setting](https://github.com/stappmus/Omarchy-Spotify/pull/56) | Closed; `c2c690e7` | Closed unmerged; fixed-width preference recorded; retain icon-only sizing. |
| [#57 Keep in-panel popups opaque on translucent themes](https://github.com/stappmus/Omarchy-Spotify/pull/57) | Closed; `ac00fb47` | Closed unmerged; opaque internal popup behavior recorded; retain theme tests. |
| [#58 feat: allow per-user Spotify client ID to opt out of shared rate limits](https://github.com/stappmus/Omarchy-Spotify/pull/58) | Closed; `687c82e8` | Closed unmerged; client-isolation implementation recorded, but W1/W2 fixes still required. |
| [#64 Honor server Retry-After delays above 30 seconds](https://github.com/stappmus/Omarchy-Spotify/pull/64) | Closed; `d1b6b756` | Closed unmerged; full Retry-After behavior recorded; preserve bounds. |
| [#65 Activate the local receiver before backend transport controls](https://github.com/stappmus/Omarchy-Spotify/pull/65) | Closed; `c9318a28` | Closed unmerged; explicit local ownership dispatch recorded; not exact context restoration. |
| [#66 Explain search deadlines blocked by Spotify cooldowns](https://github.com/stappmus/Omarchy-Spotify/pull/66) | Closed; `190d158d` | Closed unmerged; cooldown-aware search deadlines recorded; preserve message distinctions. |
| [#71 Add a playback watchdog that recovers a silent native backend](https://github.com/stappmus/Omarchy-Spotify/pull/71) | Closed; `331fe065` | Closed unmerged watchdog; W7 reevaluates bounded recovery only if still reproducible. |
| [#77 Resolve the plugin directory from the component URL](https://github.com/stappmus/Omarchy-Spotify/pull/77) | Closed; `97afcba1` | Closed unmerged path prerequisite folded into #78; use W1 canonical fix. |
| [#95 Fix pluginDir being empty on third-party installs](https://github.com/stappmus/Omarchy-Spotify/pull/95) | Closed; `afa00b64` | Closed unmerged directory duplicate; canonical #75 in W1. |
| [#96 Fall back to loaded file location for plugin directory](https://github.com/stappmus/Omarchy-Spotify/pull/96) | Closed; `f6d6db15` | Closed unmerged directory duplicate; canonical #75 in W1. |
| [#109 Fall back to the plugin's own directory when the host omits it](https://github.com/stappmus/Omarchy-Spotify/pull/109) | Closed; `8591bf3d` | Closed unmerged as duplicate of #75; no evidence main contains directory repair. |
