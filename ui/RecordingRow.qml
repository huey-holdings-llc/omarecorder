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
  property string displayTitle: ""     // friendly title from Service.displayTitle
  property bool live: false            // this recording is in progress right now
  property string elapsedText: ""      // live elapsed, HH:MM:SS
  property string jobElapsedText: ""   // elapsed of this row's transcription job
  property bool clipped: false
  property color urgent: Color.urgent

  signal clicked()
  signal transcribeRequested()
  signal openRequested()

  readonly property bool transcribed: !!(rec && rec.has_transcript)
  readonly property bool untitled: !(rec && rec.title)   // title already carries the date
  readonly property bool working: job !== null
  readonly property string statusGlyph: live ? "󰑊" : working ? "󰔟" : (transcribed ? "󰄬" : "󰍬")
  readonly property color statusColor: live ? urgent : working ? accent : (transcribed ? foreground : dimColor)
  readonly property string titleText: displayTitle ? displayTitle : (rec && rec.title ? rec.title : (rec && rec.id ? rec.id : ""))
  readonly property string subtitleText: live
    ? "Recording… " + elapsedText
    : working ? "Transcribing " + (jobElapsedText ? jobElapsedText + " · " : "") + job.model
    : ((untitled ? "" : dateText) + (durationText ? (untitled ? "" : " · ") + durationText : "") + (clipped ? " · ⚠ clipped" : ""))

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
      width: parent.width - Style.space(18) - (actions.visible ? actions.width + parent.spacing : 0) - parent.spacing
      spacing: 1
      Text {
        width: parent.width
        text: root.titleText
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: root.subtitleText
        textFormat: Text.PlainText
        color: root.live ? root.urgent : root.dimColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs
      visible: root.showActions && !root.live && !root.working
      // The primary action is a word, not a glyph: "Transcribe" for a fresh
      // take, "Open" once a transcript exists (re-run stays behind an icon).
      Button {
        text: root.transcribed ? "Open" : "Transcribe"
        iconText: root.transcribed ? "󰈙" : "󰗊"
        fontSize: Style.font.caption
        iconSize: Style.font.iconSmall
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        tooltipText: root.transcribed ? "Open the transcript in your editor" : "Transcribe with the default model"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transcribed ? root.openRequested() : root.transcribeRequested()
      }
      PanelActionButton {
        visible: root.transcribed
        iconText: "󰑐"
        tooltipText: "Transcribe again"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transcribeRequested()
      }
    }
  }
}
