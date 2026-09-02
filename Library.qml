import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import "ui/format.js" as Fmt
import qs.Ui
import "ui"

// OmaRecorder Library — fullscreen overlay: every recording on the left,
// the selected one on the right with its transcript. Summoned with
//   omarchy-shell shell toggle io.github.huey-holdings-llc.omarecorder
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
  property bool showRaw: false            // the tidy transcript is the default view
  property bool showPrev: false           // transcript.prev.md, kept from before the last re-transcribe
  readonly property bool hasTidy: !!(selected && selected.tidy_path)
  readonly property bool hasPrev: !!(selected && selected.prev_path)
  // Playback runs in mpv, outside the shell (an in-process QtMultimedia player
  // crashed quickshell on multi-hour takes). The CLI starts mpv with an IPC
  // socket; this file observes time-pos/pause over it and sends seeks.
  property bool trimMode: false
  property real trimFrom: 0
  property real trimTo: 0
  property bool trimConfirmOpen: false
  property bool previewing: false
  property string playingId: ""
  property bool mpvPaused: false
  property real positionS: 0
  readonly property bool playing: playingId !== "" && !mpvPaused
  // A listening preference, kept for the session: never reset per recording.
  property real speedX: 1.0
  readonly property var speedSteps: [1, 1.25, 1.5, 2]
  function cycleSpeed(dir) {
    var i = speedSteps.indexOf(speedX); if (i < 0) i = 0
    speedX = speedSteps[(i + dir + speedSteps.length) % speedSteps.length]
    mpvSend(["set_property", "speed", speedX])
  }

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
  // A share of the card with a floor: long titles get room when the card is
  // wide, narrow screens still keep readable rows and a usable detail pane.
  property int listWidth: Math.max(Style.space(220), Math.round(cardWidth * 0.3))

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
  function close() { root.deleteConfirmOpen = false; root.trimConfirmOpen = false; root.trimMode = false; root.opened = false; stopPlayback() }
  function toggle() { root.opened ? root.close() : root.open("{}") }

  // Transcript matches arrive ~300 ms behind the keystrokes (the CLI greps
  // the files); title/id/date matching stays instant. The query tag guards
  // against a stale answer landing after further typing.
  property var transcriptMatchIds: []
  property string transcriptMatchQuery: ""
  function filteredRows() {
    var all = svc ? svc.recordings : []
    var q = filterText.trim().toLowerCase()
    if (!q) return all
    var inText = (transcriptMatchQuery === filterText.trim()) ? transcriptMatchIds : []
    var out = []
    for (var i = 0; i < all.length; i++) {
      var r = all[i]
      var hay = ((r.title || "") + " " + (r.id || "") + " " + (r.created || "")).toLowerCase()
      if (hay.indexOf(q) !== -1 || inText.indexOf(r.id) !== -1) out.push(r)
    }
    return out
  }
  function indexOfId(id) { for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return i; return -1 }
  function ensureSelection() { if (selectedIndex < 0 && rows.length > 0) selectedId = rows[0].id }
  readonly property string hintsText: root.trimMode
    ? "Space play   ←→ seek   [ ] mark start / end   Enter trim   Esc leave trim mode"
    : "↑↓ select   Enter open / transcribe   Ctrl+M model   Space play   Ctrl+S speed   ←→ seek   F2 rename   F3 trim   F4 raw   Del delete   Esc close"
  function select(delta) {
    if (rows.length === 0) return
    var i = selectedIndex < 0 ? (delta < 0 ? rows.length - 1 : 0) : (selectedIndex + delta + rows.length) % rows.length
    selectedId = rows[i].id
    list.positionViewAtIndex(i, ListView.Contain)
  }
  function selectAbsolute(i) { if (rows.length === 0) return; i = Math.max(0, Math.min(i, rows.length - 1)); selectedId = rows[i].id; list.positionViewAtIndex(i, ListView.Contain) }
  function setFilter(t) { filterText = t; searchDebounce.restart(); Qt.callLater(ensureSelection) }
  // Transcripts change under a live query (a re-transcription finishing, a
  // trim): re-ask when the list refreshes so the match set cannot go stale.
  Connections {
    target: root.svc
    function onRecordingsChanged() { if (root.filterText.trim()) searchDebounce.restart() }
  }
  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: {
      var q = root.filterText.trim()
      if (!q) { root.transcriptMatchIds = []; root.transcriptMatchQuery = ""; return }
      if (!root.svc) return
      root.svc.searchTranscripts(q, function(code, out) {
        if (code !== 0 || q !== root.filterText.trim()) return
        try { root.transcriptMatchIds = JSON.parse(out) } catch (e) { return }
        root.transcriptMatchQuery = q
        Qt.callLater(root.ensureSelection)
      })
    }
  }

  // Enter / the main button start a transcription. Cancelling a running job is
  // only reachable through the explicit Cancel button (cancelSelected) — a
  // stray Enter must never kill an hour-long job.
  function transcribeSelected() {
    if (!svc || !selected || selectedJob || selectedLive) return
    // --download makes the CLI chain the transcription onto the model download
    // when the model is missing; the intent lives on the job in state.json.
    svc.transcribe(selected.id, modelForRun, (svc.config && svc.config.language) || "en", true)
  }
  function cancelSelected() { if (svc && selected && selectedJob) svc.cancel(selected.id) }
  // Ctrl+M walks the preset models (the ones with a label) in catalog order.
  // Same gate as the picker's visibility: never while a job runs or the take is live.
  function cycleModel(dir) {
    if (!svc || !selected || selectedJob || selectedLive) return
    var presets = []
    for (var i = 0; i < svc.models.length; i++) if (svc.models[i].label) presets.push(svc.models[i])
    if (presets.length === 0) return
    var cur = -1
    for (var j = 0; j < presets.length; j++) if (presets[j].name === modelForRun) { cur = j; break }
    var next = cur < 0 ? (dir > 0 ? 0 : presets.length - 1) : (cur + dir + presets.length) % presets.length
    chosenModel = presets[next].name
    picker.value = presets[next].name
  }
  function mpvSend(cmd) { if (mpvSock.connected) mpvSock.write(JSON.stringify({ command: cmd }) + "\n") }
  function stopPlayback() {
    if (playingId !== "" && svc) svc.stopPlay()
    playingId = ""; mpvPaused = false; positionS = 0; previewing = false
  }
  function startPlayback(seconds) {
    if (!svc || !selected) return
    playingId = selected.id; mpvPaused = false; positionS = seconds
    if (seconds > 0) svc.playFrom(selected.id, seconds.toFixed(2)); else svc.play(selected.id)
    mpvRetry.tries = 0; mpvRetry.restart()
  }
  function togglePlay() {
    if (!svc || !selected || selectedLive) return
    if (playingId === selected.id) { mpvSend(["set_property", "pause", !mpvPaused]); previewing = false }
    else startPlayback(0)
  }
  function seekTo(seconds) {
    if (!svc || !selected || selectedLive) return
    seconds = Math.max(0, seconds)
    if (playingId === selected.id && mpvSock.connected) { mpvSend(["seek", seconds, "absolute"]); positionS = seconds }
    else startPlayback(seconds)
  }
  function startTrim() {
    if (!selected || selectedLive || selectedJob || !selected.waveform) return
    trimFrom = 0; trimTo = selected.duration_s || 0; trimMode = true
  }
  function previewRange() {
    if (previewing) { mpvSend(["set_property", "pause", true]); previewing = false; return }
    previewing = true
    seekTo(trimFrom)
    if (mpvPaused) mpvSend(["set_property", "pause", false])
  }
  // [ and ] in trim mode: put the start / end where the playhead is.
  function markStart() { if (positionS < trimTo - 0.5) trimFrom = positionS }
  function markEnd() { if (positionS > trimFrom + 0.5) trimTo = positionS }
  // Trim was explicitly invoked and is reversible (the original is kept), so the
  // dialog defaults to Trim; delete keeps defaulting to Cancel.
  function requestTrim() { if (trimMode && trimTo > trimFrom + 0.5) { trimConfirm.selectedIndex = 1; trimConfirmOpen = true } }
  function confirmTrim() {
    if (svc && selected) { stopPlayback(); svc.trim(selected.id, trimFrom.toFixed(2), trimTo.toFixed(2)) }
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
  // Every list refresh rebuilds the row objects, so `selected` changes
  // identity even when the selection stayed on the same recording; a
  // transcription or download finishing mid-playback must not stop the sound.
  // Only a genuine move to a different id resets playback and view state.
  property string lastSelectedId: ""
  onSelectedChanged: {
    var newId = selected ? selected.id : ""
    if (newId === lastSelectedId) return
    lastSelectedId = newId
    stopPlayback()
    trimMode = false; previewing = false; showRaw = false; showPrev = false
    // Re-transcribe defaults to the model that produced the visible transcript.
    var last = selected && selected.transcript && selected.transcript.model ? selected.transcript.model : ""
    var m = svc && last ? svc.modelByName(last) : null
    chosenModel = m ? last : ""
    picker.value = modelForRun
  }

  // mpv's IPC socket appears shortly after the CLI starts the player; retry
  // until it does, then observe position and pause state.
  Timer {
    id: mpvRetry
    property int tries: 0
    interval: 250; repeat: true
    onTriggered: {
      if (root.playingId === "") { stop(); return }
      if (mpvSock.connected) { stop(); return }
      tries++
      if (tries > 20) { stop(); root.stopPlayback(); return }   // mpv never came up
      mpvSock.connected = false
      mpvSock.connected = true
    }
  }
  Socket {
    id: mpvSock
    path: root.svc && root.svc.runtimeDir ? root.svc.runtimeDir + "/mpv.sock" : ""
    onConnectedChanged: {
      if (connected) {
        write(JSON.stringify({ command: ["observe_property", 1, "time-pos"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", 2, "pause"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", 3, "speed"] }) + "\n")
        // mpv respawns on every play; re-sending here is what makes the
        // chosen speed a session preference rather than a per-play one.
        if (root.speedX !== 1) write(JSON.stringify({ command: ["set_property", "speed", root.speedX] }) + "\n")
      } else if (root.playingId !== "" && !mpvRetry.running) {
        root.stopPlayback()   // mpv exited (end of file, or stop-play)
      }
    }
    parser: SplitParser {
      onRead: function(line) {
        var msg
        try { msg = JSON.parse(line) } catch (e) { return }
        if (msg.event === "property-change") {
          if (msg.name === "time-pos" && typeof msg.data === "number") {
            root.positionS = msg.data
            if (root.previewing && msg.data >= root.trimTo) { root.mpvSend(["set_property", "pause", true]); root.previewing = false }
          } else if (msg.name === "pause") {
            root.mpvPaused = msg.data === true
          } else if (msg.name === "speed" && typeof msg.data === "number") {
            root.speedX = msg.data
          }
        } else if (msg.event === "end-file") {
          root.stopPlayback()
        }
      }
    }
  }

  FileView {
    id: transcriptFile
    path: !root.selected ? "" : (root.hasPrev && root.showPrev ? root.selected.prev_path
      : (root.hasTidy && !root.showRaw ? root.selected.tidy_path : (root.selected.transcript_path || "")))
    watchChanges: true
    printErrors: false
    // Clearing here (not on selection) prevents the previous recording's text
    // flashing, without wiping the view on list refreshes that keep the path.
    onPathChanged: root.transcriptText = ""
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
          if (titleField.activeFocus || noteField.activeFocus) return
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
          else if (root.trimMode && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.requestTrim(); event.accepted = true }
          else if (event.key === Qt.Key_F4) { if (root.hasTidy) { root.showRaw = !root.showRaw; root.showPrev = false } event.accepted = true }
          else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C && root.transcriptText.length > 0) {
            root.svc.copyTranscript(root.selected.id, root.showRaw, function(code) { if (code === 0) copiedFlash.restart() }); event.accepted = true
          }
          else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_O && root.transcriptText.length > 0) {
            root.svc.exportToObsidian(root.selected.id, root.showRaw, function(code) { if (code === 0) sentFlash.restart() }); event.accepted = true
          }
          else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_M) {
            root.cycleModel((event.modifiers & Qt.ShiftModifier) ? -1 : 1); event.accepted = true
          }
          else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
            root.cycleSpeed((event.modifiers & Qt.ShiftModifier) ? -1 : 1); event.accepted = true
          }
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
          message: "Keep " + wave.fmt(root.trimFrom) + " to " + wave.fmt(root.trimTo) + " and cut the rest? The original is kept and can be restored."
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
              text: "󰕽  OmaRecorder"   // tape reels, not the red record dot: this header is visible while idle
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
                  text: root.filterText ? root.filterText : "Type to search titles and transcripts"
                  color: root.filterText ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.rows.length + (root.rows.length === 1 ? " recording" : " recordings") + (root.filterText ? (root.rows.length === 1 ? " matches" : " match") : "")
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
                enabled: !root.selectedJob   // rename is refused mid-transcribe, same as notes
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
                    + (root.selected.transcript && root.selected.transcript.tidy && root.selected.transcript.tidy.repeats_removed > 0 && !root.showRaw ? " · " + root.selected.transcript.tidy.repeats_removed + " repeats removed" : "")
                    + (root.playing ? " · ▶ playing" : ""))
                  : ""
                textFormat: Text.PlainText
                color: root.selectedLive ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              TextField {
                id: noteField
                visible: !root.selectedLive
                // The CLI refuses meta writes while this recording transcribes
                // (lost-update guard), so don't offer an edit that cannot save.
                enabled: !root.selectedJob
                width: parent.width
                text: root.selected ? (root.selected.notes || "") : ""
                placeholderText: "Add a note"
                foreground: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                onAccepted: { if (root.svc && root.selected && text !== (root.selected.notes || "")) root.svc.setNote(root.selected.id, text); keyCatcher.forceActiveFocus() }
                Keys.onEscapePressed: { text = root.selected ? (root.selected.notes || "") : ""; keyCatcher.forceActiveFocus() }
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
                  // The chip row takes what the main button and icon actions
                  // leave over. The readout and speed chip have fixed widths,
                  // so the space is identical in every playback state, and
                  // when the full labels do not fit the chips go compact
                  // (names only, estimates in tooltips) instead of clipping.
                  readonly property real rowAvail: parent.width - mainButton.width - iconActions.width - posReadout.width - speedChip.width - parent.spacing * 4
                  compact: rowAvail < fullWidth
                  width: Math.min(picker.implicitWidth, rowAvail)
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
                  tooltipText: root.selectedJob ? "" : (root.selected && root.selected.has_transcript ? "Shift+Enter" : "Enter")
                  text: root.selectedJob ? "Cancel"
                    : (picker.currentInstalled ? (root.selected && root.selected.has_transcript ? "Re-transcribe" : "Transcribe")
                                               : (picker.download ? (picker.download.then ? "Downloading… will transcribe" : "Downloading…")
                                                                  : "Download + transcribe"))
                  iconText: root.selectedJob ? "󰅖" : (picker.currentInstalled ? "󰗊" : "󰇚")
                  active: !!root.selectedJob
                  iconSpinning: !!root.selectedJob || !!picker.download
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  // Stays clickable during a download: a press re-aims the
                  // chained transcription onto the selected recording (the
                  // CLI attach path; last press wins).
                  onClicked: root.selectedJob ? root.cancelSelected() : root.transcribeSelected()
                }
                Row {
                  id: iconActions
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs
                AccessibleActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.playing ? "󰏤" : "󰐊"
                  tooltipText: "Play / pause (Space)"
                  enabled: !root.selectedLive
                  opacity: enabled ? 1 : 0.4
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.togglePlay()
                }
                AccessibleActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰆐"
                  tooltipText: "Trim (F3)"
                  enabled: !!(root.selected && root.selected.waveform && !root.selectedLive && !root.selectedJob)
                  opacity: enabled ? 1 : 0.4
                  foreground: root.trimMode ? Color.accent : root.foreground; fontFamily: root.fontFamily
                  onClicked: root.trimMode ? (root.trimMode = false) : root.startTrim()
                }
                AccessibleActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  // Slot always reserved so the trash button never shifts under the pointer.
                  enabled: !!(root.selected && root.selected.has_orig)
                  opacity: enabled ? 1 : 0
                  iconText: "󰕌"
                  tooltipText: "Restore the untrimmed original"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) { root.stopPlayback(); root.svc.restoreTrim(root.selected.id) }
                }
                AccessibleActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  // Reserved-slot pattern too; appears only while the picked
                  // model is downloading. The main button cannot host this:
                  // its press during a download re-aims the chain by design.
                  enabled: !!picker.download
                  opacity: enabled ? 1 : 0
                  iconText: "󰜺"
                  tooltipText: "Cancel this model download"
                  hoverColor: root.urgent
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc) root.svc.cancelDownload(picker.value)
                }
                AccessibleActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰉋"
                  tooltipText: "Open folder"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.openFolder(root.selected.id)
                }
                AccessibleActionButton {
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
                TextMetrics {
                  // The widest string this recording's readout can show: the
                  // position never exceeds the duration. Sizing to it keeps
                  // the whole row still while the numbers tick.
                  id: posMetrics
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  text: root.selected ? Fmt.fmtClock(root.selected.duration_s) + " / " + Fmt.fmtClock(root.selected.duration_s) : ""
                }
                Text {
                  id: posReadout
                  // Fixed-width slot so nothing shifts when playback starts,
                  // visible whenever playback is possible. fmtClock matches
                  // the waveform labels.
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !!(root.selected && !root.selectedLive)
                  width: Math.ceil(posMetrics.width)
                  horizontalAlignment: Text.AlignRight
                  text: root.selected ? Fmt.fmtClock(root.positionS) + " / " + Fmt.fmtClock(root.selected.duration_s) : ""
                  textFormat: Text.PlainText
                  color: root.playing ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Button {
                  id: speedChip
                  // Right of the time so it reads as a playback property, not
                  // a transcription one. Click cycles; Ctrl+S still works.
                  // Fixed width (sized to the widest label) so switching
                  // 1x/1.25x/1.5x/2x moves nothing.
                  anchors.verticalCenter: parent.verticalCenter
                  visible: posReadout.visible
                  bordered: true
                  text: root.speedX + "x"
                  tooltipText: "Playback speed (Ctrl+S)"
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  foreground: root.speedX !== 1 ? Color.accent : root.dim
                  fontFamily: root.fontFamily
                  width: Math.ceil(speedMetrics.width) + Style.spacing.sm * 2 + 2
                  TextMetrics { id: speedMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.caption; text: "1.25x" }
                  onClicked: root.cycleSpeed(1)
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
                  text: "Keep " + wave.fmt(root.trimFrom) + " to " + wave.fmt(root.trimTo)
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

              Text {
                visible: !!(root.svc && root.svc.lastError.length > 0)
                width: parent.width
                text: root.svc ? root.svc.lastError : ""
                textFormat: Text.PlainText
                color: root.urgent
                wrapMode: Text.Wrap
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

              Column {
                width: parent.width
                spacing: Style.spacing.xxs
                visible: !root.selectedJob && root.svc && root.selected && root.svc.isLoopy(root.selected)
                Text {
                  width: parent.width
                  text: "Whisper looped on this take (longest repeat "
                    + (root.selected && root.selected.transcript && root.selected.transcript.tidy && root.selected.transcript.tidy.longest_run_words != null
                       ? root.selected.transcript.tidy.longest_run_words : "?")
                    + " words removed). Try a larger model, or:"
                  color: Color.accent
                  wrapMode: Text.Wrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Button {
                  // Halve the chunk length that produced this transcript,
                  // floored at 300 s; at or below the floor halving cannot
                  // shorten anything, so the button steps aside and the
                  // larger-model advice stands alone.
                  readonly property int lastChunk: (root.selected && root.selected.transcript && root.selected.transcript.chunk_s) || 1800
                  visible: lastChunk > 300
                  text: "Re-transcribe in shorter pieces"
                  iconText: "󰗊"
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  foreground: Color.accent; fontFamily: root.fontFamily
                  onClicked: root.svc.transcribe(root.selected.id, root.modelForRun,
                    (root.svc.config && root.svc.config.language) || "en", true,
                    Math.max(300, Math.floor(lastChunk / 2)))
                }
              }

              // Transcript tools sit above the text, outside the scroll area, so
              // they stay put however far down a long transcript you are.
              Row {
                id: transcriptTools
                visible: root.transcriptText.length > 0
                spacing: Style.spacing.xs
                AccessibleActionButton {
                  iconText: "󰈙"
                  tooltipText: "Open in editor (Enter)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.openTranscript(root.selected.id)
                }
                Button {
                  visible: root.hasTidy
                  text: "Tidy"
                  active: !root.showRaw && !root.showPrev
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  tooltipText: "Paragraphs, repeated passages removed (F4)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: { root.showRaw = false; root.showPrev = false }
                }
                Button {
                  visible: root.hasTidy
                  text: "Raw"
                  active: root.showRaw && !root.showPrev
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  tooltipText: "Exactly as whisper wrote it (F4)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: { root.showRaw = true; root.showPrev = false }
                }
                Button {
                  // Toggles, so the old text stays reachable even when there is
                  // no Tidy / Raw pair to click back to.
                  visible: root.hasPrev
                  text: "Previous"
                  active: root.showPrev
                  fontSize: Style.font.caption; horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.xxs
                  tooltipText: "The transcript the last re-transcribe replaced"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.showPrev = !root.showPrev
                }
                AccessibleActionButton {
                  iconText: "󰆏"
                  tooltipText: "Copy transcript (Ctrl+C)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.copyTranscript(root.selected.id, root.showRaw, function(code) { if (code === 0) copiedFlash.restart() })
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
                AccessibleActionButton {
                  iconText: "󰈝"
                  tooltipText: "Send to Obsidian (Ctrl+O)"
                  foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.svc && root.selected) root.svc.exportToObsidian(root.selected.id, root.showRaw, function(code) { if (code === 0) sentFlash.restart() })
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

              Text {
                visible: root.showPrev && root.transcriptText.length > 0
                width: parent.width
                text: "Previous transcript, from before the last re-transcribe. Copy and export still use the current one."
                color: Color.accent
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
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
