import QtQuick
import Quickshell
import Quickshell.Io

// Omarecorder service — the single source of truth for the plugin's UI.
// Mounted once by the shell (kind "service", keepLoaded); Panel/Library
// instances (one per monitor) read from it via bar.shell.serviceFor(id).
//
// All logic lives in bin/omarecorder. This object:
//   * watches $XDG_RUNTIME_DIR/omarecorder/state.json (no polling processes)
//   * reloads the recordings list / models / config / setup when state changes
//   * exposes actions that shell out to the CLI
QtObject {
  id: root

  property var settings: ({})
  readonly property string pluginId: "io.github.coreytyhurst.omarecorder"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: pluginDir + "/bin/omarecorder"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarecorder"
  readonly property string stateFile: runtimeDir + "/state.json"

  // ---- state mirrored from the CLI ----
  property var state: ({ recording: null, jobs: [], version: 0 })
  property var recordings: []
  property var models: []
  property var config: ({})
  property var setup: ({ ok: true })
  property string lastError: ""
  property bool listBusy: false
  property int elapsed: 0
  property int now: Math.floor(Date.now() / 1000)   // ticks once a second while anything runs

  readonly property bool recording: !!(state && state.recording)
  readonly property var activeRecording: recording ? state.recording : null
  readonly property string activeId: activeRecording ? activeRecording.id : ""
  readonly property var jobs: (state && state.jobs) ? state.jobs : []
  readonly property bool transcribing: jobs.some(function(j) { return j.type === "transcribe" })
  readonly property bool downloading: jobs.some(function(j) { return j.type === "download" })
  readonly property bool busy: transcribing || downloading
  readonly property string elapsedText: fmtHms(elapsed)
  readonly property var activeJob: jobs.find(function(j) { return j.type === "transcribe" }) || null
  // Jobs in state.json carry started_at only (elapsed_s is a `status` extra).
  function jobElapsed(j) { return j && j.started_at ? Math.max(0, now - j.started_at) : 0 }
  readonly property string transcribeElapsedText: fmtHms(jobElapsed(activeJob))
  readonly property string defaultModel: config && config.defaultModel ? config.defaultModel : "base.en"
  readonly property string defaultSource: config && config.defaultSource ? config.defaultSource : "mic"

  function fmtHms(s) {
    s = Math.max(0, Math.floor(s || 0))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m + ":" + (x < 10 ? "0" : "") + x
  }
  function fmtDuration(s) { // compact: 1h 02m / 12m 05s / 45s
    s = Math.max(0, Math.floor(s || 0))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
    if (m > 0) return m + "m " + (x < 10 ? "0" : "") + x + "s"
    return x + "s"
  }
  function fmtDate(iso) { // "2026-08-29T19:27:42-0400" → "Aug 29, 19:27"
    if (!iso) return ""
    var d = new Date(String(iso).replace(/([+-]\d\d)(\d\d)$/, "$1:$2"))
    if (isNaN(d.getTime())) return String(iso).slice(0, 16).replace("T", " ")
    return Qt.formatDateTime(d, "MMM d, HH:mm")
  }
  // Untitled recordings show a friendly name instead of the raw folder id.
  function displayTitle(rec) { if (!rec) return ""; return rec.title ? rec.title : "Recording · " + fmtDate(rec.created) }
  function sourceLabel(src) { return src === "mic" ? "microphone" : src === "system" ? "system audio" : src === "both" ? "microphone + system" : (src || "") }
  function isClipped(rec) { return !!(rec && rec.levels && rec.levels.clipped) }
  function fmtBytes(b) { b = b || 0; if (b > 1e9) return (b / 1e9).toFixed(1) + " GB"; if (b > 1e6) return Math.round(b / 1e6) + " MB"; return Math.round(b / 1e3) + " KB" }

  function jobFor(id) { for (var i = 0; i < jobs.length; i++) if (jobs[i].type === "transcribe" && jobs[i].id === id) return jobs[i]; return null }
  function downloadFor(model) { for (var i = 0; i < jobs.length; i++) if (jobs[i].type === "download" && jobs[i].model === model) return jobs[i]; return null }
  function recordingById(id) { for (var i = 0; i < recordings.length; i++) if (recordings[i].id === id) return recordings[i]; return null }
  function modelByName(name) { for (var i = 0; i < models.length; i++) if (models[i].name === name) return models[i]; return null }
  function estimateSeconds(durationS, modelName) {
    var m = modelByName(modelName); var rtf = m && m.rtf ? m.rtf : 3
    return Math.ceil((durationS || 0) / rtf)
  }

  // ---- loaders ----
  function refresh() { refreshList(); refreshModels(); refreshConfig(); refreshSetup() }
  function refreshList() { if (!listProc.running) { listBusy = true; listProc.running = true } }
  function refreshModels() { if (!modelsProc.running) modelsProc.running = true }
  function refreshConfig() { if (!configProc.running) configProc.running = true }
  function refreshSetup() { if (!setupProc.running) setupProc.running = true }

  function applyState(text) {
    try {
      var s = JSON.parse(text)
      var prevVersion = state ? state.version : -1
      state = s
      updateElapsed()
      if (s.version !== prevVersion) { refreshList(); refreshSetup() }
    } catch (e) { /* partial write; FileView will fire again */ }
  }
  function updateElapsed() {
    now = Math.floor(Date.now() / 1000)
    if (activeRecording) elapsed = Math.max(0, Math.floor(Date.now() / 1000) - activeRecording.started_at)
    else elapsed = 0
  }

  // ---- actions (fire-and-forget; state.json tells us what happened) ----
  function run(args, onDone) {
    var proc = actionComponent.createObject(root, { command: [cli].concat(args), callback: onDone || null })
    proc.running = true
  }
  function startRecording(source) { run(["record", "start", "--source", source || defaultSource]) }
  function stopRecording() { run(["record", "stop"]) }
  function toggleRecording() { recording ? stopRecording() : startRecording() }
  function transcribe(id, model, language) {
    var args = ["transcribe", id]
    if (model) args = args.concat(["--model", model])
    if (language) args = args.concat(["--language", language])
    run(args)
  }
  function cancel(id) { run(["cancel", id]) }
  function rename(id, title) { run(["rename", id, title]) }
  function remove(id) { run(["delete", id, "--yes"]) }
  function download(model) { run(["model", "download", model]) }
  function importFile(path) { run(["import", path]) }
  function play(id) { run(["play", id]) }
  function stopPlay() { run(["stop-play"]) }
  function openTranscript(id) { Quickshell.execDetached([cli, "open", id]) }
  function openFolder(id) { Quickshell.execDetached([cli, "folder", id]) }
  function copyTranscript(id) {
    var r = recordingById(id); if (!r || !r.transcript_path) return
    Quickshell.execDetached(["bash", "-c", "sed '1{/^<!--/d}' " + JSON.stringify(r.transcript_path) + " | wl-copy"])
  }
  function setConfig(key, value) { run(["config", "set", key, String(value)], function() { refreshConfig() }) }
  function openLibrary() { Quickshell.execDetached(["omarchy-shell", "shell", "toggle", pluginId]) }

  // ---- plumbing ----
  property Component actionComponent: Component {
    Process {
      id: p
      property var callback: null
      stdout: StdioCollector { id: aOut; waitForEnd: true }
      stderr: StdioCollector { id: aErr; waitForEnd: true }
      onExited: function(code) {
        if (code !== 0) root.lastError = String(aErr.text || aOut.text || ("exit " + code)).trim()
        else root.lastError = ""
        if (callback) callback(code)
        p.destroy()
      }
    }
  }

  property FileView stateView: FileView {
    path: root.stateFile
    watchChanges: true
    blockLoading: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: function(err) { root.state = { recording: null, jobs: [], version: 0 }; root.updateElapsed() }
  }

  property Timer elapsedTimer: Timer {
    interval: 1000; repeat: true; running: root.recording || root.transcribing || root.downloading
    onTriggered: { root.updateElapsed(); if (root.busy) root.refreshList() }
  }

  property Process listProc: Process {
    command: [root.cli, "list", "--json"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(code) {
      root.listBusy = false
      if (code === 0) { try { root.recordings = JSON.parse(listOut.text) } catch (e) { root.recordings = [] } }
    }
  }
  property Process modelsProc: Process {
    command: [root.cli, "models", "--json"]
    stdout: StdioCollector { id: modelsOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { root.models = JSON.parse(modelsOut.text) } catch (e) {} } }
  }
  property Process configProc: Process {
    command: [root.cli, "config", "get", "--json"]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { root.config = JSON.parse(configOut.text) } catch (e) {} } }
  }
  property Process setupProc: Process {
    command: [root.cli, "setup", "check", "--json"]
    stdout: StdioCollector { id: setupOut; waitForEnd: true }
    onExited: function(code) { try { root.setup = JSON.parse(setupOut.text) } catch (e) {}; root.refreshModels() }
  }

  Component.onCompleted: {
    // Ensure the runtime dir exists so the FileView has something to watch.
    Quickshell.execDetached(["mkdir", "-p", root.runtimeDir])
    refresh()
  }
}
