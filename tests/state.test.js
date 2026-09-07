// Unit tests for ui/state.js, run under node by tests/lint.sh:
//   { sed '/^\.pragma/d' ui/state.js; cat tests/state.test.js; } | node -
// state.js has no Qt dependency: it is the pure half of what Service.qml and
// Library.qml decide (when to re-list, which rows a filter keeps, where the
// selection lands). Keep the JS ES5-flavoured so node and Qt's engine agree.

var failed = 0, passed = 0
function eq(desc, got, want) {
  var g = JSON.stringify(got), w = JSON.stringify(want)
  if (g === w) { passed++ }
  else { failed++; console.log("  ✗ " + desc + "\n      got " + g + " expected " + w) }
}

// stateSig: what a state.json change has to touch to be worth a re-list.
var tx = { type: "transcribe", id: "2026-09-07_120000", unit: "omarecorder-tx-1", progress: { chunk: 2, of: 5, bytes_done: 100 } }
var dl = { type: "download", model: "small.en", bytes_done: 5000 }
eq("stateSig empty state", stateSig({}), "//")
eq("stateSig no jobs, live recording", stateSig({ recording: { id: "r1" } }), "//r1")
eq("stateSig one transcribe job", stateSig({ jobs: [tx] }), "transcribe:2026-09-07_120000:omarecorder-tx-1:2//")
eq("stateSig download job keys on its model", stateSig({ jobs: [dl] }), "download:small.en::0//")
eq("stateSig joins jobs with |", stateSig({ jobs: [tx, dl], recording: { id: "r1" } }), "transcribe:2026-09-07_120000:omarecorder-tx-1:2|download:small.en::0//r1")
eq("stateSig ignores bytes_done ticks", stateSig({ jobs: [Object.assign({}, dl, { bytes_done: 9000 })] }), stateSig({ jobs: [dl] }))
eq("stateSig changes when a chunk finishes", stateSig({ jobs: [Object.assign({}, tx, { progress: { chunk: 3 } })] }) !== stateSig({ jobs: [tx] }), true)

// relistNeeded: a changed signature always re-lists; an unchanged one still does when no job is running (rename, delete, notes).
eq("relistNeeded sig changed", relistNeeded("a//", "b//", [tx]), true)
eq("relistNeeded same sig with a job running", relistNeeded("a//", "a//", [tx]), false)
eq("relistNeeded same sig, no jobs", relistNeeded("//", "//", []), true)
eq("relistNeeded same sig, jobs missing", relistNeeded("//", "//", undefined), true)

// downloadModels / downloadFinished: a vanished download job means `installed` changed.
eq("downloadModels none", downloadModels({}), [])
eq("downloadModels picks download jobs only", downloadModels({ jobs: [tx, dl] }), ["small.en"])
eq("downloadFinished nothing before", downloadFinished([], ["small.en"]), false)
eq("downloadFinished still running", downloadFinished(["small.en"], ["small.en"]), false)
eq("downloadFinished vanished", downloadFinished(["small.en"], []), true)
eq("downloadFinished one of two vanished", downloadFinished(["small.en", "base.en"], ["base.en"]), true)

// filterRows: title, id and date match instantly; transcript hits only when they answer the current query.
var rows = [
  { id: "2026-09-07_120000", title: "Sons of Suds session 10", created: "2026-09-07T12:00:00-0400" },
  { id: "2026-09-01_090000", title: "Standup", created: "2026-09-01T09:00:00-0400" },
  { id: "2026-08-29_190000", title: "", created: "2026-08-29T19:00:00-0400" }
]
function ids(rs) { return rs.map(function(r) { return r.id }) }
eq("filterRows empty query returns everything", filterRows(rows, "", [], ""), rows)
eq("filterRows whitespace query returns everything", filterRows(rows, "   ", [], ""), rows)
eq("filterRows title, case-insensitive", ids(filterRows(rows, "SUDS", [], "")), ["2026-09-07_120000"])
eq("filterRows id fragment", ids(filterRows(rows, "08-29", [], "")), ["2026-08-29_190000"])
eq("filterRows date fragment", ids(filterRows(rows, "2026-09", [], "")), ["2026-09-07_120000", "2026-09-01_090000"])
eq("filterRows trims the query", ids(filterRows(rows, "  standup ", [], "")), ["2026-09-01_090000"])
eq("filterRows transcript hits count when the query matches", ids(filterRows(rows, "goblin", ["2026-08-29_190000"], "goblin")), ["2026-08-29_190000"])
eq("filterRows stale transcript hits are ignored", filterRows(rows, "goblin", ["2026-08-29_190000"], "gob"), [])
eq("filterRows transcript hits for a trimmed query", filterRows(rows, " goblin ", ["2026-08-29_190000"], "goblin").length, 1)
eq("filterRows keeps list order", ids(filterRows(rows, "2026", [], "")), ids(rows))
eq("filterRows null rows", filterRows(null, "x", [], ""), [])
eq("filterRows null rows, empty query", filterRows(null, "", [], ""), [])
eq("filterRows null hit list", filterRows(rows, "goblin", null, "goblin"), [])

// indexOfId
eq("indexOfId found", indexOfId(rows, "2026-09-01_090000"), 1)
eq("indexOfId missing", indexOfId(rows, "nope"), -1)
eq("indexOfId empty id", indexOfId(rows, ""), -1)
eq("indexOfId null rows", indexOfId(null, "x"), -1)

// stepIndex: arrow keys wrap; with nothing selected, down lands on the first row and up on the last.
eq("stepIndex down", stepIndex(0, 1, 3), 1)
eq("stepIndex up", stepIndex(1, -1, 3), 0)
eq("stepIndex wraps past the end", stepIndex(2, 1, 3), 0)
eq("stepIndex wraps before the start", stepIndex(0, -1, 3), 2)
eq("stepIndex none selected, down", stepIndex(-1, 1, 3), 0)
eq("stepIndex none selected, up", stepIndex(-1, -1, 3), 2)
eq("stepIndex empty list", stepIndex(-1, 1, 0), -1)
eq("stepIndex single row", stepIndex(0, 1, 1), 0)

// clampIndex: an absolute pick stays inside the list (delete selects the row above).
eq("clampIndex inside", clampIndex(1, 3), 1)
eq("clampIndex below zero", clampIndex(-4, 3), 0)
eq("clampIndex past the end", clampIndex(9, 3), 2)
eq("clampIndex empty list", clampIndex(0, 0), -1)

// initialSelection: the caller's id wins, else the newest row, else nothing.
eq("initialSelection requested", initialSelection("r9", rows), "r9")
eq("initialSelection newest", initialSelection("", rows), "2026-09-07_120000")
eq("initialSelection empty list", initialSelection("", []), "")
eq("initialSelection null rows", initialSelection(null, null), "")

console.log("state.js: passed " + passed + "  failed " + failed)
if (failed > 0) process.exit(1)
