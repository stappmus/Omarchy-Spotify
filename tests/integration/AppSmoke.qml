import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  QtObject {
    id: host
    property var barConfig: ({layout: {centerEnd: [{id: "quickshell.spotify", clientId: "invalid", showArtwork: "Off"}]}})
  }
  Plugin.Service { id: spotifyService; shell: host; manifest: ({id: "quickshell.spotify"}) }
  Plugin.SpotifyConnectManager { id: receiver; pluginDir: "/nonexistent"; activating: true }
  Plugin.Panel { id: panel; service: spotifyService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }
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
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
