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

// fitHints: which legend items fit the footer. Lowest priority goes first
// (the later one on a tie), kept items never go, order never changes.
function hint(width, priority, keep) { return { width: width, priority: priority, keep: !!keep } }
eq("fitHints everything fits", fitHints([hint(100, 1), hint(100, 2)], 10, 300), { shown: [0, 1], fits: true })
eq("fitHints counts the separators", fitHints([hint(100, 1), hint(100, 2)], 10, 209), { shown: [1], fits: true })
eq("fitHints drops the lowest priority and keeps order", fitHints([hint(100, 3), hint(100, 1), hint(100, 2)], 0, 200), { shown: [0, 2], fits: true })
eq("fitHints on a tie drops the later item", fitHints([hint(100, 2), hint(100, 2), hint(100, 2)], 0, 200), { shown: [0, 1], fits: true })
eq("fitHints never drops a kept item", fitHints([hint(100, 0, true), hint(100, 5)], 0, 150), { shown: [0], fits: true })
eq("fitHints drops as many as it takes", fitHints([hint(100, 1), hint(100, 2), hint(100, 3), hint(100, 4)], 10, 210), { shown: [2, 3], fits: true })
eq("fitHints says when even the kept items do not fit", fitHints([hint(300, 1, true), hint(100, 2)], 0, 200), { shown: [0], fits: false })
eq("fitHints with no width measured yet shows everything", fitHints([hint(100, 1), hint(100, 2)], 10, 0), { shown: [0, 1], fits: true })
eq("fitHints empty list", fitHints([], 10, 100), { shown: [], fits: true })

// ctrlHintAction: what a key event does to the hold-Ctrl badges. A held key
// auto-repeats as release+press pairs flagged isAutoRepeat; reacting to those
// stopped the reveal timer every time, so the badges never appeared.
eq("ctrlHintAction first Ctrl press starts the reveal", ctrlHintAction("press", true, false), "start")
eq("ctrlHintAction auto-repeat Ctrl release is ignored", ctrlHintAction("release", true, true), "none")
eq("ctrlHintAction auto-repeat Ctrl press is ignored", ctrlHintAction("press", true, true), "none")
eq("ctrlHintAction letting go of Ctrl hides", ctrlHintAction("release", true, false), "hide")
eq("ctrlHintAction another key hides (a chord is under way)", ctrlHintAction("press", false, false), "hide")
eq("ctrlHintAction another key's release does nothing", ctrlHintAction("release", false, false), "none")
eq("ctrlHintAction another key's auto-repeat does nothing", ctrlHintAction("press", false, true), "none")

// cycleValue: a one-key picker (the popup's source key) steps through a fixed
// list and wraps at both ends; an unknown current value starts from the ends.
eq("cycleValue forward", cycleValue(["mic", "system", "both"], "mic", 1), "system")
eq("cycleValue forward wraps", cycleValue(["mic", "system", "both"], "both", 1), "mic")
eq("cycleValue backward", cycleValue(["mic", "system", "both"], "system", -1), "mic")
eq("cycleValue backward wraps", cycleValue(["mic", "system", "both"], "mic", -1), "both")
eq("cycleValue unknown current, forward, takes the first", cycleValue(["mic", "system", "both"], "gone", 1), "mic")
eq("cycleValue unknown current, backward, takes the last", cycleValue(["mic", "system", "both"], "gone", -1), "both")
eq("cycleValue empty list", cycleValue([], "mic", 1), "mic")

// actionError: what a failed CLI action puts in the error banner. The CLI's
// "omarecorder: " prefix goes, the action is named, and the key says which
// action owns the message (only that action's next success clears it).
eq("actionError names the action and drops the prefix", actionError(["import", "/x.m4a"], 1, "omarecorder: file not found: /x.m4a\n", ""),
   { key: "import", text: "Import failed: file not found: /x.m4a" })
