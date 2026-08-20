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
  readonly property string surfaceKey: "spotify-popup-" + String(root)
  readonly property string lyricsRequestKey: surfaceKey + "-lyrics"
  readonly property string barText: spotify
    ? Api.barTrackText(spotify.title, spotify.artist,
      spotify.showTrackTitle, spotify.showArtistName) : ""
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
    { keys: "O", action: "Open full player" },
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
    if (spotify && spotify.currentTrackSaveAvailable) actions.push("like")
    if (spotify && spotify.lengthSeconds > 0
        && spotify.playbackControllable) actions.push("seek")
    if (spotify && spotify.playbackControllable) {
      actions.push("shuffle", "previous", "play", "next", "repeat")
    }
    if (spotify && spotify.lyricsAvailable) actions.push("lyrics")
    if (spotify && spotify.hasPlayer && spotify.volumeSupported)
      actions.push("volume")
    if (spotify && spotify.accountConnected
      && spotify.daemon && spotify.daemon.running) actions.push("quit")
    actions.push("open")
    return actions
  }

  function open() {
    popupOpen = true
  }
  function close() {
    miniShortcutHelpVisible = false
    popupOpen = false
  }
  function quitPlayer() {
    if (spotify) {
      if (spotify.playing) spotify.togglePlayback()
      spotify.stopEngine()
    }
    close()
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
    var host = bar.shell
    if (host && typeof host.isPluginOpen === "function"
        && host.isPluginOpen(moduleName) && typeof host.hide === "function") {
      host.hide(moduleName)
      Qt.callLater(function() {
        if (root.bar) root.bar.summonBarWidget(root.moduleName)
      })
      return "opened"
    }
    return bar.summonBarWidget(moduleName) ? "opened" : "unavailable"
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
          root.bar.shell.summon(root.moduleName, "{}")
      })
      return "opened"
    }
    return host.summon(moduleName, "{}") ? "opened" : "unavailable"
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
    close()
    if (!bar || !bar.shell) return
    var encoded = JSON.stringify(payload || ({}))
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
  }

  function openCurrentArtist() {
    if (!spotify || !bar || !bar.shell || spotify.artist === ""
        || !spotify.currentArtistContextAvailable) return
    spotify.currentContext("artist", function(item) {
      root.openArtist(item)
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

  function adjustVolume(delta) {
    if (!spotify || !spotify.volumeSupported) return
    var next = Api.nextVolume(spotify.volume, delta)
    if (Api.shouldRememberVolume(next)) volumeBeforeMute = next
    spotify.setVolume(next)
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
    } else if (action === "quit") quitPlayer()
    else if (action === "artist") openCurrentArtist()
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
      event.accepted = true
      return
    }

    if (miniShortcutHelpVisible) {
      if (event.key === Qt.Key_Escape
          || event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space) {
        if (!event.isAutoRepeat) toggleMiniShortcutHelp()
        event.accepted = true
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
    event.accepted = true
  }

  function syncSettings() {
    if (spotify) spotify.applySettings(settings)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onSettingsChanged: syncSettings()
  onSpotifyChanged: syncSettings()
  onMiniPlayerEnabledChanged: if (!miniPlayerEnabled) close()
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
    } else miniCursorActive = false
    if (spotify) spotify.setUiVisible(surfaceKey, popupOpen)
    if (!popupOpen && lyricsInstallPromptVisible
        && (!spotify || !spotify.lyricsPluginBusy)) {
      if (spotify) spotify.cancelLyricsPlugin(lyricsRequestKey)
      lyricsInstallPromptVisible = false
    }
  }
  Component.onCompleted: syncSettings()
  Component.onDestruction: if (spotify) spotify.setUiVisible(surfaceKey, false)

  TextMetrics {
    id: labelMetrics
    text: root.barText
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  TextMetrics {
    id: glyphMetrics
    text: ""
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: root.iconOnly
    hasVisualContent: true
    fontSize: root.iconOnly ? Style.font.bodySmall : Style.font.body
    active: root.spotify && root.spotify.playing
    // Keep the playing state legible on transparent bars. WidgetButton's
    // foreground follows bar.barForeground, which the shell derives from the
    // wallpaper underneath the bar.
    activeColor: button.foreground
    tooltipText: root.spotify && root.spotify.hasMedia
      ? root.spotify.title + (root.spotify.artist ? " — " + root.spotify.artist : "")
      : (root.spotify && !root.spotify.accountConnected
        ? "Set up Omarchy Spotify" : "Omarchy Spotify")
    fixedWidth: root.vertical ? root.barSize
      : (root.iconOnly ? Style.bar.statusSlot
        : Math.min(Style.space(240), Math.max(root.barSize,
          glyphMetrics.advanceWidth + labelMetrics.advanceWidth + Style.space(24))))
    fixedHeight: root.vertical && root.iconOnly ? Style.bar.statusSlot : -1
    clip: true

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(6)
      visible: !root.iconOnly
      enabled: false

      Text {
        id: barGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: ""
        color: button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      Item {
        id: scrollClip
        width: Math.max(0, button.width - barGlyph.implicitWidth
          - barContent.spacing - button.scaledHorizontalMargin * 2)
        height: barGlyph.implicitHeight
        anchors.verticalCenter: parent.verticalCenter
        clip: true

        // Use a wide enough ramp to read as a deliberate fade at bar scale.
        readonly property real fadeStop: width > 0
          ? Math.min(0.2, Style.space(28) / width) : 0

        Item {
          id: labelLayer
          anchors.fill: parent
          layer.enabled: barLabel.needsScroll
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

            readonly property bool needsScroll: labelMetrics.advanceWidth > scrollClip.width

            // Keep the marquee on the render thread so it remains smooth
            // without dispatching JavaScript timer callbacks through the
            // shared shell's main thread.
            XAnimator on x {
              id: barScrollAnimation
              running: root.spotify && root.spotify.scrollBarText
                && barLabel.needsScroll && !root.popupOpen && !root.vertical
              loops: Animation.Infinite
              duration: Math.round(Math.max(6000, labelMetrics.advanceWidth * 25)
                / Math.max(0.25, root.spotify ? root.spotify.scrollSpeed : 1))
              from: scrollClip.width
              to: -labelMetrics.advanceWidth
              easing.type: Easing.Linear
              onStopped: barLabel.x = 0
            }
          }
        }

        Rectangle {
          id: scrollFadeMask
          anchors.fill: parent
          visible: false
          layer.enabled: labelLayer.layer.enabled
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
              position: 0
              color: barScrollAnimation.running ? "transparent" : "white"
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
      Keys.onPressed: function(event) { root.handleMiniKey(event) }

      Shortcut {
        sequence: "Ctrl+/"
        enabled: root.popupOpen && !root.lyricsInstallPromptVisible
        onActivated: root.toggleMiniShortcutHelp()
      }

      Column {
        id: contentColumn
        anchors.fill: parent
        visible: !root.miniShortcutHelpVisible
        spacing: Style.space(10)

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
          color: Qt.darker(root.foreground, 1.4)
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

      Row {
        width: parent.width
        spacing: Style.space(12)
        visible: !root.lyricsInstallPromptVisible
          && (!root.spotify || root.spotify.accountConnected)

        BorderSurface {
          width: Style.space(78)
          height: width
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
          width: parent.width - Style.space(90)
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
              foreground: root.foreground
              selected: root.spotify && root.spotify.currentTrackSaved
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
            width: parent.width
            height: miniArtistLinks.implicitHeight + Style.space(4)
            visible: miniArtistLinks.fallbackText !== ""
              || miniArtistLinks.artists.length > 0
            hasCursor: root.miniCursorActive && root.miniCursor === "artist"
            foreground: root.foreground

            ArtistLinks {
              id: miniArtistLinks
              anchors.fill: parent
              anchors.leftMargin: Style.space(3)
              anchors.rightMargin: Style.space(3)
              artists: root.spotify ? root.spotify.currentArtists : []
              fallbackText: root.spotify ? root.spotify.artist : ""
              fallbackClickable: fallbackText !== "" && artists.length === 0
                && root.spotify && root.spotify.currentArtistContextAvailable
              color: Qt.darker(root.foreground, 1.35)
              accent: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              onArtistRequested: function(item) { root.openArtist(item) }
              onFallbackRequested: root.openCurrentArtist()
            }

            HoverHandler {
              onHoveredChanged: if (hovered) root.setMiniCursor("artist")
            }
          }

          Text {
            width: parent.width
            text: root.spotify ? root.spotify.album : ""
            color: Qt.darker(root.foreground, 1.55)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            visible: text !== ""
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
        }

        Row {
          width: parent.width

          Text {
            id: positionTime
            text: Api.millisecondsToClock((root.spotify ? root.spotify.positionSeconds : 0) * 1000)
            color: Qt.darker(root.foreground, 1.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Item { width: Math.max(0, parent.width - positionTime.implicitWidth - endTime.implicitWidth); height: 1 }

          Text {
            id: endTime
            text: Api.millisecondsToClock((root.spotify ? root.spotify.lengthSeconds : 0) * 1000)
            color: Qt.darker(root.foreground, 1.45)
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

        Button {
          iconText: "󰒟"
          foreground: root.foreground
          selected: root.spotify && root.spotify.shuffle
          hasCursor: root.miniCursorActive && root.miniCursor === "shuffle"
          tooltipText: "Shuffle · Ctrl+S"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.setShuffle(!root.spotify.shuffle)
          onHovered: function(on) { if (on) root.setMiniCursor("shuffle") }
        }

        Button {
          iconText: "󰒮"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "previous"
          tooltipText: "Previous · Ctrl+Left"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.previous()
          onHovered: function(on) { if (on) root.setMiniCursor("previous") }
        }

        Button {
          iconText: root.spotify && root.spotify.playing ? "󰏤" : "󰐊"
          iconSize: Style.font.iconLarge
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "play"
          tooltipText: (root.spotify && root.spotify.playing ? "Pause" : "Play")
            + " · Space"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.togglePlayback()
          onHovered: function(on) { if (on) root.setMiniCursor("play") }
        }

        Button {
          iconText: "󰒭"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "next"
          tooltipText: "Next · Ctrl+Right"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.next()
          onHovered: function(on) { if (on) root.setMiniCursor("next") }
        }

        Button {
          iconText: root.spotify && root.spotify.repeatMode === "track" ? "󰑘" : "󰑖"
          foreground: root.foreground
          selected: root.spotify && root.spotify.repeatMode !== "off"
          hasCursor: root.miniCursorActive && root.miniCursor === "repeat"
          tooltipText: "Repeat: " + Api.repeatModeLabel(root.spotify
            ? root.spotify.repeatMode : "off") + " · Ctrl+R"
          enabled: root.spotify && root.spotify.playbackControllable
          onClicked: if (root.spotify) root.spotify.cycleRepeat()
          onHovered: function(on) { if (on) root.setMiniCursor("repeat") }
        }

        Button {
          iconText: "󰎈"
          foreground: root.foreground
          hasCursor: root.miniCursorActive && root.miniCursor === "lyrics"
          tooltipText: "Open lyrics in Omasing · Ctrl+Shift+L"
          enabled: root.spotify && root.spotify.lyricsAvailable
          onClicked: root.openLyrics()
          onHovered: function(on) { if (on) root.setMiniCursor("lyrics") }
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
            color: root.foreground
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
            sourcePending: root.spotify && root.spotify.pendingRemoteVolume !== null
            contextKey: root.spotify ? root.spotify.playbackDeviceName : ""
            enabled: root.spotify && root.spotify.volumeSupported
            onCommitted: function(value) {
              if (root.spotify) root.spotify.setVolume(value)
            }
          }
        }

        HoverHandler {
          onHoveredChanged: if (hovered) root.setMiniCursor("volume")
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
            - (miniQuitButton.visible
              ? miniQuitButton.width + Style.space(6) : 0)
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
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Button {
          id: miniQuitButton
          text: "Quit"
          iconText: "󰐥"
          foreground: root.foreground
          focusable: true
          visible: root.spotify && root.spotify.accountConnected
            && root.spotify.daemon && root.spotify.daemon.running
          hasCursor: root.miniCursorActive && root.miniCursor === "quit"
          tooltipText: "Stop playback and shut the backend down"
          onClicked: root.quitPlayer()
          onHovered: function(on) { if (on) root.setMiniCursor("quit") }
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
        }
      }

        LyricsInstallPrompt {
          width: parent.width
          visible: root.lyricsInstallPromptVisible
          service: root.spotify
          foreground: root.foreground
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
              color: Qt.darker(root.foreground, 1.35)
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
