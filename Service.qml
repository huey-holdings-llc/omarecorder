pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "ui/format.js" as Fmt
import "ui/state.js" as State

// OmaRecorder service: the single source of truth for the plugin's UI.
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
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtimeDir: xdgRuntime ? xdgRuntime + "/omarecorder" : ""
  readonly property string stateFile: runtimeDir ? runtimeDir + "/state.json" : ""
  readonly property string levelFile: runtimeDir ? runtimeDir + "/level" : ""

  // ---- state mirrored from the CLI ----
  property var state: ({ recording: null, jobs: [], version: 0 })
  property var recordings: []
  property var models: []
  property var vaults: []      // Obsidian vaults from `omarecorder vaults --json` (open one first)
  property var config: ({})
  property var dictionary: ({ count: 0, entries: [] })
  property var setup: ({ ok: true })
  property string lastError: ""
  // Which action owns the message (State.actionError's key, "load:<what>" for
  // a loader). Only that action's next success clears it: any success used
  // to, so an unrelated one could wipe a failure before anyone read it.
  property string lastErrorKey: ""
  function setError(e) { root.lastError = e.text; root.lastErrorKey = e.key }
  // refresh() does not go through run(), so a failure could stay on screen
  // through selection changes, closes and reopens. Both surfaces can dismiss it.
  function clearError() { root.lastError = ""; root.lastErrorKey = "" }
  property var level: null            // {peak_db, clip, t} while recording (watched file)
  readonly property bool clipping: !!(level && level.clip)
  readonly property real peakDb: level && typeof level.peak_db === "number" ? level.peak_db : -99
  property int elapsed: 0
  property int now: Math.floor(Date.now() / 1000)   // ticks once a second while anything runs

  readonly property bool recording: !!(state && state.recording)
  readonly property var activeRecording: recording ? state.recording : null
  readonly property string activeId: activeRecording ? activeRecording.id : ""
  // A guarded stop of a long take is waiting for its second press (the CLI's
  // 10 second window); the popup says so instead of only a notification.
  readonly property bool stopArmed: !!(activeRecording && activeRecording.stop_armed_at && now - activeRecording.stop_armed_at <= 10)
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
  // The tidy pass flagged a long whisper repetition loop (policy lives in the CLI).
  function isLoopy(rec) { return !!(rec && rec.transcript && rec.transcript.tidy && rec.transcript.tidy.loop_warning) }
  readonly property string activeJobTitle: activeJob ? (recordingById(activeJob.id) ? displayTitle(recordingById(activeJob.id)) : activeJob.id) : ""
  readonly property string defaultModel: config && config.defaultModel ? config.defaultModel : "base.en"
  // A source picked with `c` or the dropdown counts at once. The config write
  // and reload behind it take a moment, and `c` then `r` inside that moment
  // used to record with the old source (and a second `c` stepped from it).
  property string pendingSource: ""
  readonly property string defaultSource: pendingSource || (config && config.defaultSource ? config.defaultSource : "mic")
  // A model download that failed, until the next attempt ({model, at}); the
  // Library says so beside the button instead of only in a notification.
  readonly property var downloadFailed: (state && state.download_failed) ? state.download_failed : null

  // Resume offer: the CLI arms state.last_stop on a clean stop and withdraws
  // it on a new start, trim or delete; there is no time limit. This only
  // re-checks a transcribe job for the offered take (resuming is refused
  // while one runs, so no button until it ends; jobs are mirrored from the
  // same state.json).
  readonly property var lastStop: (state && state.last_stop) ? state.last_stop : null
  readonly property bool resumable: !!(lastStop && lastStop.resumable === true && !recording
    && !jobFor(lastStop.id))
  // The take's title, for the resume button's tooltip (the label itself
  // stays generic: an untitled take's display title carries a date).
  readonly property string resumeTitle: {
    if (!lastStop) return ""
    var r = recordingById(lastStop.id)
    return lastStop.title || (r ? displayTitle(r) : lastStop.id)
  }
  readonly property string resumeAgoText: {
    if (!lastStop) return ""
    var s = Math.max(0, now - (lastStop.stopped_at || now))
    if (s < 60) return "just now"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m ago"
    if (m < 1440) return Math.floor(m / 60) + "h " + (m % 60) + "m ago"
    return Math.floor(m / 1440) + "d ago"
  }
  function resumeRecording() { run(["record", "resume"]) }

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
  // The preset's name as the chips say it (Fast, Balanced, Accurate), else the engine's.
  function modelLabel(name) { var m = modelByName(name); return m && m.label ? m.label : (name || "") }
  function estimateSeconds(durationS, modelName) {
    var m = modelByName(modelName); var rtf = m && m.rtf ? m.rtf : 3
    return Math.ceil((durationS || 0) / rtf)
  }

  // ---- loaders ----
  function refresh() { reconcile(); refreshList(); refreshModels(); refreshConfig(); refreshSetup(); refreshVaults(); refreshDictionary() }
  // A refresh asked for while the same loader is still running is remembered and
  // run again when it exits. Dropping it lost changes that landed mid-read: a
  // rename during another take's transcription left the transcript pane blank.
  property var _again: ({})
  function load(proc, name) { if (proc.running) _again[name] = true; else proc.running = true }
  function loadAgain(proc, name) { if (_again[name]) { _again[name] = false; Qt.callLater(function() { proc.running = true }) } }
  function refreshList() { load(listProc, "list") }
  function refreshDictionary() { load(dictProc, "dictionary") }
  function refreshModels() { load(modelsProc, "models") }
  function refreshVaults() { load(vaultsProc, "vaults") }
  function refreshConfig() { load(configProc, "config") }
  function refreshSetup() { load(setupProc, "setup") }

  // The signature of the last state that caused a re-list (State.stateSig:
  // job shape, per-piece progress and the live recording id, not the
  // bytes_done ticks a download writes every 2 s).
  property string _listSig: ""
  // Download-job models seen in the last state, so a download that finishes
  // (its job vanishes) triggers refreshModels(): nothing else re-reads
  // `installed`, and the picker and settings would show it stale until the
  // Library was reopened.
  property var _dlModels: []
  function applyState(text) {
    try {
      var s = JSON.parse(text)
      var prevVersion = state ? state.version : -1
      state = s
      updateElapsed()
      if (s.version !== prevVersion) {
        var dl = State.downloadModels(s)
        if (State.downloadFinished(_dlModels, dl)) refreshModels()
        _dlModels = dl
        var sig = State.stateSig(s)
        if (State.relistNeeded(_listSig, sig, s.jobs)) {
          _listSig = sig
          refreshList()
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
    var proc = actionComponent.createObject(root, { command: [cli].concat(args), action: args, callback: onDone || null })
    proc.running = true
  }
  function startRecording(source) { run(["record", "start", "--source", source || defaultSource]) }
  // A keypress (the popup's r, the toggle) may be a stray one, so it asks
  // before ending a long take (--guard); the Stop button is deliberate and
  // stops at once, as a script's plain `record stop` does.
  function stopRecording(force) { run(force ? ["record", "stop"] : ["record", "stop", "--guard"]) }
  function toggleRecording() { recording ? stopRecording() : startRecording() }
  // download defaults to true. Every surface that offers Transcribe means "and
  // fetch the model if it is missing"; the popup passed no argument at all and
  // so failed with exit 3 where the Library downloaded and chained.
  function transcribe(id, model, language, download, chunkS, onDone) {
    var args = ["transcribe", id]
    if (model) args = args.concat(["--model", model])
    if (language) args = args.concat(["--language", language])
    if (chunkS) args = args.concat(["--chunk-s", String(chunkS)])
    if (download === undefined || download) args.push("--download")
    run(args, onDone)
  }
  function cancel(id) { run(["cancel", id]) }
  // A meta edit only bumps the state version; while an unrelated job runs the
  // signature is unchanged and applyState skips the list refresh, so the UI
  // would show the old value until the job ends. Refresh on success instead.
  function rename(id, title) { run(["rename", id, title], function(code) { if (code === 0) root.refreshList() }) }
  function setNote(id, text) { run(["note", id, text], function(code) { if (code === 0) root.refreshList() }) }
  function remove(id) { run(["delete", id, "--yes"]) }
  function download(model) { run(["model", "download", model]) }
  function cancelDownload(model) { run(["model", "cancel", model]) }
  function searchTranscripts(q, onDone) { run(["search", q], onDone) }
  // Imports in flight, by path, for the popup's "Importing…" line: converting
  // a long file takes a while with nothing else on screen to say so.
  property var importing: []
  function importFile(path) {
    importing = importing.concat([path])
    run(["import", path], function(code) {
      var left = root.importing.slice(), i = left.indexOf(path)
      if (i >= 0) left.splice(i, 1)
      root.importing = left
      if (code === 0) root.refreshList()
    })
  }
  function play(id) { run(["play", id]) }
  function playFrom(id, seconds) { run(["play", id, "--from", String(seconds)]) }
  function stopPlay() { run(["stop-play"]) }
  function trim(id, from, to) { run(["trim", id, "--from", String(from), "--to", String(to)]) }
  function restoreTrim(id) { run(["trim", id, "--restore"]) }
  function openTranscript(id) { Quickshell.execDetached([cli, "open", id]) }
  function openFolder(id) { Quickshell.execDetached([cli, "folder", id]) }
  // The CLI does the copy (argv only: no shell string is ever built from a title).
  function copyTranscript(id, raw, onDone) { run(raw ? ["copy", id, "--raw"] : ["copy", id], onDone) }
  // The CLI picks the vault/folder (config, then the open vault) and opens the note in Obsidian.
  function exportToObsidian(id, raw, onDone) { run(raw ? ["export", id, "--raw"] : ["export", id], onDone) }
  // onDone(code, out) lets a settings field show its own error in place.
  // Setup is re-checked too: whether it passes depends on the source and folder.
  function setConfig(key, value, onDone) {
    if (key === "defaultSource") { setSource(String(value)); return }
    run(["config", "set", key, String(value)], function(code, out) { root.refreshConfig(); root.refreshSetup(); if (onDone) onDone(code, out) })
  }
  // One source write at a time and the latest pick wins: two quick presses
  // ran two writes that could land in either order and save the other value.
  property bool _sourceWriting: false
  function setSource(v) { pendingSource = v; if (!_sourceWriting) _writeSource() }
  function _writeSource() {
    _sourceWriting = true
    var v = pendingSource
    run(["config", "set", "defaultSource", v], function(code) {
      root._sourceWriting = false
      var next = State.sourceWriteNext(root.pendingSource, v, code === 0)
      if (next === "write") { root._writeSource(); return }
      // Saved, so it is the config now. Waiting for a reload to match instead
      // could pin the pick forever if a change made elsewhere landed between.
      if (next === "done") root.config = Object.assign({}, root.config, { defaultSource: v })
      root.pendingSource = ""
      root.refreshConfig()
      // Setup passes without a microphone only for system audio, so a source
      // change can flip it either way; the cached answer would hide that.
      root.refreshSetup()
    })
  }
  // Dictionary actions run through the CLI like everything else; add/import
  // re-read the count so the settings row stays honest.
  function dictAdd(heard, written, onDone) { run(["dictionary", "add", heard, written], function(code, out) { if (code === 0) root.refreshDictionary(); if (onDone) onDone(code, out) }) }
  function dictEdit() { run(["dictionary", "edit"]) }
  function dictCopyPrompt(onDone) { run(["dictionary", "prompt", "--copy"], onDone) }
  function dictImportClipboard(onDone) { run(["dictionary", "import", "--clipboard"], function(code, out) { if (code === 0) root.refreshDictionary(); if (onDone) onDone(code, out) }) }
  // With an id the Library opens on that take; summon rather than toggle, so a
  // Library that is already open is not closed by it.
  function openLibrary(id) {
    if (id) Quickshell.execDetached(["omarchy-shell", "shell", "summon", pluginId, JSON.stringify({ id: String(id) })])
    else Quickshell.execDetached(["omarchy-shell", "shell", "toggle", pluginId])
  }

  // ---- plumbing ----
  property Component actionComponent: Component {
    Process {
      id: p
      property var callback: null
      property var action: []   // the CLI arguments, which name the action in the banner
      property bool done: false
      stdout: StdioCollector { id: aOut; waitForEnd: true }
      stderr: StdioCollector { id: aErr; waitForEnd: true }
      // A process that never starts sends no exited, so its callback never
      // ran and anything waiting on it (the "Importing…" line) stayed up for
      // good. Exited follows the end of a real run within milliseconds; two
      // seconds without it means the command never ran.
      property Timer startGuard: Timer {
        interval: 2000
        onTriggered: {
          if (p.done) return
          p.done = true
          root.setError(State.actionError(p.action, -1, "the omarecorder command could not be started", ""))
          if (p.callback) p.callback(-1, "")
          p.destroy()
        }
      }
      onRunningChanged: if (!running && !done) startGuard.restart()
      onExited: function(code) {
        p.done = true
        if (code !== 0) root.setError(State.actionError(p.action, code, aErr.text, aOut.text))
        else if (State.errorClears(root.lastErrorKey, State.actionError(p.action, 0, "", "").key)) root.clearError()
        if (callback) callback(code, aOut.text)
        p.destroy()
      }
    }
  }

  property FileView stateView: FileView {
    path: root.stateFile
    watchChanges: true
    blockLoading: false
    // Absent after a boot until the CLI first runs; onLoadFailed covers that,
    // so the warning it would print on every shell start is noise.
    printErrors: false
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

  // The resume offer's label ages ("stopped 12m ago") while nothing else
  // ticks, so a slow clock keeps `now` honest only while an offer is armed.
  property Timer resumeTimer: Timer {
    interval: 10000; repeat: true
    running: !!(root.lastStop && root.lastStop.resumable === true) && !root.recording
    onTriggered: root.updateElapsed()
  }

  // Every loader lands here. They used to parse inline behind an empty catch
  // with no stderr and no else, so a `list` that failed was indistinguishable
  // from an empty library: the Library drew "No recordings yet" and said
  // nothing. A read that fails now names itself in the error banner.
  function applyJson(what, code, text, errText, apply) {
    if (code !== 0) { root.setError(State.loadError(what, code, errText)); return false }
    try { apply(JSON.parse(text)) } catch (e) { root.setError(State.loadError(what, code, "", true)); return false }
    if (State.errorClears(root.lastErrorKey, "load:" + what)) root.clearError()
    return true
  }
  property Process listProc: Process {
    command: [root.cli, "list", "--json"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(code) { root.applyJson("list", code, listOut.text, listErr.text, function(v) { root.recordings = v }); root.loadAgain(root.listProc, "list") }
  }
  property Process modelsProc: Process {
    command: [root.cli, "models", "--json"]
    stdout: StdioCollector { id: modelsOut; waitForEnd: true }
    stderr: StdioCollector { id: modelsErr; waitForEnd: true }
    onExited: function(code) { root.applyJson("models", code, modelsOut.text, modelsErr.text, function(v) { root.models = v }); root.loadAgain(root.modelsProc, "models") }
  }
  property Process vaultsProc: Process {
    command: [root.cli, "vaults", "--json"]
    stdout: StdioCollector { id: vaultsOut; waitForEnd: true }
    stderr: StdioCollector { id: vaultsErr; waitForEnd: true }
    onExited: function(code) { root.applyJson("vaults", code, vaultsOut.text, vaultsErr.text, function(v) { root.vaults = v }); root.loadAgain(root.vaultsProc, "vaults") }
  }
  property Process dictProc: Process {
    command: [root.cli, "dictionary", "--json"]
    stdout: StdioCollector { id: dictOut; waitForEnd: true }
    stderr: StdioCollector { id: dictErr; waitForEnd: true }
    onExited: function(code) { root.applyJson("dictionary", code, dictOut.text, dictErr.text, function(v) { root.dictionary = v }); root.loadAgain(root.dictProc, "dictionary") }
  }
  property Process configProc: Process {
    command: [root.cli, "config", "get", "--json"]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(code) { root.applyJson("config", code, configOut.text, configErr.text, function(v) { root.config = v }); root.loadAgain(root.configProc, "config") }
  }
  property Process setupProc: Process {
    command: [root.cli, "setup", "check", "--json"]
    stdout: StdioCollector { id: setupOut; waitForEnd: true }
    stderr: StdioCollector { id: setupErr; waitForEnd: true }
    // setup check exits non-zero to mean "your setup is incomplete", which is
    // the SetupCard's whole subject and not an error to report: parse either way.
    onExited: function(code) {
      try { root.setup = JSON.parse(setupOut.text); if (State.errorClears(root.lastErrorKey, "load:setup")) root.clearError() }
      catch (e) { if (code !== 0) root.setError(State.loadError("setup", code, setupErr.text)) }
      root.refreshModels()
      root.loadAgain(root.setupProc, "setup")
    }
  }

  // `status` is the only command that notices a recorder or a worker that died
  // without saying so. Run it when a surface opens (refresh) and every 30 s while
  // something is recording or working. It has its own process rather than run(),
  // so it never touches lastError; a change it finds bumps state.json, and the
  // watcher above brings the views up to date.
  property Process statusProc: Process { command: [root.cli, "status"] }
  function reconcile() { if (!statusProc.running) statusProc.running = true }
  property Timer reconcileTimer: Timer { interval: 30000; repeat: true; running: root.recording || root.busy; onTriggered: root.reconcile() }

  Component.onCompleted: {
    if (!root.runtimeDir) { root.lastError = "XDG_RUNTIME_DIR is not set, so OmaRecorder cannot run"; return }
    // `status` reconciles stale state and creates the (0700) runtime dir and
    // state.json, so the FileView above has a real file to watch from the start.
    run(["status"], function() { root.stateView.reload(); root.refresh() })
  }
}
