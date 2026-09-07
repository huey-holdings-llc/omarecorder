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
