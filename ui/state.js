// Pure decisions shared by Service.qml and Library.qml: when a state.json
// change is worth a re-list, which rows a filter keeps, where the selection
// lands. No Qt here, so tests/state.test.js runs the file under node.
.pragma library

// ---- Service.qml: what a state change has to touch to matter ----

// Which state changes actually need a re-list or a setup re-check: not the
// bytes_done ticks a download writes every 2 s. Job shape + per-piece
// progress + the live recording id cover everything the list renders.
function stateSig(s) {
  var jobs = (s.jobs || []).map(function(j) { return [j.type, j.id || j.model, j.unit, j.progress ? j.progress.chunk : 0].join(":") })
  return jobs.join("|") + "//" + (s.recording ? s.recording.id : "")
}

// A changed signature always re-lists. An unchanged one still does when no
// job is running: a version bump with no jobs is a mutation such as rename,
// delete or notes, which the signature cannot see.
function relistNeeded(prevSig, sig, jobs) {
  return sig !== prevSig || !jobs || jobs.length === 0
}

// Download-job models in a state, and whether one from the previous state
// vanished: a finished download is the only thing that changes `installed`,
// and nothing else re-reads it.
function downloadModels(s) {
  return (s.jobs || []).filter(function(j) { return j.type === "download" }).map(function(j) { return j.model })
}
function downloadFinished(prevModels, models) {
  for (var i = 0; i < prevModels.length; i++) if (models.indexOf(prevModels[i]) < 0) return true
  return false
}

// ---- Library.qml: the filtered list and the selection in it ----

// Title, note, id and date match instantly; transcript hits (matchIds) arrive
// later from the CLI and only count when they answer the query as typed now.
function filterRows(all, filterText, matchIds, matchQuery) {
  all = all || []
  var trimmed = (filterText || "").trim()
  var q = trimmed.toLowerCase()
  if (!q) return all
  var inText = (matchQuery === trimmed && matchIds) ? matchIds : []
  var out = []
  for (var i = 0; i < all.length; i++) {
    var r = all[i]
    var hay = ((r.title || "") + " " + (r.notes || "") + " " + (r.id || "") + " " + (r.created || "")).toLowerCase()
    if (hay.indexOf(q) !== -1 || inText.indexOf(r.id) !== -1) out.push(r)
  }
  return out
}

function indexOfId(rows, id) {
  rows = rows || []
  for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return i
  return -1
}

// Arrow keys wrap around the list. With nothing selected, down lands on the
// first row and up on the last. -1 on an empty list.
function stepIndex(current, delta, length) {
  if (length <= 0) return -1
  if (current < 0) return delta < 0 ? length - 1 : 0
  return (current + delta + length) % length
}

// An absolute pick stays inside the list; -1 on an empty list.
function clampIndex(i, length) {
  if (length <= 0) return -1
  return Math.max(0, Math.min(i, length - 1))
}

// The caller's id wins, else the newest row (the list is newest first), else nothing.
function initialSelection(requestedId, rows) {
  if (requestedId) return requestedId
  return rows && rows.length > 0 ? rows[0].id : ""
}

// ---- Library.qml: the key legend ----

// Which legend items fit a footer `avail` wide. Items are { width, priority,
// keep }, with one separator between neighbours. The lowest priority goes
// first (the later one on a tie), kept items never go, and the order never
// changes. `fits` is false when even the kept items overflow, so the footer
// can wrap instead of clipping. An unmeasured footer (avail <= 0) shows all.
function fitHints(items, sepWidth, avail) {
  items = items || []
  var shown = []
  for (var i = 0; i < items.length; i++) shown.push(i)
  if (!(avail > 0)) return { shown: shown, fits: true }
  function total() {
    var w = 0
    for (var k = 0; k < shown.length; k++) w += items[shown[k]].width
    return w + Math.max(0, shown.length - 1) * sepWidth
  }
  while (total() > avail) {
    var drop = -1
    for (var j = 0; j < shown.length; j++) {
      var it = items[shown[j]]
      if (it.keep) continue
      if (drop < 0 || it.priority <= items[shown[drop]].priority) drop = j
    }
    if (drop < 0) return { shown: shown, fits: false }
    shown.splice(drop, 1)
  }
  return { shown: shown, fits: true }
}

// What a key event does to the Library's hold-Ctrl badges: "start" the
// reveal timer, "hide" them, or "none". A held key auto-repeats as
// release+press pairs flagged isAutoRepeat; those must change nothing, or
// the first repeat stops the timer and the badges never appear.
function ctrlHintAction(type, isCtrl, isAutoRepeat) {
  if (isAutoRepeat) return "none"
  if (isCtrl) return type === "press" ? "start" : "hide"
  return type === "press" ? "hide" : "none"
}

