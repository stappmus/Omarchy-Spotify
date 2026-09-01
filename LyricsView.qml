import QtQuick
import qs.Commons

import "Api.js" as Api

Item {
  id: root

  property var client: null
  property real positionSeconds: 0
  property bool playing: false
  property color foreground: Color.foreground
  property color muted: Color.muted
  property string fontFamily: Style.font.family
  property bool followPlayback: true
  property string trackKey: ""

  readonly property var timedLines: client ? client.timedLines : []
  readonly property bool hasTimed: timedLines && timedLines.length > 0
  readonly property string state: client ? String(client.state || "idle") : "idle"
  readonly property int activeIndex: hasTimed
    ? Api.currentLineIndex(timedLines,
      Api.lyricsSyncPositionMs(positionSeconds, playing)) : -1

  onTrackKeyChanged: followPlayback = true
  onActiveIndexChanged: {
    if (!followPlayback || !hasTimed || activeIndex < 0) return
    lyricsList.currentIndex = activeIndex
    lyricsList.positionViewAtIndex(activeIndex, ListView.Center)
  }

  readonly property string emptyGlyph: {
    if (state === "instrumental") return "󰎃"
    if (state === "ratelimited") return "󰒏"
    if (state === "error") return "󰅚"
    if (state === "notfound" || (state === "ready" && !hasTimed
        && (!client || !client.plainLyrics)))
      return "󰎈"
    return ""
  }
  readonly property string emptyTitle: {
    if (state === "loading") return "Loading lyrics"
    if (state === "instrumental") return "Instrumental"
    if (state === "ratelimited") return "Try again shortly"
    if (state === "error") return "Could not load lyrics"
    if (state === "notfound" || (state === "ready" && !hasTimed
        && (!client || !client.plainLyrics)))
      return "No lyrics found"
    return ""
  }
  readonly property string emptyDetail: {
    if (state === "instrumental") return "This recording has no lyrics."
    if (state === "ratelimited" || state === "error")
      return client ? String(client.message || "") : ""
    if (state === "notfound")
      return "LRCLIB does not have this recording yet."
    return ""
  }
  readonly property bool showingEmpty: emptyTitle !== ""

  Column {
    anchors.fill: parent
    visible: root.showingEmpty
    spacing: Style.space(6)

    Item { width: 1; height: Math.max(0, (parent.height - 80) / 4) }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.emptyGlyph !== ""
      text: root.emptyGlyph
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.emptyTitle
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.emptyDetail !== ""
      text: root.emptyDetail
      color: root.muted
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  ListView {
    id: lyricsList
    anchors.fill: parent
    visible: root.state === "ready" && root.hasTimed
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: root.timedLines
    spacing: Style.space(4)
    currentIndex: root.activeIndex
    highlightFollowsCurrentItem: false
    onMovementStarted: root.followPlayback = false

    delegate: Text {
      width: lyricsList.width
      text: modelData && modelData.text ? modelData.text : " "
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: index === root.activeIndex
      color: index === root.activeIndex ? root.foreground
        : (index < root.activeIndex ? root.muted : root.foreground)
      opacity: index === root.activeIndex ? 1 : (index < root.activeIndex ? 0.55 : 0.78)
    }

    FastScrollHandler {
      flickable: lyricsList
      onScrolled: root.followPlayback = false
    }
  }

  Flickable {
    id: plainFlick
    anchors.fill: parent
    visible: root.state === "ready" && !root.hasTimed && root.client
      && String(root.client.plainLyrics || "") !== ""
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    contentWidth: width
    contentHeight: plainText.implicitHeight

    Text {
      id: plainText
      width: plainFlick.width
      text: root.client ? String(root.client.plainLyrics || "") : ""
      wrapMode: Text.WordWrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    FastScrollHandler { flickable: plainFlick }
  }
}
