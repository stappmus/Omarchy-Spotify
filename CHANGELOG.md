# Changelog

## Unreleased

- Add a Quit action to the mini-player footer that pauses playback and stops
  the backend, so closing the window no longer leaves music playing with no
  obvious way to stop it short of the idle timeout.

- Finish installing Omasing after the shell reloads. Adding the plugin writes
  into the plugin directory, which used to kill the installer before the
  lyrics widget could be enabled.

- Recreate the local playback socket after a failed first connect, so a
  fresh install does not wait on Spotify's Web API to start a track.
- Say when a track starts through Spotify because the local socket was
  not ready.
- Retry Spotify 429 responses after Retry-After, and keep at most two API
  calls in flight so development-mode apps hit the rate limit less often.
- Explain empty playlists when Spotify withholds tracks or the list
  failed to load.

- Open the first-run setup from the mini-player, show login progress and
  errors there, and let you cancel a stuck browser approval.
- Unlock browsing after the Spotify account connects, instead of waiting for
  local playback approval, and keep playback setup in the background.
- Play on this computer through the backend socket instead of waiting for
  Spotify to list the device. The Web API remains the fallback.
- Apply Settings immediately, hide search on the Settings page, and rename
  the keyboard-shortcut default to Omarchy Music app.
- Poll remote playback only when a speaker is active or the target is unknown,
  and start the local receiver only when you play here, choose this computer,
  or keep it available with 0 idle minutes.
- Reuse the last local speaker discovery for Sonos controls instead of
  browsing the LAN for every volume or seek command.
- Show where music is playing in the full player, humanize repeat and sleep
  labels, add lyrics shortcut parity, and fill empty queue, devices, and
  search states.
- Escape leaves Settings or Devices and returns to the last real page,
  skipping those menus in the back path, so closing the window still takes
  two Esc presses after you are back on a normal page.

- Build the plugin-owned backend's Cargo artifacts in
  `$XDG_CACHE_HOME/omarchy-spotify/target` instead of the plugin directory.
  Omarchy hot-reloads a plugin whenever any file inside it changes, so the old
  in-place `backend/target/` triggered a reload loop that killed the first-run
  setup build and restarted the bar before the backend could be installed.
- Drop a stale `tests/test-scripts.sh` assertion that expected the spotifyd
  fallback unit to carry the plugin backend's `TOKIO_WORKER_THREADS` setting.
- Replace the spotifyd runtime with a plugin-owned Rust backend that embeds a
  commit-pinned librespot engine, exports MPRIS, and exposes a versioned private
  Unix-socket API. Keep the existing spotifyd unit as a reversible fallback.
- Preserve the 1 GB audio cache and existing playback credential, and move
  local playback authorization into the plugin backend.
- Smooth manual song changes inside the pinned playback engine with the
  endpoint-continuous 20 ms ramp proposed upstream, while retaining natural
  gapless transitions.
- Cut the playback backend to a current-thread control runtime plus two tested
  player workers, publish position at the UI's one-second cadence, and suppress
  duplicate state, unused queue, and heuristic seek events. Bound local command
  buffering so a misbehaving client cannot grow backend memory without limit,
  and give each MPRIS process a collision-safe instance name.
- Link only the required librespot crates and tighten the release profile. The
  resulting backend is 9.12 MiB on the reference host, with a live playback
  median of 16.77 MiB PSS / 26.09 MiB RSS.
- Keep remote seek and volume sliders at their requested values while Spotify
  acknowledges the command, and prevent stale device-list volume data from
  snapping an active speaker's slider back.
- Launch playback-runtime checks only after the plugin directory is available,
  preventing an already-connected account from reopening on the setup screen
  after a full Quickshell restart.
- Add a configurable Omarchy Spotify keyboard action that cycles between the
  original Omarchy music launcher, full player, and mini-player, including
  explicit IPC actions for each Spotify surface.
- Give the mini-player keyboard focus, visible control selection, and complete
  keyboard operation for playback, seeking, volume, likes, lyrics, and opening
  the full player.
- Connect JBL access-token speakers such as Bar 800 by sending the streaming
  token directly. Spotify's device-auth mint is now only a fallback, because a
  non-JSON reply was aborting activation before the speaker was contacted.

## 1.0.2 — 2026-08-15

### Features

- Like or remove the currently playing song from Liked Songs directly beside
  its title in both the full player and the bar mini-player.
- Always open the mini-player on a normal bar-icon click, including while a
  refreshed shell is restoring Spotify state, with a preference to open the
  full player directly instead.
- Independently show the artist or song title in the bar, scroll long bar text
  so the complete label remains readable, and adjust its speed from 0.25× to
  3×. Scrolling turns off automatically when both text fields are hidden, and
  stopping it restores the label to its starting position.
