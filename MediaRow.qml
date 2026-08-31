import QtQuick
import qs.Commons
import qs.Ui

import "Api.js" as Api

BorderSurface {
  id: root

  required property var itemData
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted
  property string fontFamily: Style.font.family
  property bool selected: false
  property bool showPlay: true
  property bool showQueue: false
  property bool showPlaylist: true
  property bool showSave: false
  property bool saved: false
  property bool browseOnActivate: false
  property bool reorderEnabled: false
  property bool reorderDragging: false
  property int reorderDropIndicator: 0
  property bool hovered: hoverHandler.hovered
  property bool actionsExpanded: false

  readonly property bool durationActionVisible: itemData
    && itemData.kind === "item" && Number(itemData.durationMs) > 0
  readonly property bool saveActionVisible: showSave && !saved && itemData
    && !!itemData.uri && itemData.type !== "chapter"
  readonly property bool playlistActionVisible: showPlaylist && itemData
    && ["track", "episode"].indexOf(itemData.type) >= 0
  readonly property bool queueActionVisible: showQueue && itemData
    && ["track", "episode"].indexOf(itemData.type) >= 0
  readonly property bool playActionVisible: showPlay && itemData
    && ["show", "audiobook"].indexOf(itemData.type) < 0
  readonly property int fullActionCount: (durationActionVisible ? 1 : 0)
    + (saveActionVisible ? 1 : 0) + (playlistActionVisible ? 1 : 0)
    + (queueActionVisible ? 1 : 0) + (playActionVisible ? 1 : 0)
  readonly property real fullActionWidth:
    (durationActionVisible ? durationLabel.implicitWidth : 0)
    + (saveActionVisible ? saveButton.implicitWidth : 0)
    + (playlistActionVisible ? playlistButton.implicitWidth : 0)
    + (queueActionVisible ? queueButton.implicitWidth : 0)
    + (playActionVisible ? playButton.implicitWidth : 0)
    + Math.max(0, fullActionCount - 1) * Style.space(2)
  readonly property real titleWidthWithFullActions: Math.max(0,
    contentRow.width - artworkSurface.width - fullActionWidth
      - contentRow.spacing * 2)
  readonly property bool compactActions: Api.mediaRowShouldCompact(
    titleMetrics.advanceWidth, titleWidthWithFullActions, fullActionCount)

  signal activated(var item)
  signal openRequested(var item)
  signal queueRequested(var item)
  signal playlistRequested(var item)
  signal saveRequested(var item)
  signal artistRequested(var item)
  signal albumRequested(var item)
  signal contextRequested(var item, real sceneX, real sceneY)
  signal reorderDragStarted(real sceneY)
  signal reorderDragMoved(real sceneY)
  signal reorderDragFinished(real sceneY)
  signal reorderDragCanceled()

  function triggerPrimary() {
    if (browseOnActivate) openRequested(itemData)
    else activated(itemData)
  }

  function triggerPlay() { activated(itemData) }

  onItemDataChanged: actionsExpanded = false
  onCompactActionsChanged: if (!compactActions) actionsExpanded = false

  width: parent ? parent.width : implicitWidth
  implicitWidth: Style.space(420)
  implicitHeight: Style.space(66)
  height: implicitHeight
  radius: Style.cornerRadius
  color: selected || reorderDragging
    ? Style.selectedFillFor(foreground, accent)
    : (reorderDropIndicator !== 0 ? Style.hoverFillFor(foreground, accent)
    : (hovered ? Style.hoverFillFor(foreground, accent) : "transparent"))
  borderSpec: selected || reorderDragging
    ? Border.controlSpec("selected", foreground, accent)
    : Border.none()
  opacity: reorderDragging ? 0.55 : 1
  clip: true

  HoverHandler { id: hoverHandler }

  TextMetrics {
    id: titleMetrics
    text: root.itemData ? String(root.itemData.name || "Untitled") : "Untitled"
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: root.selected
  }

  MouseArea {
    id: rowMouseArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: root.reorderEnabled
    cursorShape: root.reorderEnabled
      ? (reorderGesture ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
      : Qt.PointingHandCursor

    property bool reorderCandidate: false
    property bool reorderGesture: false
    property bool suppressActivation: false
    property real pressSceneY: 0

    function pointerSceneY(mouse) {
      return mapToItem(null, mouse.x, mouse.y).y
    }

    onPressed: function(mouse) {
      suppressActivation = false
      reorderCandidate = mouse.button === Qt.LeftButton && root.reorderEnabled
      reorderGesture = false
      if (reorderCandidate) pressSceneY = pointerSceneY(mouse)
    }

    onPositionChanged: function(mouse) {
      if (!reorderCandidate || !pressed) return
      var sceneY = pointerSceneY(mouse)
      if (!reorderGesture
          && Math.abs(sceneY - pressSceneY) >= Style.space(6)) {
        reorderGesture = true
        suppressActivation = true
        root.reorderDragStarted(pressSceneY)
      }
      if (reorderGesture) root.reorderDragMoved(sceneY)
    }

    onReleased: function(mouse) {
      if (reorderGesture) root.reorderDragFinished(pointerSceneY(mouse))
      reorderCandidate = false
      reorderGesture = false
    }

    onCanceled: {
      if (reorderGesture) root.reorderDragCanceled()
      reorderCandidate = false
      reorderGesture = false
      suppressActivation = false
    }

    onClicked: function(mouse) {
      if (suppressActivation) {
        suppressActivation = false
        return
      }
      if (mouse.button === Qt.RightButton) {
        var scenePoint = root.mapToItem(null, mouse.x, mouse.y)
        root.contextRequested(root.itemData, scenePoint.x, scenePoint.y)
      } else {
        root.triggerPrimary()
      }
    }
  }

  Row {
    id: contentRow
    anchors.fill: parent
    anchors.margins: Style.space(6)
    spacing: Style.space(9)

    BorderSurface {
      id: artworkSurface
      width: parent.height
      height: width
      radius: Style.spacing.labelGap
      color: Style.normalFillFor(root.foreground, root.accent)
      borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

      RetryImage {
        id: rowArtwork
        anchors.fill: parent
        anchors.margins: Style.space(2)
        requestedSource: root.itemData && root.itemData.imageUrl
          ? root.itemData.imageUrl : ""
        retryLimit: 4
        sourceSize.width: 112
        sourceSize.height: 112
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        // List delegates are recycled; do not retain every scrolled artwork
        // pixmap in the process. The current-track artwork is the only image
        // intentionally kept in Qt's shared cache.
        cache: false
        visible: status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: rowArtwork.status !== Image.Ready
        text: !root.itemData ? "󰝚"
          : (root.itemData.type === "playlist" ? "󰲸"
          : (root.itemData.type === "artist" ? "󰠃"
          : (root.itemData.type === "album" ? "󰀥"
          : (root.itemData.type === "show" || root.itemData.type === "episode" ? "󰦔"
          : (root.itemData.type === "audiobook" || root.itemData.type === "chapter" ? "󰂺" : "󰝚")))))
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
    }

    Column {
      width: Math.max(20, parent.width - artworkSurface.width - actionRow.width
        - parent.spacing * 2)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        id: titleText
        objectName: "media-row-title"
        width: parent.width
        text: root.itemData ? String(root.itemData.name || "Untitled") : "Untitled"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: root.selected
        elide: Text.ElideRight
      }

      MediaByline {
        width: parent.width
        itemData: root.itemData
        foreground: root.foreground
        muted: root.muted
        accent: root.accent
        albumColor: root.accent
        fontFamily: root.fontFamily
        fontPixelSize: Style.font.bodySmall
        onArtistRequested: function(item) { root.artistRequested(item) }
        onAlbumRequested: function(item) { root.albumRequested(item) }
        onContextRequested: function(item) { root.openRequested(item) }
      }
    }

    Row {
      id: actionRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        id: durationLabel
        objectName: "media-row-duration"
        visible: root.durationActionVisible
          && (!root.compactActions || root.actionsExpanded)
        anchors.verticalCenter: parent.verticalCenter
        text: Api.millisecondsToClock(root.itemData ? root.itemData.durationMs : 0)
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        id: saveButton
        objectName: "media-row-save"
        visible: root.saveActionVisible
          && (!root.compactActions || root.actionsExpanded)
        iconText: "󰋑"
        foreground: Color.urgent
        accent: Color.urgent
        tooltipText: "Save to library"
        horizontalPadding: Style.space(7)
        onClicked: root.saveRequested(root.itemData)
      }

      Button {
        id: playlistButton
        objectName: "media-row-playlist"
        visible: root.playlistActionVisible
          && (!root.compactActions || root.actionsExpanded)
        iconText: "󱁐"
        foreground: root.foreground
        tooltipText: "Add to playlist"
        horizontalPadding: Style.space(7)
        onClicked: root.playlistRequested(root.itemData)
      }

      Button {
        id: queueButton
        objectName: "media-row-queue"
        visible: root.queueActionVisible
          && (!root.compactActions || root.actionsExpanded)
        iconText: "󰐕"
        foreground: root.foreground
        tooltipText: "Add to queue"
        horizontalPadding: Style.space(7)
        onClicked: root.queueRequested(root.itemData)
      }

      Button {
        id: playButton
        objectName: "media-row-play"
        visible: root.playActionVisible
          && (!root.compactActions || root.actionsExpanded)
        iconText: "󰐊"
        foreground: root.foreground
        tooltipText: "Play"
        horizontalPadding: Style.space(7)
        onClicked: root.triggerPlay()
      }

      Button {
        id: actionToggle
        objectName: "media-row-actions-toggle"
        visible: root.compactActions
        iconText: root.actionsExpanded ? "󰅖" : "󰇙"
        foreground: root.foreground
        tooltipText: root.actionsExpanded
          ? "Hide row actions" : "Show duration and actions"
        horizontalPadding: Style.space(7)
        onClicked: root.actionsExpanded = !root.actionsExpanded
      }

    }
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.max(2, Style.space(2))
    y: root.reorderDropIndicator < 0 ? 0 : parent.height - height
    visible: root.reorderDropIndicator !== 0
    color: root.accent
    z: 5
  }
}
