#!/usr/bin/env bash
# Static checks that need no audio, no voxtype and no shell: run in CI and before a release.
#   bash tests/lint.sh
# Two checks need what only a dev machine has and say so when they cannot run:
# qmllint needs the omarchy shell's QML modules, the format.js tests need node.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE" || exit 1
fail=0
step() { printf '== %s\n' "$1"; }
bad() { echo "  ✗ $1"; fail=1; }
ok() { echo "  ✓ $1"; }
skipped() { echo "  - skipped: $1"; }

step "shellcheck"
if shellcheck -S warning bin/omarecorder scripts/*.sh tests/*.sh; then ok "clean"; else bad "shellcheck findings"; fi

step "manifest.json"
m=manifest.json
jq -e '.schemaVersion == 1' "$m" >/dev/null && ok "schemaVersion is the number 1" || bad "schemaVersion must be the number 1"
jq -e '.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (startswith("omarchy.") | not)' "$m" >/dev/null && ok "id well-formed" || bad "id"
jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$m" >/dev/null && ok "version is semver" || bad "version"
for k in name author license description homepage; do jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' "$m" >/dev/null && ok "$k present" || bad "$k missing"; done
for kind in $(jq -r '.kinds[]' "$m"); do
  case "$kind" in bar-widget) key=barWidget ;; *) key=$kind ;; esac
  ep=$(jq -r --arg k "$key" '.entryPoints[$k] // empty' "$m")
  [[ -n "$ep" && -f "$ep" ]] && ok "entry point for $kind: $ep" || bad "entry point for $kind missing or absent on disk"
done
[[ "$(jq -r .version "$m")" == "$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | tr -d '[]# ')" ]] && ok "CHANGELOG top release matches manifest version" || bad "CHANGELOG top release != manifest version"
if find . -path ./.git -prune -o -type l -print | grep -q .; then bad "symlinks in the plugin tree (validator rejects them)"; else ok "no symlinks"; fi
if command -v omarchy-plugin-validate >/dev/null; then
  omarchy-plugin-validate . >/dev/null && ok "omarchy-plugin-validate" || bad "omarchy-plugin-validate"
else skipped "omarchy-plugin-validate (not installed)"; fi

step "CLI"
# Every command the dispatcher knows is in the help text, so the README/help table cannot drift.
missing=""
for c in $(sed -n '/^main()/,/^}/p' bin/omarecorder | grep -oE '^\s+[a-z][a-z-]*\)' | tr -d ' )'); do
  bin/omarecorder help | grep -qwF -- "$c" || missing="$missing $c"
done
[[ -z "$missing" ]] && ok "every dispatcher command appears in help" || bad "commands missing from help:$missing"

step "QML hygiene"
QML=(*.qml ui/*.qml)
if grep -nE '"bash", *"-c"|"sh", *"-c"|bash -c' -- "${QML[@]}"; then bad "shell strings built in QML"; else ok "no shell strings in QML"; fi
if grep -nE '(^|[^A-Za-z])/tmp(/|\b)' -- "${QML[@]}" bin/omarecorder | grep -vE '^[^:]+:[0-9]+:\s*(#|//)'; then bad "/tmp referenced"; else ok "no /tmp paths (comments aside)"; fi
for f in "${QML[@]}"; do [[ -s "$f" ]] || bad "$f empty"; done
# User strings render as plain text: the hardening pass set PlainText everywhere and nothing may undo it.
if grep -nE 'textFormat: *(Text|TextEdit)\.(RichText|StyledText|AutoText)' -- "${QML[@]}"; then bad "rich text format on a Text element"; else ok "no RichText/StyledText/AutoText"; fi
# Theme tokens only (Color.*, Style.*): no colour literals, no hand-picked pixel sizes.
if grep -nE '"#[0-9a-fA-F]{3,8}"|Qt\.rgba\(' -- "${QML[@]}"; then bad "colour literal in QML (use Color.* tokens)"; else ok "no colour literals"; fi
# Commands are argv arrays; a string here would be a shell line.
if grep -nE 'command: *"|execDetached\("' -- "${QML[@]}"; then bad "command given as a string, not an argv array"; else ok "commands are argv arrays"; fi
if grep -nE 'console\.' -- "${QML[@]}" ui/*.js; then bad "console.* left in"; else ok "no console output left in"; fi
# Field contract: every JSON key the QML reads off a recording, job, model or
# transcript exists in the CLI, so a rename there cannot silently blank a label.
missing=""
for k in $(grep -ohE '\b(rec|r|selected|modelData|j|m)\.[a-z_]+(\.[a-z_]+){0,2}' -- "${QML[@]}" | cut -d. -f2- | tr '.' '\n' | sort -u); do
  case "$k" in length|indexOf|map|filter|some|find|push|join|toString|trim|replace|slice|split|toLowerCase|concat) continue ;; esac
  grep -qE "(^|[^A-Za-z_])$k([^A-Za-z_]|$)" bin/omarecorder || missing="$missing $k"
done
[[ -z "$missing" ]] && ok "every field the QML reads exists in the CLI" || bad "fields read by QML but absent from the CLI:$missing"
# qmllint, with the shell's own modules registered. Three classes are noise here
# and disabled: missing-property (the shell's Style/Color token groups are untyped
# QtObjects), signal-handler-parameters (onExited(code) drops exitStatus on
# purpose), uncreatable-type (PanelWindow is a Quickshell interface type).
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"; command -v "$QMLLINT" >/dev/null 2>&1 || QMLLINT=$(command -v qmllint || true)
SHELLQML=/usr/share/omarchy/shell
if [[ -n "$QMLLINT" && -f "$SHELLQML/Commons/qmldir" && -f "$SHELLQML/Ui/qmldir" ]]; then
  if "$QMLLINT" -i "$SHELLQML/Commons/qmldir" -i "$SHELLQML/Ui/qmldir" \
       --missing-property disable --signal-handler-parameters disable --uncreatable-type disable "${QML[@]}"; then ok "qmllint clean"; else bad "qmllint findings"; fi
else skipped "qmllint (needs the omarchy shell's QML modules)"; fi

step "format.js"
# The only Qt call in format.js is Qt.formatDateTime with one format; a stub
# stands in so the pure functions run under node. Dates are checked in UTC.
if command -v node >/dev/null; then
  QT_STUB='var Qt = { formatDateTime: function(d, f) { var M = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]; function p(n) { return (n < 10 ? "0" : "") + n } return M[d.getMonth()] + " " + d.getDate() + ", " + p(d.getHours()) + ":" + p(d.getMinutes()) } }'
  if out=$({ printf '%s\n' "$QT_STUB"; sed '/^\.pragma/d' ui/format.js; cat tests/format.test.js; } | TZ=UTC node - 2>&1); then ok "$out"; else printf '%s\n' "$out"; bad "format.js tests"; fi
else skipped "format.js tests (need node)"; fi

step "docs"
grep -q '## Remove' README.md && ok "README has a Remove section" || bad "README lacks Remove"
grep -q '## Update' README.md && ok "README has an Update section" || bad "README lacks Update"
grep -q 'omarchy plugin add' README.md && ok "README has the install command" || bad "README lacks install command"
[[ -f LICENSE && -f preview.png ]] && ok "LICENSE and preview.png present" || bad "LICENSE/preview.png"

echo; [[ $fail == 0 ]] && echo "lint: ok" || { echo "lint: FAILED"; exit 1; }
