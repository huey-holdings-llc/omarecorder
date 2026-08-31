import QtQuick
import qs.Commons
import qs.Ui

// One recording in a list. Pure view: emits signals, owns no state.
CursorSurface {
  id: root
  property var rec: ({})
  property var svc: null               // the Service singleton; every derived string comes from it
  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool showActions: true
  property color urgent: Color.urgent

  // Derived from rec + svc so the two lists (popup, Library) do not repeat the wiring.
  readonly property var job: svc && rec ? svc.jobFor(rec.id) : null
  readonly property string displayTitle: svc ? svc.displayTitle(rec) : ""
  readonly property bool live: !!(svc && rec && rec.id === svc.activeId)
  readonly property string elapsedText: svc ? svc.elapsedText : ""
  readonly property string jobElapsedText: svc && job ? svc.jobProgressText(job) + svc.fmtHms(svc.jobElapsed(job)) : ""
  readonly property bool clipped: !!(svc && svc.isClipped(rec))
  readonly property string durationText: svc && rec ? svc.fmtDuration(rec.duration_s) : ""
  readonly property string dateText: svc && rec ? svc.fmtDate(rec.created) : ""

  signal clicked()
  signal transcribeRequested()
  signal openRequested()

  readonly property bool transcribed: !!(rec && rec.has_transcript)
  readonly property bool untitled: !(rec && rec.title)   // title already carries the date
  readonly property bool working: job !== null
  readonly property bool partial: !!(rec && rec.transcript && rec.transcript.partial)
  readonly property string statusGlyph: live ? "󰑊" : working ? "󰔟" : (transcribed ? (partial ? "󰄮" : "󰄬") : "󰍬")
  readonly property color statusColor: live ? urgent : working ? accent : (transcribed ? foreground : dimColor)
  readonly property string titleText: displayTitle ? displayTitle : (rec && rec.title ? rec.title : (rec && rec.id ? rec.id : ""))
  readonly property string subtitleText: live
    ? "Recording… " + elapsedText
    : working ? "Transcribing " + (jobElapsedText ? jobElapsedText + " · " : "") + job.model
    : ((untitled ? "" : dateText) + (durationText ? (untitled ? "" : " · ") + durationText : "") + (clipped ? " · ⚠ clipped" : "") + (partial ? " · partial transcript" : ""))

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
      AccessibleActionButton {
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
