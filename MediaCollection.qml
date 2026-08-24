import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

import "Api.js" as Api

Item {
  id: root
  objectName: "media-collection"

  required property var service
  property var sourceItems: []
  property string filterText: ""
  property string sortKey: "default"
  property string contextUri: ""
  property bool showFilter: true
  property bool showSort: showFilter
  property bool showQueue: true
  property bool showPlaylist: true
  property bool showSave: true
  property bool browseContexts: true
  property bool loading: false
  property bool hasMore: false
  property string emptyMessage: "Nothing here yet."
  property real restoredContentY: 0
  property string stateKey: ""
  property bool restoreApplied: false
  property bool keyboardSortSelected: false
  property bool keyboardMoreSelected: false
  property string keyboardSortHint: ""
  property string keyboardMoreHint: ""
  property string keyboardListHint: ""
  property bool keyboardAtList: false
  property bool keyboardAtListPrev: false
  property bool keyboardAtListNext: false
  property bool keyboardListIsTab: false
  property bool keyboardListIsBacktab: false
  property bool keyboardNavModifiers: false
  property bool keyboardCtrlHeld: false
  property bool keyboardShiftHeld: false
  property bool keyboardAltHeld: false
  property bool keyboardHintsActive: false
  property string keyboardListId: "list"
  readonly property int listCurrentIndex: mediaList.currentIndex
  readonly property int listCount: mediaList.count
  property bool allowReorder: false
  property bool reorderBusy: false
  property int dragSourceIndex: -1
  property int dragDestinationIndex: -1
  property real dragSceneY: 0
  property int dragAutoScrollDirection: 0

  readonly property var visibleItems: Api.filteredSorted(sourceItems, filterText, sortKey)
  readonly property var sortKeys: ["default", "name", "artist", "album", "duration",
    "date", "date-asc"]
  readonly property bool canReorder: allowReorder && !reorderBusy
    && String(filterText || "").trim() === "" && sortKey === "default"
    && visibleItems.length > 1
  readonly property var dragItem: dragSourceIndex >= 0
    && dragSourceIndex < visibleItems.length ? visibleItems[dragSourceIndex] : null

  signal activated(var item, var sourceItems, string contextUri)
  signal opened(var item)
  signal queued(var item)
  signal playlistRequested(var item)
  signal saveToggled(var item)
  signal contextRequested(var item, real sceneX, real sceneY, int index,
    var sourceItems, string contextUri)
  signal reorderRequested(int sourceIndex, int destinationIndex)
  signal loadMoreRequested()
  signal viewStateChanged(string filterText, string sortKey, real contentY)

  function sortLabel() {
    if (sortKey === "name") return "Title"
    if (sortKey === "artist") return "Artist"
    if (sortKey === "album") return "Album"
    if (sortKey === "duration") return "Duration"
    if (sortKey === "date") return "Date: newest"
    if (sortKey === "date-asc") return "Date: oldest"
    return "Original"
  }

  function cycleSort() {
    var index = sortKeys.indexOf(sortKey)
    sortKey = sortKeys[(index + 1) % sortKeys.length]
    viewStateChanged(filterText, sortKey, mediaList.contentY)
  }

  function focusList() {
    mediaList.forceActiveFocus()
    if (mediaList.currentIndex < 0 && mediaList.count > 0) mediaList.currentIndex = 0
  }

  function moveCurrent(delta) {
    var next = Api.listIndexAfterMove(mediaList.count, mediaList.currentIndex, delta)
    if (next < 0) return false
    mediaList.currentIndex = next
    return true
  }

  function currentContextAnchor() {
    var index = mediaList.currentIndex
    if (index < 0 || index >= visibleItems.length) return null
    var row = mediaList.currentItem
    var point = row ? row.mapToItem(null, row.width / 2, row.height / 2)
      : ({ x: 0, y: 0 })
    return {
      item: visibleItems[index],
      index: index,
      x: point.x,
      y: point.y,
      items: visibleItems,
      uri: contextUri
    }
  }

  function activateCurrent() {
    if (mediaList.currentItem) mediaList.currentItem.triggerPrimary()
  }

  function jumpToEdge(toEnd) {
    if (mediaList.count <= 0) return
    mediaList.currentIndex = toEnd ? mediaList.count - 1 : 0
  }

  function firstVisibleListIndex() {
    if (mediaList.count <= 0) return 0
    var y = mediaList.contentY + 1
    if (y < mediaList.originY) y = mediaList.originY + 1
    var index = mediaList.indexAt(Math.max(1, mediaList.width / 2), y)
    return Api.listHintRowIndex(mediaList.count, index)
  }

  function jumpToFirstVisible() {
    if (mediaList.count <= 0) return
    mediaList.currentIndex = firstVisibleListIndex()
  }

  function blurList() {
    mediaList.focus = false
  }

  function rowNavHint(index) {
    if (!keyboardHintsActive) return ""
    return Api.cursorListRowHint({
      rowIndex: index,
      currentIndex: mediaList.currentIndex,
      count: mediaList.count,
      tabRowIndex: firstVisibleListIndex(),
      atList: keyboardAtList,
      previousIsCurrent: keyboardAtListPrev,
      nextIsCurrent: keyboardAtListNext,
      tabIsList: keyboardListIsTab,
      backtabIsList: keyboardListIsBacktab,
      modifiersHeld: keyboardNavModifiers
    })
  }

  function requestMore() {
    if (hasMore && !loading) loadMoreRequested()
  }

  function reorderIndexAtSceneY(sceneY) {
    if (mediaList.count <= 0) return -1
    var top = mediaList.mapToItem(null, 0, 0)
    var bottom = mediaList.mapToItem(null, 0, mediaList.height)
    var center = mediaList.mapToItem(null, mediaList.width / 2, 0)
    var clampedY = Math.max(top.y + 1, Math.min(bottom.y - 1, sceneY))
    var contentPoint = mediaList.contentItem.mapFromItem(null, center.x, clampedY)
    var candidate = mediaList.indexAt(contentPoint.x, contentPoint.y)
    if (candidate >= 0) return candidate

    // The pointer can land in ListView.spacing, where indexAt() intentionally
    // returns -1. Pick the nearest instantiated row in that case.
    var closest = -1
    var closestDistance = Number.MAX_VALUE
    for (var i = 0; i < mediaList.count; i++) {
      var row = mediaList.itemAtIndex(i)
      if (!row) continue
      var rowCenter = row.mapToItem(null, row.width / 2, row.height / 2)
      var distance = Math.abs(rowCenter.y - clampedY)
      if (distance < closestDistance) {
        closest = i
        closestDistance = distance
      }
    }
    if (closest >= 0) return closest
    return contentPoint.y <= mediaList.originY ? 0 : mediaList.count - 1
  }

  function updateReorder(sceneY) {
    if (dragSourceIndex < 0) return
    dragSceneY = sceneY
    dragDestinationIndex = reorderIndexAtSceneY(sceneY)
    var center = mediaList.mapToItem(null, mediaList.width / 2, 0)
    var point = mediaList.mapFromItem(null, center.x, sceneY)
    var edge = Math.min(Style.space(48), mediaList.height / 3)
    dragAutoScrollDirection = point.y < edge ? -1
      : (point.y > mediaList.height - edge ? 1 : 0)
  }

  function beginReorder(index, sceneY) {
    if (!canReorder || index < 0 || index >= visibleItems.length) return
    mediaList.cancelFlick()
    dragSourceIndex = index
    dragDestinationIndex = index
    dragSceneY = sceneY
    dragAutoScrollDirection = 0
  }

  function finishReorder(sceneY, canceled) {
    if (dragSourceIndex < 0) return
    if (!canceled) updateReorder(sceneY)
    var source = dragSourceIndex
    var destination = dragDestinationIndex
    dragSourceIndex = -1
    dragDestinationIndex = -1
    dragAutoScrollDirection = 0
    rememberView()
    if (!canceled && destination >= 0 && destination !== source)
      reorderRequested(source, destination)
  }

  function cancelReorder() {
    finishReorder(dragSceneY, true)
  }

  function rememberView() {
    viewStateChanged(filterText, sortKey, mediaList.contentY)
  }

  function restoreView() {
    if (restoreApplied || restoredContentY <= 0 || mediaList.count <= 0) return
    restoreTimer.restart()
  }

  function resetRestore() {
    restoreApplied = false
    restoreTimer.restart()
  }

  Timer {
    id: restoreTimer
    interval: 0
    onTriggered: {
      if (root.restoreApplied) return
      if (root.restoredContentY <= 0) {
        mediaList.contentY = mediaList.originY
        root.restoreApplied = true
        return
      }
      if (mediaList.count <= 0) return
      var maximum = Math.max(mediaList.originY,
        mediaList.contentHeight - mediaList.height + mediaList.originY)
      mediaList.contentY = Math.max(mediaList.originY,
        Math.min(maximum, root.restoredContentY))
      root.restoreApplied = true
    }
  }

  Component.onCompleted: restoreView()
  onRestoredContentYChanged: resetRestore()
  onStateKeyChanged: resetRestore()
  onCanReorderChanged: if (!canReorder) cancelReorder()
  Component.onDestruction: rememberView()

  Timer {
    interval: 30
    repeat: true
    running: root.dragSourceIndex >= 0 && root.dragAutoScrollDirection !== 0
    onTriggered: {
      var minimum = mediaList.originY
      var maximum = Math.max(minimum,
        mediaList.contentHeight - mediaList.height + mediaList.originY)
      var next = Math.max(minimum, Math.min(maximum,
        mediaList.contentY + root.dragAutoScrollDirection * Style.space(9)))
      if (next === mediaList.contentY) return
      mediaList.contentY = next
      root.updateReorder(root.dragSceneY)
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(7)

    Row {
      id: tools
      width: parent.width
      height: visible ? Style.space(38) : 0
      visible: root.showFilter || root.showSort
      spacing: Style.space(7)

      TextField {
        id: filterField
        visible: root.showFilter
        width: visible ? Math.max(80, parent.width
          - (sortButton.visible ? sortButton.width + parent.spacing : 0)
          - countLabel.width - parent.spacing) : 0
        foreground: Color.foreground
        placeholderText: "Filter this list"
        text: root.filterText
        onTextEdited: {
          root.filterText = text
          root.viewStateChanged(root.filterText, root.sortKey, mediaList.contentY)
        }
        Keys.onDownPressed: root.focusList()
      }

      Button {
        id: sortButton
        visible: root.showSort
        text: root.sortLabel()
        iconText: "󰒺"
        foreground: Color.foreground
        tooltipText: "Change sort order"
        focusable: false
        hasCursor: root.keyboardSortSelected
        onClicked: root.cycleSort()
        ShortcutHint {
          active: root.keyboardHintsActive && root.keyboardSortHint !== ""
          navHint: root.keyboardSortHint
        }
      }

      Text {
        id: countLabel
        anchors.verticalCenter: parent.verticalCenter
        text: root.visibleItems.length
          + (root.filterText ? (root.visibleItems.length === 1 ? " match" : " matches")
            : (root.visibleItems.length === 1 ? " item" : " items"))
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    ListView {
      id: mediaList
      width: parent.width
      height: Math.max(30, parent.height - tools.height - moreButton.height
        - emptyLabel.height - parent.spacing * 3)
      model: root.visibleItems
      clip: true
      spacing: Style.space(3)
      reuseItems: true
      cacheBuffer: Style.space(160)
      interactive: root.dragSourceIndex < 0
      activeFocusOnTab: false
      keyNavigationEnabled: false
      highlightFollowsCurrentItem: true
      ScrollBar.vertical: ScrollBar { }
      onMovementEnded: root.rememberView()
      onCountChanged: {
        root.restoreView()
        if (root.dragSourceIndex >= count) root.cancelReorder()
      }

      FastScrollHandler {
        parent: mediaList
        flickable: mediaList
        onScrolled: root.rememberView()
      }

      Keys.onReturnPressed: function(event) {
        if (!root.keyboardAtList) {
          event.accepted = false
          return
        }
        if (currentItem) currentItem.triggerPrimary()
        event.accepted = true
      }
      Keys.onEnterPressed: function(event) {
        if (!root.keyboardAtList) {
          event.accepted = false
          return
        }
        if (currentItem) currentItem.triggerPrimary()
        event.accepted = true
      }

      delegate: MediaRow {
        required property var modelData
        required property int index
        itemData: modelData
        foreground: Color.foreground
        accent: Color.accent
        fontFamily: Style.font.family
        selected: ListView.isCurrentItem && root.keyboardAtList
        browseOnActivate: root.browseContexts && modelData.kind === "context"
        showQueue: root.showQueue
        showPlaylist: root.showPlaylist
        showSave: root.showSave
        reorderEnabled: root.canReorder
        reorderDragging: root.dragSourceIndex === index
        reorderDropIndicator: root.dragDestinationIndex === index
          && root.dragSourceIndex !== index
          ? (index < root.dragSourceIndex ? -1 : 1) : 0
        saved: root.service ? root.service.isSaved(modelData) : false
        artworkEnabled: !root.service || root.service.artworkEnabled
        ShortcutHint {
          ctrlHeld: root.keyboardCtrlHeld
          shiftHeld: root.keyboardShiftHeld
          altHeld: root.keyboardAltHeld
          sequences: selected ? ["C"] : []
          active: root.keyboardHintsActive && (hint !== "" || selected)
          navHint: hint
          readonly property string hint: {
            mediaList.currentIndex
            mediaList.count
            mediaList.contentY
            root.keyboardAtList
            root.keyboardAtListPrev
            root.keyboardAtListNext
            root.keyboardListIsTab
            root.keyboardListIsBacktab
            root.keyboardNavModifiers
            root.keyboardHintsActive
            return root.rowNavHint(index)
          }
        }
        onActivated: function(item) {
          root.activated(item, root.visibleItems, root.contextUri)
        }
        onOpenRequested: function(item) { root.opened(item) }
        onArtistRequested: function(item) { root.opened(item) }
        onAlbumRequested: function(item) { root.opened(item) }
        onQueueRequested: function(item) { root.queued(item) }
        onPlaylistRequested: function(item) { root.playlistRequested(item) }
        onSaveRequested: function(item) { root.saveToggled(item) }
        onContextRequested: function(item, sceneX, sceneY) {
          root.contextRequested(item, sceneX, sceneY, index,
            root.visibleItems, root.contextUri)
        }
        onReorderDragStarted: function(sceneY) {
          root.beginReorder(index, sceneY)
        }
        onReorderDragMoved: function(sceneY) { root.updateReorder(sceneY) }
        onReorderDragFinished: function(sceneY) {
          root.finishReorder(sceneY, false)
        }
        onReorderDragCanceled: root.cancelReorder()
      }
    }

    Text {
      id: emptyLabel
      width: parent.width
      height: visible ? contentHeight : 0
      visible: !root.loading && root.visibleItems.length === 0
      text: root.emptyMessage
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Button {
      id: moreButton
      anchors.horizontalCenter: parent.horizontalCenter
      height: visible ? implicitHeight : 0
      visible: root.loading || root.hasMore
      text: root.loading ? "Loading…" : "Load more"
      foreground: Color.foreground
      enabled: root.hasMore && !root.loading
      hasCursor: root.keyboardMoreSelected
      onClicked: root.loadMoreRequested()
      ShortcutHint {
        active: root.keyboardHintsActive && root.keyboardMoreHint !== ""
        navHint: root.keyboardMoreHint
      }
    }
  }

  BorderSurface {
    id: dragPreview
    x: Style.space(4)
    width: Math.max(40, parent.width - Style.space(8))
    height: Style.space(48)
    y: Math.max(0, Math.min(parent.height - height,
      root.mapFromItem(null, 0, root.dragSceneY).y - height / 2))
    visible: root.dragSourceIndex >= 0 && !!root.dragItem
    enabled: false
    z: 20
    radius: Style.cornerRadius
    color: Style.selectedFillFor(Color.foreground, Color.accent)
    borderSpec: Border.controlSpec("selected", Color.foreground, Color.accent)
    opacity: 0.94

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(8)

      Column {
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          text: root.dragItem ? String(root.dragItem.name || "Untitled") : ""
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.dragItem ? String(root.dragItem.subtitle || "") : ""
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
