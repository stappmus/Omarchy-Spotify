pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

import "Api.js" as Api

// A compact, keyboard-first queue/search surface. It deliberately uses the
// same KeyboardPanel, Color and Style primitives as Omarchy's own panels.
KeyboardPanel {
  id: root

  required property var spotify
  property bool launcherOpen: false
  property var priorityItems: []
  property var queueItems: []
  property int selectedIndex: 0
  readonly property string surfaceKey: "spotify-queue-launcher-" + String(root)
  readonly property var nowPlayingItem: spotify
    ? (spotify.currentTrackItem || spotify.remoteTrack) : null
  readonly property string nowPlayingTitle: spotify && spotify.title
    ? String(spotify.title)
    : (nowPlayingItem ? String(nowPlayingItem.name || "") : "")
  readonly property string nowPlayingArtist: readableText(spotify && spotify.artist)
    || artistText(nowPlayingItem)
  readonly property string nowPlayingArtUrl: spotify && spotify.artUrl
    ? String(spotify.artUrl)
    : (nowPlayingItem ? String(nowPlayingItem.imageUrl || "") : "")

  open: launcherOpen
  centerOnBar: true
  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(520))
  contentHeight: fittedContentHeight(Style.space(430))

  readonly property bool searchMode: searchField.text.trim() !== ""
  readonly property var visibleItems: searchMode
    ? (spotify ? spotify.searchItems("track").slice(0, 5) : [])
    : queueItems

  onLauncherOpenChanged: if (spotify) spotify.setUiVisible(surfaceKey, launcherOpen)
  Component.onDestruction: if (spotify) spotify.setUiVisible(surfaceKey, false)

  function syncQueue() {
    var remote = spotify && Array.isArray(spotify.queue) ? spotify.queue : []
    queueItems = Api.mergePriorityQueue(priorityItems, remote)
    selectedIndex = Math.max(0, Math.min(selectedIndex, queueItems.length - 1))
  }

  // QML can expose values from nested JavaScript arrays as reference objects.
  // Detach those wrappers before rendering them, and never leak their debug
  // representation into the launcher.
  function readableText(value) {
    if (value === undefined || value === null) return ""
    if (typeof value === "string" || typeof value === "number")
      return String(value)
    try {
      var detached = JSON.parse(JSON.stringify(value))
      if (detached !== value) {
        if (typeof detached === "string" || typeof detached === "number")
          return String(detached)
        if (detached && detached.name !== undefined)
          return readableText(detached.name)
      }
    } catch (error) {
      // Fall through to the safe string conversion below.
    }
    var text = String(value)
    return text.indexOf("[object ") === 0 ? "" : text
  }

  function artistText(item) {
    if (!item) return ""
    var artists = Api.arrayValues(item.artists)
    var names = []
    for (var i = 0; i < artists.length; i++) {
      var artist = artists[i]
      var name = readableText(artist && artist.name !== undefined
        ? artist.name : artist)
      if (name) names.push(name)
    }
    if (names.length) return names.join(", ")
    return readableText(item.subtitle) || readableText(item.artist)
  }

  function openLauncher() {
    searchField.text = ""
    selectedIndex = 0
    syncQueue()
    launcherOpen = true
    if (spotify) spotify.loadQueue()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closeLauncher() {
    launcherOpen = false
    searchField.text = ""
  }

  function moveSelection(delta) {
    if (!visibleItems.length) return
    selectedIndex = Math.max(0, Math.min(visibleItems.length - 1,
      selectedIndex + delta))
    results.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function handlePlaybackChanged(uri) {
    var current = String(uri || "")
    if (!current || !spotify) return
    var nextPriority = priorityItems.slice()
    for (var i = 0; i < nextPriority.length; i++) {
      if (Api.queueItemIdentity(nextPriority[i]) === current) {
        nextPriority.splice(i, 1)
        priorityItems = nextPriority
        break
      }
    }
    spotify.loadQueue()
  }

  function skipToQueueItem(index, item) {
    var remote = spotify && Array.isArray(spotify.queue) ? spotify.queue : []
    var remoteIndex = Api.queueItemIndex(remote, item)
    if (remoteIndex < 0 || !spotify) {
      if (spotify && !spotify.queueLoading) spotify.loadQueue()
      return false
    }
    var count = Api.queueSkipCount(remoteIndex, remote.length)
    if (!count) return false
    // Enter explicitly follows Spotify's real queue, so cancel any pending
    // local edits before issuing the requested number of Next operations.
    priorityItems = []
    // Dispatch every Next request immediately. Responses only trigger a later
    // state refresh and never gate the remaining skips.
    spotify.nextBurst(count)
    return true
  }

  function activateSelection(playInstead) {
    var item = visibleItems[selectedIndex]
    if (!item || !spotify) return
    if (!searchMode) {
      if (skipToQueueItem(selectedIndex, item)) closeLauncher()
      return
    }
    if (searchMode && !playInstead) {
      priorityItems = priorityItems.concat([item])
      syncQueue()
      spotify.addToQueue(item)
      searchField.text = ""
      selectedIndex = Math.min(priorityItems.length - 1, queueItems.length - 1)
      keyCatcher.forceActiveFocus()
      return
    }
    spotify.playItem(item, visibleItems, "", "Playing selection")
    closeLauncher()
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    Connections {
      target: root.spotify
      function onQueueChanged() { root.syncQueue() }
      function onCurrentUriChanged() { root.handlePlaybackChanged(root.spotify.currentUri) }
    }

    Timer {
      interval: 5000
      repeat: true
      running: root.launcherOpen && !!root.spotify
      onTriggered: if (!root.spotify.queueLoading) root.spotify.loadQueue()
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.searchMode) {
          searchField.text = ""
          root.selectedIndex = 0
          keyCatcher.forceActiveFocus()
        } else {
          root.closeLauncher()
        }
      } else if (event.key === Qt.Key_Up) {
        root.moveSelection(-1)
      } else if (event.key === Qt.Key_Down) {
        root.moveSelection(1)
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.activateSelection((event.modifiers & Qt.ShiftModifier) !== 0)
      } else if (event.key === Qt.Key_Backspace) {
        if (root.searchMode) {
          searchField.forceActiveFocus()
          searchField.remove(Math.max(0, searchField.cursorPosition - 1),
            searchField.cursorPosition)
        }
      } else if (event.text.length > 0
          && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
        searchField.forceActiveFocus()
        searchField.insert(searchField.cursorPosition, event.text)
        root.selectedIndex = 0
      } else {
        event.accepted = false
        return
      }
      event.accepted = true
    }

    Column {
      anchors.fill: parent
      spacing: Style.space(8)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: Math.max(110, parent.width - modeHint.width - parent.spacing)
          text: root.searchMode ? "SEARCH SPOTIFY" : "NOW PLAYING:"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          id: modeHint
          text: root.searchMode ? "Enter queue · Shift+Enter play"
            : "↑↓ select · Enter skip"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      TextField {
        id: searchField
        visible: root.searchMode
        width: parent.width
        foreground: Color.foreground
        placeholderText: "Type to search Spotify"
        onTextChanged: {
          root.selectedIndex = 0
          if (root.spotify && text.trim() !== "") root.spotify.search(text)
        }
        Keys.onEscapePressed: function(event) {
          text = ""
          root.selectedIndex = 0
          keyCatcher.forceActiveFocus()
          event.accepted = true
        }
        Keys.onUpPressed: function(event) {
          root.moveSelection(-1)
          event.accepted = true
        }
        Keys.onDownPressed: function(event) {
          root.moveSelection(1)
          event.accepted = true
        }
        Keys.onReturnPressed: function(event) {
          root.activateSelection((event.modifiers & Qt.ShiftModifier) !== 0)
          event.accepted = true
        }
        Keys.onEnterPressed: function(event) {
          root.activateSelection((event.modifiers & Qt.ShiftModifier) !== 0)
          event.accepted = true
        }
      }

      Item {
        id: nowPlayingSection
        visible: !root.searchMode
        width: parent.width
        height: Style.space(62)

        Row {
          id: nowPlayingRow
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(50)
          spacing: Style.space(10)

          BorderSurface {
            id: nowPlayingArtwork
            width: parent.height
            height: width
            radius: Style.cornerRadius
            color: Qt.lighter(Color.background, 1.08)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              source: root.nowPlayingArtUrl
              sourceSize.width: 96
              sourceSize.height: 96
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
            }
          }

          Column {
            width: Math.max(20, parent.width - nowPlayingArtwork.width - parent.spacing)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.nowPlayingTitle || "Nothing playing"
              color: "#1ed760"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.nowPlayingArtist
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: Color.muted
          opacity: 0.35
        }
      }

      Text {
        width: parent.width
        text: root.searchMode ? "RESULTS" : "QUEUE"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      ListView {
        id: results
        width: parent.width
        height: Math.max(80, parent.height - y)
        model: root.visibleItems
        clip: true
        spacing: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds
        onModelChanged: currentIndex = root.selectedIndex
        onCurrentIndexChanged: if (currentIndex >= 0) root.selectedIndex = currentIndex

        delegate: BorderSurface {
          id: resultDelegate
          required property var modelData
          required property int index
          width: results.width
          height: Style.space(58)
          radius: Style.cornerRadius
          color: resultDelegate.index === root.selectedIndex
            ? Style.selectedFillFor(Color.foreground, Color.accent) : "transparent"
          borderSpec: resultDelegate.index === root.selectedIndex
            ? Border.controlSpec("selected", Color.foreground, Color.accent) : Border.none()

          Row {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            spacing: Style.space(10)

            Text {
              id: rowNumber
              visible: !root.searchMode
              width: visible ? Style.space(22) : 0
              height: parent.height
              text: String(resultDelegate.index + 1)
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }

            BorderSurface {
              id: rowArtwork
              width: parent.height
              height: width
              radius: Style.cornerRadius
              color: Qt.lighter(Color.background, 1.08)
              Image {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                source: resultDelegate.modelData && resultDelegate.modelData.imageUrl
                  ? resultDelegate.modelData.imageUrl : ""
                sourceSize.width: 96
                sourceSize.height: 96
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
              }
            }

            Column {
              width: Math.max(20, parent.width - rowNumber.width
                - rowArtwork.width - parent.spacing * (rowNumber.visible ? 2 : 1))
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: resultDelegate.modelData
                  ? String(resultDelegate.modelData.name || "Untitled") : "Untitled"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: resultDelegate.index === root.selectedIndex
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: root.artistText(resultDelegate.modelData)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: {
              root.selectedIndex = resultDelegate.index
              root.activateSelection(false)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: results.count === 0
          text: root.searchMode
            ? (root.spotify && root.spotify.searchLoading ? "Searching…" : "No songs found")
            : (root.spotify && root.spotify.queueLoading ? "Loading queue…" : "Queue is empty")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
