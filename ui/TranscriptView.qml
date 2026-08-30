import QtQuick
import QtQuick.Controls
import qs.Commons

// Scrollable, selectable, read-only transcript body.
Flickable {
  id: root
  property string text: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body

  clip: true
  contentWidth: width
  contentHeight: body.implicitHeight + Style.spacing.md
  boundsBehavior: Flickable.StopAtBounds
  flickableDirection: Flickable.VerticalFlick
  ScrollBar.vertical: ThinScrollBar { id: bar; foreground: root.foreground }

  TextEdit {
    id: body
    width: root.width - bar.width - Style.spacing.sm   // text never runs under the bar
    text: root.text
    readOnly: true
    selectByMouse: true
    wrapMode: TextEdit.Wrap
    color: root.foreground
    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
    selectedTextColor: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    textFormat: TextEdit.PlainText
  }
}
