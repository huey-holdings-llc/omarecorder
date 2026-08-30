import QtQuick
import QtQuick.Controls
import qs.Commons

// A slim, theme-coloured scrollbar. The default Qt one is nearly invisible on a
// dark theme. Light, but readable: 35 percent of the foreground, 60 percent
// while hovered or dragged. Callers inset their content by `width` so the bar
// never covers text.
ScrollBar {
  id: root
  property color foreground: Color.foreground

  policy: ScrollBar.AsNeeded
  visible: size < 1        // nothing to scroll, nothing to show (AsNeeded alone left a full-height bar)
  implicitWidth: Style.space(8)
  padding: Style.space(1)
  minimumSize: 0.08

  background: Rectangle {
    radius: width / 2
    color: Util.alpha(root.foreground, 0.08)
    visible: root.size < 1
  }
  contentItem: Rectangle {
    implicitWidth: Style.space(6)
    radius: width / 2
    color: Util.alpha(root.foreground, root.pressed ? 0.7 : (root.hovered ? 0.55 : 0.35))
    Behavior on color { ColorAnimation { duration: 120 } }
  }
}
