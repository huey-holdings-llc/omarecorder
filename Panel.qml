import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ui"

// Omarecorder bar widget: glyph + elapsed timer in the bar, and a popup with
// record/stop, source, the most recent recordings, and settings.
// All state comes from Service.qml (shared across monitors); this file is a view.
Panel {
  id: root
  moduleName: "io.github.coreytyhurst.omarecorder"
  ipcTarget: "io.github.coreytyhurst.omarecorder"
  manageIpc: false

  readonly property var svc: bar && bar.shell && bar.shell.serviceFor ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: svc !== null
  readonly property bool recording: ready && svc.recording
  readonly property bool transcribing: ready && svc.transcribing

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int recentCount: Math.max(0, Math.min(10, parseInt(setting("recentCount", 5)) || 5))

  // Idle shows a microphone (what the button does), recording the red record
  // glyph plus the timer, transcribing an hourglass.
  readonly property string barGlyph: recording ? "󰑊" : (transcribing ? "󰔟" : "󰍬")
  // While the input clips the bar says so instead of the timer (the glyph is already urgent-coloured).
  readonly property string barLabel: recording && !vertical ? "  " + (svc.clipping ? "CLIP" : svc.elapsedText) : ""
  readonly property string stateText: !ready ? "Service unavailable"
    : recording ? "Recording " + svc.elapsedText + (svc.activeRecording ? " · " + svc.sourceLabel(svc.activeRecording.source) : "") + (svc.clipping ? " · ⚠ clipping" : "")
    : transcribing ? "Transcribing " + svc.jobProgressText(svc.activeJob) + svc.transcribeElapsedText + " · " + svc.activeJobTitle
    : (svc.downloading ? "Downloading model…" : "Idle")

  property bool settingsOpen: false
  property bool cursorActive: false
  property int cursorIndex: -1
  // The take being recorded is the hero's status line already; Recent lists the rest.
  readonly property var recent: ready ? svc.recordings.filter(function(r) { return r.id !== svc.activeId }).slice(0, recentCount) : []

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false; cursorIndex = -1
    if (panelFlick) panelFlick.contentY = 0
    if (ready) svc.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  // Settings live at the bottom of a capped popup: bring them into view.
  onSettingsOpenChanged: if (settingsOpen) Qt.callLater(function() {
    if (panelFlick) panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
  })

  function moveCursor(dy) {
    if (recent.length === 0) return
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(recent.length - 1, cursorIndex + dy))
  }
  function activateCursor() {
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= recent.length) return
    var r = recent[cursorIndex]
    if (r.id === svc.activeId) return
    if (r.has_transcript) svc.openTranscript(r.id); else svc.transcribe(r.id)
  }
  function toggleRecording() { if (ready) svc.toggleRecording() }
  // Import = a path field in the popup. (A QtQuick FileDialog crashes
  // Quickshell on Omarchy 4 — both in-shell and in its own process — so no
  // graphical picker until that is fixed upstream.)
  property bool importOpen: false
  function importAudio() { if (!ready) return; importOpen = !importOpen; if (importOpen) Qt.callLater(function() { importField.forceActiveFocus() }) }
  function openLibrary() { if (ready) { root.close(); svc.openLibrary() } }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function record(): string { root.toggleRecording(); return root.recording ? "stopping" : "starting" }
    function status(): string { return root.stateText }
    function library(): void { root.openLibrary() }
    function importAudio(): void { root.importAudio() }
  }

  // WidgetButton (not BarIconButton) so the bar slot grows with the timer
  // label instead of overflowing into neighbouring widgets.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph + root.barLabel
    active: root.recording
    fontSize: root.recording ? Style.font.bodySmall : Style.bar.iconFont
    tooltipText: root.stateText + (root.recording ? "\nRight-click to stop" : "\nRight-click to record")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleRecording()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (settingsSection.visible && settingsSection.activeFocus) || importField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.toggleRecording()
        else if (t === "l" || t === "L") root.openLibrary()
        else if (t === "s" || t === "S") root.settingsOpen = !root.settingsOpen
        else if (t === "i" || t === "I") root.importAudio()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ThinScrollBar { id: panelBar; foreground: root.foreground }

        Column {
          id: column
          width: panelFlick.width - (panelFlick.contentHeight > panelFlick.height ? panelBar.width + Style.spacing.xs : 0)
          spacing: Style.spacing.md

          PanelHero {
            id: hero
            // Inside iconComponent/trailingControl `root` resolves to the hero,
            // so panel state is exposed here under distinct names.
            readonly property bool rec: root.recording
            readonly property bool busy: root.transcribing
            readonly property color recColor: root.urgent
            width: parent.width
            title: "Omarecorder"
            meta: root.stateText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: hero.rec ? "󰑊" : (hero.busy ? "󰔟" : "󰍬")
                color: hero.rec ? hero.recColor : (hero.busy ? Color.accent : hero.foreground)
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          LevelMeter {
            visible: root.recording
            width: parent.width
            peakDb: root.ready ? root.svc.peakDb : -99
            clip: root.ready && root.svc.clipping
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.ready && root.svc.lastError.length > 0
            width: parent.width
            text: root.ready ? root.svc.lastError : ""
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          SetupCard {
            width: parent.width
            svc: root.svc
            foreground: root.foreground
            urgent: root.urgent
            fontFamily: root.fontFamily
          }

          Dropdown {
            visible: root.ready && !root.recording
            width: parent.width
            label: "Source"
            value: root.ready ? root.svc.defaultSource : "mic"
            // Say what each option captures: a mic on speakers hears the computer too.
            options: [
              { value: "mic", label: "Microphone (what the mic hears)" },
              { value: "system", label: "System audio (what the computer plays)" },
              { value: "both", label: "Mic + system audio (two tracks, mixed)" }
            ]
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.svc.setConfig("defaultSource", v) }
          }

          Button {
            width: parent.width
            text: root.recording ? "Stop recording  (r)" : "Start recording  (r)"
            iconText: root.recording ? "󰓛" : "󰑊"
            active: root.recording
            foreground: root.recording ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            enabled: root.ready
            onClicked: root.toggleRecording()
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader { text: "RECENT"; foreground: root.foreground; fontFamily: root.fontFamily }

          Text {
            visible: root.recent.length === 0
            width: parent.width
            text: root.ready ? "No recordings yet." : "Service not loaded."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Column {
            id: recentColumn
            width: parent.width
            spacing: Style.spacing.xxs
            Repeater {
              model: root.recent
              delegate: RecordingRow {
                required property var modelData
                required property int index
                width: recentColumn.width
                rec: modelData
                svc: root.svc
                foreground: root.foreground
                dimColor: root.dim
                fontFamily: root.fontFamily
                current: root.cursorActive && root.cursorIndex === index
                urgent: root.urgent
                onClicked: { root.cursorActive = true; root.cursorIndex = index; root.openLibrary() }
                onTranscribeRequested: root.svc.transcribe(modelData.id)
                onOpenRequested: root.svc.openTranscript(modelData.id)
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            Button {
              width: parent.width - gear.width - importButton.width - parent.spacing * 2
              text: "Open library  (l)"
              iconText: "󰈔"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: root.openLibrary()
            }
            PanelActionButton {
              id: importButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰋺"
              tooltipText: "Import an audio file (i)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: root.importAudio()
            }
            PanelActionButton {
              id: gear
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒓"
              tooltipText: "Settings (s)"
              foreground: root.settingsOpen ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.settingsOpen = !root.settingsOpen
            }
          }

          Column {
            visible: root.importOpen && root.ready
            width: parent.width
            spacing: Style.spacing.xxs
            Text { text: "Import an audio file (path, Enter)"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            TextField {
              id: importField
              width: parent.width
              placeholderText: "~/Downloads/meeting.m4a"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: { if (text.trim().length) { root.svc.importFile(text.trim()); text = ""; root.importOpen = false }; keyCatcher.forceActiveFocus() }
              Keys.onEscapePressed: { root.importOpen = false; keyCatcher.forceActiveFocus() }
            }
          }

          SettingsSection {
            id: settingsSection
            visible: root.settingsOpen && root.ready
            width: parent.width
            svc: root.svc
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }
}
