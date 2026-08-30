import QtQuick
import qs.Commons

// Waveform strip with a playback scrubber; in trim mode two draggable handles
// pick a range. Pure view: emits seekRequested / rangeChanged, owns no state.
Item {
  id: root
  property var rec: null                 // {waveform, size_bytes, duration_s}
  property real position: 0              // seconds
  property real duration: rec && rec.duration_s ? rec.duration_s : 0
  property bool trimMode: false
  property real trimFrom: 0
  property real trimTo: duration
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal seekRequested(real seconds)
  signal rangeChanged(real from, real to)

  implicitHeight: Style.space(72)
  readonly property real pxPerSecond: duration > 0 ? width / duration : 0
  function clampT(t) { return Math.max(0, Math.min(duration, t)) }
  function fmt(s) { s = Math.max(0, Math.floor(s || 0)); var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return (h > 0 ? h + ":" : "") + (m < 10 ? "0" : "") + m + ":" + (x < 10 ? "0" : "") + x }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius / 2
    color: Util.alpha(root.foreground, 0.06)
    clip: true

    // The CLI regenerates waveform.png after every trim; size_bytes changes with it,
    // so the query string defeats Qt's image cache.
    Image {
      anchors.fill: parent
      source: root.rec && root.rec.waveform ? "file://" + root.rec.waveform + "?" + (root.rec.size_bytes || 0) : ""
      fillMode: Image.Stretch
      cache: false
      smooth: true
      asynchronous: true
    }

    // played region (scrub mode)
    Rectangle {
      visible: !root.trimMode && root.duration > 0
      x: 0; y: 0; height: parent.height
      width: Math.min(parent.width, root.position * root.pxPerSecond)
      color: Util.alpha(root.accent, 0.22)
    }
    Rectangle {
      visible: !root.trimMode && root.duration > 0
      x: Math.min(parent.width - width, root.position * root.pxPerSecond); y: 0
      width: Math.max(2, Style.space(2)); height: parent.height
      color: root.accent
    }

    // trim mode: dim what will be cut, two handles
    Rectangle { visible: root.trimMode; x: 0; y: 0; height: parent.height; width: root.trimFrom * root.pxPerSecond; color: Util.alpha("#000000", 0.55) }
    Rectangle { visible: root.trimMode; x: root.trimTo * root.pxPerSecond; y: 0; height: parent.height; width: parent.width - x; color: Util.alpha("#000000", 0.55) }
    Rectangle {
      id: fromHandle
      visible: root.trimMode
      x: root.trimFrom * root.pxPerSecond - width / 2; y: 0
      width: Style.space(8); height: parent.height
      radius: 2; color: root.accent
      MouseArea {
        anchors.fill: parent; anchors.margins: -Style.space(6)
        cursorShape: Qt.SizeHorCursor
        drag.target: fromHandle; drag.axis: Drag.XAxis; drag.minimumX: -fromHandle.width / 2; drag.maximumX: toHandle.x - fromHandle.width
        onPositionChanged: if (drag.active) { root.trimFrom = root.clampT((fromHandle.x + fromHandle.width / 2) / root.pxPerSecond) }
        onReleased: root.rangeChanged(root.trimFrom, root.trimTo)
      }
    }
    Rectangle {
      id: toHandle
      visible: root.trimMode
      x: root.trimTo * root.pxPerSecond - width / 2; y: 0
      width: Style.space(8); height: parent.height
      radius: 2; color: root.accent
      MouseArea {
        anchors.fill: parent; anchors.margins: -Style.space(6)
        cursorShape: Qt.SizeHorCursor
        drag.target: toHandle; drag.axis: Drag.XAxis; drag.minimumX: fromHandle.x + fromHandle.width; drag.maximumX: root.width - toHandle.width / 2
        onPositionChanged: if (drag.active) { root.trimTo = root.clampT((toHandle.x + toHandle.width / 2) / root.pxPerSecond) }
        onReleased: root.rangeChanged(root.trimFrom, root.trimTo)
      }
    }

    // click to seek (scrub mode only; the handles take the clicks in trim mode)
    MouseArea {
      anchors.fill: parent
      z: -1
      enabled: !root.trimMode && root.duration > 0
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { root.seekRequested(root.clampT(mouse.x / root.pxPerSecond)) }
    }

    // time labels
    Text {
      anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: Style.spacing.xxs
      text: root.trimMode ? root.fmt(root.trimFrom) : root.fmt(root.position)
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      style: Text.Outline; styleColor: Util.alpha("#000000", 0.6)
    }
    Text {
      anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: Style.spacing.xxs
      text: root.trimMode ? root.fmt(root.trimTo) : root.fmt(root.duration)
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      style: Text.Outline; styleColor: Util.alpha("#000000", 0.6)
    }
  }
}
