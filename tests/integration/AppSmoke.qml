import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  QtObject {
    id: host
    function serviceFor(moduleName) { return spotifyService }
    property var barConfig: ({layout: {centerEnd: [{id: "quickshell.spotify", clientId: "invalid", showArtwork: "Off"}]}})
  }
  Plugin.Service { id: spotifyService; shell: host; manifest: ({id: "quickshell.spotify"}) }
  Plugin.SpotifyConnectManager { id: receiver; pluginDir: "/nonexistent"; activating: true }
  Plugin.Panel { id: panel; service: spotifyService; width: 1280; height: 800 }
  QtObject {
    id: testBar
    property var shell: host
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 32
    property string fontFamily: "sans-serif"
    property string position: "top"
    property color foreground: "white"
    property color barForeground: "white"
    property color background: "black"
  }
  Plugin.BarWidget { id: widget; bar: testBar }
  Plugin.MediaRow {
    id: measuredRow
    width: 240
    itemData: ({kind:"item", type:"track", uri:"spotify:track:test", name:"A long title that needs compact controls", durationMs:120000})
    showQueue: true
    showSave: true
  }
  Timer {
    interval: 20
    running: true
    onTriggered: {
      var fullWidth = measuredRow.fullActionWidth
      measuredRow.actionsExpanded = true
      if (Math.abs(measuredRow.fullActionWidth - fullWidth) > 0.1)
        throw new Error("Action visibility changed the full row measurement")
      var expected = decodeURIComponent(String(Qt.resolvedUrl("plugin"))).replace(/^file:\/\//, "")
      if (spotifyService.pluginDir !== expected) throw new Error("Public manifest lost plugin path")
      if (!spotifyService.settingsReady || spotifyService.settings.clientId !== "invalid")
        throw new Error("Public centerEnd settings not loaded")
      spotifyService.applySettings({})
      if (spotifyService.settings.showArtwork !== "Off") throw new Error("Empty widget push reset settings")
      if (!receiver.control("speaker123", "volume", "10") || !receiver.control("speaker123", "volume", "25"))
        throw new Error("Busy receiver rejected valid absolute control")
      receiver.control("speaker123", "next", "")
      receiver.control("speaker123", "next", "")
      receiver.control("speaker123", "mode", "SHUFFLE_REPEAT_ONE")
      if (receiver.queuedControls.length !== 4 || receiver.queuedControls[0].value !== "25")
        throw new Error("Speaker queue lost relative commands or failed to coalesce")
      receiver.discardQueuedControls()
      if (receiver.queuedControls.length) throw new Error("Stale speaker controls survived cancellation")
      spotifyService.remotePlayback = {device: {id: "speaker123"}}
      var modes = ["NORMAL", "REPEAT_ALL", "REPEAT_ONE", "SHUFFLE_NOREPEAT", "SHUFFLE", "SHUFFLE_REPEAT_ONE"]
      for (var i = 0; i < modes.length; i++) {
        spotifyService.applySonosControlResult("mode", modes[i])
        var state = spotifyService.remotePlayback
        if (spotifyService.sonosPlayMode(state.repeatMode, state.shuffle) !== modes[i])
          throw new Error("Sonos mode did not round trip: " + modes[i])
      }
      var device = {id: "speaker123"}
      spotifyService.rememberRemoteVolume(device, 70, 200)
      spotifyService.rememberRemoteVolume(device, 10, 100)
      if (spotifyService.rememberedRemoteVolumePercent !== 70) throw new Error("Stale discovery replaced fresh volume")
      spotifyService.search("smoke-test", "track")
      if (spotifyService.searchLoading || !spotifyService.searchError)
        throw new Error("Search service did not return the authorization error")
      if (!panel.primaryNavigationItems().some(function(item) { return item.id === "search" }))
        throw new Error("Search navigation is missing")
      spotifyService.clearSearch()
      if (spotifyService.searchQuery !== "") throw new Error("Search state did not clear")
      var removed = null
      var volumes = []
      var confirmations = []
      spotifyService.api.nativeSession = {
        request: function(method, path, query, body, done) {
          var base = "/playlists/test"
          var track = {item: {type: "track", id: "song", name: "Song", uri: "spotify:track:song"}}
          if (method === "DELETE" && path === base + "/items") {
            removed = body
            done(200, {snapshot_id: "updated"}, "")
          } else if (path === "/me/player/volume") {
            volumes.push([query.device_id, query.volume_percent])
            confirmations.push(done)
          } else if (path === base)
            done(200, {type: "playlist", id: "test", name: "Playlist", collaborative: true, items: {total: 3}}, "")
          else if (path === base + "/items?limit=50")
            done(200, {items: [track, {item: null}], snapshot_id: "revision", offset: 0, next: base + "/items?offset=2"}, "")
          else if (path.endsWith("/items?offset=2"))
            done(200, {items: [track], snapshot_id: "revision", offset: 2, next: null}, "")
          else done(200, [], "")
          return null
        }
      }
      spotifyService.openDetail({kind: "context", type: "playlist", id: "test"}, "", 3)
      if (spotifyService.detailItems.length !== 3 || spotifyService.detailNext
          || spotifyService.detailItems[0].name !== "Song"
          || spotifyService.detailItems[2].playlistPosition !== 2)
        throw new Error("Playlist detail failed to load both item pages")
      var unavailable = spotifyService.detailItems[1]
      measuredRow.itemData = unavailable
      if (unavailable.name !== "Unavailable track" || unavailable.playlistPosition !== 1
          || measuredRow.enabled || measuredRow.fullActionCount)
        throw new Error("Unavailable playlist entry became actionable or lost its position")
      spotifyService.removePlaylistItem(spotifyService.detailItems[2], spotifyService.detailItem)
      if (!removed || removed.snapshot_id !== "revision"
          || JSON.stringify(removed.items) !== JSON.stringify([{uri: "spotify:track:song", positions: [2]}]))
        throw new Error("Removing a duplicate lost its position or revision")

      function selectSpeaker(id, percent) {
        spotifyService.remotePlayback = {device: {id: id, name: "Speaker", active: true,
          type: "Speaker", supportsVolume: true, volumePercent: percent}}
      }
      selectSpeaker("office123", 42)
      if (typeof panel === "undefined") spotifyService.toggleMute()
      else panel.toggleMute()
      selectSpeaker("studio123", 2)
      spotifyService.toggleMute()
      selectSpeaker("office123", 0)
      if (typeof widget === "undefined") spotifyService.toggleMute()
      else widget.toggleMute()
      selectSpeaker("studio123", 0)
      spotifyService.toggleMute()
      while (confirmations.length) confirmations.shift()(204, null, "")
      if (JSON.stringify(volumes) !== JSON.stringify([
          ["office123", 0], ["studio123", 0], ["office123", 42], ["studio123", 2]]))
        throw new Error("Mute did not restore each speaker's audible level: " + JSON.stringify(volumes))
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
