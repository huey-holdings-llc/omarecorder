import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtMultimedia
import qs.Commons
import qs.Ui
import "ui"

// Omarecorder Library — fullscreen overlay: every recording on the left,
// the selected one on the right with its transcript. Summoned with
//   omarchy-shell shell toggle io.github.coreytyhurst.omarecorder
// Uses the theme's [popups] surface tokens (same chrome as the bar popup) so
// the overlay reads as part of the same plugin; list selection reuses the
// [menu] selection tokens.
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
  property string transcriptText: ""
  // playback (in-process, QtMultimedia) and trim mode
  property bool trimMode: false
  property real trimFrom: 0
  property real trimTo: 0
  property bool trimConfirmOpen: false
  property bool previewing: false
  readonly property var player: playerLoader.status === Loader.Ready ? playerLoader.item : null
  readonly property bool playing: !!(player && player.playbackState === MediaPlayer.PlayingState)
  readonly property real positionS: player ? player.position / 1000 : 0

  property color background: Color.popups.background
  property color foreground: Color.popups.text
  property color border: Color.popups.border
  property var borderSpec: Border.surfaceSpec("popups", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.family
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(1000), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(660), panel.height - Style.gapsOut * 2)
  property int listWidth: Style.space(300)

  readonly property var rows: filteredRows()
  readonly property int selectedIndex: indexOfId(selectedId)
  readonly property var selected: selectedIndex >= 0 ? rows[selectedIndex] : null
  readonly property var selectedJob: svc && selected ? svc.jobFor(selected.id) : null
  readonly property string modelForRun: chosenModel || (svc ? svc.defaultModel : "base.en")
  readonly property bool selectedLive: !!(svc && selected && selected.id === svc.activeId)

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.deleteConfirmOpen = false
    var requested = ""
    try { var p = JSON.parse(payloadJson || "{}"); if (p && p.id) requested = String(p.id) } catch (e) {}
    // Newest recording is selected unless the caller asked for a specific one.
    root.selectedId = requested || (rows.length > 0 ? rows[0].id : "")
    if (svc) svc.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.deleteConfirmOpen = false; root.trimConfirmOpen = false; root.trimMode = false; root.opened = false; if (player) player.stop() }
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
  readonly property string hintsText: root.trimMode
    ? "Space play   ←→ seek   [ ] mark start / end at the playhead   Esc leave trim mode"
    : "↑↓ select   Enter transcribe / open   Space play   ←→ seek   F2 rename   F3 trim   Del delete   Esc close"
  function select(delta) {
    if (rows.length === 0) return
    var i = selectedIndex < 0 ? (delta < 0 ? rows.length - 1 : 0) : (selectedIndex + delta + rows.length) % rows.length
    selectedId = rows[i].id
    list.positionViewAtIndex(i, ListView.Contain)
  }
  function selectAbsolute(i) { if (rows.length === 0) return; i = Math.max(0, Math.min(i, rows.length - 1)); selectedId = rows[i].id; list.positionViewAtIndex(i, ListView.Contain) }
  function setFilter(t) { filterText = t; Qt.callLater(ensureSelection) }

  // Enter / the main button start a transcription. Cancelling a running job is
  // only reachable through the explicit Cancel button (cancelSelected) — a
  // stray Enter must never kill an hour-long job.
  function transcribeSelected() {
    if (!svc || !selected || selectedJob || selectedLive) return
    var m = svc.modelByName(modelForRun)
    if (m && !m.installed) { svc.download(m.name); return }
    svc.transcribe(selected.id, modelForRun, svc.config.language || "en")
  }
  function cancelSelected() { if (svc && selected && selectedJob) svc.cancel(selected.id) }
  function audioUrl(rec) { return rec && rec.audio ? "file://" + rec.audio : "" }
  function loadSelected() { if (player && selected && String(player.source) !== audioUrl(selected)) player.source = audioUrl(selected) }
  function togglePlay() {
    if (!player || !selected || selectedLive) return
    if (playing) { player.pause(); previewing = false } else { loadSelected(); player.play() }
  }
  function seekTo(seconds) {
    if (!player || !selected || selectedLive) return
    loadSelected(); player.position = Math.max(0, Math.round(seconds * 1000))
  }
  function startTrim() {
    if (!selected || selectedLive || selectedJob || !selected.waveform) return
    trimFrom = 0; trimTo = selected.duration_s || 0; trimMode = true
  }
  function previewRange() {
    if (!player) return
    if (previewing) { player.pause(); previewing = false; return }
    seekTo(trimFrom); previewing = true; player.play()
  }
  // [ and ] in trim mode: put the start / end where the playhead is.
  function markStart() { if (positionS < trimTo - 0.5) trimFrom = positionS }
  function markEnd() { if (positionS > trimFrom + 0.5) trimTo = positionS }
  function requestTrim() { if (trimMode && trimTo > trimFrom) { trimConfirm.selectedIndex = 0; trimConfirmOpen = true } }
  function confirmTrim() {
    if (svc && selected) { if (player) player.stop(); svc.trim(selected.id, trimFrom.toFixed(2), trimTo.toFixed(2)) }
    trimConfirmOpen = false; trimMode = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function cancelTrimConfirm() { trimConfirmOpen = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  function requestDelete() { if (selected && !selectedLive) { deleteConfirm.selectedIndex = 0; deleteConfirmOpen = true } }
  function confirmDelete() {
    if (svc && selected) { var i = selectedIndex; svc.remove(selected.id); deleteConfirmOpen = false; Qt.callLater(function() { selectAbsolute(Math.max(0, i - 1)) }) }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function cancelDelete() { deleteConfirmOpen = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
  function stripHeader(t) { return String(t || "").replace(/^<!--[^\n]*-->\n?/, "").trim() }

  onRowsChanged: ensureSelection()
  onSelectedChanged: {
    if (player) player.stop()
    trimMode = false; previewing = false
    if (!selected || !selected.transcript_path) transcriptText = ""
    // Re-transcribe defaults to the model that produced the visible transcript.
    var last = selected && selected.transcript && selected.transcript.model ? selected.transcript.model : ""
    var m = svc && last ? svc.modelByName(last) : null
    chosenModel = m ? last : ""
    picker.value = modelForRun
  }

  // The audio backend only exists while the Library is open.
  Loader {
    id: playerLoader
    active: root.opened
    sourceComponent: Component {
      MediaPlayer {
        audioOutput: AudioOutput {}
        onPositionChanged: if (root.previewing && position >= root.trimTo * 1000) { pause(); root.previewing = false }
        onPlaybackStateChanged: if (playbackState !== MediaPlayer.PlayingState) root.previewing = false
        onErrorOccurred: function(error, errorString) { if (root.svc) root.svc.lastError = "Playback: " + errorString }
      }
    }
  }

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
        // BorderSurface.padding is advisory: content insets itself.
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) { if (deleteConfirm.handleKey(event)) event.accepted = true; return }
          if (root.trimConfirmOpen) { if (trimConfirm.handleKey(event)) event.accepted = true; return }
          if (titleField.activeFocus) return
          if (event.key === Qt.Key_Escape) { if (root.trimMode) { root.trimMode = false; root.previewing = false } else if (root.filterText) root.setFilter(""); else root.close(); event.accepted = true }
          else if (Util.editsFilter(event, root.filterText)) { root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true }
          else if (event.key === Qt.Key_Up) { root.select(-1); event.accepted = true }
          else if (event.key === Qt.Key_Down) { root.select(1); event.accepted = true }
          else if (event.key === Qt.Key_PageUp) { root.select(-6); event.accepted = true }
          else if (event.key === Qt.Key_PageDown) { root.select(6); event.accepted = true }
          else if (event.key === Qt.Key_Home) { root.selectAbsolute(0); event.accepted = true }
          else if (event.key === Qt.Key_End) { root.selectAbsolute(root.rows.length - 1); event.accepted = true }
          else if (event.key === Qt.Key_Delete) { root.requestDelete(); event.accepted = true }
          else if (event.key === Qt.Key_Left && !root.filterText) { root.seekTo(root.positionS - 5); event.accepted = true }
          else if (event.key === Qt.Key_Right && !root.filterText) { root.seekTo(root.positionS + 5); event.accepted = true }
          else if (event.key === Qt.Key_F2) { titleField.forceActiveFocus(); titleField.selectAll(); event.accepted = true }
          else if (event.key === Qt.Key_F3) { if (root.trimMode) root.trimMode = false; else root.startTrim(); event.accepted = true }
          else if (root.trimMode && event.key === Qt.Key_BracketLeft) { root.markStart(); event.accepted = true }
          else if (root.trimMode && event.key === Qt.Key_BracketRight) { root.markEnd(); event.accepted = true }
          else if (event.key === Qt.Key_Space) { if (root.filterText) root.setFilter(root.filterText + " "); else root.togglePlay(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.svc && root.selected && root.selected.has_transcript && !(event.modifiers & Qt.ShiftModifier)) root.svc.openTranscript(root.selected.id)
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
          // The kit dialog renders AutoText: keep markup-looking characters out of the title.
          message: root.selected && root.svc ? "Move \"" + root.svc.displayTitle(root.selected).replace(/[<>]/g, "") + "\" to the trash?" : ""
          confirmText: "Move to trash"
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

        ConfirmDialog {
          id: trimConfirm
          anchors.fill: parent
          opened: root.trimConfirmOpen
          z: 10
          message: "Keep " + wave.fmt(root.trimFrom) + " – " + wave.fmt(root.trimTo) + " and cut the rest? The original stays as audio.orig.wav."
          confirmText: "Trim"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelTrimConfirm()
          onConfirmed: root.confirmTrim()
        }

        Column {
          anchors.fill: parent
          spacing: Style.spacing.md

          // ---- header: title + live search ----
          Row {
            width: parent.width
            spacing: Style.spacing.lg
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰑊  Omarecorder"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            BorderSurface {
              id: searchBox
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(320)
              height: Style.spacing.controlHeight
              radius: Style.cornerRadius
              color: "transparent"
              borderSpec: Border.controlSpec(root.filterText ? "focus" : "normal", root.foreground, Color.accent)
              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.sm
                Text { anchors.verticalCenter: parent.verticalCenter; text: "󰍉"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.icon }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.filterText ? root.filterText : "Type to search"
                  color: root.filterText ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.rows.length + (root.rows.length === 1 ? " recording" : " recordings") + (root.filterText ? " match" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          Row {
            width: parent.width
            height: parent.height - y - Style.space(28)
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
                ScrollBar.vertical: ThinScrollBar { id: listBar; foreground: root.foreground }
                delegate: RecordingRow {
                  required property var modelData
                  required property int index
                  width: list.width - listBar.width - Style.spacing.xs
                  rec: modelData
                  svc: root.svc
                  showActions: false
                  foreground: root.foreground
                  dimColor: root.dim
                  fontFamily: root.fontFamily
                  current: index === root.selectedIndex
                  currentFill: root.selectedBackground
                  urgent: root.urgent
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
                placeholderText: root.selected && root.svc ? root.svc.displayTitle(root.selected) : ""
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                onAccepted: { if (root.svc && root.selected && text !== (root.selected.title || "")) root.svc.rename(root.selected.id, text); keyCatcher.forceActiveFocus() }
                Keys.onEscapePressed: { text = root.selected ? (root.selected.title || "") : ""; keyCatcher.forceActiveFocus() }
              }

              Text {
                visible: titleField.activeFocus
                width: parent.width
                text: "Renaming: Enter saves, Esc cancels"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                text: root.selected && root.svc
                  ? (root.selectedLive ? "Recording now · " + root.svc.elapsedText + " · " + root.svc.sourceLabel(root.selected.source)
                    : root.svc.fmtDate(root.selected.created) + " · " + root.svc.fmtDuration(root.selected.duration_s) + " · " + root.svc.fmtBytes(root.selected.size_bytes)
                    + " · " + root.svc.sourceLabel(root.selected.source)
                    + (root.selected.transcript ? " · transcribed with " + root.selected.transcript.model : "")
                    + (root.selected.exported_to ? " · in Obsidian" : "")
                    + (root.svc.isClipped(root.selected) ? " · ⚠ clipped" : "")
                    + (root.svc.isPartial(root.selected) ? " · partial transcript" : "")
                    + (root.selected.trim ? " · trimmed" : "")
                    + (root.playing ? " · ▶ playing" : ""))
                  : ""
                textFormat: Text.PlainText
                color: root.selectedLive ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              LevelMeter {
                visible: root.selectedLive
                width: parent.width
                peakDb: root.svc ? root.svc.peakDb : -99
                clip: !!(root.svc && root.svc.clipping)
                foreground: root.foreground
                urgent: root.urgent
                fontFamily: root.fontFamily
              }

              // ---- actions ----
              Row {
                width: parent.width
                spacing: Style.spacing.sm
                ModelPicker {
                  id: picker
                  // Sized to its longest label; the main button and icon actions follow.
                  width: Math.min(picker.implicitWidth, parent.width - mainButton.width - iconActions.width - parent.spacing * 2)
                  anchors.verticalCenter: parent.verticalCenter
                  svc: root.svc
                  durationS: root.selected ? root.selected.duration_s : 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: !root.selectedJob && !root.selectedLive
                  onChanged: function(m) { root.chosenModel = m }
                }
                Button {
                  id: mainButton
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !root.selectedLive
                  text: root.selectedJob ? "Cancel"
                    : (picker.currentInstalled ? (root.selected && root.selected.has_transcript ? "Re-transcribe" : "Transcribe")
                                               : (picker.download ? "Downloading…" : "Download model"))
                  iconText: root.selectedJob ? "󰅖" : (picker.currentInstalled ? "󰗊" : "󰇚")
                  active: !!root.selectedJob
                  iconSpinning: !!root.selectedJob || !!picker.download
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !picker.download
                  onClicked: root.selectedJob ? root.cancelSelected() : root.transcribeSelected()
                }
                Row {
                  id: iconActions
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.playing ? "󰏤" : "󰐊"
                  tooltipText: "Play / pause (Space)"
                  enabled: !root.selectedLive
                  opacity: enabled ? 1 : 0.4
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.togglePlay()
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰆐"
                  tooltipText: "Trim (drag the handles on the waveform)"
                  enabled: !!(root.selected && root.selected.waveform && !root.selectedLive && !root.selectedJob)
                  opacity: enabled ? 1 : 0.4
                  foreground: root.trimMode ? Color.accent : root.foreground; fontFamily: root.fontFamily
                  onClicked: root.trimMode ? (root.trimMode = false) : root.startTrim()
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !!(root.selected && root.selected.has_orig)
                  iconText: "󰕌"
                  tooltipText: "Restore the untrimmed original"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) { if (root.player) root.player.stop(); root.svc.restoreTrim(root.selected.id) }
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰉋"
                  tooltipText: "Open folder"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.openFolder(root.selected.id)
                }
                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰆴"
                  tooltipText: "Move to trash (Del)"
                  enabled: !root.selectedLive
                  opacity: enabled ? 1 : 0.4
                  hoverColor: root.urgent
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.requestDelete()
                }
                }
              }

              Waveform {
                id: wave
                visible: !!(root.selected && root.selected.waveform && !root.selectedLive)
                width: parent.width
                rec: root.selected
                position: root.positionS
                trimMode: root.trimMode
                trimFrom: root.trimFrom
                trimTo: root.trimTo
                foreground: root.foreground
                fontFamily: root.fontFamily
                onSeekRequested: function(s) { root.seekTo(s) }
                onRangeChanged: function(f, t) { root.trimFrom = f; root.trimTo = t }
              }

              Row {
                visible: root.trimMode
                width: parent.width
                spacing: Style.spacing.sm
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - previewButton.width - trimButton.width - cancelButton.width - parent.spacing * 3
                  text: "Keep " + wave.fmt(root.trimFrom) + " – " + wave.fmt(root.trimTo) + "  ·  drag the handles, or play and press [ ] at the playhead"
                  elide: Text.ElideRight
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
                Button {
                  id: previewButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.previewing ? "Stop preview" : "Preview"
                  iconText: root.previewing ? "󰏤" : "󰐊"
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.previewRange()
                }
                Button {
                  id: trimButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Trim"
                  iconText: "󰆐"
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  foreground: Color.accent; fontFamily: root.fontFamily
                  enabled: root.trimTo > root.trimFrom + 0.5
                  onClicked: root.requestTrim()
                }
                Button {
                  id: cancelButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Cancel"
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: { root.trimMode = false; root.previewing = false }
                }
              }

              Text {
                visible: !!root.selectedJob
                width: parent.width
                text: root.selectedJob && root.svc
                  ? "Transcribing with " + root.selectedJob.model + " · " + root.svc.jobProgressText(root.selectedJob) + root.svc.fmtHms(root.svc.jobElapsed(root.selectedJob))
                    + " elapsed · ≈ " + root.svc.fmtDuration(root.svc.estimateSeconds(root.selected.duration_s, root.selectedJob.model)) + " expected"
                  : ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }

              Text {
                visible: !root.selectedJob && root.svc && root.selected && (root.svc.isPartial(root.selected) || root.svc.isStale(root.selected))
                width: parent.width
                text: root.svc && root.selected && root.svc.isPartial(root.selected)
                  ? "Partial: stopped after " + root.selected.transcript.chunks_done + "/" + root.selected.transcript.chunks + " pieces. Re-transcribe to finish."
                  : "The audio was trimmed after this transcript was made. Re-transcribe to match."
                color: Color.accent
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Transcript tools sit above the text, outside the scroll area, so
              // they stay put however far down a long transcript you are.
              Row {
                id: transcriptTools
                visible: root.transcriptText.length > 0
                spacing: Style.spacing.xs
                PanelActionButton {
                  iconText: "󰈙"
                  tooltipText: "Open in editor (Enter)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.openTranscript(root.selected.id)
                }
                PanelActionButton {
                  iconText: "󰆏"
                  tooltipText: "Copy transcript"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.copyTranscript(root.selected.id, function(code) { if (code === 0) copiedFlash.restart() })
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: copiedFlash.running
                  text: "Copied"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Timer { id: copiedFlash; interval: 1500 }
                PanelActionButton {
                  iconText: "󰈝"
                  tooltipText: "Send to Obsidian"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.exportToObsidian(root.selected.id, function(code) { if (code === 0) sentFlash.restart() })
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: sentFlash.running
                  text: "Sent"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Timer { id: sentFlash; interval: 1500 }
              }

              TranscriptView {
                width: parent.width
                height: detail.height - y
                visible: root.transcriptText.length > 0
                text: root.transcriptText
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              Text {
                // The progress line above already says "Transcribing…"; say nothing twice.
                visible: root.transcriptText.length === 0 && !root.selectedJob
                width: parent.width
                text: root.selectedLive ? "Recording in progress. Stop it from the bar icon, then transcribe."
                  : "Not transcribed yet. Pick a model above and press Transcribe (or Enter)."
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

          // ---- footer: key hints ----
          Text {
            width: parent.width
            text: root.hintsText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
