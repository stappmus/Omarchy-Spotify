import QtQuick
import qs.Commons
import qs.Commons as Theme
import qs.Ui

Item {
  id: root

  property var service: null
  property color foreground: Theme.Color.foreground
  property color muted: Theme.Color.muted
  property color urgent: Theme.Color.urgent
  property string surfaceKey: ""
  property bool cancelHasCursor: false
  property bool confirmHasCursor: false
  readonly property string availability: service
    ? String(service.lyricsPluginAvailability || "missing") : "missing"
  readonly property bool busy: service && service.lyricsPluginBusy
  readonly property string errorText: service
    ? String(service.lyricsPluginError || "") : ""

  signal canceled()

  implicitWidth: Style.space(340)
  implicitHeight: promptContent.implicitHeight
  height: implicitHeight

  Column {
    id: promptContent
    width: parent.width
    spacing: Style.space(9)

    Text {
      objectName: "lyrics-install-title"
      width: parent.width
      text: root.availability === "disabled" ? "Enable Omasing Lyrics?"
        : (root.availability === "ready" && root.errorText
          ? "Omasing didn't open" : "Install Omasing Lyrics?")
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "lyrics-install-description"
      width: parent.width
      text: root.availability === "disabled"
        ? "Omasing is already installed. Enable it and add its widget to the center of your bar?"
        : (root.availability === "ready"
          ? "The plugin is installed, but Spotify could not open its lyrics window."
          : "Lyrics are provided by the optional Omasing plugin. Install and enable it now?")
      color: root.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      visible: root.availability === "missing"
      text: "This downloads github.com/stappmus/Omasing. Omarchy plugins run unsandboxed inside the shell."
      color: root.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      objectName: "lyrics-install-error"
      width: parent.width
      visible: text !== ""
      text: root.errorText
      color: root.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Button {
        objectName: "lyrics-install-cancel"
        width: (parent.width - parent.spacing) / 2
        text: "Cancel"
        foreground: root.foreground
        focusable: true
        hasCursor: root.cancelHasCursor
        enabled: !root.busy
        onClicked: root.canceled()
      }

      Button {
        objectName: "lyrics-install-confirm"
        width: (parent.width - parent.spacing) / 2
        text: root.busy
          ? (root.service && root.service.lyricsPluginOperation === "disabled"
            ? "Enabling…" : "Installing…")
          : (root.availability === "disabled" ? "Enable"
            : (root.availability === "ready" ? "Try again" : "Install"))
        iconText: root.availability === "ready" ? "󰑓" : "󰐕"
        foreground: root.foreground
        selected: true
        focusable: true
        hasCursor: root.confirmHasCursor
        enabled: root.service && !root.busy
        onClicked: root.service.confirmLyricsPlugin(root.surfaceKey)
      }
    }
  }
}
