import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

// Owns only short-lived runtime/authentication commands. The plugin backend
// (or its spotifyd fallback) is supervised by a user unit and is never launched
// as an untracked child of the shell.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property string pluginDir: ""
  property string deviceName: "Omarchy Spotify"
  property int bitrateKbps: 320
  property string audioDevice: ""
  property var audioSinks: []
  property string unitName: "omarchy-spotify.service"
  property bool authenticationCancelled: false
  property bool mprisPresent: false

  property bool binaryAvailable: false
  property bool binaryChecked: false
  property bool unitAvailable: false
  property bool unitChecked: false
  property bool usingFallbackRuntime: false
  property bool automaticSetupAttempted: false
  property bool credentialsAvailable: false
  property bool credentialsChecked: false
  property bool serviceActive: false
  readonly property bool requirementsChecked: binaryChecked && unitChecked
  readonly property bool playbackReady: binaryAvailable && unitAvailable
  readonly property bool setupRequired: requirementsChecked && !playbackReady
  readonly property bool running: mprisPresent || serviceActive
  property bool busy: false
  property bool setupBusy: false
  property bool authenticationBusy: false
  property bool credentialsClearBusy: false
  property bool configurationBusy: false
  property bool configurationPending: false
  property bool startAfterConfiguration: false
  property string configurationInput: ""
  property bool authAfterStop: false
  property string lastError: ""
  property bool terminalFailure: false
  property bool explicitStart: false
  property int startupStatusAttempts: 0

  signal started()
  signal stopped()
  signal setupSucceeded()
  signal setupFailed(string reason)
  signal authenticationSucceeded()
  signal authenticationFailed(string reason)
  signal credentialsCleared()
  signal credentialsClearFailed(string reason)

  function safeError(value) {
    return Api.redact(String(value || ""))
  }

  function checkRequirements() {
    if (!pluginDir) return
    // pluginDir is supplied by the host after this item's child Processes are
    // constructed. Build path-dependent commands at launch so an initial
    // empty binding cannot run /scripts/playback-runtime.sh and report 127.
    if (!binaryCheck.running) {
      binaryCheck.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "check"]
      binaryCheck.running = true
    }
    if (!unitCheck.running) {
      unitCheck.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "unit"]
      unitCheck.running = true
    }
    checkCredentials()
    refreshAudioSinks()
    requestConfiguration()
  }

  // Omarchy deliberately does not execute install hooks while cloning a
  // plugin. Once this enabled plugin is loaded, install its verified release
  // backend into the user's runtime directory. The readiness check also
  // rejects a stale binary or unit, so plugin updates replace older installs.
  function installPlaybackBackendIfNeeded() {
    if (automaticSetupAttempted || setupBusy || !pluginDir
        || !requirementsChecked) return
    if (playbackReady && !usingFallbackRuntime) return
    automaticSetupAttempted = true
    setupPlayback()
  }

  function setupPlayback() {
    if (setupBusy || !pluginDir) return
    lastError = ""
    setupBusy = true
    setupCommand.command = [pluginDir + "/scripts/setup-playback.sh"]
    setupCommand.running = true
  }

  function refreshAudioSinks() {
    if (!pluginDir || sinkList.running) return
    sinkList.command = ["/usr/bin/bash", pluginDir + "/scripts/list-audio-sinks.sh"]
    sinkList.running = true
  }

  function requestConfiguration() {
    configurationPending = true
    configurationDelay.restart()
  }

  function checkCredentials() {
    if (!pluginDir || credentialsCheck.running) return
    // Build this path at launch. pluginDir is assigned after the child Process
    // exists, and a stale initial binding can otherwise run /scripts/... and
    // incorrectly report that a saved playback authorization is missing.
    credentialsCheck.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "credentials"]
    credentialsCheck.running = true
  }

  function refreshStatus() {
    if (!pluginDir || statusCheck.running) return
    statusCheck.command = ["systemctl", "--user", "is-active", unitName]
    statusCheck.running = true
  }

  function start(explicit) {
    if (terminalFailure && explicit !== true) return
    explicitStart = explicit === true
    if (explicitStart) terminalFailure = false
    if (busy || serviceActive) return
    if (!binaryAvailable) {
      lastError = "Playback support is not installed yet"
      return
    }
    if (!unitAvailable) {
      lastError = "Playback support needs to be set up"
      return
    }
    lastError = ""
    busy = true
    startAfterConfiguration = true
    configurationPending = true
    configureDeviceName()
  }

  function startCommandNow() {
    startAfterConfiguration = false
    startCommand.command = ["/usr/bin/bash", pluginDir + "/scripts/playback-runtime.sh",
      explicitStart ? "start-explicit" : "start"]
    startCommand.running = true
  }

  function configureDeviceName() {
    if (configurationBusy || configWriter.running) return
    if (!pluginDir || !deviceName) {
      if (startAfterConfiguration) startCommandNow()
      return
    }
    configurationPending = false
    // The third line names the PulseAudio sink librespot opens. Blank leaves
    // the key out, so playback follows Omarchy's system default output.
    configurationInput = String(deviceName) + "\n" + String(bitrateKbps)
      + "\n" + String(audioDevice) + "\n"
    configurationBusy = true
    configWriter.command = [pluginDir + "/scripts/configure-spotifyd.sh"]
    configWriter.running = true
  }

  function stop() {
    if (busy && !authenticationBusy) return
    lastError = ""
    busy = true
    stopCommand.running = true
  }

  function authenticate() {
    if (authenticationBusy) return
    if (!binaryAvailable) {
      lastError = "Playback support is not installed yet"
      authenticationFailed(lastError)
      return
    }
    if (!unitAvailable) {
      lastError = "Playback support needs to be set up"
      authenticationFailed(lastError)
      return
    }
    authenticationBusy = true
    busy = true
    lastError = ""
    authAfterStop = true
    stopCommand.running = true
  }

  function beginAuthenticationProcess() {
    authAfterStop = false
    if (authenticationCancelled) {
      authenticationCancelled = false
      authenticationBusy = false
      busy = false
      return
    }
    authCommand.command = [pluginDir + "/scripts/spotifyd-auth.sh"]
    authCommand.running = true
  }

  function cancelAuthentication() {
    if (!authenticationBusy && !authAfterStop) return
    authenticationCancelled = true
    authAfterStop = false
    lastError = ""
    if (authCommand.running) authCommand.running = false
    authenticationBusy = false
    busy = false
  }

  function returnFromAuthentication() {
    if (!pluginDir || returnCommand.running) return
    returnCommand.command = [pluginDir + "/scripts/return-from-auth.sh"]
    returnCommand.running = true
  }

  function clearCredentials() {
    if (credentialsClearBusy || authenticationBusy) return
    credentialsClearBusy = true
    busy = true
    lastError = ""
    clearCredentialsCommand.command = [pluginDir + "/scripts/spotifyd-logout.sh"]
    clearCredentialsCommand.running = true
  }

  onMprisPresentChanged: {
    if (mprisPresent) serviceActive = true
    else refreshStatus()
  }

  onDeviceNameChanged: requestConfiguration()
  onBitrateKbpsChanged: requestConfiguration()
  onAudioDeviceChanged: requestConfiguration()
  onPluginDirChanged: {
    if (!pluginDir) return
    checkRequirements()
    refreshStatus()
  }

  Component.onCompleted: checkRequirements()

  Timer {
    id: configurationDelay
    interval: 0
    onTriggered: root.configureDeviceName()
  }

  Process {
    id: configWriter
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.configurationInput + "\n")
      root.configurationInput = ""
    }
    onExited: function(exitCode) {
      root.configurationBusy = false
      root.configurationInput = ""
      var shouldStart = root.startAfterConfiguration
      if (exitCode === 3) {
        root.startAfterConfiguration = false
        root.busy = false
        root.lastError = "Playback settings contain an invalid device name or quality"
        return
      }
      if (exitCode !== 0 && exitCode !== 4)
        root.lastError = "Could not update playback settings"
      if (root.configurationPending) {
        configurationDelay.restart()
        return
      }
      if (shouldStart) root.startCommandNow()
    }
  }

  Process {
    id: binaryCheck
    onExited: function(exitCode) {
      root.binaryAvailable = exitCode === 0
      root.binaryChecked = true
      root.installPlaybackBackendIfNeeded()
    }
  }

  Process {
    id: unitCheck
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var unit = String(stdout.text || "").trim()
      root.unitAvailable = exitCode === 0
      root.unitChecked = true
      if (unit) root.unitName = unit
      root.usingFallbackRuntime = exitCode === 0
        && unit === "omarchy-spotifyd.service"
      if (exitCode === 0) root.requestConfiguration()
      root.installPlaybackBackendIfNeeded()
    }
  }

  Process {
    id: setupCommand
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.setupBusy = false
      if (exitCode === 0) {
        root.lastError = ""
        root.binaryAvailable = true
        root.binaryChecked = true
        root.unitAvailable = true
        root.unitChecked = true
        root.checkRequirements()
        root.refreshStatus()
        root.setupSucceeded()
        return
      }
      root.checkRequirements()
      root.lastError = exitCode === 20
        ? "Omarchy could not open the system authorization prompt"
        : (exitCode === 21
          ? "Playback setup was cancelled or could not install the required package"
          : "Playback setup could not be completed")
      root.setupFailed(root.lastError)
    }
  }

  Timer {
    id: startupStatusTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.refreshStatus()
      if (root.mprisPresent || root.terminalFailure || ++root.startupStatusAttempts >= 10) stop()
    }
  }

  Process {
    id: statusCheck
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.serviceActive = exitCode === 0
      if (!root.serviceActive && !failureCheck.running) {
        failureCheck.command = ["/usr/bin/bash", root.pluginDir + "/scripts/playback-runtime.sh", "failure"]
        failureCheck.running = true
      }
    }
  }

  Process {
    id: failureCheck
    stdout: StdioCollector { id: failureOutput; waitForEnd: true }
    onExited: {
      var code = String(failureOutput.text || "").trim()
      var messages = {
        invalid_configuration: "Playback configuration is invalid. Review Settings, then start this computer again.",
        missing_credentials: "Authorize playback on this computer in Settings.",
        reconnect_exhausted: "Playback lost its connection repeatedly. Check the network, then start this computer again.",
        restart_limit: "Playback stopped after repeated failures. Check your network, Premium account and playback authorization, then start this computer again."
      }
      if (messages[code]) {
        root.terminalFailure = true
        root.lastError = messages[code]
      }
    }
  }

  Process {
    id: sinkList
    stdout: StdioCollector { id: sinkListOutput; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.audioSinks = []
        return
      }
      var rows = []
      var lines = String(sinkListOutput.text || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t")
        var name = Api.normalizedAudioDevice(parts[0])
        if (!name) continue
        rows.push({ name: name, description: String(parts[1] || "").trim() || name })
      }
      root.audioSinks = rows
    }
  }

  Process {
    id: credentialsCheck
    onExited: function(exitCode) {
      root.credentialsAvailable = exitCode === 0
      root.credentialsChecked = true
    }
  }

  Process {
    id: startCommand
    command: ["/usr/bin/bash", root.pluginDir + "/scripts/playback-runtime.sh", "start"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode === 0) {
        root.serviceActive = true
        root.startupStatusAttempts = 0
        startupStatusTimer.restart()
        root.started()
      } else {
        root.lastError = "Could not start playback on this computer"
      }
    }
  }

  Process {
    id: stopCommand
    command: ["/usr/bin/bash", root.pluginDir + "/scripts/playback-runtime.sh", "stop"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.serviceActive = false
      if (root.authAfterStop) {
        root.beginAuthenticationProcess()
        return
      }
      root.busy = false
      if (exitCode === 0) root.stopped()
      else root.lastError = "Could not stop playback on this computer"
    }
  }

  Process {
    id: authCommand
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.safeError(line) }
    }
    // Consume authentication output without forwarding it to the journal or
    // retaining it in a long-lived collector.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.safeError(line) }
    }
    onExited: function(exitCode) {
      if (root.authenticationCancelled) {
        root.authenticationCancelled = false
        root.authenticationBusy = false
        root.busy = false
        return
      }
      root.authenticationBusy = false
      root.busy = false
      if (exitCode === 0) {
        root.credentialsAvailable = true
        root.credentialsChecked = true
        root.authenticationSucceeded()
        root.returnFromAuthentication()
      } else {
        root.checkCredentials()
        root.lastError = "Spotify could not connect playback on this computer. Try again"
        root.authenticationFailed(root.lastError)
      }
    }
  }

  Process {
    id: returnCommand
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: clearCredentialsCommand
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.credentialsClearBusy = false
      root.busy = false
      root.serviceActive = false
      if (exitCode === 0) {
        root.credentialsAvailable = false
        root.credentialsChecked = true
        root.credentialsCleared()
      } else {
        root.lastError = "Could not clear the saved playback session"
        root.credentialsClearFailed(root.lastError)
        root.checkCredentials()
      }
    }
  }
}
