import QtQuick
import qs.Commons
import qs.Commons as Theme
import qs.Ui

import "Api.js" as Api

// Next-key overlay for shortcut mode. Uses a weak theme-urgent (red) wash
// and keycap so tutorial hints stay distinct from hover and selection.
Item {
  id: root

  property var sequences: []
  property bool ctrlHeld: false
  property bool shiftHeld: false
  property bool altHeld: false
  property bool active: false
  property string navHint: ""
  property bool showWash: true
  property color foreground: Theme.Color.foreground
  property color accent: Theme.Color.accent
  property color hintColor: Theme.Color.urgent
  readonly property color washColor: Qt.rgba(hintColor.r, hintColor.g,
    hintColor.b, Style.hoverFillAlpha)
  readonly property color washBorder: Qt.rgba(hintColor.r, hintColor.g,
    hintColor.b, Style.hoverBorderAlpha)
  readonly property color keycapFill: Qt.rgba(hintColor.r, hintColor.g,
    hintColor.b, Style.selectedFillAlpha)
  readonly property color keycapBorder: Qt.rgba(hintColor.r, hintColor.g,
    hintColor.b, Style.normalBorderAlpha)

  readonly property string label: Api.shortcutOverlayLabel(sequences, {
    ctrl: ctrlHeld,
    shift: shiftHeld,
    alt: altHeld
  }, active, navHint)
  readonly property bool shown: label !== "" && (!parent || parent.enabled !== false)
  readonly property real reservedRight: shown
    ? keycap.implicitWidth + Style.space(4) : 0

  anchors.fill: parent
  visible: opacity > 0.01
  opacity: shown ? 1 : 0
  z: 24
  enabled: false
  clip: false

  Behavior on opacity { NumberAnimation { duration: 90 } }

  BorderSurface {
    anchors.fill: parent
    visible: root.showWash
    radius: Style.cornerRadius
    color: root.washColor
    borderSpec: Border.flat(root.washBorder, Math.max(1, Style.normalBorderWidth))
  }

  BorderSurface {
    id: keycap
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Math.max(1, Style.space(2))
    implicitWidth: keycapText.implicitWidth + Style.space(8)
    implicitHeight: keycapText.implicitHeight + Style.space(3)
    radius: Math.max(2, Math.round(Style.cornerRadius * 0.7))
    color: root.keycapFill
    borderSpec: Border.flat(root.keycapBorder, Math.max(1, Style.normalBorderWidth))

    Text {
      id: keycapText
      anchors.centerIn: parent
      text: root.label
      color: root.hintColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
