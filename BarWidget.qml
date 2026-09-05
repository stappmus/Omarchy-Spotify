import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "Api.js" as Api

BarWidget {
  id: root

  moduleName: "quickshell.spotify"

  readonly property var spotify: bar && bar.shell
    ? bar.shell.serviceFor("quickshell.spotify") : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Color.muted
  readonly property string surfaceKey: "spotify-popup-" + String(root)
  readonly property string lyricsRequestKey: surfaceKey + "-lyrics"
  readonly property string barText: spotify
    ? Api.barTrackText(spotify.title, spotify.artist,
      spotify.showTrackTitle, spotify.showArtistName, spotify.playing,
      spotify.showPausedTrack) : ""
  readonly property bool miniPlayerEnabled:
    String(root.setting("showMiniPlayer", "On")) !== "Off"
  readonly property bool iconOnly: !spotify || vertical || !spotify.hasMedia
    || barText === ""
  property bool popupOpen: false
  property bool lyricsInstallPromptVisible: false
  property bool miniShortcutHelpVisible: false
  property bool popoutSwitchClosing: false
  property bool miniCursorActive: false
  property string miniCursor: "play"
  property real volumeBeforeMute: 0.5
  property bool shortcutModeLatched: false
  property int heldModifierFlags: 0
  property bool pendingShortcutLatch: false
  readonly property bool shortcutHintsEnabled: spotify
    ? spotify.shortcutHintsEnabled
    : String(root.setting("shortcutHints", "On")) !== "Off"
  readonly property bool shortcutHintsActive: shortcutHintsEnabled
    && shortcutModeLatched && !miniShortcutHelpVisible
    && !lyricsInstallPromptVisible
  readonly property bool shortcutHintsInPopup: shortcutHintsEnabled
    && shortcutModeLatched
  readonly property bool hintCtrlHeld: (heldModifierFlags & Qt.ControlModifier) !== 0
  readonly property bool hintShiftHeld: (heldModifierFlags & Qt.ShiftModifier) !== 0
  readonly property bool hintAltHeld: (heldModifierFlags & Qt.AltModifier) !== 0

  component KeyHint: ShortcutHint {
    ctrlHeld: root.hintCtrlHeld
    shiftHeld: root.hintShiftHeld
    altHeld: root.hintAltHeld
    active: root.shortcutHintsActive
    foreground: root.foreground
    accent: Color.accent
  }
  readonly property bool opened: popupOpen
  readonly property var miniShortcutRows: [
    { keys: "Tab / arrows / HJKL", action: "Select a control" },
    { keys: "Enter", action: "Activate selected button" },
    { keys: "Left / Right", action: "Adjust selected slider" },
    { keys: "Space", action: "Play or pause" },
    { keys: "Ctrl+Left / Right", action: "Previous or next track" },
    { keys: "Shift+Left / Right", action: "Seek 10 seconds" },
    { keys: "Ctrl+Up / Down", action: "Change volume" },
    { keys: "M", action: "Mute or restore volume" },
    { keys: "Ctrl+S / Ctrl+R", action: "Shuffle / repeat" },
    { keys: "Ctrl+Shift+L", action: "Open lyrics" },
    { keys: "Ctrl+Shift+A", action: "Open the current artist" },
    { keys: "Ctrl+Shift+B", action: "Open the current album" },
    { keys: "O", action: "Open full player" },
    { keys: "Ctrl+H", action: "Hide visible shortcut hints" },
    { keys: "Ctrl+/", action: "Toggle this reference" },
    { keys: "Scroll the bar icon", action: "Previous or next track" },
    { keys: "Middle-click the bar icon", action: "Play or pause" },
    { keys: "Esc", action: "Close" }
  ]
  readonly property var miniKeyboardActions: {
    if (lyricsInstallPromptVisible) return ["prompt-cancel", "prompt-confirm"]
    if (miniShortcutHelpVisible) return ["help-close"]
    if (spotify && !spotify.accountConnected) {
      var setupActions = ["setup"]
      if (spotify.loginBusy) setupActions.push("setup-cancel")
      setupActions.push("open")
      return setupActions
    }
    var actions = []
    if (spotify && spotify.currentArtistContextAvailable) actions.push("artist")
    if (spotify && spotify.currentAlbumContextAvailable) actions.push("album")
    if (spotify && spotify.currentTrackSaveAvailable) actions.push("like")
    if (spotify && spotify.lengthSeconds > 0
        && spotify.playbackControllable) actions.push("seek")
    if (spotify && spotify.playbackControllable) {
      actions.push("shuffle", "previous", "play", "next", "repeat")
    }
    if (spotify && spotify.lyricsAvailable) actions.push("lyrics")
    if (spotify && spotify.hasPlayer && spotify.volumeSupported)
      actions.push("volume")
    actions.push("open")
    return actions
  }

  function open() {
    popupOpen = true
  }
  function close() {
    miniShortcutHelpVisible = false
    clearShortcutMode()
    popupOpen = false
  }

  function applySequenceModifiers(sequence) {
    var parsed = Api.parseShortcutSequence(sequence)
    var flags = 0
    if (parsed.ctrl) flags |= Qt.ControlModifier
    if (parsed.shift) flags |= Qt.ShiftModifier
    if (parsed.alt) flags |= Qt.AltModifier
    heldModifierFlags = flags
  }

  function latchShortcutMode(sequence) {
    if (!shortcutHintsEnabled) return
    shortcutModeLatched = true
    if (sequence) applySequenceModifiers(sequence)
  }

  function clearShortcutMode() {
    shortcutModeLatched = false
    heldModifierFlags = 0
  }

  function disableShortcutHints() {
    clearShortcutMode()
    if (spotify) spotify.persistSettings({ shortcutHints: "Off" })
  }

  function noteHeldModifiers(event, pressed) {
    if (!event) return
    heldModifierFlags = Api.shortcutModifierFlagsAfterEvent(event.modifiers,
      pressed, heldModifierFlags, hintModifierFlag(event.key))
  }

  function isModifierKey(key) {
    return key === Qt.Key_Control || key === Qt.Key_Shift
      || key === Qt.Key_Alt || key === Qt.Key_AltGr || key === Qt.Key_Meta
  }

  function isHintModifierKey(key) {
    return key === Qt.Key_Control || key === Qt.Key_Shift
      || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

  function hintModifierFlag(key) {
    if (key === Qt.Key_Control) return Qt.ControlModifier
    if (key === Qt.Key_Shift) return Qt.ShiftModifier
    if (key === Qt.Key_Alt || key === Qt.Key_AltGr) return Qt.AltModifier
    return 0
  }

  function acceptMiniKey(event) {
    latchShortcutMode()
    if (event) heldModifierFlags = event.modifiers
    event.accepted = true
  }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }
  function toggle() {
    if (miniPlayerEnabled) popupOpen ? close() : open()
    else openFullPanel()
  }

  function shortcutPlayer() {
    return Api.normalizedShortcutPlayer(root.setting("shortcutPlayer",
      "Omarchy Music app"))
  }

  function toggleMiniPlayerShortcut() {
    if (!bar || typeof bar.isBarWidgetOpen !== "function"
        || typeof bar.hideBarWidget !== "function"
        || typeof bar.summonBarWidget !== "function") return "unavailable"
    if (bar.isBarWidgetOpen(moduleName))
      return bar.hideBarWidget(moduleName) ? "closed" : "unavailable"
    pendingShortcutLatch = true
    var host = bar.shell
    if (host && typeof host.isPluginOpen === "function"
        && host.isPluginOpen(moduleName) && typeof host.hide === "function") {
      host.hide(moduleName)
      Qt.callLater(function() {
        if (root.bar) root.bar.summonBarWidget(root.moduleName)
      })
      return "opened"
    }
    var opened = bar.summonBarWidget(moduleName)
    if (!opened) pendingShortcutLatch = false
    return opened ? "opened" : "unavailable"
  }

  function toggleFullPlayerShortcut() {
    var host = bar ? bar.shell : null
    if (!host || typeof host.isPluginOpen !== "function"
        || typeof host.hide !== "function"
        || typeof host.summon !== "function") return "unavailable"
    if (host.isPluginOpen(moduleName)) {
      host.hide(moduleName)
      return "closed"
    }
    if (bar && typeof bar.isBarWidgetOpen === "function"
        && bar.isBarWidgetOpen(moduleName)
        && typeof bar.hideBarWidget === "function") {
      bar.hideBarWidget(moduleName)
      Qt.callLater(function() {
        if (root.bar && root.bar.shell)
          root.bar.shell.summon(root.moduleName,
            JSON.stringify({ shortcutLatch: true }))
      })
      return "opened"
    }
    return host.summon(moduleName, JSON.stringify({ shortcutLatch: true }))
      ? "opened" : "unavailable"
  }

  function toggleConfiguredPlayerShortcut() {
    var target = shortcutPlayer()
    if (target === "Full player") return toggleFullPlayerShortcut()
    if (target === "Mini player") return toggleMiniPlayerShortcut()
    if (!bar || typeof bar.run !== "function") return "unavailable"
    bar.run("omarchy launch spotify")
    return "launched"
  }

  function openFullPanel(payload) {
    var next = payload && typeof payload === "object" ? Api.shallowCopy(payload) : ({})
    if (shortcutModeLatched) next.shortcutLatch = true
    close()
    if (!bar || !bar.shell) return
    var encoded = JSON.stringify(next)
    if (typeof bar.shell.hide === "function"
        && typeof bar.shell.summon === "function") {
      // Remap an existing full player onto the workspace containing this bar.
      // Splitting hide and summon across event-loop turns lets Wayland finish
      // unmapping the old surface before the shell opens it here.
      bar.shell.hide("quickshell.spotify")
      Qt.callLater(function() {
        if (root.bar && root.bar.shell)
          root.bar.shell.summon("quickshell.spotify", encoded)
      })
    } else if (payload && typeof bar.shell.summon === "function")
      bar.shell.summon("quickshell.spotify", encoded)
    else bar.shell.toggle("quickshell.spotify", encoded)
  }

  IpcHandler {
    target: root.moduleName + ".player"

    function configuredPlayer(): string {
      return root.shortcutPlayer()
    }

    function togglePlayer(): string {
      return root.toggleConfiguredPlayerShortcut()
    }

    function toggleMiniPlayer(): string {
      return root.toggleMiniPlayerShortcut()
    }

    function toggleFullPlayer(): string {
      return root.toggleFullPlayerShortcut()
    }

    function volumeUp(): string {
      return root.adjustVolume(0.05) ? "ok" : "unavailable"
    }

    function volumeDown(): string {
      return root.adjustVolume(-0.05) ? "ok" : "unavailable"
    }
  }

  function openCurrentArtist() {
    if (!spotify || !bar || !bar.shell
        || !spotify.currentArtistContextAvailable) return
    spotify.currentContext("artist", function(item) {
      root.openArtist(item)
    })
  }

  function openCurrentAlbum() {
    if (!spotify || !bar || !bar.shell
        || !spotify.currentAlbumContextAvailable) return
    spotify.currentContext("album", function(item) {
      if (item) root.openFullPanel({ tab: "detail", detailItem: item })
    })
  }

  function openArtist(item) {
    if (!item || !spotify) return
    if (item.id) {
      openFullPanel({ tab: "detail", detailItem: item })
      return
    }
    spotify.resolveArtist(item.name, function(resolved) {
      if (resolved) root.openFullPanel({ tab: "detail", detailItem: resolved })
    })
  }

  function openLyrics() {
    if (!spotify || !spotify.currentLyricsSong) return
    var result = spotify.requestLyrics(lyricsRequestKey)
    if (result !== "opening") {
      lyricsInstallPromptVisible = true
      popupOpen = true
    }
  }

  function dismissLyricsInstallPrompt() {
    if (spotify) spotify.cancelLyricsPlugin(lyricsRequestKey)
    lyricsInstallPromptVisible = false
  }

  function toggleMiniShortcutHelp() {
    if (lyricsInstallPromptVisible) return
    miniShortcutHelpVisible = !miniShortcutHelpVisible
    if (miniShortcutHelpVisible) setMiniCursor("help-close")
    else ensureMiniCursor()
  }

  function ensureMiniCursor() {
    var actions = miniKeyboardActions
    if (!actions.length) {
      miniCursorActive = false
      return
    }
    if (actions.indexOf(miniCursor) >= 0) return
    miniCursor = actions.indexOf("play") >= 0 ? "play" : actions[0]
  }

  function setMiniCursor(action) {
    if (miniKeyboardActions.indexOf(action) < 0) return
    miniCursor = action
    miniCursorActive = true
  }

  function moveMiniCursor(delta) {
    var actions = miniKeyboardActions
    if (!actions.length) return
    var index = actions.indexOf(miniCursor)
    if (index < 0) index = actions.indexOf("play")
    if (index < 0) index = 0
    index = (index + (delta < 0 ? -1 : 1) + actions.length) % actions.length
    miniCursor = actions[index]
    miniCursorActive = true
  }

  function seekBy(seconds) {
    if (!spotify || !spotify.playbackControllable) return
    spotify.seekSeconds(Api.seekPosition(spotify.positionSeconds, seconds,
      spotify.lengthSeconds))
  }

  function setVolumeValue(value, live) {
    if (!spotify || !spotify.volumeSupported) return false
    var next = Api.nextVolume(value, 0)
    if (Api.shouldRememberVolume(next)) volumeBeforeMute = next
    spotify.setVolume(next, live === true)
    return true
  }

  function adjustVolume(delta) {
    if (!spotify || !spotify.volumeSupported) return false
    return setVolumeValue(Api.nextVolume(spotify.volume, delta), false)
  }

  function toggleMute() {
    if (!spotify || !spotify.volumeSupported) return
    var current = Api.nextVolume(spotify.volume, 0)
    if (Api.shouldRememberVolume(current)) {
      volumeBeforeMute = current
      spotify.setVolume(0)
    } else spotify.setVolume(Api.unmuteVolume(volumeBeforeMute))
  }

  function activateMiniAction(action) {
    if (action === "help-close") toggleMiniShortcutHelp()
    else if (action === "prompt-cancel") dismissLyricsInstallPrompt()
    else if (action === "prompt-confirm") {
      if (spotify && !spotify.lyricsPluginBusy)
        spotify.confirmLyricsPlugin(lyricsRequestKey)
    } else if (action === "artist") openCurrentArtist()
    else if (action === "album") openCurrentAlbum()
    else if (action === "like") {
      if (spotify) spotify.toggleCurrentTrackSaved()
    } else if (action === "shuffle") {
      if (spotify) spotify.setShuffle(!spotify.shuffle)
    } else if (action === "previous") {
      if (spotify) spotify.previous()
    } else if (action === "play") {
      if (spotify) spotify.togglePlayback()
    } else if (action === "next") {
      if (spotify) spotify.next()
    } else if (action === "repeat") {
      if (spotify) spotify.cycleRepeat()
    } else if (action === "lyrics") openLyrics()
    else if (action === "volume") toggleMute()
    else if (action === "setup") {
      if (spotify && !spotify.loginBusy) spotify.login()
    } else if (action === "setup-cancel") {
      if (spotify) spotify.cancelLogin()
    } else if (action === "open") openFullPanel()
  }

  function handleMiniKey(event) {
    root.noteHeldModifiers(event, true)
    if (root.isModifierKey(event.key)) {
      if (root.isHintModifierKey(event.key)) root.latchShortcutMode()
      event.accepted = true
      return
    }
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var plain = !ctrl && !shift && !alt
    var text = String(event.text || "").toLowerCase()

    if (lyricsInstallPromptVisible) {
      if (event.key === Qt.Key_Escape) {
        dismissLyricsInstallPrompt()
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        moveMiniCursor(shift || event.key === Qt.Key_Backtab ? -1 : 1)
      } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up
          || text === "h" || text === "k") {
        moveMiniCursor(-1)
      } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down
          || text === "l" || text === "j") {
        moveMiniCursor(1)
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space) {
        if (!event.isAutoRepeat) activateMiniAction(miniCursor)
      } else return
      root.acceptMiniKey(event)
      return
    }

    if (miniShortcutHelpVisible) {
      if (event.key === Qt.Key_Escape
          || event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space) {
        if (!event.isAutoRepeat) toggleMiniShortcutHelp()
        root.acceptMiniKey(event)
      }
      return
    }

    if (event.key === Qt.Key_Escape) {
      close()
    } else if (ctrl && event.key === Qt.Key_Left) {
      if (spotify) spotify.previous()
    } else if (ctrl && event.key === Qt.Key_Right) {
      if (spotify) spotify.next()
    } else if (shift && !ctrl && event.key === Qt.Key_Left) {
      seekBy(-10)
    } else if (shift && !ctrl && event.key === Qt.Key_Right) {
      seekBy(10)
    } else if (ctrl && event.key === Qt.Key_Up) {
      adjustVolume(0.05)
    } else if (ctrl && event.key === Qt.Key_Down) {
      adjustVolume(-0.05)
    } else if (ctrl && !shift && event.key === Qt.Key_S) {
      if (spotify && !event.isAutoRepeat) spotify.setShuffle(!spotify.shuffle)
    } else if (ctrl && !shift && event.key === Qt.Key_R) {
      if (spotify && !event.isAutoRepeat) spotify.cycleRepeat()
    } else if (ctrl && shift && event.key === Qt.Key_L) {
      if (!event.isAutoRepeat) openLyrics()
    } else if (ctrl && shift && !alt && event.key === Qt.Key_A) {
      if (!event.isAutoRepeat) openCurrentArtist()
    } else if (ctrl && shift && !alt && event.key === Qt.Key_B) {
      if (!event.isAutoRepeat) openCurrentAlbum()
    } else if (plain && event.key === Qt.Key_Space) {
      if (spotify && !event.isAutoRepeat) spotify.togglePlayback()
    } else if (plain && event.key === Qt.Key_M) {
      if (!event.isAutoRepeat) toggleMute()
    } else if (plain && event.key === Qt.Key_O) {
      if (!event.isAutoRepeat) openFullPanel()
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      moveMiniCursor(shift || event.key === Qt.Key_Backtab ? -1 : 1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!event.isAutoRepeat) activateMiniAction(miniCursor)
    } else if (plain && (event.key === Qt.Key_Left || text === "h")) {
      if (miniCursor === "seek") seekBy(-5)
      else if (miniCursor === "volume") adjustVolume(-0.05)
      else moveMiniCursor(-1)
    } else if (plain && (event.key === Qt.Key_Right || text === "l")) {
      if (miniCursor === "seek") seekBy(5)
      else if (miniCursor === "volume") adjustVolume(0.05)
      else moveMiniCursor(1)
    } else if (plain && (event.key === Qt.Key_Up || text === "k")) {
      moveMiniCursor(-1)
    } else if (plain && (event.key === Qt.Key_Down || text === "j")) {
      moveMiniCursor(1)
    } else if (plain && event.key === Qt.Key_Home) {
      setMiniCursor(miniKeyboardActions[0])
    } else if (plain && event.key === Qt.Key_End) {
      setMiniCursor(miniKeyboardActions[miniKeyboardActions.length - 1])
    } else return
    root.acceptMiniKey(event)
  }

  function syncSettings() {
    if (spotify) spotify.applySettings(settings)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onSettingsChanged: syncSettings()
  onSpotifyChanged: syncSettings()
  onMiniPlayerEnabledChanged: if (!miniPlayerEnabled) close()
  onShortcutHintsEnabledChanged: if (!shortcutHintsEnabled) clearShortcutMode()
  onMiniKeyboardActionsChanged: ensureMiniCursor()
  onLyricsInstallPromptVisibleChanged: {
    if (lyricsInstallPromptVisible) {
      miniCursor = "prompt-cancel"
      miniCursorActive = true
    } else ensureMiniCursor()
  }
  onPopupOpenChanged: {
    if (popupOpen) {
      miniCursor = miniKeyboardActions.indexOf("play") >= 0
        ? "play" : miniKeyboardActions[0]
      miniCursorActive = miniKeyboardActions.length > 0
      if (pendingShortcutLatch) latchShortcutMode()
      pendingShortcutLatch = false
    } else {
      miniCursorActive = false
      clearShortcutMode()
      pendingShortcutLatch = false
    }
    if (spotify) spotify.setUiVisible(surfaceKey, popupOpen)
    if (!popupOpen && lyricsInstallPromptVisible
        && (!spotify || !spotify.lyricsPluginBusy)) {
      if (spotify) spotify.cancelLyricsPlugin(lyricsRequestKey)
      lyricsInstallPromptVisible = false
    }
  }
  Component.onCompleted: syncSettings()
  Component.onDestruction: if (spotify) spotify.setUiVisible(surfaceKey, false)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconOnly ? "" : ""
    hasVisualContent: true
    slotSize: Style.bar.iconSlot
    opticalSize: Style.bar.iconCanvas
    fontSize: root.iconOnly ? Style.bar.iconFont : Style.font.body
    active: root.spotify && root.spotify.playing
    // Follow the bar's contrast-aware color when transparency changes.
    // Keep root.foreground theme-based for the popup/player surfaces.
    foreground: root.bar ? root.bar.barForeground : root.foreground
    activeColor: foreground
    tooltipText: root.spotify && root.spotify.hasMedia
      ? root.spotify.title + (root.spotify.artist ? " — " + root.spotify.artist : "")
      : (root.spotify && !root.spotify.accountConnected
        ? "Set up Omarchy Spotify" : "Omarchy Spotify")
    // Size from the painted glyph and label plus the real inner chrome.
    readonly property real fittedWidth: Math.ceil(barGlyph.width
      + barContent.spacing + barLabel.implicitWidth + scaledHorizontalMargin * 2)
    readonly property real barTextCap: root.spotify ? root.spotify.maxBarTextWidth : 240

    fixedWidth: root.vertical ? root.barSize
      : (root.iconOnly ? Style.bar.iconSlot
        : Api.barSlotWidth(root.spotify && root.spotify.fixedBarWidth,
          barTextCap > 0 ? Style.space(barTextCap) : 0, fittedWidth,
          root.barSize))
    fixedHeight: root.vertical && root.iconOnly ? Style.bar.iconSlot : -1
    clip: true

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(6)
      visible: !root.iconOnly
      enabled: false

      OpticalGlyph {
        id: barGlyph
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: Style.space(16)
        text: ""
        color: button.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.font.body
      }

      Item {
        id: scrollClip
        width: Math.max(0, button.width - barGlyph.width
          - barContent.spacing - button.scaledHorizontalMargin * 2)
        height: barGlyph.height
        anchors.verticalCenter: parent.verticalCenter
        clip: barLabel.needsScroll

        readonly property bool scrolling: root.spotify && root.spotify.scrollBarText
          && barLabel.needsScroll && !root.popupOpen && !root.vertical
        // Use a wide enough ramp to read as a deliberate fade at bar scale.
        readonly property real fadeStop: width > 0
          ? Math.min(0.2, Style.space(28) / width) : 0

        Item {
          id: labelLayer
          anchors.fill: parent
          layer.enabled: scrollClip.scrolling
          layer.smooth: true
          layer.effect: MultiEffect {
            autoPaddingEnabled: false
            maskEnabled: true
            maskSource: scrollFadeMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
          }

          Text {
            id: barLabel
            anchors.verticalCenter: parent.verticalCenter
            text: root.barText
            color: button.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering

            readonly property bool needsScroll: implicitWidth > scrollClip.width

            // Keep the marquee on the render thread so it remains smooth
            // without dispatching JavaScript timer callbacks through the
            // shared shell's main thread.
            XAnimator on x {
              id: barScrollAnimation
              running: scrollClip.scrolling
              loops: Animation.Infinite
              duration: Math.round(Math.max(6000, implicitWidth * 25)
                / Math.max(0.25, root.spotify ? root.spotify.scrollSpeed : 1))
              from: scrollClip.width
              to: -implicitWidth
              easing.type: Easing.Linear
              onStopped: barLabel.x = 0
            }
          }
        }

        Rectangle {
          id: scrollFadeMask
          anchors.fill: parent
          visible: false
          layer.enabled: scrollClip.scrolling
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
              position: 0
              color: "transparent"
            }
            GradientStop {
              position: scrollClip.fadeStop
              color: "white"
            }
            GradientStop {
              position: 1 - scrollClip.fadeStop
              color: "white"
            }
            GradientStop {
              position: 1
              color: "transparent"
            }
          }
        }
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.spotify) root.spotify.togglePlayback()
      } else {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      if (!root.spotify) return
      if (delta > 0) root.spotify.previous()
      else if (delta < 0) root.spotify.next()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: miniKeyCatcher
    contentWidth: fittedContentWidth(Style.space(340))
    contentHeight: fittedContentHeight(root.miniShortcutHelpVisible
      ? miniShortcutHelp.implicitHeight : contentColumn.implicitHeight)

    Item {
      id: miniKeyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      onActiveFocusChanged: if (!activeFocus) {
        root.heldModifierFlags = 0
        root.shortcutModeLatched = false
      }
      Keys.onShortcutOverride: function(event) {
        if (root.isHintModifierKey(event.key)) {
          root.noteHeldModifiers(event, true)
          root.latchShortcutMode()
          event.accepted = true
        }
      }
      Keys.onPressed: function(event) { root.handleMiniKey(event) }
      Keys.onReleased: function(event) {
        root.noteHeldModifiers(event, false)
        if (root.isHintModifierKey(event.key)) event.accepted = true
      }

      Shortcut {
        sequence: "Ctrl+/"
        enabled: root.popupOpen && !root.lyricsInstallPromptVisible
        onActivated: {
          root.latchShortcutMode("Ctrl+/")
          root.toggleMiniShortcutHelp()
        }
      }
      Shortcut {
        sequence: "Ctrl+H"
        enabled: root.shortcutHintsActive
        onActivated: root.disableShortcutHints()
      }

      Column {
        id: contentColumn
        anchors.fill: parent
        visible: !root.miniShortcutHelpVisible
        spacing: Style.space(10)

      Row {
        width: parent.width
        visible: root.shortcutHintsActive

        Item {
          width: Math.max(0, parent.width - miniHideHintsButton.width)
          height: 1
        }

        Button {
          id: miniHideHintsButton
          text: "Ctrl+H · Hide hints"
          foreground: root.foreground
          fontSize: Style.font.caption
          focusable: false
          tooltipText: "Hide shortcut hints until re-enabled in Settings · Ctrl+H"
          onClicked: root.disableShortcutHints()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: !root.lyricsInstallPromptVisible
          && root.spotify && !root.spotify.accountConnected

        Text {
          width: parent.width
          text: root.spotify ? root.spotify.loginProgress : "Spotify is unavailable"
          color: root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Connect your Spotify account from here. Playback on this computer can finish in the background."
          color: root.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.spotify && (root.spotify.lastError !== ""
            || root.spotify.auth.lastError !== ""
            || root.spotify.daemon.lastError !== "")
          text: root.spotify ? (root.spotify.lastError
            || root.spotify.auth.lastError
            || root.spotify.daemon.lastError) : ""
          color: Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Button {
            text: root.spotify && root.spotify.loginBusy
              ? "Working…" : "Set up and continue"
            iconText: "󰍂"
            foreground: root.foreground
            hasCursor: root.miniCursorActive && root.miniCursor === "setup"
            enabled: root.spotify && !root.spotify.loginBusy
            onClicked: if (root.spotify) root.spotify.login()
            onHovered: function(on) { if (on) root.setMiniCursor("setup") }
          }

          Button {
            text: "Cancel"
            foreground: root.foreground
            visible: root.spotify && root.spotify.loginBusy
            hasCursor: root.miniCursorActive && root.miniCursor === "setup-cancel"
            onClicked: if (root.spotify) root.spotify.cancelLogin()
            onHovered: function(on) { if (on) root.setMiniCursor("setup-cancel") }
          }
        }
      }

      Item {
        id: miniNowPlaying
        width: parent.width
        implicitHeight: Math.max(miniArtworkSurface.height,
          miniNowPlayingMetadata.implicitHeight)
        height: implicitHeight
        readonly property real metadataSpacing: Style.space(12)
        visible: !root.lyricsInstallPromptVisible
          && (!root.spotify || root.spotify.accountConnected)

        BorderSurface {
          id: miniArtworkSurface
          width: Style.space(78)
          height: width
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

          Image {
            id: popupArtwork
            anchors.fill: parent
            anchors.margins: Style.space(3)
            source: root.popupOpen && root.spotify ? root.spotify.artUrl : ""
            sourceSize.width: 156
            sourceSize.height: 156
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: popupArtwork.status !== Image.Ready
            text: ""
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }

        }

        Column {
          id: miniNowPlayingMetadata
          anchors.left: miniArtworkSurface.right
          anchors.leftMargin: miniNowPlaying.metadataSpacing
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(3)

            Text {
              width: Math.max(20, parent.width
                - (barCurrentTrackLikeButton.visible
                  ? barCurrentTrackLikeButton.width + parent.spacing : 0))
              anchors.verticalCenter: parent.verticalCenter
              text: root.spotify && root.spotify.title
                ? root.spotify.title : "Nothing playing"
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Button {
              id: barCurrentTrackLikeButton
              objectName: "bar-current-track-like"
              visible: root.spotify && !!root.spotify.currentTrackItem
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.spotify && root.spotify.currentTrackSaved
                ? "󰋑" : "󰋕"
              iconSize: Style.font.body
              foreground: Color.urgent
              accent: Color.urgent
              hasCursor: root.miniCursorActive && root.miniCursor === "like"
              enabled: root.spotify && root.spotify.currentTrackSaveAvailable
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              tooltipText: root.spotify && root.spotify.currentTrackSaveChecking
                ? "Checking liked status…"
                : (root.spotify && root.spotify.currentTrackSaveBusy
                  ? "Updating liked status…"
                  : (root.spotify && root.spotify.currentTrackSaved
                    ? "Remove like" : "Like this song"))
              onClicked: if (root.spotify)
                root.spotify.toggleCurrentTrackSaved()
              onHovered: function(on) {
                if (on) root.setMiniCursor("like")
              }
            }
          }

          CursorSurface {
            id: miniArtistCursor
            z: 2
            clip: false
            width: parent.width
            height: miniArtistLinks.implicitHeight + Style.space(4)
            visible: miniArtistLinks.fallbackText !== ""
              || miniArtistLinks.artists.length > 0
            enabled: root.spotify && root.spotify.currentArtistContextAvailable
            hasCursor: root.miniCursorActive && root.miniCursor === "artist"
            foreground: root.foreground

            ArtistLinks {
              id: miniArtistLinks
              anchors.fill: parent
              anchors.leftMargin: Style.space(3)
              anchors.rightMargin: Style.space(3) + miniArtistHint.reservedRight
              artists: root.spotify ? root.spotify.currentArtists : []
              fallbackText: root.spotify ? root.spotify.artist : ""
              fallbackClickable: fallbackText !== "" && artists.length === 0
                && root.spotify && root.spotify.currentArtistContextAvailable
              color: root.spotify && root.spotify.artist !== ""
                && root.spotify.currentArtistContextAvailable
                ? Color.accent : root.muted
              accent: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              onArtistRequested: function(item) { root.openArtist(item) }
              onFallbackRequested: root.openCurrentArtist()
            }

            HoverHandler {
              id: miniArtistHover
              onHoveredChanged: if (hovered) root.setMiniCursor("artist")
            }
            PanelToolTip {
              visible: miniArtistHover.hovered
              text: "Open artist · Ctrl+Shift+A"
            }
            KeyHint {
              id: miniArtistHint
              sequences: ["Ctrl+Shift+A"]
            }
          }

          CursorSurface {
            id: miniAlbumCursor
            z: 1
            clip: false
            width: parent.width
            height: miniAlbumLinks.implicitHeight
            visible: miniAlbumLinks.fallbackText !== ""
            enabled: root.spotify && root.spotify.currentAlbumContextAvailable
            hasCursor: root.miniCursorActive && root.miniCursor === "album"
            foreground: root.foreground

            ArtistLinks {
              id: miniAlbumLinks
              anchors.fill: parent
              anchors.leftMargin: Style.space(3)
              anchors.rightMargin: Style.space(3) + miniAlbumHint.reservedRight
              artists: []
              fallbackText: root.spotify ? root.spotify.album : ""
              fallbackClickable: root.spotify
                && root.spotify.currentAlbumContextAvailable
              color: root.spotify && root.spotify.currentAlbumContextAvailable
                ? Color.accent : root.muted
              accent: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              onFallbackRequested: root.openCurrentAlbum()
            }

            HoverHandler {
              id: miniAlbumHover
              onHoveredChanged: if (hovered) root.setMiniCursor("album")
            }
            PanelToolTip {
              visible: miniAlbumHover.hovered
              text: "Open album · Ctrl+Shift+B"
            }
            KeyHint {
              id: miniAlbumHint
              sequences: ["Ctrl+Shift+B"]
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: !root.lyricsInstallPromptVisible
          && (!root.spotify || root.spotify.accountConnected)
          && root.spotify && root.spotify.lengthSeconds > 0

        CursorSurface {
          id: miniSeekCursor
          width: parent.width
          height: miniSeekSlider.implicitHeight + Style.space(2)
          hasCursor: root.miniCursorActive && root.miniCursor === "seek"
          foreground: root.foreground

          PlaybackSlider {
            id: miniSeekSlider
            anchors.fill: parent
            anchors.leftMargin: Style.space(3)
            anchors.rightMargin: Style.space(3)
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.spotify ? root.spotify.lengthSeconds : 1)
            sourceValue: root.spotify ? root.spotify.positionSeconds : 0
            sourcePending: root.spotify && root.spotify.pendingRemoteSeek !== null
            acknowledgeTolerance: 2
            contextKey: root.spotify
              ? root.spotify.currentUri + "|" + root.spotify.playbackDeviceName : ""
            step: 5
            onCommitted: function(value) {
              if (root.spotify) root.spotify.seekSeconds(value)
            }
          }

          HoverHandler {
            onHoveredChanged: if (hovered) root.setMiniCursor("seek")
          }
          KeyHint {
            sequences: ["Shift+Left", "Shift+Right"]
            active: root.shortcutHintsActive && root.spotify
              && root.spotify.playbackControllable
          }
        }

        Row {
          width: parent.width

          Text {
            id: positionTime
            text: Api.millisecondsToClock((root.spotify ? root.spotify.positionSeconds : 0) * 1000)
            color: root.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item { width: Math.max(0, parent.width - positionTime.implicitWidth - endTime.implicitWidth); height: 1 }

          Text {
            id: endTime
            text: Api.millisecondsToClock((root.spotify ? root.spotify.lengthSeconds : 0) * 1000)
            color: root.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(5)
        visible: !root.lyricsInstallPromptVisible
          && (!root.spotify || root.spotify.accountConnected)

        TransportButton {
          glyphText: "󰒟"
          foreground: root.foreground
          selected: root.spotify && root.spotify.shuffle
          hasCursor: root.miniCursorActive && root.miniCursor === "shuffle"
          tooltipText: "Shuffle · Ctrl+S"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.setShuffle(!root.spotify.shuffle)
          onHovered: function(on) { if (on) root.setMiniCursor("shuffle") }
          KeyHint { sequences: ["Ctrl+S"] }
        }

        TransportButton {
          glyphText: "󰒮"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "previous"
          tooltipText: "Previous · Ctrl+Left"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.previous()
          onHovered: function(on) { if (on) root.setMiniCursor("previous") }
          KeyHint { sequences: ["Ctrl+Left"] }
        }

        TransportButton {
          glyphText: root.spotify && root.spotify.playing ? "󰏤" : "󰐊"
          glyphSize: Style.font.iconLarge
          foreground: root.foreground
          selected: root.spotify && root.spotify.playing
          hasCursor: root.miniCursorActive && root.miniCursor === "play"
          tooltipText: (root.spotify && root.spotify.playing ? "Pause" : "Play")
            + " · Space"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.togglePlayback()
          onHovered: function(on) { if (on) root.setMiniCursor("play") }
          KeyHint { sequences: ["Space"] }
        }

        TransportButton {
          glyphText: "󰒭"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "next"
          tooltipText: "Next · Ctrl+Right"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.next()
          onHovered: function(on) { if (on) root.setMiniCursor("next") }
          KeyHint { sequences: ["Ctrl+Right"] }
        }

        TransportButton {
          glyphText: root.spotify && root.spotify.repeatMode === "track" ? "󰑘" : "󰑖"
          foreground: root.foreground
          selected: root.spotify && root.spotify.repeatMode !== "off"
          hasCursor: root.miniCursorActive && root.miniCursor === "repeat"
          tooltipText: "Repeat: " + Api.repeatModeLabel(root.spotify
            ? root.spotify.repeatMode : "off") + " · Ctrl+R"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.cycleRepeat()
          onHovered: function(on) { if (on) root.setMiniCursor("repeat") }
          KeyHint { sequences: ["Ctrl+R"] }
        }

        TransportButton {
          glyphText: "󰎈"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "lyrics"
          tooltipText: "Open lyrics in Omasing · Ctrl+Shift+L"
          enabled: root.spotify && root.spotify.lyricsAvailable
          onClicked: root.openLyrics()
          onHovered: function(on) { if (on) root.setMiniCursor("lyrics") }
          KeyHint { sequences: ["Ctrl+Shift+L"] }
        }
      }

      CursorSurface {
        id: miniVolumeCursor
        width: parent.width
        height: miniVolumeRow.implicitHeight + Style.space(2)
        visible: !root.lyricsInstallPromptVisible
          && (!root.spotify || root.spotify.accountConnected)
          && root.spotify && root.spotify.hasPlayer
        hasCursor: root.miniCursorActive && root.miniCursor === "volume"
        foreground: root.foreground

        Row {
          id: miniVolumeRow
          anchors.fill: parent
          anchors.leftMargin: Style.space(3)
          anchors.rightMargin: Style.space(3)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.spotify && root.spotify.volume <= 0.001 ? "󰝟" : "󰕾"
            color: root.spotify && root.spotify.volume <= 0.001
              ? root.muted : root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.icon
          }

          PlaybackSlider {
            width: parent.width - Style.space(34)
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            minimum: 0
            maximum: 1
            step: 0.05
            sourceValue: root.spotify ? root.spotify.volume : 0
            sourcePending: root.spotify && root.spotify.volumePending
            contextKey: root.spotify ? root.spotify.playbackDeviceName : ""
            enabled: root.spotify && root.spotify.volumeSupported
            liveCommit: true
            onCommitted: function(value, live) {
              root.setVolumeValue(value, live)
            }
          }
        }

        HoverHandler {
          onHoveredChanged: if (hovered) root.setMiniCursor("volume")
        }
        KeyHint {
          sequences: ["M", "Ctrl+Up", "Ctrl+Down"]
          active: root.shortcutHintsActive && root.spotify
            && root.spotify.volumeSupported
        }
      }

      PanelSeparator {
        foreground: root.foreground
        visible: !root.lyricsInstallPromptVisible
      }

      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.lyricsInstallPromptVisible

        Text {
          width: parent.width - openButton.width - Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: !root.spotify ? "Spotify is unavailable"
            : (root.spotify.lastError !== "" ? root.spotify.lastError
            : (root.spotify.statusMessage !== "" ? root.spotify.statusMessage
            : (!root.spotify.accountConnected ? "Connect Spotify to start"
            : (!root.spotify.fullyConnected
              ? (root.spotify.loginBusy ? root.spotify.loginProgress
                : "Account connected · finish playback in Settings")
            : (root.spotify.useRemotePlayback
              ? (root.spotify.playing ? "Playing on " : "Connected to ")
                + root.spotify.playbackDeviceName
              : (root.spotify.daemon.running ? "Playing on this computer"
                : "Ready when you press play"))))))
          color: root.muted
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Button {
          id: openButton
          text: "Open"
          iconText: "󰏋"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "open"
          tooltipText: "Open full player · O"
          onClicked: root.openFullPanel()
          onHovered: function(on) { if (on) root.setMiniCursor("open") }
          KeyHint { sequences: ["O"] }
        }
      }

        LyricsInstallPrompt {
          width: parent.width
          visible: root.lyricsInstallPromptVisible
          service: root.spotify
          foreground: root.foreground
          muted: root.muted
          surfaceKey: root.lyricsRequestKey
          cancelHasCursor: root.miniCursorActive
            && root.miniCursor === "prompt-cancel"
          confirmHasCursor: root.miniCursorActive
            && root.miniCursor === "prompt-confirm"
          onCanceled: root.dismissLyricsInstallPrompt()
        }
      }

      Column {
        id: miniShortcutHelp
        anchors.fill: parent
        visible: root.miniShortcutHelpVisible
        spacing: Style.space(7)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width - miniShortcutHelpClose.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "Keyboard shortcuts"
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Button {
            id: miniShortcutHelpClose
            iconText: "󰅖"
            foreground: root.foreground
            focusable: true
            hasCursor: root.miniCursorActive && root.miniCursor === "help-close"
            tooltipText: "Close shortcut reference · Ctrl+/ or Esc"
            onClicked: root.toggleMiniShortcutHelp()
            onHovered: function(on) { if (on) root.setMiniCursor("help-close") }
            KeyHint {
              sequences: ["Esc", "Ctrl+/"]
              active: root.shortcutHintsInPopup
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Repeater {
          model: root.miniShortcutRows

          delegate: Row {
            required property var modelData
            width: miniShortcutHelp.width
            spacing: Style.space(8)

            Text {
              width: Style.space(128)
              text: modelData.keys
              color: root.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              width: parent.width - Style.space(128) - parent.spacing
              text: modelData.action
              color: root.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  Connections {
    target: root.spotify
    ignoreUnknownSignals: true
    function onLyricsPluginPromptRequested(surface, availability) {
      if (String(surface) !== root.lyricsRequestKey) return
      root.lyricsInstallPromptVisible = true
      root.popupOpen = true
    }
    function onLyricsPluginOpened(surface) {
      if (String(surface) !== root.lyricsRequestKey) return
      root.lyricsInstallPromptVisible = false
      root.close()
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.popupOpen && root.spotify && root.spotify.playing
    onTriggered: root.spotify.refreshPosition()
  }
}
