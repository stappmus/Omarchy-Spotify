import QtQuick
import qs.Commons
import qs.Ui

import "Api.js" as Api

Column {
  id: root

  required property var service
  property string heading: "RESULTS"
  property var sourceItems: []
  property bool loading: false
  property bool hasMore: false
  property bool browseContexts: false
  property bool showQueue: false
  property bool showPlaylist: true
  property bool showSave: true
  property string contextUri: ""

  readonly property int resultCount: sourceItems ? sourceItems.length : 0
  readonly property int columnCount: Api.responsiveResultColumns(width,
    Style.space(760))
  readonly property int resultRows: Math.ceil(resultCount / columnCount)

  signal activated(var item, var sourceItems, string contextUri)
  signal opened(var item)
  signal queued(var item)
  signal playlistRequested(var item)
  signal saveToggled(var item)
  signal contextRequested(var item, real sceneX, real sceneY, int index,
    var sourceItems, string contextUri)
  signal loadMoreRequested()

  visible: loading || resultCount > 0
  height: visible ? implicitHeight : 0
  spacing: Style.space(5)

  Row {
    width: parent.width
    spacing: Style.space(8)

    Text {
      width: Math.max(40, parent.width - resultStatus.width - parent.spacing)
      text: root.heading
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: resultStatus
      text: root.loading && root.resultCount === 0
        ? "Finding…" : String(root.resultCount)
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  GridView {
    id: resultGrid
    width: parent.width
    height: root.resultCount > 0 ? root.resultRows * cellHeight : 0
    visible: height > 0
    model: root.sourceItems
    interactive: false
    clip: false
    reuseItems: true
    cellWidth: width / root.columnCount
    cellHeight: root.service && root.service.artworkEnabled
      ? Style.space(72) : Style.space(50)

    delegate: Item {
      id: resultCell
      required property var modelData
      required property int index
      width: resultGrid.cellWidth
      height: resultGrid.cellHeight

      MediaRow {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        itemData: resultCell.modelData
        foreground: Color.foreground
        accent: Color.accent
        fontFamily: Style.font.family
        browseOnActivate: root.browseContexts && modelData.kind === "context"
        showQueue: root.showQueue
        showPlaylist: root.showPlaylist
        showSave: root.showSave
        saved: root.service ? root.service.isSaved(modelData) : false
        artworkEnabled: !root.service || root.service.artworkEnabled
        onActivated: function(item) {
          root.activated(item, root.sourceItems, root.contextUri)
        }
        onOpenRequested: function(item) { root.opened(item) }
        onArtistRequested: function(item) { root.opened(item) }
        onAlbumRequested: function(item) { root.opened(item) }
        onQueueRequested: function(item) { root.queued(item) }
        onPlaylistRequested: function(item) { root.playlistRequested(item) }
        onSaveRequested: function(item) { root.saveToggled(item) }
        onContextRequested: function(item, sceneX, sceneY) {
          root.contextRequested(item, sceneX, sceneY, resultCell.index,
            root.sourceItems, root.contextUri)
        }
      }
    }
  }

  Button {
    anchors.horizontalCenter: parent.horizontalCenter
    height: visible ? implicitHeight : 0
    visible: root.loading || root.hasMore
    text: root.loading ? "Loading…" : "Load more"
    foreground: Color.foreground
    enabled: root.hasMore && !root.loading
    onClicked: root.loadMoreRequested()
  }
}
