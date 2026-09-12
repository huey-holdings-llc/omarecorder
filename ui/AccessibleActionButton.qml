import QtQuick
import qs.Ui

// PanelActionButton renders only a glyph, so a screen reader has nothing to
// announce. The tooltip is the label; its trailing "(key)" becomes the
// description, so the shortcut is offered separately from the name.
PanelActionButton {
  Accessible.role: Accessible.Button
  Accessible.name: (tooltipText || "").replace(/\s*\([^)]*\)\s*$/, "")
  Accessible.description: { var m = (tooltipText || "").match(/\(([^)]*)\)\s*$/); return m ? m[1] : "" }
}
