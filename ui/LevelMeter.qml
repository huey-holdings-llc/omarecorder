import QtQuick
import qs.Commons

// Live input level while recording: a slim bar (−60 dBFS … 0) that turns
// urgent and says CLIP while the input sits on the rails. Fed by
// $XDG_RUNTIME_DIR/omarecorder/level, which the CLI's meter writes ≤ 4×/s.
Item {
  id: root
  property real peakDb: -99          // dBFS, ≤ 0
  property bool clip: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  readonly property real fill: Math.max(0, Math.min(1, (peakDb + 60) / 60))
  readonly property bool hot: peakDb > -6 && !clip   // near the rails, not there yet

  implicitHeight: Style.space(14)
  implicitWidth: Style.space(200)

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: label.left
    anchors.rightMargin: Style.spacing.sm
    anchors.verticalCenter: parent.verticalCenter
    height: Style.space(6)
    radius: height / 2
    color: Util.alpha(root.foreground, 0.15)
    Rectangle {
      height: parent.height
      radius: parent.radius
      width: parent.width * root.fill
      color: root.clip ? root.urgent : (root.hot ? Qt.lighter(root.urgent, 1.4) : Color.accent)
      Behavior on width { NumberAnimation { duration: 120 } }
    }
  }
  Text {
    id: label
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(44)
    horizontalAlignment: Text.AlignRight
    text: root.clip ? "CLIP" : (root.peakDb <= -90 ? "" : Math.round(root.peakDb) + " dB")
    color: root.clip ? root.urgent : Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: root.clip
    textFormat: Text.PlainText
  }
}
