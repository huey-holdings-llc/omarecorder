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

// Title, id and date match instantly; transcript hits (matchIds) arrive later
// from the CLI and only count when they answer the query as typed now.
function filterRows(all, filterText, matchIds, matchQuery) {
  all = all || []
  var trimmed = (filterText || "").trim()
  var q = trimmed.toLowerCase()
  if (!q) return all
  var inText = (matchQuery === trimmed && matchIds) ? matchIds : []
  var out = []
  for (var i = 0; i < all.length; i++) {
    var r = all[i]
    var hay = ((r.title || "") + " " + (r.id || "") + " " + (r.created || "")).toLowerCase()
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