eq("actionError strips the prefix on every line", actionError(["rename", "id", "t"], 1, "omarecorder: one\nomarecorder: two", "").text, "Rename failed: one\ntwo")
eq("actionError falls back to stdout", actionError(["trim", "id"], 1, "", "omarecorder: bad range").text, "Trim failed: bad range")
eq("actionError falls back to the exit code", actionError(["delete", "id"], 3, "", "").text, "Delete failed: exit 3")
eq("actionError tells a download from a cancel", actionError(["model", "cancel", "small.en"], 1, "omarecorder: nope", "").text, "Cancel download failed: nope")
eq("actionError model download", actionError(["model", "download", "small.en"], 1, "omarecorder: download already running", "").text, "Model download failed: download already running")
eq("actionError an unknown action keeps the message plain", actionError(["frobnicate"], 1, "omarecorder: huh", ""), { key: "frobnicate", text: "huh" })
eq("actionError no args", actionError([], 1, "boom", "").key, "")
// loadError: a loader (list, models, config...) that fails names itself.
eq("loadError names the loader", loadError("list", 1, "omarecorder: jq: error\n"), { key: "load:list", text: "Loading the recordings failed: jq: error" })
eq("loadError unknown loader keeps its name", loadError("widgets", 2, ""), { key: "load:widgets", text: "Loading widgets failed: exit 2" })
eq("loadError unreadable output", loadError("config", 0, "", true), { key: "load:config", text: "Loading the settings failed: output this build cannot read" })
// Keys are as fine as the commands: a setting by its name, subcommands apart.
eq("actionError keys a setting by its name", actionError(["config", "set", "recordingsDir", "/x"], 1, "e", "").key, "config set recordingsDir")
eq("actionError keys model download and cancel apart",
   [actionError(["model", "download", "a"], 1, "", "").key, actionError(["model", "cancel", "a"], 1, "", "").key], ["model download", "model cancel"])
eq("actionError keys record start and stop apart", actionError(["record", "stop"], 1, "", "").key, "record stop")
eq("errorClears a different setting leaves it",
   errorClears(actionError(["config", "set", "recordingsDir", "/x"], 1, "", "").key, actionError(["config", "set", "defaultSource", "mic"], 0, "", "").key), false)
// errorClears: only a success of the action that failed clears its message.
eq("errorClears same action", errorClears("import", "import"), true)
eq("errorClears another action leaves it", errorClears("import", "rename"), false)
eq("errorClears nothing showing", errorClears("", "rename"), false)

// downloadPercent: a download job's progress for a label; -1 when unknown.
eq("downloadPercent halfway", downloadPercent({ bytes_done: 50, expected_bytes: 100 }), 50)
eq("downloadPercent rounds", downloadPercent({ bytes_done: 1, expected_bytes: 3 }), 33)
eq("downloadPercent never claims 100 before the job ends", downloadPercent({ bytes_done: 120, expected_bytes: 100 }), 99)
eq("downloadPercent no bytes yet", downloadPercent({ expected_bytes: 100 }), 0)
eq("downloadPercent unknown size", downloadPercent({ bytes_done: 5 }), -1)
eq("downloadPercent no job", downloadPercent(null), -1)

// englishOnly: whisper's .en models understand English and nothing else.
eq("englishOnly base.en", englishOnly("base.en"), true)
eq("englishOnly large-v3-turbo", englishOnly("large-v3-turbo"), false)
eq("englishOnly empty", englishOnly(""), false)
// languageMismatch: an English-only model with any language but English (auto included).
eq("languageMismatch en model, de", languageMismatch("small.en", "de"), true)
eq("languageMismatch en model, auto", languageMismatch("small.en", "auto"), true)
eq("languageMismatch en model, en", languageMismatch("small.en", "en"), false)
eq("languageMismatch en model, unset language means en", languageMismatch("small.en", ""), false)
eq("languageMismatch multilingual model, de", languageMismatch("large-v3-turbo", "de"), false)

console.log("state.js: passed " + passed + "  failed " + failed)
if (failed > 0) process.exit(1)
