import QtQuick
import qs.Commons

// The key letter a control shows while Ctrl is held (the Library's hold-Ctrl
// hints). Text on the popup background with an accent edge: that pair clears
// 4.5:1 in every shipped theme, where an accent fill would not. Decoration
// only; each control's accessible name already carries its key.
Rectangle {
  id: root
  property string key: ""
  property bool shown: false
  property string fontFamily: Style.font.family
  property color foreground: Color.popups.text
  property color background: Color.popups.background

  visible: shown && key.length > 0
  // Sits on the parent's top-right corner, half outside it.
  x: parent ? parent.width - width * 0.7 : 0
  y: -height * 0.45
  z: 5
  width: Math.max(height, label.implicitWidth + Style.space(8))
  height: label.implicitHeight + Style.space(3)
  radius: Style.space(4)
  color: root.background
  border.color: Color.accent
  border.width: 1
  Accessible.ignored: true

  Text {
    id: label
    anchors.centerIn: parent
    text: root.key
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
