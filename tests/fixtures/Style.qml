// Fixture for lint's kit-token parser (style_tokens in tests/lint.sh). The
// real input is the Omarchy shell's Commons/Style.qml, which CI does not have.
// Expected tokens: font.body font.caption spacing.nested spacing.sm spacing.xs
import QtQuick

QtObject {
  id: root
  property int cornerRadius: 0
  readonly property QtObject spacing: QtObject {
    readonly property int xs: 3
    // readonly property int commented: 9
    readonly property var nested: ({ a: { b: 1 } })
    readonly property int sm: 4
  }
  readonly property QtObject font: QtObject { readonly property int caption: 12
    readonly property int body: 14 }
  property int after: 1
}