// One key stepping through a fixed list (the popup's source key): wraps at
// both ends, and an unknown current value starts from the matching end.
function cycleValue(values, current, dir) {
  if (!values || values.length === 0) return current
  var i = values.indexOf(current)
  if (i < 0) return dir < 0 ? values[values.length - 1] : values[0]
  return values[(i + dir + values.length) % values.length]
}

// The error banner. A failed action names itself and loses the CLI's
// "omarecorder: " prefix; its key says which action owns the message, so an
// unrelated success no longer wipes it before anyone has read it.
var ACTION_NAMES = {
  record: "Recording", "import": "Import", transcribe: "Transcription", cancel: "Cancel",
  rename: "Rename", note: "Note", "delete": "Delete", model: "Model download",
  play: "Playback", "stop-play": "Playback", trim: "Trim", copy: "Copy",
  "export": "Send to Obsidian", config: "Setting", search: "Search",
  dictionary: "Dictionary", tidy: "Tidy"
}
var LOADER_NAMES = {
  list: "the recordings", models: "the models", config: "the settings",
  vaults: "the Obsidian vaults", dictionary: "the dictionary", setup: "the setup check"
}
function cleanCliText(text) {
  return String(text).trim().split("\n").map(function(l) { return l.replace(/^omarecorder: /, "") }).join("\n")
}
// As fine as the commands: a setting by its name, subcommands apart, so a
// successful `c` (config set defaultSource) cannot clear a failed folder change.
function actionKey(args) {
  if (!args || !args.length) return ""
  var a = String(args[0])
  if (a === "config" && args[1] === "set" && args.length > 2) return "config set " + args[2]
  if ((a === "model" || a === "dictionary" || a === "record") && args.length > 1) return a + " " + args[1]
  return a
}
function actionError(args, code, errText, outText) {
  var key = actionKey(args)
  var msg = cleanCliText(errText || outText || ("exit " + code))
  var verb = args && args.length ? String(args[0]) : ""
  var name = ACTION_NAMES.hasOwnProperty(verb) ? ACTION_NAMES[verb] : ""
  if (verb === "model" && args[1] === "cancel") name = "Cancel download"
  return { key: key, text: name ? name + " failed: " + msg : msg }
}
function loadError(what, code, errText, unreadable) {
  var name = LOADER_NAMES.hasOwnProperty(what) ? LOADER_NAMES[what] : what
  var msg = unreadable ? "output this build cannot read" : cleanCliText(errText || ("exit " + code))
  return { key: "load:" + what, text: "Loading " + name + " failed: " + msg }
}
function errorClears(errorKey, successKey) { return !!errorKey && errorKey === successKey }

// The popup's line while imports run: the first file by name, then a count.
// A long file converts for a while with nothing else on screen to say so.
function importingText(paths) {
  if (!paths || paths.length === 0) return ""
  var name = String(paths[0]).replace(/^.*\//, "")
  return "Importing " + name + (paths.length > 1 ? " and " + (paths.length - 1) + " more" : "") + "…"
}

// Whether `export` will open Obsidian, by the CLI's own order: a configured
// vault first (it opens even if the registry list has not loaded), then a
// configured exportDir (never opens), then the registry's first vault, else
// the note sits next to the recording. The Library closes only when a window
// is about to open under it.
function exportOpensObsidian(config, vaultCount) {
  if (config && config.obsidianVault) return true
  if (config && config.exportDir) return false
  return (vaultCount || 0) > 0
}

// After a source write finishes: "write" the newer pick if one is waiting
// (whether this write worked or not: a failed older write used to drop it),
// else "done" when it was saved or "drop" when it failed.
function sourceWriteNext(pending, written, ok) {
  if (pending !== written) return "write"
  return ok ? "done" : "drop"
}

// A download job's progress for a label, capped at 99 until the job is gone
// (the file can outgrow the catalog size); -1 when there is nothing to show.
function downloadPercent(job) {
  if (!job || !job.expected_bytes) return -1
  return Math.min(99, Math.round(100 * (job.bytes_done || 0) / job.expected_bytes))
}

// whisper's .en models (Fast, Balanced) understand English and nothing else;
// asking them for another language, or to detect one, gets an English guess.
function englishOnly(model) { return /\.en$/.test(String(model || "")) }
function languageMismatch(model, language) { return englishOnly(model) && !!language && language !== "en" }
