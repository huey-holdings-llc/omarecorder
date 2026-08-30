#!/usr/bin/env bash
# Static checks that need no audio, no voxtype and no shell: run in CI and before a release.
#   bash tests/lint.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE" || exit 1
fail=0
step() { printf '== %s\n' "$1"; }
bad() { echo "  ✗ $1"; fail=1; }
ok() { echo "  ✓ $1"; }

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
command -v omarchy-plugin-validate >/dev/null && { omarchy-plugin-validate . >/dev/null && ok "omarchy-plugin-validate" || bad "omarchy-plugin-validate"; }

step "QML hygiene"
if grep -nE '"bash", *"-c"|"sh", *"-c"|bash -c' -- *.qml ui/*.qml; then bad "shell strings built in QML"; else ok "no shell strings in QML"; fi
if grep -nE '"/tmp' -- *.qml ui/*.qml bin/omarecorder; then bad "/tmp referenced"; else ok "no /tmp paths"; fi
for f in *.qml ui/*.qml; do [[ -s "$f" ]] || bad "$f empty"; done
if command -v qmllint >/dev/null; then qmllint --version >/dev/null 2>&1 && ok "qmllint available (imports need the shell; not run)"; fi

step "docs"
grep -q '## Remove' README.md && ok "README has a Remove section" || bad "README lacks Remove"
grep -q '## Update' README.md && ok "README has an Update section" || bad "README lacks Update"
grep -q 'omarchy plugin add' README.md && ok "README has the install command" || bad "README lacks install command"
[[ -f LICENSE && -f preview.png ]] && ok "LICENSE and preview.png present" || bad "LICENSE/preview.png"

echo; [[ $fail == 0 ]] && echo "lint: ok" || { echo "lint: FAILED"; exit 1; }
