import QtQuick
import QtTest

import "../Api.js" as Api

TestCase {
  name: "SpotifyApiLogic"

  function test_queryString_isStableAndEncoded() {
    compare(Api.queryString({ z: "last", q: "AC/DC & friends", empty: "" }),
      "q=AC%2FDC%20%26%20friends&z=last")
  }

  function test_barTrackText_respectsIndependentTitleAndArtistSettings() {
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, false,
      true, true),
      "Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", false, true,
      true, true),
      "Miles Davis")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      true, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", false, false,
      true, true), "")
    compare(Api.barTrackText("  Blue in Green  ", "  Miles Davis  ", true,
      true, true, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "", true, true, true, true),
      "Blue in Green")
    compare(Api.barTrackText("", "Miles Davis", true, true, true, true),
      "Miles Davis")
  }

  function test_barTrackText_pausedVisibilityIsConfigurable() {
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      false, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      false, false), "")
  }

  function test_idleShutdown_onlyRunsForAnEmptyReceiver() {
    verify(Api.idleShutdownShouldRun(true, false, false, 15))
    verify(!Api.idleShutdownShouldRun(true, true, false, 15))
    verify(!Api.idleShutdownShouldRun(true, false, true, 15))
    verify(!Api.idleShutdownShouldRun(false, false, false, 15))
    verify(!Api.idleShutdownShouldRun(true, false, false, 0))
  }

  function test_scrollAvailability_requiresAtLeastOneBarLabel() {
    verify(Api.canScrollBarText(true, true))
    verify(Api.canScrollBarText(true, false))
    verify(Api.canScrollBarText(false, true))
    verify(!Api.canScrollBarText(false, false))
  }

  function test_normalizedMaxBarTextWidth_defaultsClampsAndSnaps() {
    compare(Api.normalizedMaxBarTextWidth(undefined), 240)
    compare(Api.normalizedMaxBarTextWidth(null), 240)
    compare(Api.normalizedMaxBarTextWidth(""), 240)
    compare(Api.normalizedMaxBarTextWidth("nonsense"), 240)
    compare(Api.normalizedMaxBarTextWidth(-40), 240)
    // 0 is the uncapped sentinel and must survive normalization untouched.
    compare(Api.normalizedMaxBarTextWidth(0), 0)
    compare(Api.normalizedMaxBarTextWidth("0"), 0)
    compare(Api.normalizedMaxBarTextWidth(240), 240)
    compare(Api.normalizedMaxBarTextWidth(247), 240)
    compare(Api.normalizedMaxBarTextWidth(265), 280)
    compare(Api.normalizedMaxBarTextWidth(10), 160)
    compare(Api.normalizedMaxBarTextWidth(9999), 560)
  }

  function test_barTextWidthSlider_notchesCoverEveryNormalizedWidth() {
    var slider = Api.barTextWidthSlider()
    // The uncapped notch must sit past every real width, so no stored value can
    // normalize onto it and be mistaken for "unlimited".
    for (var i = 0; i < slider.ticks; i++) {
      var stop = slider.min + i * slider.step
      if (stop === slider.unlimited) continue
      compare(Api.normalizedMaxBarTextWidth(stop), stop)
    }
    compare(slider.min + (slider.ticks - 1) * slider.step, slider.unlimited)
    verify(Api.normalizedMaxBarTextWidth(slider.unlimited) < slider.unlimited)
    compare(Api.normalizedMaxBarTextWidth(240), 240)
  }

  function test_normalizedScrollSpeed_defaultsClampsAndSnaps() {
    compare(Api.normalizedScrollSpeed(undefined), 1)
    compare(Api.normalizedScrollSpeed("not-a-speed"), 1)
    compare(Api.normalizedScrollSpeed(0), 0.25)
    compare(Api.normalizedScrollSpeed(4), 3)
    compare(Api.normalizedScrollSpeed(1), 1)
    compare(Api.normalizedScrollSpeed(1.12), 1)
    compare(Api.normalizedScrollSpeed(1.13), 1.25)
  }

  function test_cacheFreshnessAndSleepDeadline_boundaries() {
    verify(Api.timestampIsFresh(1000, 5999, 5000))
    verify(!Api.timestampIsFresh(1000, 6000, 5000))
    verify(!Api.timestampIsFresh(1000, 999, 5000))
    verify(!Api.timestampIsFresh(0, 1000, 5000))

    compare(Api.deadlineRemainingSeconds(2501, 1000), 2)
    compare(Api.deadlineRemainingSeconds(2000, 1000), 1)
    compare(Api.deadlineRemainingSeconds(999, 1000), 0)
    compare(Api.deadlineRemainingSeconds("invalid", 1000), 0)
  }

  function test_boundedOrder_mutatesInPlaceAndEvictsOldestKeys() {
    var order = ["one", "two", "three"]
    var sameOrder = order
    compare(Api.touchBoundedOrder(order, "two", 3), "")
    verify(order === sameOrder)
    compare(order, ["one", "three", "two"])

    compare(Api.touchBoundedOrder(order, "four", 3), "one")
    compare(order, ["three", "two", "four"])
    compare(Api.touchBoundedOrder(order, "", 3), "")
  }

  function test_filteredSorted_reusesTheUnchangedDefaultList() {
    var rows = [{ name: "One" }, { name: "Two" }]
    verify(Api.filteredSorted(rows, "", "default") === rows)
    verify(Api.filteredSorted(rows, " two ", "default") !== rows)
    compare(Api.filteredSorted(rows, " two ", "default"), [rows[1]])
    compare(Api.filteredSorted([rows[0], null, rows[1]], "", "default"), rows)
  }

  function test_spotifydVolumeCurve_hasStableEndpointsAndRoundTrips() {
    compare(Api.spotifydVolumeToSlider(0), 0)
    compare(Api.spotifydVolumeToSlider(1), 1)
    compare(Api.sliderToSpotifydVolume(0), 0)
    compare(Api.sliderToSpotifydVolume(1), 1)

    var positions = [0.01, 0.1, 0.25, 0.5, 0.75, 0.9]
    for (var i = 0; i < positions.length; i++) {
      var slider = positions[i]
      var backend = Api.sliderToSpotifydVolume(slider)
      verify(Math.abs(Api.spotifydVolumeToSlider(backend) - slider) < 0.000001)
    }
  }

  function test_spotifydVolumeCurve_usesGentlerCubicTaper() {
    var backendMidpoint = Api.sliderToSpotifydVolume(0.5)
    verify(backendMidpoint > 0.73 && backendMidpoint < 0.75)
    verify(Api.spotifydVolumeToSlider(0.5) < 0.25)
  }

  function test_normalizeVolumePercent_preservesUnknownAndValidMute() {
    compare(Api.normalizeVolumePercent(null), null)
    compare(Api.normalizeVolumePercent(undefined), null)
    compare(Api.normalizeVolumePercent(""), null)
    compare(Api.normalizeVolumePercent("not-a-volume"), null)
    compare(Api.normalizeVolumePercent(0), 0)
    compare(Api.normalizeVolumePercent(47), 47)
    compare(Api.normalizeVolumePercent(120), 100)
  }

  function test_catalogSearchText_scopesResultsToArtist() {
    compare(Api.sanitizeSearchTerm("AC/DC \"Live\""), "AC/DC Live")
    compare(Api.catalogSearchText("Miles Davis", "blue in green"),
      "blue in green artist:\"Miles Davis\"")
    compare(Api.catalogSearchText("AC/DC \"Live\"", ""),
      "artist:\"AC/DC Live\"")
    compare(Api.artistPlaylistSearchText("Miles Davis", "blue in green"),
      "blue in green Miles Davis")
  }

  function test_volumeAndSeekHelpers_clampMuteAndRemember() {
    compare(Api.nextVolume(0.5, 0.1), 0.6)
    compare(Api.nextVolume(0.98, 0.1), 1)
    compare(Api.nextVolume(0.02, -0.1), 0)
    verify(Api.shouldRememberVolume(0.05))
    verify(!Api.shouldRememberVolume(0.001))
    compare(Api.unmuteVolume(0.4), 0.4)
    compare(Api.unmuteVolume(0), 0.05)
    compare(Api.seekPosition(10, 10, 183), 20)
    compare(Api.seekPosition(180, 10, 183), 183)
    compare(Api.seekPosition(5, -10, 183), 0)
    compare(Api.seekPosition(40, 10, 0), 50)
  }

  function test_volumeFlushInterval_slowsDownForNetworkBackends() {
    compare(Api.volumeFlushInterval("local"), Api.VOLUME_FLUSH_MS)
    compare(Api.volumeFlushInterval("remote"), Api.VOLUME_FLUSH_REMOTE_MS)
    compare(Api.volumeFlushInterval("sonos"), Api.VOLUME_FLUSH_SONOS_MS)
    compare(Api.volumeFlushInterval("SONOS"), Api.VOLUME_FLUSH_SONOS_MS)
    compare(Api.volumeFlushInterval(""), Api.VOLUME_FLUSH_MS)
    compare(Api.volumeFlushInterval(null), Api.VOLUME_FLUSH_MS)
    compare(Api.volumeFlushInterval("unknown"), Api.VOLUME_FLUSH_MS)
    verify(Api.VOLUME_FLUSH_REMOTE_MS > Api.VOLUME_FLUSH_SONOS_MS)
    verify(Api.VOLUME_FLUSH_SONOS_MS > Api.VOLUME_FLUSH_MS)
  }

  function test_pendingSliderVolumeHoldsUntilPlayerAcknowledgesIt() {
    var pending = { slider: 0.55, expiresAt: 9000 }
    verify(Api.pendingSliderVolumeShouldHold(0.5, pending, 2000))
    compare(Api.displayedSliderVolume(0.5, pending, 2000), 0.55)
    verify(!Api.pendingSliderVolumeShouldHold(0.55, pending, 2000))
    compare(Api.displayedSliderVolume(0.55, pending, 2000), 0.55)
    verify(!Api.pendingSliderVolumeShouldHold(0.5, pending, 9000))
    compare(Api.displayedSliderVolume(0.5, pending, 9000), 0.5)
    verify(!Api.pendingSliderVolumeShouldHold(0.5, null, 2000))
    compare(Api.SEARCH_DEBOUNCE_MS, 600)
    compare(Api.SEARCH_REQUEST_TIMEOUT_MS, 8000)
    compare(Api.VOLUME_FLUSH_MS, 80)
  }

  function test_shallowCopyAndAssign_copyWithoutSharingIdentity() {
    var source = { name: "Work", volume: 12 }
    var copy = Api.shallowCopy(source)
    compare(copy.name, "Work")
    verify(copy !== source)
    source.name = "Kitchen"
    compare(copy.name, "Work")
    compare(Api.assign({ a: 1 }, { b: 2, a: 3 }).a, 3)
    compare(Api.rateLimitSuffix("4"), ". Try again in 4 seconds.")
    compare(Api.rateLimitSuffix("1"), ". Try again in 1 second.")
    compare(Api.rateLimitSuffix(""), "")
    compare(Api.rateLimitMessage("1"), "Spotify is busy. Try again in 1 second.")
    compare(Api.rateLimitMessage(""), "Spotify is busy. Try again in a moment.")
    compare(Api.rateLimitRetryMs("4"), 4400)
    compare(Api.rateLimitRetryMs("0"), 1400)
    compare(Api.rateLimitRetryMs("1"), 1400)
    compare(Api.rateLimitRetryMs("1", 2), 4400)
    compare(Api.rateLimitRetryMs("120"), 30000)
    compare(Api.rateLimitRetryMs(""), 10000)
    compare(Api.rateLimitRetryMs("Wed, 21 Oct 2015 07:28:00 GMT"), 10000)
    compare(Api.apiCooldownMs(1000, 1500), 500)
    compare(Api.apiCooldownMs(1500, 1000), 0)
    compare(Api.nextRateLimitedUntil(1000, "2", 0), 3400)
    compare(Api.nextRateLimitedUntil(1000, "1", 4000), 4000)
    compare(Api.nextRateLimitedUntil(1000, "1", 0, 3), 9400)
    compare(Api.responseRetryAfter({
      getResponseHeader: function(name) {
        return name === "Retry-After" ? "10" : ""
      }
    }), "10")
    verify(Api.localSocketFallbackMessage().indexOf("local player") >= 0)
  }

  function test_apiRequestQueue_ordersMutationsAndSkipsAborted() {
    compare(Api.API_MAX_IN_FLIGHT, 2)
    compare(Api.API_MAX_RATE_LIMIT_RETRIES, 4)
    compare(Api.apiInFlightLimit(false), 2)
    compare(Api.apiInFlightLimit(true), 1)
    verify(Api.shouldRetryRateLimit(0))
    verify(Api.shouldRetryRateLimit(3))
    verify(!Api.shouldRetryRateLimit(4))
    verify(Api.apiRequestIsMutating("PUT"))
    verify(Api.apiRequestIsMutating("POST"))
    verify(!Api.apiRequestIsMutating("GET"))
    var queued = Api.enqueueApiJob([], { method: "GET", id: "one" })
    queued = Api.enqueueApiJob(queued, { method: "GET", id: "two" })
    queued = Api.enqueueApiJob(queued,
      { method: "GET", id: "search", priority: "interactive" })
    queued = Api.enqueueApiJob(queued, { method: "PUT", id: "play" })
    compare(queued[0].id, "play")
    compare(queued[1].id, "search")
    compare(queued[2].id, "one")
    compare(queued[3].id, "two")
    compare(Api.apiJobPriority(queued[0]), 2)
    compare(Api.apiJobPriority(queued[1]), 1)
    compare(Api.apiJobPriority(queued[2]), 0)
    queued = Api.enqueueApiJob(queued,
      { method: "GET", id: "search-two", priority: "interactive" })
    queued = Api.enqueueApiJob(queued, { method: "POST", id: "pause" })
    compare(queued[1].id, "pause")
    compare(queued[2].id, "search")
    compare(queued[3].id, "search-two")
    var skipped = Api.dequeueApiJob([
      { id: "stale", handle: { aborted: true } },
      { id: "live", handle: { aborted: false } }
    ])
    compare(skipped.job.id, "live")
    compare(skipped.queue.length, 0)
    compare(Api.dequeueApiJob([]).job, null)
  }

  function test_playlistItemsEmptyMessage_distinguishesHiddenAndFailedLists() {
    var own = { id: "own", ownerId: "user-1", collaborative: false }
    var followed = { id: "weekly", ownerId: "spotify", collaborative: false }
    compare(Api.playlistOwnedByUser(own, "user-1"), true)
    compare(Api.playlistOwnedByUser(followed, "user-1"), false)
    compare(Api.playlistItemsEmptyMessage(null, 0, "", 0, "user-1"), "")
    compare(Api.playlistItemsEmptyMessage(own, 3, "", 200, "user-1"), "")
    compare(Api.playlistItemsEmptyMessage(own, 0, "", 200, "user-1"),
      "This playlist has no visible items.")
    compare(Api.playlistItemsEmptyMessage(followed, 0, "", 200, "user-1"),
      Api.playlistItemsHiddenMessage())
    compare(Api.playlistItemsEmptyMessage(followed, 0, "Forbidden", 403, "user-1"),
      Api.playlistItemsHiddenMessage())
    compare(Api.playlistItemsEmptyMessage(own, 0,
      "API rate limit exceeded. Try again in 10 seconds.", 429, "user-1"),
      "Couldn't load this playlist. Try again in a moment.")
    compare(Api.playlistItemsEmptyMessage(followed, 0, "", 200, ""),
      "This playlist has no visible items.")
  }

  function test_responsiveMediaRowsAndSearchColumnsUseMeasuredWidth() {
    verify(Api.mediaRowShouldCompact(220, 180, 4))
    verify(!Api.mediaRowShouldCompact(180, 220, 4))
    verify(!Api.mediaRowShouldCompact(220, 180, 0))
    compare(Api.responsiveResultColumns(1000, 760), 2)
    compare(Api.responsiveResultColumns(500, 760), 1)
  }

  function test_sectionedMediaRows_flattensGroupsForOneVirtualizedView() {
    var songs = [{ id: "one" }, { id: "two" }, { id: "three" }]
    var rows = Api.sectionedMediaRows([
      { id: "songs", heading: "SONGS", items: songs, loading: false, hasMore: true },
      { id: "albums", heading: "ALBUMS", items: [], loading: false, hasMore: false },
      { id: "playlists", heading: "PLAYLISTS", items: [], loading: true, hasMore: false }
    ], 2)

    compare(rows.length, 6)
    compare(rows[0].kind, "heading")
    compare(rows[0].sectionId, "songs")
    compare(rows[1].kind, "items")
    compare(rows[1].items.length, 2)
    compare(rows[1].startIndex, 0)
    compare(rows[2].items.length, 1)
    compare(rows[2].startIndex, 2)
    compare(rows[3].kind, "more")
    compare(rows[4].kind, "heading")
    compare(rows[4].sectionId, "playlists")
    compare(rows[5].kind, "more")
  }

  function test_artistSubtitleSuffix_keepsNonArtistAlbumDetails() {
    compare(Api.artistSubtitleSuffix({
      subtitle: "Jimi Hendrix · Album · 1967",
      artists: [{ name: "Jimi Hendrix" }]
    }), " · Album · 1967")
    compare(Api.artistSubtitleSuffix({ subtitle: "Playlist", artists: [] }), "")
  }

  function test_artistForName_prefersAnExactArtist() {
    var artists = [
      { id: "tribute", type: "artist", name: "The Jimi Hendrix Experience Tribute" },
      { id: "jimi", type: "artist", name: "Jimi Hendrix" }
    ]
    compare(Api.artistForName(artists, "jimi hendrix").id, "jimi")
    compare(Api.artistForName(artists, "unknown").id, "tribute")
    compare(Api.artistForName([{ type: "album", name: "Jimi Hendrix" }],
      "Jimi Hendrix"), null)
  }

  function test_artistContextAvailable_onlyLinksTrackPerformers() {
    verify(Api.artistContextAvailable("track", "", []))
    verify(Api.artistContextAvailable("", "track-id", []))
    verify(Api.artistContextAvailable("", "", [{ name: "Björk" }]))
    verify(!Api.artistContextAvailable("episode", "", []))
    verify(!Api.artistContextAvailable("chapter", "", []))
  }

  function test_lyricsSong_requiresATrackAndPreservesPlaybackMetadata() {
    compare(Api.lyricsSong("", "Episode", "Podcast", "Show", 120, ""), null)
    compare(Api.lyricsSong("track-id", "", "Artist", "Album", 180, ""), null)

    var song = Api.lyricsSong("track-id", " Song ", " Artist ", " Album ",
      183.5, "https://images.example/cover.jpg", 91.75)
    compare(song.id, "spotify:track:track-id")
    compare(song.title, "Song")
    compare(song.artist, "Artist")
    compare(song.album, "Album")
    compare(song.duration, 183.5)
    compare(song.coverUrl, "https://images.example/cover.jpg")
    compare(song.positionSeconds, 91.75)

    compare(Api.lyricsSong("track-id", "Song", "Artist", "", 180, "", -5)
      .positionSeconds, 0)
    compare(Api.lyricsSong("track-id", "Song", "Artist", "", 180, "", 200)
      .positionSeconds, 180)
  }

  function test_optionalLyricsPluginRequiresConfirmationBeforeSetup() {
    compare(Api.optionalPluginState(false, false), "missing")
    compare(Api.optionalPluginState(true, false), "disabled")
    compare(Api.optionalPluginState(true, true), "ready")

    compare(Api.optionalPluginSetupCommand("missing", "stappmus.lyrics",
      "https://github.com/stappmus/Omasing.git"), [
        "/usr/bin/omarchy", "plugin", "add",
        "https://github.com/stappmus/Omasing.git", "--enable", "--yes"
      ])
    compare(Api.optionalPluginSetupCommand("disabled", "stappmus.lyrics",
      "https://github.com/stappmus/Omasing.git"), [
        "/usr/bin/omarchy", "plugin", "enable", "stappmus.lyrics",
        "--section", "center"
      ])
    compare(Api.optionalPluginSetupCommand("ready", "stappmus.lyrics",
      "https://github.com/stappmus/Omasing.git"), [])

    var song = { id: "spotify:track:one", title: "Song", artist: "Artist" }
    var intent = Api.lyricsInstallIntent(song, "spotify-panel-lyrics", 1000)
    compare(intent.surface, "spotify-panel-lyrics")
    compare(intent.song.title, "Song")
    verify(Api.lyricsInstallIntentIsFresh(intent, 1000, 180000))
    verify(Api.lyricsInstallIntentIsFresh(intent, 180999, 180000))
    verify(!Api.lyricsInstallIntentIsFresh(intent, 181000, 180000))
    compare(Api.lyricsInstallIntent(null, "surface", 1000), null)
    compare(Api.sessionWithoutLyricsInstall({
      lastRadioPlaylist: "keep",
      pendingLyricsInstall: intent
    }).lastRadioPlaylist, "keep")
    compare(Api.sessionWithoutLyricsInstall({
      pendingLyricsInstall: intent
    }).pendingLyricsInstall, undefined)
  }

  function test_sessionRecord_roundTripsAndMigratesPluginSettings() {
    compare(Api.sessionRecordIsEmpty(Api.emptySessionRecord()), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("")), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("{")), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("[]")), true)
    compare(Api.pluginSettingsHaveSessionKeys(null), false)
    compare(Api.pluginSettingsHaveSessionKeys({ deviceName: "Omarchy Spotify" }), false)
    compare(Api.pluginSettingsHaveSessionKeys({ sessionState: "{}" }), true)
    compare(Api.pluginSettingsHaveSessionKeys({ searchHistory: "[]" }), true)

    var encoded = Api.encodeSessionRecord({
      tab: "playlists",
      searchText: "radiohead",
      selectedPlaylist: {
        kind: "context", type: "playlist", id: "playlist-one",
        uri: "spotify:playlist:playlist-one", name: "Long playlist"
      },
      selectedPlaylistItemCount: 150,
      detailItemCount: 100
    }, ["radiohead", "bjork"])
    compare(JSON.parse(encoded).version, 1)
    var restored = Api.parseSessionRecord(encoded)
    compare(restored.sessionState.tab, "playlists")
    compare(restored.sessionState.searchText, "radiohead")
    compare(restored.sessionState.selectedPlaylist.id, "playlist-one")
    compare(restored.sessionState.selectedPlaylistItemCount, 150)
    compare(restored.sessionState.detailItemCount, 100)
    compare(JSON.stringify(restored.searchHistory),
      JSON.stringify(["radiohead", "bjork"]))
    compare(Api.sessionRecordIsEmpty(restored), false)

    var fromPlugin = Api.sessionRecordFromPluginSettings({
      deviceName: "Office",
      sessionState: "{\"tab\":\"library\",\"libraryType\":\"albums\"}",
      searchHistory: "[\"kid a\", \"kid a\", \"\"]"
    })
    compare(fromPlugin.sessionState.tab, "library")
    compare(fromPlugin.sessionState.libraryType, "albums")
    compare(JSON.stringify(fromPlugin.searchHistory), JSON.stringify(["kid a"]))

    var oversized = { tab: "detail", blob: Array(16001).join("x") }
    compare(JSON.stringify(Api.normalizedSessionState(oversized)), "{}")
    compare(Api.sessionRecordIsEmpty(Api.sessionRecord(oversized, [])), true)
  }

  function test_spotifyTrackId_acceptsUrisUrlsAndSpotifydObjectPaths() {
    compare(Api.spotifyTrackId("spotify:track:14XWXWv5FoCbFzLksawpEe"),
      "14XWXWv5FoCbFzLksawpEe")
    compare(Api.spotifyTrackId("https://open.spotify.com/track/14XWXWv5FoCbFzLksawpEe"),
      "14XWXWv5FoCbFzLksawpEe")
    compare(Api.spotifyTrackId("/spotify/track/14XWXWv5FoCbFzLksawpEe"),
      "14XWXWv5FoCbFzLksawpEe")
    compare(Api.spotifyTrackId("/spotify/episode/not-a-track"), "")
  }

  function test_currentPlaybackTrack_reusesRemoteTracksAndSynthesizesMprisTracks() {
    var remote = {
      id: "remote-id", uri: "spotify:track:remote-id", type: "track",
      name: "Remote song"
    }
    compare(Api.currentPlaybackTrack("remote-id", remote, "", "", "", "", 0, ""),
      remote)

    var local = Api.currentPlaybackTrack("local-id", remote, "Local song",
      "Local artist", "Local album", "cover", 183.5, "web-url")
    compare(local.type, "track")
    compare(local.uri, "spotify:track:local-id")
    compare(local.name, "Local song")
    compare(local.subtitle, "Local artist")
    compare(local.durationMs, 183500)
    compare(local.externalUrl, "web-url")

    compare(Api.currentPlaybackTrack("episode-id", {
      id: "episode-id", uri: "spotify:episode:episode-id", type: "episode"
    }, "Episode", "", "", "", 120, ""), null)
    compare(Api.currentPlaybackTrack("", remote, "", "", "", "", 0, ""), null)
  }

  function test_arrayValues_acceptsQmlSequenceShape() {
    var sequence = ({ length: 2 })
    sequence[0] = { name: "One" }
    sequence[1] = { name: "Two" }

    verify(!Array.isArray(sequence))
    compare(Api.arrayValues(sequence).length, 2)
    compare(Api.artistNames(sequence), "One, Two")
  }

  function test_searchScope_tracksTheOpenAreaAndSearchMode() {
    var artist = Api.searchScope("detail", {
      id: "artist-id", uri: "spotify:artist:artist-id",
      type: "artist", name: "Björk"
    }, null, "recent", "tracks")
    verify(artist.available)
    compare(artist.key, "detail:spotify:artist:artist-id")
    compare(artist.label, "Björk")
    compare(artist.mode, "artist")

    var playlist = Api.searchScope("playlists", null, {
      id: "playlist-id", type: "playlist", name: "Night drive"
    }, "recent", "tracks")
    verify(playlist.available)
    compare(playlist.key, "playlist:playlist-id")
    compare(playlist.label, "Night drive")
    compare(playlist.mode, "filter")

    compare(Api.searchScope("home", null, null, "artists", "tracks").label,
      "Top artists")
    compare(Api.searchScope("library", null, null, "recent", "albums").label,
      "Saved albums")
    verify(!Api.searchScope("search", null, null, "recent", "tracks").available)
    verify(!Api.searchScope("devices", null, null, "recent", "tracks").available)
  }

  function test_universalSearchVisibility_isExplicitAndHiddenFromDevices() {
    verify(Api.universalSearchVisible("search", false))
    verify(!Api.universalSearchVisible("setup", true))
    verify(!Api.universalSearchVisible("setup", false))
    verify(!Api.universalSearchVisible("devices", true))
    verify(!Api.universalSearchVisible("login", true))
  }

  function test_previousContentTab_skipsSettingsAndDevices() {
    compare(Api.previousContentTab("setup", "home"), "home")
    compare(Api.previousContentTab("devices", "library"), "library")
    compare(Api.previousContentTab("devices", "setup"), "home")
    compare(Api.previousContentTab("setup", "devices"), "home")
    compare(Api.previousContentTab("setup", ""), "home")
    compare(Api.previousContentTab("home", "library"), "")
    compare(Api.rememberContentTab("setup"), "")
    compare(Api.rememberContentTab("playlists"), "playlists")
  }

  function test_tracksForArtist_filtersBroadSearchByStableArtistId() {
    var rows = Api.tracksForArtist([
      { id: "solo", type: "track", artists: [{ id: "target", name: "Artist" }] },
      { id: "feature", type: "track", artists: [
        { id: "guest", name: "Guest" }, { id: "target", name: "Artist" }
      ] },
      { id: "tribute", type: "track", artists: [{ id: "other", name: "Artist" }] },
      { id: "album", type: "album", artists: [{ id: "target", name: "Artist" }] }
    ], { id: "target", name: "Artist" })

    compare(rows.length, 2)
    compare(rows[0].id, "solo")
    compare(rows[1].id, "feature")
  }

  function test_findThisIsPlaylist_requiresExactTitleAndPrefersSpotify() {
    var result = Api.findThisIsPlaylist([
      { id: "lookalike", type: "playlist", name: "This Is Nearly Björk", ownerName: "Spotify" },
      { id: "fan", type: "playlist", name: "THIS IS BJÖRK!", ownerName: "A listener" },
      { id: "official", type: "playlist", name: "This Is Björk", ownerId: "spotify" }
    ], "Björk")

    verify(result !== null)
    compare(result.id, "official")
    compare(Api.findThisIsPlaylist([
      { id: "wrong", type: "playlist", name: "Best of Björk", ownerName: "Spotify" }
    ], "Björk"), null)
  }

  function test_trackRadioPlaylists_onlyKeepsExactSpotifyContexts() {
    var result = Api.trackRadioPlaylists([
      { id: "official", uri: "spotify:playlist:official", type: "playlist",
        name: "Dreams - 2004 Remaster Radio", ownerId: "spotify" },
      { id: "copy", uri: "spotify:playlist:copy", type: "playlist",
        name: "Dreams - 2004 Remaster Radio", ownerName: "A listener" },
      { id: "other", uri: "spotify:playlist:other", type: "playlist",
        name: "Sunset Dreams - 2004 Remaster Radio", ownerName: "Spotify" }
    ], "Dreams - 2004 Remaster")

    compare(result.length, 1)
    compare(result[0].id, "official")
  }

  function test_radioSeedMatches_acceptsRelinkedTrackFromSameArtist() {
    verify(Api.radioSeedMatches({
      id: "market-version", uri: "spotify:track:market-version",
      name: "Love The Way You Lie",
      artists: [{ id: "eminem", name: "Eminem" }, { id: "rihanna", name: "Rihanna" }]
    }, {
      id: "original", uri: "spotify:track:original",
      name: "Love The Way You Lie",
      artists: [{ id: "eminem", name: "Eminem" }]
    }))
    verify(!Api.radioSeedMatches({
      id: "cover", name: "Love The Way You Lie",
      artists: [{ id: "cover-band", name: "Cover Band" }]
    }, {
      id: "original", name: "Love The Way You Lie",
      artists: [{ id: "eminem", name: "Eminem" }]
    }))
  }

  function test_uniqueRadioTracks_keepsSeedFirstAndDropsDuplicateUris() {
    var seed = { uri: "spotify:track:seed", name: "Seed" }
    var radio = Api.uniqueRadioTracks(seed, [
      { uri: "spotify:track:seed", name: "Duplicate seed" },
      { uri: "spotify:track:two", name: "Two" },
      { uri: "", name: "Missing" },
      { uri: "spotify:track:two", name: "Two again" },
      { uri: "spotify:track:three", name: "Three" }
    ])
    compare(radio.length, 3)
    compare(radio[0], seed)
    compare(radio[1].name, "Two")
    compare(radio[2].name, "Three")
  }

  function test_discoveryPlaylists_keepsOfficialRelevantResultsInUsefulOrder() {
    var rows = Api.discoveryPlaylists([
      { id: "fan", type: "playlist", name: "Discover Weekly", ownerName: "A listener" },
      { id: "fresh", uri: "spotify:playlist:fresh", type: "playlist",
        name: "Fresh Finds Indie", ownerName: "Spotify" },
      { id: "mix", uri: "spotify:playlist:mix", type: "playlist",
        name: "Daily Mix 2", ownerId: "spotify" },
      { id: "radar", uri: "spotify:playlist:radar", type: "playlist",
        name: "Release Radar", ownerName: "Spotify" },
      { id: "weekly", uri: "spotify:playlist:weekly", type: "playlist",
        name: "Discover Weekly", ownerName: "Spotify" },
      { id: "weekly", uri: "spotify:playlist:weekly", type: "playlist",
        name: "Discover Weekly", ownerName: "Spotify" },
      { id: "unrelated", type: "playlist", name: "Party Hits", ownerName: "Spotify" }
    ])

    compare(rows.length, 4)
    compare(rows[0].id, "weekly")
    compare(rows[1].id, "radar")
    compare(rows[2].id, "mix")
    compare(rows[3].id, "fresh")
  }

  function test_scopes_followLeastPrivilege() {
    verify(Api.SCOPES.indexOf("user-modify-playback-state") >= 0)
    verify(Api.SCOPES.indexOf("user-library-read") >= 0)
    verify(Api.SCOPES.indexOf("user-follow-read") >= 0)
    verify(Api.SCOPES.indexOf("user-read-recently-played") >= 0)
    verify(Api.SCOPES.indexOf("user-top-read") >= 0)
    verify(Api.SCOPES.indexOf("playlist-modify-private") >= 0)
    verify(Api.SCOPES.indexOf("playlist-modify-public") >= 0)
    verify(Api.SCOPES.indexOf("user-read-private") === -1)
    verify(Api.SCOPES.indexOf("user-read-email") === -1)
    verify(Api.SCOPES.indexOf("user-read-currently-playing") === -1)
  }

  function test_safeApiUrl_rejectsForeignHosts() {
    compare(Api.safeApiUrl("/me"), Api.API_BASE + "/me")
    compare(Api.safeApiUrl(Api.API_BASE + "/me/tracks"), Api.API_BASE + "/me/tracks")
    compare(Api.safeApiUrl("https://api.spotify.com.evil.example/v1/me"), "")
    compare(Api.safeApiUrl("https://example.com/v1/me"), "")
  }

  function test_normalizeTrack_supportsCurrentPlaylistItems() {
    var normalized = Api.normalizeTrack({
      item: {
        id: "track-id",
        uri: "spotify:track:track-id",
        type: "track",
        name: "A track",
        duration_ms: 123000,
        explicit: true,
        artists: [{ name: "One" }, { name: "Two" }],
        album: {
          name: "An album",
          images: [
            { url: "large", width: 640 },
            { url: "small", width: 64 },
            { url: "right-sized", width: 96 }
          ]
        },
        external_urls: { spotify: "https://open.spotify.com/track/track-id" }
      }
    }, 96)

    verify(normalized !== null)
    compare(normalized.name, "A track")
    compare(normalized.subtitle, "One, Two")
    compare(normalized.album, "An album")
    compare(normalized.imageUrl, "right-sized")
    compare(normalized.durationMs, 123000)
    compare(normalized.explicit, true)
    compare(normalized.artists.length, 2)
    compare(normalized.albumItem.name, "An album")
    compare(normalized.albumItem.type, "album")
  }

  function test_normalizeTrack_supportsEpisodesAndResumePosition() {
    var episode = Api.normalizeTrack({
      played_at: "2026-08-11T10:00:00Z",
      item: {
        id: "episode-id",
        uri: "spotify:episode:episode-id",
        type: "episode",
        name: "Episode one",
        duration_ms: 3600000,
        resume_point: { resume_position_ms: 42000, fully_played: false },
        show: {
          id: "show-id",
          uri: "spotify:show:show-id",
          type: "show",
          name: "A show",
          images: [{ url: "show-art", width: 128 }]
        }
      }
    }, 96)

    compare(episode.type, "episode")
    compare(episode.subtitle, "A show")
    compare(episode.parentContext.type, "show")
    compare(episode.resumeMs, 42000)
    compare(episode.fullyPlayed, false)
    compare(episode.playedAt, "2026-08-11T10:00:00Z")
  }

  function test_searchGroups_normalizeEverySupportedType() {
    var groups = Api.searchGroups({
      tracks: { items: [{ id: "t", uri: "spotify:track:t", type: "track", name: "Track" }], total: 1 },
      artists: { items: [{ id: "a", uri: "spotify:artist:a", type: "artist", name: "Artist" }], total: 1 },
      albums: { items: [{ id: "b", uri: "spotify:album:b", type: "album", name: "Album" }], total: 1 },
      playlists: { items: [{ id: "p", uri: "spotify:playlist:p", type: "playlist", name: "Playlist" }], total: 1 },
      shows: { items: [{ id: "s", uri: "spotify:show:s", type: "show", name: "Show" }], total: 1 },
      episodes: { items: [{ id: "e", uri: "spotify:episode:e", type: "episode", name: "Episode" }], total: 1 },
      audiobooks: { items: [{ id: "book", uri: "spotify:audiobook:book", type: "audiobook", name: "Book" }], total: 1 }
    })

    compare(groups.track.items[0].type, "track")
    compare(groups.artist.items[0].type, "artist")
    compare(groups.album.items[0].type, "album")
    compare(groups.playlist.items[0].type, "playlist")
    compare(groups.show.items[0].type, "show")
    compare(groups.episode.items[0].type, "episode")
    compare(groups.audiobook.items[0].type, "audiobook")
  }

  function test_normalizeContext_labelsAlbumsAndEps() {
    var album = Api.normalizeContext({
      id: "album", uri: "spotify:album:album", type: "album",
      album_type: "album", name: "Full length", release_date: "2025-04-10",
      total_tracks: 12, artists: [{ name: "Artist" }]
    })
    var ep = Api.normalizeContext({
      id: "ep", uri: "spotify:album:ep", type: "album",
      album_type: "single", name: "Short release", release_date: "2026",
      total_tracks: 5, artists: [{ name: "Artist" }]
    })

    compare(album.subtitle, "Artist · Album · 2025")
    compare(album.releaseType, "album")
    compare(ep.subtitle, "Artist · EP / Single · 2026")
  }

  function test_playlistItemUris_keepsOrderAndDuplicates() {
    var uris = Api.playlistItemUris([
      { type: "track", uri: "spotify:track:one" },
      { type: "track", uri: "spotify:track:one" },
      { type: "album", uri: "spotify:album:nope" },
      { type: "episode", uri: "spotify:episode:two" },
      { type: "track", uri: "" }
    ])
    compare(JSON.stringify(uris), JSON.stringify([
      "spotify:track:one", "spotify:track:one", "spotify:episode:two"
    ]))
  }

  function test_playlistBackingItems_matchesStableIdsOnly() {
    var selectedItems = [{ name: "Selected song" }]
    var detailItems = [{ name: "Detail song" }]
    var refreshedContext = { id: "selected" }

    verify(Api.playlistBackingItems(refreshedContext,
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems) === selectedItems)
    verify(Api.playlistBackingItems({ id: "detail" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems) === detailItems)
    compare(Api.playlistBackingItems({ id: "unrelated" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems).length, 0)
    compare(Api.playlistBackingItems({ id: "detail" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "album" }, detailItems).length, 0)
  }

  function test_playlistReorderBody_translatesFinalIndexesForSpotify() {
    compare(JSON.stringify(Api.playlistReorderBody(1, 3, 4, "snapshot")),
      JSON.stringify({
        range_start: 1,
        insert_before: 4,
        range_length: 1,
        snapshot_id: "snapshot"
      }))
    compare(JSON.stringify(Api.playlistReorderBody(3, 1, 4, "")),
      JSON.stringify({ range_start: 3, insert_before: 1, range_length: 1 }))
    compare(Api.playlistReorderBody(1, 1, 4, "snapshot"), null)
    compare(Api.playlistReorderBody(-1, 2, 4, "snapshot"), null)
    compare(Api.playlistReorderBody(0, 4, 4, "snapshot"), null)
  }

  function test_playlistReorder_preservesRawPositionsAcrossHiddenItems() {
    var rows = [
      { name: "one", playlistPosition: 0 },
      { name: "two", playlistPosition: 2 },
      { name: "three", playlistPosition: 3 },
      { name: "four", playlistPosition: 4 }
    ]
    compare(JSON.stringify(Api.playlistReorderBodyForItems(
      rows, 1, 3, 5, "snapshot")), JSON.stringify({
        range_start: 2,
        insert_before: 5,
        range_length: 1,
        snapshot_id: "snapshot"
      }))

    var movedDown = Api.reorderedPlaylistItemsAtPositions(rows, 2, 4)
    compare(movedDown.map(function(item) { return item.name }).join(","),
      "one,three,four,two")
    compare(movedDown.map(function(item) { return item.playlistPosition }).join(","),
      "0,2,3,4")

    var movedUp = Api.reorderedPlaylistItemsAtPositions(rows, 4, 2)
    compare(movedUp.map(function(item) { return item.name }).join(","),
      "one,four,two,three")
    compare(movedUp.map(function(item) { return item.playlistPosition }).join(","),
      "0,2,3,4")
    compare(rows[1].playlistPosition, 2)

    var duplicates = [
      { name: "one", playlistPosition: 0 },
      { name: "duplicate", playlistPosition: 1 },
      { name: "two", playlistPosition: 2 },
      { name: "duplicate", playlistPosition: 3 }
    ]
    var oneOccurrence = Api.reorderedPlaylistItemsAtPositions(duplicates, 1, 3)
    compare(oneOccurrence.map(function(item) { return item.name }).join(","),
      "one,two,duplicate,duplicate")
    compare(duplicates[1].playlistPosition, 1)
  }

  function test_mergeSearchGroups_keepsUnchangedCategories() {
    var first = Api.searchGroups({
      tracks: { items: [{ id: "one", uri: "spotify:track:one", type: "track", name: "One" }], total: 2 },
      artists: { items: [{ id: "artist", uri: "spotify:artist:artist", type: "artist", name: "Artist" }], total: 1 }
    })
    var more = Api.searchGroups({
      tracks: { items: [{ id: "two", uri: "spotify:track:two", type: "track", name: "Two" }], total: 2 }
    })
    var merged = Api.mergeSearchGroups(first, more)

    compare(merged.track.items.length, 2)
    compare(merged.artist.items.length, 1)
  }

  function test_filteredSorted_filtersAndSortsWithoutMutatingSource() {
    var source = [
      { name: "Zulu", subtitle: "Someone", addedAt: "2026-01-01" },
      { name: "Alpha", subtitle: "Target artist", addedAt: "2026-08-01" },
      { name: "Unknown", subtitle: "No date" }
    ]
    var filtered = Api.filteredSorted(source, "target", "name")
    compare(filtered.length, 1)
    compare(filtered[0].name, "Alpha")

    var newest = Api.filteredSorted(source, "", "date")
    compare(newest[0].name, "Alpha")
    compare(newest[1].name, "Zulu")
    compare(newest[2].name, "Unknown")

    var oldest = Api.filteredSorted(source, "", "date-asc")
    compare(oldest[0].name, "Zulu")
    compare(oldest[1].name, "Alpha")
    compare(oldest[2].name, "Unknown")
    compare(source[0].name, "Zulu")
  }

  function test_touchHistory_deduplicatesAndCaps() {
    var history = Api.touchHistory(["old", "same", "older"], " same ", 3)
    compare(JSON.stringify(history), JSON.stringify(["same", "old", "older"]))
    history = Api.touchHistory(history, "new", 3)
    compare(JSON.stringify(history), JSON.stringify(["new", "same", "old"]))
  }

  function test_normalizePage_filtersMalformedRowsAndNextHost() {
    var page = Api.normalizePage({
      items: [
        { type: "track", id: "one", uri: "spotify:track:one", name: "One" },
        { type: "unsupported", id: "bad" }
      ],
      next: Api.API_BASE + "/me/tracks?offset=1",
      previous: "https://attacker.example/steal",
      total: 2
    }, function(value) { return Api.normalizeTrack(value, 64) })

    compare(page.items.length, 1)
    compare(page.items[0].id, "one")
    compare(page.next, Api.API_BASE + "/me/tracks?offset=1")
    compare(page.previous, "")
    compare(page.total, 2)
  }

  function test_playlistPageState_keepsLoadingPastSharedCacheLimit() {
    var existing = []
    var incoming = []
    for (var i = 0; i < 200; i++) existing.push({ playlistPosition: i })
    for (var j = 200; j < 250; j++) incoming.push({ playlistPosition: j })
    var nextUrl = Api.API_BASE + "/playlists/list/items?offset=250"

    var page = Api.playlistPageState(existing, incoming, true, nextUrl)
    compare(page.items.length, 250)
    compare(page.items[0].playlistPosition, 0)
    compare(page.items[249].playlistPosition, 249)
    compare(page.next, nextUrl)

    var refreshed = Api.playlistPageState(existing, incoming, false, "")
    verify(refreshed.items === incoming)
    compare(refreshed.items.length, 50)
    compare(refreshed.next, "")
  }

  function test_playlistRestoreCount_isBoundedAndContinuesOnlyWithNextPage() {
    compare(Api.normalizedPlaylistRestoreCount(undefined), 0)
    compare(Api.normalizedPlaylistRestoreCount(-10), 0)
    compare(Api.normalizedPlaylistRestoreCount(149.9), 149)
    compare(Api.normalizedPlaylistRestoreCount(999999), 10000)

    var nextUrl = Api.API_BASE + "/playlists/list/items?offset=50"
    verify(Api.playlistRestorePending(50, 150, true, ""))
    verify(Api.playlistRestorePending(50, 150, false, nextUrl))
    verify(!Api.playlistRestorePending(150, 150, true, nextUrl))
    verify(!Api.playlistRestorePending(50, 150, false, ""))
    verify(Api.playlistRestoreShouldContinue(50, 150, nextUrl))
    verify(!Api.playlistRestoreShouldContinue(150, 150, nextUrl))
    verify(!Api.playlistRestoreShouldContinue(50, 150,
      "https://attacker.example/items?offset=50"))
  }

  function test_playbackBodies() {
    compare(JSON.stringify(Api.playbackBody({
      kind: "context", type: "playlist", uri: "spotify:playlist:abc"
    })), JSON.stringify({ context_uri: "spotify:playlist:abc" }))
    compare(JSON.stringify(Api.playbackBody({
      kind: "item", type: "track", uri: "spotify:track:def"
    })), JSON.stringify({ uris: ["spotify:track:def"] }))

    var rows = [
      { kind: "item", uri: "spotify:track:a" },
      { kind: "item", uri: "spotify:track:b" },
      { kind: "context", uri: "spotify:album:ignored" },
      { kind: "item", uri: "spotify:track:c" }
    ]
    compare(JSON.stringify(Api.playbackBody(rows[1], rows, "")), JSON.stringify({
      uris: ["spotify:track:b", "spotify:track:c", "spotify:track:a"]
    }))
    rows[1].playlistPosition = 7
    compare(JSON.stringify(Api.playbackBody(rows[1], rows, "spotify:playlist:list")),
      JSON.stringify({
        context_uri: "spotify:playlist:list",
        offset: { position: 7 }
      }))

    var epRows = [
      { kind: "item", uri: "spotify:track:first", discNumber: 1, trackNumber: 1 },
      { kind: "item", uri: "spotify:track:second", discNumber: 1, trackNumber: 2 },
      { kind: "item", uri: "spotify:track:third", discNumber: 1, trackNumber: 3 }
    ]
    compare(JSON.stringify(Api.playbackBody(epRows[2], epRows,
      "spotify:album:ep")), JSON.stringify({
        context_uri: "spotify:album:ep",
        offset: { position: 2 }
      }))

    var multiDiscRows = [
      { kind: "item", uri: "spotify:track:d1t1", discNumber: 1, trackNumber: 1 },
      { kind: "item", uri: "spotify:track:d1t2", discNumber: 1, trackNumber: 2 },
      { kind: "item", uri: "spotify:track:d2t1", discNumber: 2, trackNumber: 1 }
    ]
    compare(JSON.stringify(Api.playbackBody(multiDiscRows[2], multiDiscRows,
      "spotify:album:multi")), JSON.stringify({
        context_uri: "spotify:album:multi",
        offset: { position: 2 }
      }))
    compare(Api.playbackBody(null), null)
    compare(Api.playbackBody({
      kind: "context", type: "show", uri: "spotify:show:podcast"
    }), null)
    compare(JSON.stringify(Api.playbackBody({
      kind: "item", type: "episode", uri: "spotify:episode:one", resumeMs: 9000
    }, [], "spotify:show:podcast")), JSON.stringify({
      uris: ["spotify:episode:one"], position_ms: 9000
    }))
  }

  function test_playbackContext_followsTheDisplayedOrderOnlyWhenCustomized() {
    var playlist = "spotify:playlist:list"
    var album = "spotify:album:record"
    compare(Api.playbackContextForView(playlist, "", "default"), playlist)
    compare(Api.playbackContextForView(playlist, "miles", "default"), "")
    compare(Api.playbackContextForView(playlist, "", "name"), "")
    compare(Api.playbackContextForView(album, "", "date"), "")
    compare(Api.playbackContextForView("spotify:show:podcast", "", "name"),
      "spotify:show:podcast")
    verify(Api.playbackUsesVisibleOrder(playlist, "miles", "default"))
    verify(!Api.playbackUsesVisibleOrder(playlist, "", "default"))
    compare(Api.visibleOrderPlaybackMessage(12), "Playing the displayed order")
    verify(Api.visibleOrderPlaybackMessage(114).indexOf("100 items") >= 0)
    compare(Api.PLAYBACK_URI_LIMIT, 100)
  }

  function test_visibleOrderPlayback_preservesOccurrencesAndCapsLongLists() {
    var duplicateRows = [
      { kind: "item", uri: "spotify:track:duplicate", playlistPosition: 0 },
      { kind: "item", uri: "spotify:track:middle", playlistPosition: 1 },
      { kind: "item", uri: "spotify:track:duplicate", playlistPosition: 2 },
      { kind: "item", uri: "spotify:track:last", playlistPosition: 3 }
    ]
    compare(JSON.stringify(Api.playbackBody(duplicateRows[2], duplicateRows, "")),
      JSON.stringify({ uris: ["spotify:track:duplicate", "spotify:track:last",
        "spotify:track:duplicate", "spotify:track:middle"] }))

    var longRows = []
    for (var i = 0; i < 114; i++)
      longRows.push({ kind: "item", uri: "spotify:track:" + i,
        playlistPosition: i })
    var body = Api.playbackBody(longRows[110], longRows, "")
    compare(body.uris.length, Api.PLAYBACK_URI_LIMIT)
    compare(body.uris[0], "spotify:track:110")
    compare(body.uris[3], "spotify:track:113")
    compare(body.uris[4], "spotify:track:0")
    compare(body.uris[99], "spotify:track:95")
  }

  function test_playbackPreservesActiveDeviceAndFallsBackToLocal() {
    var external = { id: "desktop", local: false, active: true, restricted: false }
    var local = { id: "omarchy", local: true, active: false, restricted: false }
    var devices = [external, local]

    compare(Api.preferredPlaybackDevice(devices, "", false).id, "desktop")
    compare(Api.preferredPlaybackDevice(devices, "omarchy", false).id, "desktop")
    compare(Api.preferredPlaybackDevice(devices, "desktop", true).id, "desktop")

    external.active = false
    compare(Api.preferredPlaybackDevice(devices, "", false).id, "omarchy")
  }

  function test_automaticLocalPlaybackDevice_selectsAnActiveLocalReceiver() {
    var activeLocal = {
      id: "omarchy", local: true, active: true, restricted: false
    }
    var inactiveLocal = {
      id: "fallback", local: true, active: false, restricted: false
    }
    var activeRemote = {
      id: "phone", local: false, active: true, restricted: false
    }

    compare(Api.automaticLocalPlaybackDevice("", activeLocal, activeLocal).id,
      "omarchy")
    compare(Api.automaticLocalPlaybackDevice("", inactiveLocal, inactiveLocal).id,
      "fallback")
    compare(Api.automaticLocalPlaybackDevice("", activeRemote, inactiveLocal), null)
    compare(Api.automaticLocalPlaybackDevice("chosen", activeLocal, activeLocal), null)
    compare(Api.automaticLocalPlaybackDevice("", null, {
      id: "restricted", local: true, restricted: true
    }), null)
  }

  function test_visibleUiStartsAndRefreshesLocalReceiver() {
    compare(Api.visibleLocalReceiverAction(false, true, false, false), "idle")
    compare(Api.visibleLocalReceiverAction(true, false, false, false), "idle")
    compare(Api.visibleLocalReceiverAction(true, true, false, true), "wait")
    compare(Api.visibleLocalReceiverAction(true, true, false, false), "start")
    compare(Api.visibleLocalReceiverAction(true, true, true, false), "refresh")
  }

  function test_remotePlaybackPoll_skipsBackgroundLocalPlayback() {
    verify(Api.remotePlaybackPollShouldRun(true, false, true, false, true))
    verify(Api.remotePlaybackPollShouldRun(true, false, false, true, true))
    verify(!Api.remotePlaybackPollShouldRun(true, false, false, false, true))
    verify(!Api.remotePlaybackPollShouldRun(true, true, true, true, true))
    verify(!Api.remotePlaybackPollShouldRun(false, false, true, true, true))
    compare(Api.remotePlaybackPollInterval(true, true, false), 5000)
    compare(Api.remotePlaybackPollInterval(true, false, true), 15000)
    compare(Api.remotePlaybackPollInterval(false, true, false), 15000)
  }

  function test_normalizedShortcutPlayer_mapsLegacyDefault() {
    compare(Api.normalizedShortcutPlayer("Omarchy default"), "Omarchy Music app")
    compare(Api.normalizedShortcutPlayer("Full player"), "Full player")
    compare(Api.normalizedShortcutPlayer("Mini player"), "Mini player")
    compare(Api.normalizedShortcutPlayer(""), "Omarchy Music app")
  }

  function test_repeatAndSearchLabels_areHumanReadable() {
    compare(Api.repeatModeLabel("off"), "Off")
    compare(Api.repeatModeLabel("track"), "This song")
    compare(Api.repeatModeLabel("context"), "All")
    compare(Api.searchTypeLabel("track"), "Songs")
    compare(Api.searchTypeLabel("audiobook"), "Books")
    compare(Api.spotifyTypeLabel("track"), "Song")
    compare(Api.spotifyTypeLabel("playlist"), "Playlist")
  }

  function test_backendLoadFields_mapsWebApiBodies() {
    compare(JSON.stringify(Api.backendLoadFields({
      context_uri: "spotify:album:abc",
      offset: { position: 3 }
    })), JSON.stringify({
      play: true,
      context_uri: "spotify:album:abc",
      offset_index: 3
    }))
    compare(JSON.stringify(Api.backendLoadFields({
      uris: ["spotify:track:one", "spotify:track:two"],
      position_ms: 1500
    })), JSON.stringify({
      play: true,
      uris: ["spotify:track:one", "spotify:track:two"],
      position_ms: 1500
    }))
    compare(Api.backendLoadFields(null), null)
    compare(Api.backendLoadFields({}), null)
  }

  function test_currentPlaybackDeviceWorksBeforeDeviceListLoads() {
    var current = {
      id: "phone", name: "Phone", type: "Smartphone",
      local: false, active: true, restricted: false
    }

    compare(Api.preferredPlaybackDevice([], "", false, current).id, "phone")
  }

  function test_explicitDeviceOverridesCurrentPlaybackDevice() {
    var selected = { id: "speaker", local: false, active: false, restricted: false }
    var current = { id: "phone", local: false, active: true, restricted: false }

    compare(Api.preferredPlaybackDevice([selected], "speaker", true, current).id,
      "speaker")
  }

  function test_activePlaybackTargetOmitsDeviceId() {
    var active = { id: "phone", active: true }
    var fallback = { id: "omarchy", active: false }

    compare(Api.playbackTargetDeviceId(active, false), "")
    compare(Api.playbackTargetDeviceId(active, true), "phone")
    compare(Api.playbackTargetDeviceId(fallback, false), "omarchy")
    compare(Api.playbackTargetDeviceId(null, false), "")
  }

  function test_restrictedActiveDeviceDoesNotSilentlyFallBackToLocal() {
    var speaker = {
      id: "speaker", local: false, active: true, restricted: true
    }
    var local = {
      id: "omarchy", local: true, active: false, restricted: false
    }

    compare(Api.preferredPlaybackDevice([speaker, local], "", false).id,
      "speaker")
    compare(Api.playbackTargetDeviceId(speaker, false), "")
  }

  function test_unavailableExplicitDeviceFallsBackToLocal() {
    var local = { id: "omarchy", local: true, restricted: false }
    compare(Api.preferredPlaybackDevice([local], "gone", true).id, "omarchy")
    compare(Api.preferredPlaybackDevice([], "gone", true), null)
  }

  function test_localPlaybackDevice_survivesAConfiguredRename() {
    verify(Api.isLocalPlaybackDevice({ id: "local", name: "Old desk" },
      "New desk", "Old desk", ""))
    verify(Api.isLocalPlaybackDevice({ id: "local", name: "Unexpected API label" },
      "New desk", "", "local"))
    verify(!Api.isLocalPlaybackDevice({ id: "speaker", name: "Kitchen" },
      "New desk", "Old desk", "local"))
  }

  function test_playbackDeviceMatch_fallsBackToNameWhenCurrentIdIsMissing() {
    verify(Api.playbackDevicesMatch({ id: "", name: "Work", type: "Speaker" },
      { id: "sonos-id", name: "work", type: "speaker" }))
    verify(!Api.playbackDevicesMatch({ id: "api-id", name: "Work", type: "Speaker" },
      { id: "different-id", name: "Work", type: "Speaker" }))
    verify(!Api.playbackDevicesMatch({ id: "", name: "Work", type: "Speaker" },
      { id: "sonos-id", name: "Work", type: "Computer" }))
  }

  function test_remoteSeekHoldsRequestedPositionUntilSpotifyCatchesUp() {
    var device = { id: "speaker", name: "Speaker", type: "Speaker" }
    var playback = {
      device: device,
      item: { uri: "spotify:track:one" },
      progressSeconds: 20,
      receivedAt: 1000,
      playing: true
    }
    var pending = {
      device: device,
      uri: "spotify:track:one",
      positionSeconds: 90,
      requestedAt: 1500,
      playing: true,
      expiresAt: 9500
    }

    verify(Api.pendingRemoteSeekShouldHold(playback, pending, 2000))
    compare(Api.displayedRemotePosition(playback, pending, 2000), 90.5)

    playback.progressSeconds = 90.4
    playback.receivedAt = 1900
    verify(!Api.pendingRemoteSeekShouldHold(playback, pending, 2000))
    compare(Api.displayedRemotePosition(playback, pending, 2000), 90.5)
  }

  function test_remoteSeekStopsHoldingForExpiryOrTrackChange() {
    var device = { id: "speaker", name: "Speaker", type: "Speaker" }
    var playback = {
      device: device,
      item: { uri: "spotify:track:two" },
      progressSeconds: 20,
      receivedAt: 1000,
      playing: false
    }
    var pending = {
      device: device,
      uri: "spotify:track:one",
      positionSeconds: 90,
      requestedAt: 1500,
      playing: false,
      expiresAt: 9500
    }

    verify(!Api.pendingRemoteSeekShouldHold(playback, pending, 2000))
    playback.item.uri = "spotify:track:one"
    verify(!Api.pendingRemoteSeekShouldHold(playback, pending, 9500))
  }

  function test_remoteVolumeHoldsUntilMatchingDeviceAcknowledgesIt() {
    var device = {
      id: "speaker", name: "Speaker", type: "Speaker", volumePercent: 25
    }
    var pending = {
      device: device,
      volumePercent: 60,
      expiresAt: 9000
    }

    verify(Api.pendingRemoteVolumeShouldHold(device, pending, 2000))
    device.volumePercent = 60
    verify(!Api.pendingRemoteVolumeShouldHold(device, pending, 2000))
    device.volumePercent = 25
    verify(!Api.pendingRemoteVolumeShouldHold(device, pending, 9000))
    verify(!Api.pendingRemoteVolumeShouldHold({
      id: "other", name: "Other", type: "Speaker", volumePercent: 25
    }, pending, 2000))
  }

  function test_playbackSliderFeedbackWaitsForAuthoritativeValue() {
    verify(!Api.playbackSliderFeedbackComplete(
      0.2, 0.8, false, 100, 0.01, 300, 8000))
    verify(!Api.playbackSliderFeedbackComplete(
      0.8, 0.8, true, 500, 0.01, 300, 8000))
    verify(Api.playbackSliderFeedbackComplete(
      0.8, 0.8, false, 500, 0.01, 300, 8000))
    verify(Api.playbackSliderFeedbackComplete(
      0.2, 0.8, true, 8000, 0.01, 300, 8000))
  }

  function test_playbackDeviceDisplayName_prefersMatchedLocalAlias() {
    var deviceId = "0123456789abcdef0123456789abcdef01234567"
    var current = { id: deviceId, name: deviceId, type: "Speaker" }
    var receivers = [{
      id: deviceId, name: "Living room soundbar", type: "Speaker",
      brand: "JBL", model: "BAR_800"
    }]

    verify(Api.spotifyDeviceNameNeedsDiscovery(current))
    compare(Api.playbackDeviceDisplayName(current, receivers), "Living room soundbar")
    compare(Api.playbackDeviceDisplayName(current, []), deviceId)
    verify(!Api.spotifyDeviceNameNeedsDiscovery({
      id: deviceId, name: "Living room", type: "Speaker"
    }))
  }

  function test_spotifyConnectTokenType_preservesSupportedReceiverFlows() {
    compare(Api.spotifyConnectTokenType("accesstoken"), "accesstoken")
    compare(Api.spotifyConnectTokenType("authorization_code"), "authorization_code")
    compare(Api.spotifyConnectTokenType("default"), "default")
    compare(Api.spotifyConnectTokenType("unexpected"), "default")
    verify(Api.isSpotifyConnectDeviceId("abcdEFGH1234"))
    verify(!Api.isSpotifyConnectDeviceId("short"))
    verify(!Api.isSpotifyConnectDeviceId("bad id"))
  }

  function test_normalizePlaybackState_keepsRemoteTrackAndNullableDeviceId() {
    var state = Api.normalizePlaybackState({
      is_playing: true,
      progress_ms: 42000,
      repeat_state: "context",
      shuffle_state: true,
      device: {
        id: null, name: "Work", type: "Speaker", is_active: true,
        is_restricted: true, volume_percent: 33, supports_volume: true
      },
      item: {
        id: "track", uri: "spotify:track:track", type: "track",
        name: "A song", duration_ms: 180000,
        artists: [{ name: "An artist" }], album: { name: "An album" }
      }
    }, 192)

    verify(state !== null)
    compare(state.device.id, "")
    compare(state.device.name, "Work")
    compare(state.device.restricted, true)
    compare(state.device.volumePercent, 33)
    compare(state.item.name, "A song")
    compare(state.item.subtitle, "An artist")
    compare(state.progressSeconds, 42)
    compare(state.repeatMode, "context")
    compare(state.shuffle, true)
    compare(state.contextUri, "")
    compare(state.contextHref, "")
    compare(state.contextType, "")
  }

  function test_normalizePlaybackState_keepsRadioContextFields() {
    var state = Api.normalizePlaybackState({
      is_playing: true,
      progress_ms: 1000,
      device: { id: "phone", name: "Phone", type: "Smartphone", is_active: true },
      context: {
        uri: "spotify:playlist:radio",
        href: "https://api.spotify.com/v1/playlists/radio",
        type: "playlist"
      },
      item: {
        id: "track", uri: "spotify:track:track", type: "track",
        name: "A song", duration_ms: 180000
      }
    }, 192)

    compare(state.contextUri, "spotify:playlist:radio")
    compare(state.contextHref, "https://api.spotify.com/v1/playlists/radio")
    compare(state.contextType, "playlist")
  }

  function test_normalizePlaybackState_preservesUnknownRemoteVolume() {
    var state = Api.normalizePlaybackState({
      device: {
        id: "phone", name: "Phone", type: "Smartphone", is_active: true,
        is_restricted: false, volume_percent: null, supports_volume: true
      }
    }, 192)

    verify(state !== null)
    compare(state.device.volumePercent, null)
    compare(state.device.supportsVolume, true)
  }

  function test_normalizePlaybackState_rejectsEmptyPlaybackResponse() {
    compare(Api.normalizePlaybackState(null, 192), null)
    compare(Api.normalizePlaybackState({}, 192), null)
    compare(Api.normalizePlaybackState([], 192), null)
  }

  function test_mergeUnique_preservesOrder() {
    var merged = Api.mergeUnique([
      { uri: "spotify:track:a" },
      { uri: "spotify:track:b" }
    ], [
      { uri: "spotify:track:b" },
      { uri: "spotify:track:c" }
    ])
    compare(merged.length, 3)
    compare(merged[0].uri, "spotify:track:a")
    compare(merged[2].uri, "spotify:track:c")
  }

  function test_redact_coversHeadersFormsUrlsAndJson() {
    var raw = [
      "Authorization: Bearer access-value",
      "refresh_token=refresh-value&code=authorization-value",
      "?code_verifier=verifier-value&client_secret=secret-value",
      "{\"access_token\":\"json-token\",\"password\":\"nope\"}"
    ].join("\n")
    var safe = Api.redact(raw)

    verify(safe.indexOf("access-value") === -1)
    verify(safe.indexOf("refresh-value") === -1)
    verify(safe.indexOf("authorization-value") === -1)
    verify(safe.indexOf("verifier-value") === -1)
    verify(safe.indexOf("secret-value") === -1)
    verify(safe.indexOf("json-token") === -1)
    verify(safe.indexOf("\"nope\"") === -1)
    verify(safe.indexOf("<redacted>") >= 0)
  }

  function test_clockFormatting() {
    compare(Api.millisecondsToClock(0), "0:00")
    compare(Api.millisecondsToClock(61000), "1:01")
    compare(Api.millisecondsToClock(-100), "0:00")
  }

  function test_quotaErrorIncludesMachineReason() {
    compare(Api.responseError(429, {
      error: { status: 429, message: "Too many requests", reason: "QUOTA_EXCEEDED" }
    }, ""), "Too many requests (QUOTA_EXCEEDED)")
  }

  function test_shortcutHints_matchRequiredModifiersAndKeycaps() {
    compare(Api.normalizedShortcutHints(undefined), "On")
    compare(Api.normalizedShortcutHints("On"), "On")
    compare(Api.normalizedShortcutHints("Off"), "Off")
    compare(Api.normalizedShortcutHints("off"), "On")

    var none = { ctrl: false, shift: false, alt: false }
    var ctrl = { ctrl: true, shift: false, alt: false }
    var shift = { ctrl: false, shift: true, alt: false }
    var ctrlShift = { ctrl: true, shift: true, alt: false }
    var altShift = { ctrl: false, shift: true, alt: true }

    compare(Api.shortcutHintCaption("Space", none, true), "Space")
    compare(Api.shortcutHintCaption("Space", ctrl, true), "")
    compare(Api.shortcutHintCaption("Ctrl+S", ctrl, true), "S")
    compare(Api.shortcutHintCaption("Ctrl+S", none, true), "")
    compare(Api.shortcutHintCaption("Ctrl+S", ctrlShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+L", ctrl, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+L", ctrlShift, true), "L")
    compare(Api.shortcutHintCaption("Shift+F10", ctrlShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", ctrlShift, true), "A")
    compare(Api.shortcutHintCaption("Alt+Shift+H", altShift, true), "H")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", altShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+B", ctrlShift, true), "B")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", ctrl, true), "")
    compare(Api.shortcutHintCaption("Alt+Left", { ctrl: false, shift: false, alt: true }, true), "←")
    compare(Api.shortcutHintCaption(["Ctrl+Up", "Ctrl+Down"], ctrl, true), "↑ ↓")
    compare(Api.shortcutHintCaption(["/", "Ctrl+F"], none, true), "/")
    compare(Api.shortcutHintCaption(["/", "Ctrl+F"], ctrl, true), "F")
    compare(Api.shortcutHintCaption("Shift+Right", shift, true), "→")
    compare(Api.shortcutHintCaption("Shift+F10", shift, true), "F10")
    compare(Api.shortcutHintCaption("Shift+F10", none, true), "")
    compare(Api.shortcutHintCaption("Menu", none, true), "Menu")
    compare(Api.shortcutOverlayLabel("Shift+F10", shift, true, "↵"), "↵ F10")
    compare(Api.shortcutOverlayLabel("Shift+F10", shift, true, ""), "F10")
    compare(Api.shortcutHintCaption("C", none, true), "C")
    compare(Api.shortcutOverlayLabel("C", none, true, "↵"), "↵ C")
    compare(Api.shortcutHintCaption("Ctrl+,", ctrl, true), ",")
    compare(Api.shortcutHintCaption("Ctrl+/", ctrl, true), "/")
    compare(Api.shortcutHintCaption("Esc", none, true), "Esc")
    compare(Api.shortcutHintCaption("Space", none, false), "")
    compare(Api.shortcutOverlayLabel("Space", none, true, "Tab"), "Tab Space")
    compare(Api.shortcutOverlayLabel(["/", "Ctrl+F"], none, true, "Tab"), "Tab /")
    compare(Api.shortcutOverlayLabel("Space", none, true, ""), "Space")
    compare(Api.shortcutOverlayLabel("Space", none, true, "↵"), "↵ Space")
    compare(Api.shortcutOverlayLabel("Ctrl+S", none, true, ""), "")
    compare(Api.shortcutOverlayLabel("Space", none, false, "Tab"), "")
    compare(Api.shortcutModifierFlagsAfterEvent(0, false, 3, 0), 3)
    compare(Api.shortcutModifierFlagsAfterEvent(3, true, 0, 1), 3)
    compare(Api.shortcutModifierFlagsAfterEvent(3, false, 3, 1), 2)
    compare(Api.shortcutModifierFlagsAfterEvent(1, false, 1, 1), 0)
    compare(Api.shortcutModifierFlagsAfterEvent(3, true, 0, 0), 3)
  }

  function test_searchShortcutAction_focusesThenTogglesScope() {
    compare(Api.searchShortcutAction(false, true, true), "focus")
    compare(Api.searchShortcutAction(false, true, false), "enter-context")
    compare(Api.searchShortcutAction(true, true, true), "toggle-scope")
    compare(Api.searchShortcutAction(true, true, false), "toggle-scope")
    compare(Api.searchShortcutAction(false, false, true), "focus")
    compare(Api.searchShortcutAction(true, false, false), "focus")
  }

  function test_cursorNavigation_wrapsAndLeavesLists() {
    compare(Api.ensureCursorAction(["play", "next"], "shuffle", "play"), "play")
    compare(Api.ensureCursorAction(["play", "next"], "next", "play"), "next")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "play", 1), "next")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "next", 1), "shuffle")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "shuffle", -1), "next")
    compare(Api.listIndexAfterMove(3, 0, 1), 1)
    compare(Api.listIndexAfterMove(3, 2, 1), -1)
    compare(Api.listIndexAfterMove(3, 0, -1), -1)
    compare(Api.listIndexAfterMove(3, -1, 1), 0)
  }

  function test_cursorNavHint_marksTabAndArrowDestinations() {
    var query = {
      currentRegion: "footer",
      currentAction: "play",
      regionActions: ["previous", "play", "next"],
      tabRegion: "sidebar",
      tabAction: "nav-home",
      backtabRegion: "page",
      backtabAction: "list",
      modifiersHeld: false
    }
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "play"
    })), "↵")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "next"
    })), "↓")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "previous"
    })), "↑")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "sidebar", action: "nav-home"
    })), "Tab")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "page", action: "list"
    })), "⇧Tab")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "next", modifiersHeld: true
    })), "")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "sidebar", action: "nav-home", modifiersHeld: true
    })), "Tab")
    compare(Api.cursorNavHint({
      region: "popup",
      action: "sleep-30",
      currentRegion: "popup",
      currentAction: "sleep-15",
      regionActions: ["sleep-15", "sleep-30", "sleep-cancel"],
      tabRegion: "popup",
      tabAction: "sleep-30"
    }), "Tab")
    compare(Api.cursorNavHint({
      region: "footer",
      action: "play",
      currentRegion: "footer",
      currentAction: "play",
      tabRegion: "footer",
      tabAction: "play",
      cursorActive: false
    }), "Tab")
  }

  function test_cursorListRowHint_marksTheRowsArrowsWouldPress() {
    var list = {
      count: 5,
      currentIndex: 3,
      atList: true,
      modifiersHeld: false
    }
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 3 }, list)), "↵")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 2 }, list)), "↑")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 4 }, list)), "↓")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 0 }, list)), "")
    compare(Api.cursorListRowHint({
      rowIndex: 0, count: 5, currentIndex: 3, previousIsCurrent: true
    }), "↓")
    compare(Api.cursorListRowHint({
      rowIndex: 4, count: 5, currentIndex: 3, nextIsCurrent: true
    }), "↑")
    compare(Api.cursorNavHint({
      region: "sidebar",
      action: "nav-settings",
      currentRegion: "sidebar",
      currentAction: "sidebar-playlists",
      regionActions: ["nav-playlists", "sidebar-playlists", "nav-settings"],
      listAction: "sidebar-playlists",
      listIndex: 3,
      listCount: 8
    }), "")
    compare(Api.cursorNavHint({
      region: "sidebar",
      action: "nav-settings",
      currentRegion: "sidebar",
      currentAction: "sidebar-playlists",
      regionActions: ["nav-playlists", "sidebar-playlists", "nav-settings"],
      listAction: "sidebar-playlists",
      listIndex: 7,
      listCount: 8
    }), "↓")
    compare(Api.cursorListRowHint({
      rowIndex: 3, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1
    }), "")
    compare(Api.cursorListRowHint({
      rowIndex: 1, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1
    }), "Tab")
    compare(Api.cursorListRowHint({
      rowIndex: 1, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1,
      modifiersHeld: true
    }), "Tab")
    compare(Api.cursorListRowHint({
      rowIndex: 3, count: 5, currentIndex: 3, atList: true, tabIsList: true
    }), "↵")
    compare(Api.listHintRowIndex(8, 1), 1)
    compare(Api.listHintRowIndex(8, -1), 0)
    compare(Api.listHintRowIndex(0, 0), -1)
  }

  function test_tabCursorDestination_entersTheSongListThenLeaves() {
    var regions = ["sidebar", "header", "page", "footer"]
    var actionsByRegion = {
      sidebar: ["nav-home", "nav-playlists", "sidebar-playlists", "nav-settings"],
      header: ["search", "help", "close"],
      page: ["playlist-play", "playlist-more", "sort", "list", "more"],
      footer: ["shuffle", "play", "next"]
    }
    var base = {
      regions: regions,
      actionsByRegion: actionsByRegion,
      pageActions: actionsByRegion.page,
      listCount: 12
    }
    function dest(region, action, back) {
      return Api.tabCursorDestination(Api.assign(Api.assign({}, base), {
        currentRegion: region,
        currentAction: action,
        back: back === true
      }))
    }
    var next = dest("header", "search")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "playlist-play")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "sort")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "list")
    compare(next.region, "footer")
    compare(next.action, "play")
    next = dest("page", "more")
    compare(next.region, "footer")
    compare(next.action, "play")
    next = dest("footer", "play")
    compare(next.region, "sidebar")
    compare(next.action, "nav-home")
    next = dest("footer", "play", true)
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "list", true)
    compare(next.region, "page")
    compare(next.action, "sort")
    next = dest("page", "more", true)
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "playlist-play", true)
    compare(next.region, "header")
    compare(next.action, "search")
    next = dest("header", "search", true)
    compare(next.region, "sidebar")
    compare(next.action, "nav-settings")
    next = Api.tabCursorDestination(Api.assign(Api.assign({}, base), {
      currentRegion: "footer",
      currentAction: "play",
      cursorActive: false
    }))
    compare(next.region, "footer")
    compare(next.action, "play")
    var searchPage = ["search-track", "search-artist", "search-album", "list"]
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "header",
      currentAction: "scope",
      pageActions: searchPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: searchPage,
        footer: actionsByRegion.footer
      },
      listCount: 8,
      pageLanding: "search-track"
    })
    compare(next.region, "page")
    compare(next.action, "search-track")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "search-track",
      pageActions: searchPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: searchPage,
        footer: actionsByRegion.footer
      },
      listCount: 8,
      pageLanding: "search-track"
    })
    compare(next.region, "page")
    compare(next.action, "list")
    var artistPage = ["detail-play", "list-albums", "list-songs", "detail-thisis"]
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "header",
      currentAction: "search",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "page")
    compare(next.action, "list-albums")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "list-albums",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "page")
    compare(next.action, "list-songs")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "list-songs",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "footer")
    compare(next.action, "play")
    verify(Api.isCursorListAction("list"))
    verify(Api.isCursorListAction("list-songs"))
    verify(!Api.isCursorListAction("sort"))
  }

  function test_tabCursorDestination_skipsEmptyListsAndCyclesPopups() {
    var empty = Api.tabCursorDestination({
      regions: ["header", "page", "footer"],
      currentRegion: "header",
      currentAction: "search",
      pageActions: ["sort", "list"],
      actionsByRegion: {
        header: ["search"],
        page: ["sort", "list"],
        footer: ["play"]
      },
      listCount: 0
    })
    compare(empty.region, "page")
    compare(empty.action, "sort")
    var popup = Api.tabCursorDestination({
      regions: ["popup"],
      currentRegion: "popup",
      currentAction: "sleep-15",
      actionsByRegion: { popup: ["sleep-15", "sleep-30", "sleep-cancel"] }
    })
    compare(popup.region, "popup")
    compare(popup.action, "sleep-30")
  }

  function test_searchEscapeAction_clearsThenReleasesFocus() {
    compare(Api.searchEscapeAction(true, true, "query", false), "dismiss")
    compare(Api.searchEscapeAction(true, false, "query", false), "dismiss")
    compare(Api.searchEscapeAction(true, false, "", true), "dismiss")
    compare(Api.searchEscapeAction(true, true, "", false), "blur")
    compare(Api.searchEscapeAction(true, true, "   ", false), "blur")
    compare(Api.searchEscapeAction(true, false, "", false), "")
    compare(Api.searchEscapeAction(false, true, "query", true), "")
  }

  function test_opaqueSurface_floorsAlphaAndKeepsHue() {
    var glass = Qt.rgba(0.95, 0.95, 0.97, 0.3)
    var floored = Api.opaqueSurface(glass, 0.96)
    fuzzyCompare(floored.a, 0.96, 0.001)
    fuzzyCompare(floored.r, 0.95, 0.001)
    fuzzyCompare(floored.b, 0.97, 0.001)
    var solid = Qt.rgba(0.1, 0.1, 0.1, 1)
    compare(Api.opaqueSurface(solid, 0.96), solid)
    compare(Api.opaqueSurface(null, 0.96), null)
  }
}
