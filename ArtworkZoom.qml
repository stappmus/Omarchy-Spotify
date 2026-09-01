import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

import "Api.js" as Api

Item {
  id: root

  property var client: null
  property string title: ""
  property string artist: ""
  property string album: ""
  property string fallbackUrl: ""
  property string trackKey: ""
  property color foreground: Color.foreground
  property color background: Color.background
  property string fontFamily: Style.font.family

  readonly property bool opened: window.visible
  readonly property int maxEdge: {
    var screens = Quickshell.screens
    var height = 1080
    if (screens && screens.length)
      height = Number(screens[0].height) || height
    return Math.max(320, Math.min(720, Math.round(height * 0.55)))
  }
  readonly property int chrome: Style.space(16)
  readonly property int edge: {
    var native = zoomImage.status === Image.Ready
      ? Math.max(Number(zoomImage.sourceSize.width) || 0,
        Number(zoomImage.sourceSize.height) || 0) : 0
    var image = native > 0 ? Math.min(native, maxEdge) : Math.min(480, maxEdge)
    return image + chrome
  }

  function toggle() {
    if (window.visible) close()
    else open()
  }

  function open() {
    if (client)
      client.fetchArt(title, artist, album, fallbackUrl)
    if (!ruleProcess.running) ruleProcess.running = true
    window.visible = true
    Qt.callLater(function() {
      if (keyCatcher) keyCatcher.forceActiveFocus()
    })
  }

  onTrackKeyChanged: if (window.visible && client)
    client.fetchArt(title, artist, album, fallbackUrl)

  function close() {
    window.visible = false
  }

  Process {
    id: ruleProcess
    running: false
    command: ["hyprctl", "eval",
      'if omarchy_spotify_art_zoom_rule == nil then '
      + 'omarchy_spotify_art_zoom_rule = hl.window_rule({ '
      + 'name = "omarchy-spotify-art-zoom-pre-map", '
      + 'match = { class = "org[.]quickshell", '
      + 'title = "Album art — Omarchy Spotify" }, '
      + 'float = true, center = true }) '
      + 'else omarchy_spotify_art_zoom_rule:set_enabled(true) end']
  }

  Process {
    id: sizeProcess
    running: false
    command: []
  }

  function applyWindowSize() {
    var size = Math.max(240, root.edge)
    sizeProcess.command = ["hyprctl", "--batch",
      'dispatch hl.dsp.window.resize({ x = ' + size + ', y = ' + size
      + ', window = "title:Album art — Omarchy Spotify" }); '
      + 'dispatch hl.dsp.window.center({ window = "title:Album art — Omarchy Spotify" })']
    sizeProcess.running = true
  }

  FloatingWindow {
    id: window
    visible: false
    title: "Album art — Omarchy Spotify"
    color: root.background
    implicitWidth: root.edge
    implicitHeight: root.edge
    minimumSize: Qt.size(root.edge, root.edge)
    maximumSize: Qt.size(root.edge, root.edge)

    onVisibleChanged: if (visible && keyCatcher) {
      keyCatcher.forceActiveFocus()
      Qt.callLater(root.applyWindowSize)
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        root.close()
        event.accepted = true
      }

      Rectangle {
        id: artFrame
        anchors.fill: parent
        color: root.background
        radius: Style.cornerRadius

        Image {
          id: zoomImage
          anchors.fill: parent
          anchors.margins: Style.space(8)
          source: root.client ? root.client.imageUrl : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: true
          visible: status === Image.Ready
          onStatusChanged: if (status === Image.Ready && window.visible)
            root.applyWindowSize()
        }

        Text {
          anchors.centerIn: parent
          visible: zoomImage.status !== Image.Ready
          text: root.client && root.client.state === "loading" ? "…" : "󰎈"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.close()
        }
      }
    }
  }
}
