import QtQuick
import Quickshell.Io

import "Api.js" as Api

// Runs one-shot local discovery, activation, and Sonos control commands. There
// is no resident network scanner; a restricted active speaker triggers one
// discovery so the UI can use its local transport controls.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property string pluginDir: ""
  property var devices: []
  property bool loading: false
  property bool activating: false
  property string activatingDeviceId: ""
  property string activationInput: ""
  property string discoveryResult: ""
  property string activationResult: ""
  property bool controlling: false
  property string controllingDeviceId: ""
  property string controlAction: ""
  property string controlValue: ""
  property string controlInput: ""
  property string controlResult: ""
  property string lastError: ""

  property var queuedControls: []
  property int controlGeneration: 0
  property int runningControlGeneration: 0
  property double discoveryStartedAt: 0
  // Absolute controls coalesce; relative transport commands retain order.
  readonly property bool controlBusy: controlling || controlCommand.running
    || activating

  signal refreshed()
  signal refreshFailed(string reason)
  signal activated(string deviceId)
  signal activationFailed(string reason)
  signal controlled(string deviceId, string action, string value)
  signal controlFailed(string deviceId, string reason)

  function validDeviceId(value) {
    return Api.isSpotifyConnectDeviceId(value)
  }

  function refresh() {
    if (loading || discoveryCommand.running || !pluginDir) return
    discoveryStartedAt = Date.now()
    loading = true
    lastError = ""
    discoveryResult = ""
    discoveryCommand.command = [pluginDir + "/scripts/spotify-connect-device.py", "discover"]
    discoveryCommand.running = true
  }

  function activate(deviceId, accessToken) {
    var requested = String(deviceId || "")
    var token = String(accessToken || "").trim()
    if (activating || activationCommand.running || !pluginDir
        || !validDeviceId(requested)) return
    if (token.length > 4096 || /\s/.test(token)) return
    activating = true
    activatingDeviceId = requested
    // Both values cross the process boundary only through stdin. In
    // particular, never expose the short-lived streaming token in argv.
    activationInput = requested + "\n" + token
    activationResult = ""
    lastError = ""
    activationCommand.command = [pluginDir + "/scripts/spotify-connect-device.py", "activate"]
    activationCommand.running = true
  }

  function control(deviceId, action, value) {
    var requested = String(deviceId || "")
    var command = String(action || "").trim().toLowerCase()
    var argument = String(value === undefined ? "" : value).trim()
    if (!pluginDir || !validDeviceId(requested)
        || ["play", "pause", "next", "previous", "seek", "volume", "mode"]
          .indexOf(command) < 0
        || argument.length > 128 || /[\r\n]/.test(argument)) return false
    if (controlBusy) {
      var queue = queuedControls.slice()
      if (["volume", "seek", "mode"].indexOf(command) >= 0)
        queue = queue.filter(function(item) { return item.device !== requested || item.action !== command })
      if (queue.length >= 32) {
        controlFailed(requested, "Too many pending speaker commands. Try again.")
        return false
      }
      queue.push({device: requested, action: command, value: argument})
      queuedControls = queue
      return true
    }
    runningControlGeneration = controlGeneration
    controlling = true
    controllingDeviceId = requested
    controlAction = command
    controlValue = argument
    controlInput = requested + "\n" + command + "\n" + argument
    controlResult = ""
    lastError = ""
    controlCommand.command = [pluginDir + "/scripts/spotify-connect-device.py", "control"]
    controlCommand.running = true
    return true
  }

  function drainControls() {
    if (controlBusy || !queuedControls.length) return
    var queue = queuedControls.slice()
    var next = queue.shift()
    queuedControls = queue
    control(next.device, next.action, next.value)
  }

  function discardQueuedControls() { queuedControls = []; controlGeneration++ }

  Timer {
    id: drainTimer
    interval: 0
    onTriggered: root.drainControls()
  }
  onControlBusyChanged: if (!controlBusy) drainTimer.restart()

  function rememberVolume(deviceId, value) {
    var requested = String(deviceId || "")
    var volume = Api.normalizeVolumePercent(value)
    if (!requested || volume === null) return
    var changed = false
    var next = []
    for (var i = 0; i < devices.length; i++) {
      var item = devices[i]
      if (String((item && item.id) || "") !== requested) {
        next.push(item)
        continue
      }
      var updated = Api.shallowCopy(item)
      updated.volumePercent = volume
      updated.volumeObservedAt = Date.now()
      changed = true
      next.push(updated)
    }
    if (changed) devices = next
  }

  function applyDiscovery(raw) {
    var payload = Api.parseJson(raw, null)
    if (!payload || payload.schemaVersion !== 1 || !Array.isArray(payload.devices)) {
      devices = []
      return
    }
    var next = []
    for (var i = 0; i < payload.devices.length && next.length < 32; i++) {
      var item = payload.devices[i] || {}
      var id = String(item.id || "")
      if (!validDeviceId(id)) continue
      next.push({
        id: id,
        name: String(item.name || "Spotify Connect device").slice(0, 160),
        type: String(item.type || "Speaker").slice(0, 80),
        description: String(item.description || "").slice(0, 260),
        brand: String(item.brand || "").slice(0, 120),
        model: String(item.model || "").slice(0, 120),
        localDiscovery: true,
        activationRequired: true,
        activeUser: item.activeUser === true,
        volumePercent: Api.normalizeVolumePercent(item.volumePercent),
        volumeObservedAt: discoveryStartedAt,
        tokenType: Api.spotifyConnectTokenType(item.tokenType)
      })
    }
    devices = next
  }

  Process {
    id: discoveryCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.discoveryResult = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode === 0) {
        root.applyDiscovery(root.discoveryResult)
        root.discoveryResult = ""
        root.lastError = ""
        root.refreshed()
      } else {
        root.discoveryResult = ""
        root.lastError = "Could not find Spotify Connect devices on this network"
        root.refreshFailed(root.lastError)
      }
    }
  }

  Process {
    id: activationCommand
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.activationResult = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.activationInput + "\n")
      root.activationInput = ""
    }
    onExited: function(exitCode) {
      var requested = root.activatingDeviceId
      root.activating = false
      root.activatingDeviceId = ""
      root.activationInput = ""
      root.activationResult = ""
      if (exitCode === 0) {
        root.lastError = ""
        root.activated(requested)
      } else {
        root.lastError = "Could not connect to this Spotify Connect device"
        root.activationFailed(root.lastError)
      }
    }
  }

  Process {
    id: controlCommand
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.controlResult = String(text || "")
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.controlInput + "\n")
      root.controlInput = ""
    }
    onExited: function(exitCode) {
      var requested = root.controllingDeviceId
      var action = root.controlAction
      var value = root.controlValue
      root.controlling = false
      root.controllingDeviceId = ""
      root.controlAction = ""
      root.controlValue = ""
      root.controlInput = ""
      root.controlResult = ""
      if (root.runningControlGeneration !== root.controlGeneration) return
      if (exitCode === 0) {
        root.lastError = ""
        root.controlled(requested, action, value)
      } else {
        root.lastError = "Could not control this Sonos speaker"
        root.controlFailed(requested, root.lastError)
      }
    }
  }
}
