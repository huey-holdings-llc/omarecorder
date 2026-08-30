#!/usr/bin/env bash
# CLI tests for omarecorder. Runs against a throwaway XDG tree; uses the real
# voxtype + base.en model if present (transcription tests are skipped otherwise).
#   bash tests/cli.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/omarecorder"
TMP="$HERE/tmp/$$"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Keep PipeWire/Pulse reachable while XDG_RUNTIME_DIR points at the sandbox.
REAL_RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PIPEWIRE_RUNTIME_DIR="$REAL_RUNTIME" PULSE_SERVER="unix:$REAL_RUNTIME/pulse/native"
export OMARECORDER_DIR="$TMP/Recordings" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$TMP/run"
export OMARECORDER_QUIET=1 OMARECORDER_SYNC=1
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "      $2"; }
check() { # check <desc> <cmd...>  — passes when command exits 0
  local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "cmd: $*"; fi
}
eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got '$2' expected '$3'"; }

# Fixtures: short speech clip (ships with alsa-utils) and a 12 s version of it
SPEECH=/usr/share/sounds/alsa/Front_Right.wav
if [[ -f "$SPEECH" ]]; then
  ffmpeg -v error -y -i "$SPEECH" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/speech.wav"
  ffmpeg -v error -y -stream_loop 7 -i "$TMP/speech.wav" -c copy "$TMP/speech12.wav"
fi
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -ar 48000 -ac 2 "$TMP/tone48.wav"
touch -d "2026-01-02 03:04:05" "$TMP/tone48.wav"
touch -d "2026-01-03 03:04:05" "$TMP/speech.wav" 2>/dev/null

echo "== basics"
eq "version" "$($CLI version)" "0.1.0"
check "help exits 0" "$CLI" help
eq "config default source" "$($CLI config get defaultSource)" "mic"
check "config set" "$CLI" config set defaultSource both
eq "config persisted" "$($CLI config get defaultSource)" "both"
check "config rejects bad value" bash -c "! $CLI config set defaultSource bogus"
$CLI config set defaultSource mic >/dev/null
eq "status idle" "$($CLI status)" "idle"
eq "status --json shape" "$($CLI status --json | jq -c '[.recording, (.jobs|length)]')" "[null,0]"

echo "== import"
ID1=$($CLI import "$TMP/tone48.wav" --title "Tone Test")
eq "import id from mtime" "$ID1" "2026-01-02_030405"
D1="$OMARECORDER_DIR/$ID1 Tone Test"
check "folder named id + title" test -d "$D1"
eq "audio converted to 16k mono s16" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$D1/audio.wav")" "pcm_s16le,16000,1"
eq "meta duration" "$(jq -r .duration_s "$D1/meta.json")" "3"
eq "meta title" "$(jq -r .title "$D1/meta.json")" "Tone Test"
eq "meta source" "$(jq -r .source "$D1/meta.json")" "import"
V1=$(jq -r .version "$XDG_RUNTIME_DIR/omarecorder/state.json")
if [[ -f "$TMP/speech.wav" ]]; then
  ID2=$($CLI import "$TMP/speech.wav"); eq "second import id" "$ID2" "2026-01-03_030405"
  eq "title defaults to filename" "$(jq -r .title "$OMARECORDER_DIR/$ID2 speech/meta.json")" "speech"
fi

echo "== list / show"
eq "list newest first" "$($CLI list --json | jq -r '.[0].id')" "${ID2:-$ID1}"
eq "list has_transcript false" "$($CLI list --json | jq -r '.[-1].has_transcript')" "false"
eq "show --json dir" "$($CLI show "$ID1" --json | jq -r .dir)" "$D1"
check "show unknown id fails" bash -c "! $CLI show 2000-01-01_000000"

echo "== rename"
$CLI rename "$ID1" "Renamed / Title  here" >/dev/null
D1B="$OMARECORDER_DIR/$ID1 Renamed - Title here"
check "folder renamed (sanitized)" test -d "$D1B"
check "old folder gone" bash -c "! test -d '$D1'"
eq "id stable after rename" "$($CLI show "$ID1" --json | jq -r .id)" "$ID1"
eq "meta title updated" "$(jq -r .title "$D1B/meta.json")" "Renamed - Title here"
V2=$(jq -r .version "$XDG_RUNTIME_DIR/omarecorder/state.json")
check "state version bumped by mutations" test "$V2" -gt "$V1"

