import QtQuick
import qs.Ui

// PanelActionButton renders only a glyph, so a screen reader has nothing to
// announce. The tooltip is the label; the trailing "(key)" hint is dropped.
PanelActionButton {
  Accessible.role: Accessible.Button
  Accessible.name: (tooltipText || "").replace(/\s*\([^)]*\)\s*$/, "")
}
