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

  implicitHeight: Style.space(72) + badgeRoom
  readonly property real pxPerSecond: duration > 0 ? width / duration : 0
  function clampT(t) { return Math.max(0, Math.min(duration, t)) }
  function fmt(s) { s = Math.max(0, Math.floor(s || 0)); var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return (h > 0 ? h + ":" : "") + (m < 10 ? "0" : "") + m + ":" + (x < 10 ? "0" : "") + x }

  // Room above the strip for the trim badges (they sit outside the clipped area).
  readonly property real badgeRoom: root.trimMode ? Style.space(18) : 0
  Rectangle {
    anchors.fill: parent
    anchors.topMargin: root.badgeRoom
    radius: Style.cornerRadius / 2
    color: Util.alpha(root.foreground, 0.06)
    clip: false

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
    Rectangle {   // playhead (both modes; [ ] mark from it in trim mode)
      visible: root.duration > 0
      x: Math.min(parent.width - width, root.position * root.pxPerSecond); y: 0
      width: Math.max(2, Style.space(2)); height: parent.height
      color: root.trimMode ? root.foreground : root.accent
      z: 2
    }

    // trim mode: what is cut goes dark, what is kept gets the accent tint, and the
    // two handles stay inside the strip (clamped) with a time badge each.
    readonly property real hw: Style.space(10)
    Rectangle { visible: root.trimMode; x: 0; y: 0; height: parent.height; width: root.trimFrom * root.pxPerSecond; color: Util.alpha("#000000", 0.65) }
    Rectangle { visible: root.trimMode; x: root.trimTo * root.pxPerSecond; y: 0; height: parent.height; width: Math.max(0, parent.width - x); color: Util.alpha("#000000", 0.65) }
    Rectangle {
      visible: root.trimMode; y: 0; height: parent.height
      x: root.trimFrom * root.pxPerSecond; width: Math.max(0, (root.trimTo - root.trimFrom) * root.pxPerSecond)
      color: Util.alpha(root.accent, 0.12)
      border.color: Util.alpha(root.accent, 0.6); border.width: 1
    }
    Rectangle {
      id: fromHandle
      visible: root.trimMode
      x: Math.max(0, Math.min(parent.width - parent.hw, root.trimFrom * root.pxPerSecond - parent.hw / 2)); y: 0
      width: parent.hw; height: parent.height
      radius: 3; color: root.accent; z: 3
      Text { anchors.centerIn: parent; text: "‖"; color: "#000000"; font.pixelSize: Style.font.caption; font.bold: true }
      Rectangle {   // time badge
        anchors.bottom: parent.top; anchors.bottomMargin: 2; anchors.left: parent.left
        width: fromBadge.implicitWidth + Style.spacing.xs * 2; height: fromBadge.implicitHeight + 2
        radius: 3; color: root.accent
        Text { id: fromBadge; anchors.centerIn: parent; text: "start " + root.fmt(root.trimFrom); color: "#000000"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
      }
      MouseArea {
        anchors.fill: parent; anchors.margins: -Style.space(6)
        cursorShape: Qt.SizeHorCursor
        drag.target: fromHandle; drag.axis: Drag.XAxis; drag.minimumX: 0; drag.maximumX: toHandle.x - fromHandle.width
        onPositionChanged: if (drag.active) { root.trimFrom = root.clampT((fromHandle.x + fromHandle.width / 2) / root.pxPerSecond) }
        onReleased: root.rangeChanged(root.trimFrom, root.trimTo)
      }
    }
    Rectangle {
      id: toHandle
      visible: root.trimMode
      x: Math.max(0, Math.min(parent.width - parent.hw, root.trimTo * root.pxPerSecond - parent.hw / 2)); y: 0
      width: parent.hw; height: parent.height
      radius: 3; color: root.accent; z: 3
      Text { anchors.centerIn: parent; text: "‖"; color: "#000000"; font.pixelSize: Style.font.caption; font.bold: true }
      Rectangle {   // time badge
        anchors.bottom: parent.top; anchors.bottomMargin: 2; anchors.right: parent.right
        width: toBadge.implicitWidth + Style.spacing.xs * 2; height: toBadge.implicitHeight + 2
        radius: 3; color: root.accent
        Text { id: toBadge; anchors.centerIn: parent; text: "end " + root.fmt(root.trimTo); color: "#000000"; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
      }
      MouseArea {
        anchors.fill: parent; anchors.margins: -Style.space(6)
        cursorShape: Qt.SizeHorCursor
        drag.target: toHandle; drag.axis: Drag.XAxis; drag.minimumX: fromHandle.x + fromHandle.width; drag.maximumX: root.width - toHandle.width
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
      visible: !root.trimMode   // the badges carry the times in trim mode
      text: root.trimMode ? root.fmt(root.trimFrom) : root.fmt(root.position)
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      style: Text.Outline; styleColor: Util.alpha("#000000", 0.6)
    }
    Text {
      anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: Style.spacing.xxs
      visible: !root.trimMode
      text: root.trimMode ? root.fmt(root.trimTo) : root.fmt(root.duration)
      color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      style: Text.Outline; styleColor: Util.alpha("#000000", 0.6)
    }
  }
}