echo "== models / estimate"
check "models --json lists base.en" bash -c "$CLI models --json | jq -e '.[] | select(.name==\"base.en\")'"
eq "estimate uses default rtf" "$($CLI estimate "$ID1" --model base.en | jq -r '.rtf, .source' | paste -sd,)" "10,default"

echo "== transcribe"
if command -v voxtype >/dev/null && [[ -f "$HOME/.local/share/voxtype/models/ggml-base.en.bin" && -f "$TMP/speech12.wav" ]]; then
  ID3=$($CLI import "$TMP/speech12.wav" --title "Speech 12s")
  D3="$OMARECORDER_DIR/$ID3 Speech 12s"
  eq "12 s fixture duration" "$(jq -r .duration_s "$D3/meta.json")" "12"
  ( VOXTYPE_MODELS_DIR="$TMP/nomodels" "$CLI" transcribe "$ID3" >/dev/null 2>&1; echo $? > "$TMP/rc" )
  eq "missing model → exit 3" "$(cat "$TMP/rc")" "3"
  check "transcribe (sync) succeeds" "$CLI" transcribe "$ID3" --model base.en
  check "transcript.md written" test -s "$D3/transcript.md"
  check "transcript header line" bash -c "head -1 '$D3/transcript.md' | grep -q '<!-- omarecorder model=base.en'"
  check "transcript mentions 'right'" bash -c "grep -qi right '$D3/transcript.md'"
  eq "meta.transcript.model" "$(jq -r .transcript.model "$D3/meta.json")" "base.en"
  check "bench.json learned rtf" bash -c "jq -e '.[\"base.en\"].rtf > 0' '$XDG_STATE_HOME/omarecorder/bench.json'"
  eq "estimate now measured" "$($CLI estimate "$ID3" --model base.en | jq -r .source)" "measured"
  eq "list has_transcript true" "$($CLI show "$ID3" --json | jq -r .has_transcript)" "true"
  check "show --json includes text" bash -c "$CLI show '$ID3' --json | jq -e '.transcript_text | length > 0'"
  eq "no jobs left in state" "$($CLI status --json | jq -r '.jobs|length')" "0"
  check "range transcribe" "$CLI" transcribe "$ID3" --model base.en --from 0 --to 3
  check "range header" bash -c "head -1 '$D3/transcript.md' | grep -q 'range=0-3'"
else
  echo "  (skipped: voxtype/base.en/fixture not available)"
fi

echo "== record (real mic, 2 s)"
if pactl list short sources 2>/dev/null | grep -qv '\.monitor'; then
  IDR=$($CLI record start --title "Mic check")
  check "record start returns id" test -n "$IDR"
  eq "status shows recording" "$($CLI status --json | jq -r .recording.id)" "$IDR"
  check "start refused while recording" bash -c "! $CLI record start"
  sleep 2
  check "record stop" "$CLI" record stop
  DR="$OMARECORDER_DIR/$IDR Mic check"
  eq "wav header valid" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$DR/audio.wav")" "pcm_s16le,16000,1"
  DUR=$(jq -r .duration_s "$DR/meta.json"); check "duration ≈ 2 s" test "$DUR" -ge 1 -a "$DUR" -le 4
  eq "state cleared" "$($CLI status)" "idle"
  check "toggle starts" "$CLI" record toggle --source mic
  sleep 1
  check "toggle stops" "$CLI" record toggle
else
  echo "  (skipped: no microphone source)"
fi

echo "== delete"
check "delete --yes" "$CLI" delete "$ID1" --yes
check "folder gone" bash -c "! test -d '$D1B'"
check "delete unknown fails" bash -c "! $CLI delete 2000-01-01_000000 --yes"

echo "== setup"
check "setup check --json runs" bash -c "$CLI setup check --json | jq -e '.version'"

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
