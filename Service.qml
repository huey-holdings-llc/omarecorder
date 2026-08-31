import QtQuick
import Quickshell
import Quickshell.Io
import "ui/format.js" as Fmt

// OmaRecorder service — the single source of truth for the plugin's UI.
// Mounted once by the shell (kind "service", keepLoaded); Panel/Library
// instances (one per monitor) read from it via bar.shell.serviceFor(id).
//
// All logic lives in bin/omarecorder. This object:
//   * watches $XDG_RUNTIME_DIR/omarecorder/state.json (no polling processes)
//   * reloads the recordings list / models / config / setup when state changes
//   * exposes actions that shell out to the CLI
QtObject {
  id: root

  readonly property string pluginId: "io.github.huey-holdings-llc.omarecorder"
  // decodeURIComponent: a home directory with a space arrives as %20 otherwise.
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString()).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: pluginDir + "/bin/omarecorder"
  // Runtime state lives only in the per-user runtime dir (never /tmp): without
  // XDG_RUNTIME_DIR there is nothing safe to watch, so the service stays idle.
  readonly property string xdgRuntime: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string runtimeDir: xdgRuntime ? xdgRuntime + "/omarecorder" : ""
  readonly property string stateFile: runtimeDir ? runtimeDir + "/state.json" : ""
  readonly property string levelFile: runtimeDir ? runtimeDir + "/level" : ""

  // ---- state mirrored from the CLI ----
  property var state: ({ recording: null, jobs: [], version: 0 })
  property var recordings: []
  property var models: []
  property var vaults: []      // Obsidian vaults from `omarecorder vaults --json` (open one first)
  property var config: ({})
  property var setup: ({ ok: true })
  property string lastError: ""
  property var level: null            // {peak_db, clip, t} while recording (watched file)
  readonly property bool clipping: !!(level && level.clip)
  readonly property real peakDb: level && typeof level.peak_db === "number" ? level.peak_db : -99
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
  // "2/4 · " while a long take is transcribed in pieces; "" otherwise.
  function jobProgressText(j) { return j && j.progress && j.progress.chunks > 1 ? j.progress.chunk + "/" + j.progress.chunks + " · " : "" }
  function isPartial(rec) { return !!(rec && rec.transcript && rec.transcript.partial) }
  function isStale(rec) { return !!(rec && rec.transcript && rec.transcript.stale) }
  readonly property string activeJobTitle: activeJob ? (recordingById(activeJob.id) ? displayTitle(recordingById(activeJob.id)) : activeJob.id) : ""
  readonly property string defaultModel: config && config.defaultModel ? config.defaultModel : "base.en"
  readonly property string defaultSource: config && config.defaultSource ? config.defaultSource : "mic"

  function fmtHms(s) { return Fmt.fmtHms(s) }
  function fmtDuration(s) { return Fmt.fmtDuration(s) }
  function fmtDate(iso) { return Fmt.fmtDate(iso) }
  // Untitled recordings show a friendly name instead of the raw folder id.
  function displayTitle(rec) { if (!rec) return ""; return rec.title ? rec.title : "Recording · " + fmtDate(rec.created) }
  function sourceLabel(src) { return src === "mic" ? "microphone" : src === "system" ? "system audio" : src === "both" ? "mic + system audio" : src === "import" ? "imported" : (src || "") }
  function isClipped(rec) { return !!(rec && rec.levels && rec.levels.clipped) }
  function fmtBytes(b) { return Fmt.fmtBytes(b) }

  function jobFor(id) { for (var i = 0; i < jobs.length; i++) if (jobs[i].type === "transcribe" && jobs[i].id === id) return jobs[i]; return null }
  function downloadFor(model) { for (var i = 0; i < jobs.length; i++) if (jobs[i].type === "download" && jobs[i].model === model) return jobs[i]; return null }
  function recordingById(id) { for (var i = 0; i < recordings.length; i++) if (recordings[i].id === id) return recordings[i]; return null }
  function modelByName(name) { for (var i = 0; i < models.length; i++) if (models[i].name === name) return models[i]; return null }
  function estimateSeconds(durationS, modelName) {
    var m = modelByName(modelName); var rtf = m && m.rtf ? m.rtf : 3
    return Math.ceil((durationS || 0) / rtf)
  }

  // ---- loaders ----
  function refresh() { refreshList(); refreshModels(); refreshConfig(); refreshSetup(); refreshVaults() }
  function refreshList() { if (!listProc.running) listProc.running = true }
  function refreshModels() { if (!modelsProc.running) modelsProc.running = true }
  function refreshVaults() { if (!vaultsProc.running) vaultsProc.running = true }
  function refreshConfig() { if (!configProc.running) configProc.running = true }
  function refreshSetup() { if (!setupProc.running) setupProc.running = true }

  // Which state changes actually need a re-list or a setup re-check: not the
  // bytes_done ticks a download writes every 2 s. jobs shape + per-piece
  // progress + the recording id cover everything the list renders.
  property string _listSig: ""
  function _stateSig(s) {
    var jobs = (s.jobs || []).map(function(j) { return [j.type, j.id || j.model, j.unit, j.progress ? j.progress.chunk : 0].join(":") })
    return jobs.join("|") + "//" + (s.recording ? s.recording.id : "")
  }
  function applyState(text) {
    try {
      var s = JSON.parse(text)
      var prevVersion = state ? state.version : -1
      state = s
      updateElapsed()
      if (s.version !== prevVersion) {
        var sig = _stateSig(s)
        if (sig !== _listSig) {
          _listSig = sig
          refreshList()
          if (!setup || setup.ok !== true) refreshSetup()
        } else if (!s.jobs || s.jobs.length === 0) {
          refreshList()   // a bump with no jobs: a mutation such as rename or delete
          if (!setup || setup.ok !== true) refreshSetup()
        }
      }
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
  // force skips the long-take confirmation; the popup's Stop button uses it,
  // a button press being deliberate in a way a keybinding is not.
  function stopRecording(force) { run(force ? ["record", "stop", "--force"] : ["record", "stop"]) }
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
  function importFile(path) { run(["import", path], function(code) { if (code === 0) root.refreshList() }) }
  function play(id) { run(["play", id]) }
  function playFrom(id, seconds) { run(["play", id, "--from", String(seconds)]) }
  function stopPlay() { run(["stop-play"]) }
  function trim(id, from, to) { run(["trim", id, "--from", String(from), "--to", String(to)]) }
  function restoreTrim(id) { run(["trim", id, "--restore"]) }
  function openTranscript(id) { Quickshell.execDetached([cli, "open", id]) }
  function openFolder(id) { Quickshell.execDetached([cli, "folder", id]) }
  // The CLI does the copy (argv only — no shell string is ever built from a title).
  function copyTranscript(id, raw, onDone) { run(raw ? ["copy", id, "--raw"] : ["copy", id], onDone) }
  // The CLI picks the vault/folder (config, then the open vault) and opens the note in Obsidian.
  function exportToObsidian(id, raw, onDone) { run(raw ? ["export", id, "--raw"] : ["export", id], onDone) }
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

  // Ticks the elapsed clocks only. Everything else is event-driven: the CLI
  // bumps state.json (watched above) whenever anything changes.
  // The meter file exists only while recording; watching it costs nothing idle.
  property FileView levelView: FileView {
    path: root.recording ? root.levelFile : ""
    watchChanges: true
    blockLoading: false
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.level = JSON.parse(text()) } catch (e) {} }
    onLoadFailed: root.level = null
    onPathChanged: if (!path) root.level = null
  }

  property Timer elapsedTimer: Timer {
    interval: 1000; repeat: true; running: root.recording || root.transcribing || root.downloading
    onTriggered: root.updateElapsed()
  }

  property Process listProc: Process {
    command: [root.cli, "list", "--json"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) { try { root.recordings = JSON.parse(listOut.text) } catch (e) { root.recordings = [] } }
    }
  }
  property Process modelsProc: Process {
    command: [root.cli, "models", "--json"]
    stdout: StdioCollector { id: modelsOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { root.models = JSON.parse(modelsOut.text) } catch (e) {} } }
  }
  property Process vaultsProc: Process {
    command: [root.cli, "vaults", "--json"]
    stdout: StdioCollector { id: vaultsOut; waitForEnd: true }
    onExited: function(code) { if (code === 0) { try { root.vaults = JSON.parse(vaultsOut.text) } catch (e) {} } }
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
    if (!root.runtimeDir) { root.lastError = "XDG_RUNTIME_DIR is not set, so OmaRecorder cannot run"; return }
    // `status` reconciles stale state and creates the (0700) runtime dir and
    // state.json, so the FileView above has a real file to watch from the start.
    run(["status"], function() { root.stateView.reload(); root.refresh() })
  }
}