- Replace separate Spotify, artist, and collection search fields with one
  context-aware search bar throughout the app. The checked **In …** control
  filters the open area and can be unchecked to search all of Spotify.
- Add Spotify-style shortcuts for search, navigation, playback, seeking,
  shuffle, repeat, mute, and volume, plus shortcut hints on matching controls.
- Add a themed, scrollable keyboard-shortcut reference with `Ctrl+/`; playback
  shortcuts automatically pause while typing in a text field.
- Open artists directly from every artist label, including individual artists
  on collaborations, album headers, media rows, and both players.
- Open the current song directly in Omasing Lyrics from either player, passing
  the exact recording metadata and playback position so lyrics can load without
  another search and open near the current line.
- Ask before installing and enabling Omasing when the optional lyrics plugin is
  missing, with progress, retryable errors, and an explicit unsandboxed-plugin
  notice.
- Move playlist creation into a focused popup opened by the **+** beside
  Playlists in the sidebar.
- Rearrange songs in owned playlists by dragging their cards while using the
  original playlist order, with edge auto-scroll and immediate feedback while
  Spotify saves the new order.
- Give artist-scoped searches a dedicated responsive results page for songs,
  albums, and playlists, hiding empty categories instead of retaining the
  artist-home layout.

### Refinements

- Fade overflowing bar text at its viewport edges, organize preferences into
  clearer groups, hide completed playback setup, and place new installations
  in the left bar section by default.
- Streamline the sidebar by removing the redundant Search and Devices entries.
  Search is available from the shared header, while Devices remains beside the
  volume slider and is also available through `Alt+Shift+D`.
- Make Escape dismiss popups and clear search first, then use a theme-colored
  close-button warning before a second Escape closes the window.
- Preserve universal-search results and their underlying page when opening an
  item and going Back, and prevent an old query from covering Settings or a
  newly selected page.
- Release keyboard focus from search as soon as a selected song starts playing,
  so playback shortcuts work immediately.
- Keep this computer available in Spotify Connect while the mini player or full
  app is open, waking local playback and refreshing its device registration when
  either surface appears.
- Automatically select this computer when it is already the active player and
  no device was selected, while continuing to preserve an active remote target.
- Keep podcast, show, and audiobook subtitles as plain text instead of treating
  them as artist links.
- Move an already-open full player to the current workspace when opening it
  from the mini player, without requiring a second click.
- Polish the shortcut reference with theme-native borders, enough room for its
  scrollbar, and stable section sizing without layout-binding warnings.
- Collapse a song row's secondary actions behind an expand button whenever
  showing them would truncate its title.

## 1.0.1 — 2026-08-13

- Use Omarchy Spotify consistently as the product name.
- Document the user-initiated, narrowly scoped playback setup and its exact
  privileged package-install command.

- Show active playback from remote Spotify Connect devices, including Sonos
  players omitted from Spotify's available-device response or reported without
  a device id.
- Activate Sonos and other authorization-code receivers with their advertised
  OAuth flow instead of sending an incompatible reusable-credential blob.
- Mark restricted active devices clearly and avoid sending controls that the
  Spotify Web API will reject.
- Keep new song selections on the currently active Spotify Connect device,
  falling back to this computer only when no device is active.
- Control locally discovered Sonos playback, seeking, modes, and volume over
  its fixed LAN endpoints when Spotify marks the device restricted.
- Keep the remote volume slider visible when Spotify omits its nullable volume
  reading, including an authoritative local volume read for Sonos.
- Reconnect to a previously authorized Sonos by waking its retained session,
  with transient receiver retries and OAuth activation as fallback.
- Show locally advertised aliases for active speakers whose Spotify API name is
  only an opaque device id, and honor JBL-style access-token activation.

## 1.0.0 — 2026-08-12

First public release for Omarchy 4.

- Full Spotify home, search, library, playlist, queue, and detail views.
- Artist pages with Spotify's **This Is** playlist directly above releases,
  a full top 10 songs loaded across Spotify result pages, and artist-specific
  search.
- Dedicated Discover tab for official personal mixes and fresh Spotify playlists.
- Local on-demand playback plus Spotify Connect device switching.
- Guided first-run setup and browser sign-in from one user-facing flow.
- Playlist editing, track radio, saved items, recent searches, and sleep timers.
- One-click song-to-playlist picking and safe conversion of followed playlists.
- Playlist menus fit long actions cleanly; unused playlist pinning was removed.
- Escape/focus-loss menu dismissal and context-menu-only library removal.
- Very high (320 kbps) audio quality by default.
- Device-name changes update the Devices view immediately without losing the
  local playback target.
- Track artist and album labels stay together and truncate cleanly on artist pages.
- Theme-native bar popup and full app with compact tiled-window navigation.
- Keyring-backed sessions, PKCE sign-in, credential redaction, and loopback-only callbacks.
- Offline QML and script tests plus documented resource benchmarks.
