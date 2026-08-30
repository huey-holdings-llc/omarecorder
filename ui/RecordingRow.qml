import QtQuick
import qs.Commons
import qs.Ui

// One recording in a list. Pure view: emits signals, owns no state.
CursorSurface {
  id: root
  property var rec: ({})
  property var job: null              // active transcribe job for this rec, or null
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool showActions: true
  property string durationText: ""
  property string dateText: ""

  signal clicked()
  signal transcribeRequested()
  signal openRequested()

  readonly property bool transcribed: !!(rec && rec.has_transcript)
  readonly property bool working: job !== null
  readonly property string statusGlyph: working ? "󰔟" : (transcribed ? "󰄬" : "󰑊")
  readonly property color statusColor: working ? accent : (transcribed ? foreground : dimColor)
  readonly property string titleText: rec && rec.title ? rec.title : (rec && rec.id ? rec.id : "")

  width: parent ? parent.width : Style.space(300)
  height: Math.max(Style.space(40), col.implicitHeight + Style.spacing.rowPaddingX)
  fill: Style.hoverFillFor(foreground, accent)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
    onEntered: root.hasCursor = true
    onExited: root.hasCursor = false
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.sm
    spacing: Style.spacing.sm

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      text: root.statusGlyph
      color: root.statusColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      horizontalAlignment: Text.AlignHCenter
    }

    Column {
      id: col
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(18) - actions.width - parent.spacing * 2
      spacing: 1
      Text {
        width: parent.width
        text: root.titleText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: root.working
          ? "Transcribing with " + root.job.model + "…"
          : (root.dateText + (root.durationText ? " · " + root.durationText : "") + (root.transcribed ? " · " + root.rec.transcript.model : ""))
        color: root.dimColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
      visible: root.showActions
      PanelActionButton {
        visible: root.transcribed
        iconText: "󰈙"
        tooltipText: "Open transcript"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.openRequested()
      }
      PanelActionButton {
        visible: !root.working
        iconText: root.transcribed ? "󰑐" : "󰗊"
        tooltipText: root.transcribed ? "Transcribe again" : "Transcribe"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transcribeRequested()
      }
    }
  }
}
