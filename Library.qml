import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "ui"

// Omarecorder Library — fullscreen overlay: every recording on the left,
// the selected one on the right with its transcript. Summoned with
//   omarchy-shell shell toggle io.github.coreytyhurst.omarecorder
// Uses the [menu] surface tokens like the clipboard manager so themes apply.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var service: null
  readonly property var svc: service

  property bool opened: false
  property string filterText: ""
  property string selectedId: ""
  property bool deleteConfirmOpen: false
  property string chosenModel: ""
  property string playingId: ""
  property string transcriptText: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(1000), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)
  property int listWidth: Style.space(330)

  readonly property var rows: filteredRows()
  readonly property int selectedIndex: indexOfId(selectedId)
  readonly property var selected: selectedIndex >= 0 ? rows[selectedIndex] : null
  readonly property var selectedJob: svc && selected ? svc.jobFor(selected.id) : null
  readonly property string modelForRun: chosenModel || (svc ? svc.defaultModel : "base.en")

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.deleteConfirmOpen = false
    try { var p = JSON.parse(payloadJson || "{}"); if (p && p.id) root.selectedId = String(p.id) } catch (e) {}
    if (svc) { svc.refresh(); if (!svc.recording) {} }
    ensureSelection()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.deleteConfirmOpen = false; root.opened = false; if (playingId && svc) { svc.stopPlay(); playingId = "" } }
  function toggle() { root.opened ? root.close() : root.open("{}") }

  function filteredRows() {
    var all = svc ? svc.recordings : []
    var q = filterText.trim().toLowerCase()
    if (!q) return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      var r = all[i]
      var hay = ((r.title || "") + " " + (r.id || "") + " " + (r.created || "")).toLowerCase()
      if (hay.indexOf(q) !== -1) out.push(r)
    }
    return out
  }
  function indexOfId(id) { for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return i; return -1 }
  function ensureSelection() { if (selectedIndex < 0 && rows.length > 0) selectedId = rows[0].id }
  function select(delta) {
    if (rows.length === 0) return
    var i = selectedIndex < 0 ? (delta < 0 ? rows.length - 1 : 0) : (selectedIndex + delta + rows.length) % rows.length
    selectedId = rows[i].id
    list.positionViewAtIndex(i, ListView.Contain)
  }
  function selectAbsolute(i) { if (rows.length === 0) return; i = Math.max(0, Math.min(i, rows.length - 1)); selectedId = rows[i].id; list.positionViewAtIndex(i, ListView.Contain) }
  function setFilter(t) { filterText = t; Qt.callLater(ensureSelection) }

  function transcribeSelected() {
    if (!svc || !selected) return
    if (selectedJob) { svc.cancel(selected.id); return }
    var m = svc.modelByName(modelForRun)
    if (m && !m.installed) { svc.download(m.name); return }
    svc.transcribe(selected.id, modelForRun, svc.config.language || "en")
  }
  function togglePlay() {
    if (!svc || !selected) return
    if (playingId === selected.id) { svc.stopPlay(); playingId = "" } else { svc.play(selected.id); playingId = selected.id }
  }
  function requestDelete() { if (selected) { deleteConfirm.selectedIndex = 1; deleteConfirmOpen = true } }
  function confirmDelete() {
    if (svc && selected) { var i = selectedIndex; svc.remove(selected.id); deleteConfirmOpen = false; Qt.callLater(function() { selectAbsolute(Math.max(0, i - 1)) }) }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function cancelDelete() { deleteConfirmOpen = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  function stripHeader(t) { return String(t || "").replace(/^<!--[^\n]*-->\n?/, "") }

  onRowsChanged: ensureSelection()
  onSelectedChanged: if (!selected || !selected.transcript_path) transcriptText = ""

  FileView {
    id: transcriptFile
    path: root.selected && root.selected.transcript_path ? root.selected.transcript_path : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.transcriptText = root.stripHeader(text())
    onLoadFailed: root.transcriptText = ""
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarecorder-library"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) { if (deleteConfirm.handleKey(event)) event.accepted = true; return }
          if (titleField.activeFocus) return
          if (event.key === Qt.Key_Escape) { if (root.filterText) root.setFilter(""); else root.close(); event.accepted = true }
          else if (Util.editsFilter(event, root.filterText)) { root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true }
          else if (event.key === Qt.Key_Up) { root.select(-1); event.accepted = true }
          else if (event.key === Qt.Key_Down) { root.select(1); event.accepted = true }
          else if (event.key === Qt.Key_PageUp) { root.select(-6); event.accepted = true }
          else if (event.key === Qt.Key_PageDown) { root.select(6); event.accepted = true }
          else if (event.key === Qt.Key_Home) { root.selectAbsolute(0); event.accepted = true }
          else if (event.key === Qt.Key_End) { root.selectAbsolute(root.rows.length - 1); event.accepted = true }
          else if (event.key === Qt.Key_Delete) { root.requestDelete(); event.accepted = true }
          else if (event.key === Qt.Key_F2) { titleField.forceActiveFocus(); titleField.selectAll(); event.accepted = true }
          else if (event.key === Qt.Key_Space) { root.togglePlay(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.selected && root.selected.has_transcript && !(event.modifiers & Qt.ShiftModifier)) root.svc.openTranscript(root.selected.id)
            else root.transcribeSelected()
            event.accepted = true
          }
          else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text); event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm
          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: root.selected ? "Move \"" + (root.selected.title || root.selected.id) + "\" to trash?" : ""
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }

        Column {
          anchors.fill: parent
          spacing: Style.spacing.md

          // ---- header ----
          Row {
            width: parent.width
            spacing: Style.spacing.md
            Text {
              text: "󰑊  Omarecorder"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText ? "Search: " + root.filterText + "  (Esc clears)" : "Type to search"
              color: root.filterText ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item { width: parent.width - hints.width - Style.space(220) - parent.spacing * 3; height: 1 }
            Text {
              id: hints
              anchors.verticalCenter: parent.verticalCenter
              text: "↑↓ select · Enter transcribe/open · Space play · F2 rename · Del delete · Esc close"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Row {
            width: parent.width
            height: parent.height - y
            spacing: Style.spacing.lg

            // ---- list ----
            Item {
              width: root.listWidth
              height: parent.height
              ListView {
                id: list
                anchors.fill: parent
                clip: true
                model: root.rows
                spacing: Style.spacing.xxs
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                delegate: RecordingRow {
                  required property var modelData
                  required property int index
                  width: list.width - Style.spacing.sm
                  rec: modelData
                  job: root.svc ? root.svc.jobFor(modelData.id) : null
                  showActions: false
                  foreground: root.foreground
                  dimColor: root.dim
                  fontFamily: root.fontFamily
                  current: index === root.selectedIndex
                  currentFill: root.selectedBackground
                  durationText: root.svc ? root.svc.fmtDuration(modelData.duration_s) : ""
                  dateText: root.svc ? root.svc.fmtDate(modelData.created) : ""
                  onClicked: root.selectAbsolute(index)
                }
              }
              Text {
                anchors.centerIn: parent
                visible: root.rows.length === 0
                text: root.filterText ? "No matches." : "No recordings yet.\nStart one from the bar icon."
                color: root.dim
                horizontalAlignment: Text.AlignHCenter
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // ---- detail ----
            Column {
              id: detail
              width: parent.width - root.listWidth - parent.spacing
              height: parent.height
              spacing: Style.spacing.sm
              visible: root.selected !== null

              TextField {
                id: titleField
                width: parent.width
                text: root.selected ? (root.selected.title || "") : ""
                placeholderText: root.selected ? root.selected.id + "  (untitled — type a name, Enter to save)" : ""
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                onAccepted: { if (root.svc && root.selected && text !== (root.selected.title || "")) root.svc.rename(root.selected.id, text); keyCatcher.forceActiveFocus() }
                Keys.onEscapePressed: { text = root.selected ? (root.selected.title || "") : ""; keyCatcher.forceActiveFocus() }
              }

              Text {
                width: parent.width
                text: root.selected && root.svc
                  ? root.svc.fmtDate(root.selected.created) + " · " + root.svc.fmtDuration(root.selected.duration_s) + " · " + root.svc.fmtBytes(root.selected.size_bytes)
                    + " · " + root.selected.source
                    + (root.selected.transcript ? " · transcribed with " + root.selected.transcript.model : "")
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              // ---- actions ----
              Row {
                width: parent.width
                spacing: Style.spacing.sm
                ModelPicker {
                  id: picker
                  width: Style.space(360)
                  anchors.verticalCenter: parent.verticalCenter
                  svc: root.svc
                  durationS: root.selected ? root.selected.duration_s : 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: !root.selectedJob
                  onChanged: function(m) { root.chosenModel = m }
                }
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.selectedJob ? "Cancel  (" + root.svc.fmtHms(root.selectedJob.elapsed_s || 0) + ")"
                    : (picker.currentInstalled ? (root.selected && root.selected.has_transcript ? "Transcribe again" : "Transcribe")
                                               : (picker.download ? "Downloading…" : "Download model"))
                  iconText: root.selectedJob ? "󰅖" : (picker.currentInstalled ? "󰗊" : "󰇚")
                  active: !!root.selectedJob
                  iconSpinning: !!root.selectedJob || !!picker.download
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !picker.download
                  onClicked: root.transcribeSelected()
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.playingId === (root.selected ? root.selected.id : "") ? "󰓛" : "󰐊"
                  tooltipText: "Play / stop (Space)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.togglePlay()
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰈙"
                  tooltipText: "Open transcript in editor"
                  enabled: !!(root.selected && root.selected.has_transcript)
                  opacity: enabled ? 1 : 0.4
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.svc.openTranscript(root.selected.id)
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰆏"
                  tooltipText: "Copy transcript"
                  enabled: !!(root.selected && root.selected.has_transcript)
                  opacity: enabled ? 1 : 0.4
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.svc.copyTranscript(root.selected.id)
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰉋"
                  tooltipText: "Open folder"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.svc.openFolder(root.selected.id)
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰆴"
                  tooltipText: "Delete (Del)"
                  hoverColor: root.urgent
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.requestDelete()
                }
              }

              Text {
                visible: !!root.selectedJob
                width: parent.width
                text: root.selectedJob && root.svc
                  ? "Transcribing with " + root.selectedJob.model + " — " + root.svc.fmtHms(root.selectedJob.elapsed_s || 0)
                    + " elapsed, ≈ " + root.svc.fmtDuration(root.svc.estimateSeconds(root.selected.duration_s, root.selectedJob.model)) + " expected"
                  : ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }

              TranscriptView {
                width: parent.width
                height: detail.height - y
                visible: root.transcriptText.length > 0
                text: root.transcriptText
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                visible: root.transcriptText.length === 0
                width: parent.width
                text: root.selectedJob ? "Transcribing…" : "Not transcribed yet — pick a model above and press Transcribe (or Enter)."
                color: root.dim
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Text {
              visible: root.selected === null && root.rows.length > 0
              text: "Select a recording."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }
      }
    }
  }
}
