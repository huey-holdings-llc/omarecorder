#!/usr/bin/env bash
# CLI tests for omarecorder. Runs against a throwaway XDG tree; uses the real
# voxtype + base.en model if present (transcription tests are skipped otherwise).
#   bash tests/cli.test.sh                                    # everything: about three minutes with a mic and voxtype
#   OMARECORDER_TEST_ONLY=export,tidy bash tests/cli.test.sh  # just those sections (--list prints the names)
#   OMARECORDER_TEST_ALLOW_SKIP=1 bash tests/cli.test.sh      # a missing mic/engine skips instead of failing (CI)
#   OMARECORDER_TEST_KEEP=1 bash tests/cli.test.sh            # keep the sandbox afterwards (kept on failure anyway)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/omarecorder"
# OMARECORDER_TEST_TMP: where the sandbox goes. Not inside the plugin tree (the
# marketplace validator walks it and rejects the symlink farm some tests build)
# and not tmpfs (`gio trash` needs a trash can on the same filesystem as $HOME).
TMP="${OMARECORDER_TEST_TMP:-${XDG_CACHE_HOME:-$HOME/.cache}/omarecorder-tests}/$$"; mkdir -p "$TMP"
pass=0; fail=0; skipped=0
cleanup() {
  if [[ "${OMARECORDER_TEST_KEEP:-0}" == "1" || $fail -gt 0 ]]; then
    echo "sandbox kept: $TMP   (CLI log: $TMP/state/omarecorder/omarecorder.log)"
  else rm -rf "$TMP"; fi
}
trap cleanup EXIT

# Keep PipeWire/Pulse reachable while XDG_RUNTIME_DIR points at the sandbox.
REAL_RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PIPEWIRE_RUNTIME_DIR="$REAL_RUNTIME" PULSE_SERVER="unix:$REAL_RUNTIME/pulse/native"
# XDG_RUNTIME_DIR stays real so `systemd-run --user` / `systemctl --user` work; the CLI state goes to $RUN.
export OMARECORDER_DIR="$TMP/Recordings" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" XDG_RUNTIME_DIR="$REAL_RUNTIME"
export OMARECORDER_RUN_DIR="$TMP/run/omarecorder"; RUN="$OMARECORDER_RUN_DIR"
export OMARECORDER_QUIET=1 OMARECORDER_SYNC=1
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$TMP/run"

# ---------------------------------------------------------------- harness ---
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { # bad <desc> [detail lines...]: every extra argument is printed indented under the cross
  fail=$((fail+1)); echo "  ✗ $1"; shift
  local l; for l in "$@"; do [[ -n "$l" ]] && sed 's/^/      /' <<<"$l"; done
}
_tail() { { cat "$TMP/.err"; cat "$TMP/.out"; } 2>/dev/null | grep -v '^$' | tail -n 4; }
check() { # check <desc> <cmd...>: passes when the command exits 0; on failure shows rc and the last lines it printed
  local d="$1"; shift
  "$@" >"$TMP/.out" 2>"$TMP/.err"; local rc=$?
  if (( rc == 0 )); then ok "$d"; else bad "$d" "rc=$rc  cmd: $*" "$(_tail)"; fi
}
eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got '$2' expected '$3'"; }
fails() { # fails <desc> <cmd...>: passes when the command exits non-zero
  local d="$1"; shift
  if "$@" >"$TMP/.out" 2>"$TMP/.err"; then bad "$d" "unexpectedly succeeded: $*" "$(_tail)"; else ok "$d"; fi
}
# A missing fixture/engine is a failure unless the caller opted into skipping
# (CI has no voxtype/mic): OMARECORDER_TEST_ALLOW_SKIP=1. Skips are counted either way.
skip() { skipped=$((skipped+1)); if [[ "${OMARECORDER_TEST_ALLOW_SKIP:-0}" == "1" ]]; then echo "  (skipped: $1)"; else bad "skipped: $1"; fi; }
# shellcheck disable=SC2034
run_cli() { # run_cli <cmd...>: RC, OUT and ERR for assertions that need more than one of them
  OUT=$("$@" 2>"$TMP/.err"); RC=$?; ERR=$(<"$TMP/.err")
}
wait_for() { # wait_for <whole seconds> <cmd...>: poll at 10 Hz until the command succeeds
  local n=$(( $1 * 10 )); shift
  while (( n-- > 0 )); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1
}
# State fixtures. Reconcile keeps a job that has no unit (a sync worker), so a
# hand-built job stands until a test cancels it or the next section resets.
set_state() { # set_state [recording] [jobs] [last_stop]  (JSON; defaults null, [], none)
  jq -cn --argjson r "${1:-null}" --argjson j "${2:-[]}" --argjson l "${3:-null}" \
    '{recording:$r,jobs:$j,version:1} + (if $l == null then {} else {last_stop:$l} end)' > "$RUN/state.json"
}
tx_job() { jq -cn --arg id "$1" --arg m "${2:-base.en}" '{type:"transcribe",id:$id,model:$m,started_at:0}'; }
# Every section starts idle, with default config and no dictionary, from the
# sandbox root (a stray relative `touch` from a hostile string lands there).
fresh_state() { install -d -m 700 "$RUN"; set_state; rm -rf "$XDG_CONFIG_HOME/omarecorder"; cd "$TMP" || exit 1; }
# The shared "Tone Test" take (ID1) and the speech import (ID2) that several
# sections read; imported on first use so any section can run on its own.
ensure_base() {
  { [[ -n "${ID1:-}" ]] && "$CLI" show "$ID1" >/dev/null 2>&1; } || { ID1=$($CLI import "$TMP/tone48.wav" --title "Tone Test"); D1="$OMARECORDER_DIR/$ID1 Tone Test"; }
  { [[ -n "${ID2:-}" ]] && "$CLI" show "$ID2" >/dev/null 2>&1; } || ID2=$($CLI import "$TMP/speech.wav")
}
MANIFEST_VERSION=$(jq -r .version "$HERE/../manifest.json")
DICT="$XDG_CONFIG_HOME/omarecorder/dictionary"

# Fixtures: short speech clip (ships with alsa-utils) and a 12 s version of it
SPEECH=/usr/share/sounds/alsa/Front_Right.wav
if [[ -f "$SPEECH" ]]; then
  ffmpeg -v error -y -i "$SPEECH" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/speech.wav"
  ffmpeg -v error -y -stream_loop 7 -i "$TMP/speech.wav" -c copy "$TMP/speech12.wav"
  ffmpeg -v error -y -stream_loop 4 -i "$TMP/speech12.wav" -c copy "$TMP/speech60.wav"
else
  # No alsa-utils (CI): a tone stands in so the import assertions still run.
  # The transcription tests need real speech and keep their own gate (no speech12.wav).
  ffmpeg -v error -y -f lavfi -i "sine=frequency=220:duration=3" -ar 16000 -ac 1 "$TMP/speech.wav"
fi
# Level fixtures: a quiet tone and the same tone driven 20 dB into the rails.
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -af volume=-12dB -ar 16000 -ac 1 "$TMP/quiet.wav"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -af volume=20dB -ar 16000 -ac 1 "$TMP/hot.wav"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -ar 48000 -ac 2 "$TMP/tone48.wav"
touch -d "2026-01-02 03:04:05" "$TMP/tone48.wav"
touch -d "2026-01-03 03:04:05" "$TMP/speech.wav"

# ------------------------------------------------------------------ fakes ---
# PATH shims stand in for the tools CI does not have. Prepend a fake dir to PATH
# for one call; the CLI calls every external tool by bare name.
# A fake audio stack: pactl reports one microphone and one sink, and pw-record
# "records" by copying the 3 s quiet fixture into its target file and sleeping
# until the stop signal arrives. That makes the whole start/stop/resume/join
# pipeline testable with no hardware at all.
FAKEAUDIO="$TMP/fakeaudio"; mkdir -p "$FAKEAUDIO"
cat > "$FAKEAUDIO/pactl" <<'STUBEOF'
#!/bin/bash
case "$*" in
  "get-default-source") echo fakemic ;;
  "list short sources") printf '0\tfakemic\tPipeWire\ts16le 1ch 16000Hz\tRUNNING\n' ;;
  "get-default-sink") echo fakesink ;;
esac
exit 0
STUBEOF
cat > "$FAKEAUDIO/pw-record" <<STUBEOF
#!/bin/bash
# PWREC_DELAY holds the file back, standing in for a recorder that is slow to
# open the device (the race tests park a caller in the file-wait watchdog).
[ -n "\${PWREC_DELAY:-}" ] && sleep "\$PWREC_DELAY"
for f in "\$@"; do :; done   # the output file is the last argument
cp "$TMP/quiet.wav" "\$f"
exec sleep 600
STUBEOF
chmod +x "$FAKEAUDIO/pactl" "$FAKEAUDIO/pw-record"
FAKEPATH="$FAKEAUDIO:$PATH"
STUB="$TMP/voxstub"; mkdir -p "$STUB"          # success: writes the model file; transcribes to stub text
cat > "$STUB/voxtype" <<STUBEOF
#!/bin/bash
# setup --download writes the model file; anything else is the transcribe
# call (voxtype -q --model ... transcribe FILE), which emits text after a
# blank line the way the real engine does.
if [ "\$1" = setup ]; then
  head -c 100 /dev/zero > "\$VOXTYPE_MODELS_DIR/ggml-small.en.bin"
else
  printf '\nchained stub text\n'
fi
exit 0
STUBEOF
STUBSNAP="$TMP/voxsnap"; mkdir -p "$STUBSNAP"  # snapshot: capture state mid-download, then fail
cat > "$STUBSNAP/voxtype" <<STUBEOF
#!/bin/bash
[ "\$1" = setup ] && cp "$RUN/state.json" "$TMP/state.mid"
exit 1
STUBEOF
STUBFAIL="$TMP/voxfail"; mkdir -p "$STUBFAIL"  # failure: download never produces the file
printf '#!/bin/bash\nexit 1\n' > "$STUBFAIL/voxtype"
chmod +x "$STUB/voxtype" "$STUBSNAP/voxtype" "$STUBFAIL/voxtype"
mkstoprec() { # <id> <title>: hand-built live recording with a harmless pid
  local dir="$OMARECORDER_DIR/$1 $2"
  mkdir -p "$dir"; cp "$TMP/quiet.wav" "$dir/audio.wav"
  jq -cn --arg id "$1" --arg ttl "$2" '{id:$id,title:$ttl,source:"mic",created:"2026-01-06T01:01:01+0000",duration_s:null,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$dir/meta.json"
  # stdout redirected so the $(...) capture is not held open by the child
  sleep 60 >/dev/null 2>&1 & local spid=$!
  jq -cn --arg id "$1" --arg dir "$dir" --argjson p "$spid" --argjson t "$(date +%s)" \
    '{recording:{id:$id,dir:$dir,source:"mic",pids:[$p],started_at:$t},jobs:[],version:1}' > "$RUN/state.json"
  echo "$dir"
}
armresume() { # <id> [stopped_at]: an armed resume offer, by default from 100 s ago
  set_state null '[]' "$(jq -cn --arg id "$1" --argjson t "${2:-$(( ${NOW:-$(date +%s)} - 100))}" '{id:$id,title:"Resume Take",stopped_at:$t,resumable:true}')"
}


t_basics() {
eq "version" "$("$CLI" version)" "$MANIFEST_VERSION"
check "help exits 0" "$CLI" help
eq "config default source" "$($CLI config get defaultSource)" "mic"
check "config set" "$CLI" config set defaultSource both
eq "config persisted" "$($CLI config get defaultSource)" "both"
fails "config rejects bad value" "$CLI" config set defaultSource bogus
$CLI config set defaultSource mic >/dev/null
eq "status idle" "$($CLI status)" "idle"
eq "status --json shape" "$($CLI status --json | jq -c '[.recording, (.jobs|length)]')" "[null,0]"

}

t_import() {
ID1=$($CLI import "$TMP/tone48.wav" --title "Tone Test")
eq "import id from mtime" "$ID1" "2026-01-02_030405"
D1="$OMARECORDER_DIR/$ID1 Tone Test"
check "folder named id + title" test -d "$D1"
eq "audio converted to 16k mono s16" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$D1/audio.wav")" "pcm_s16le,16000,1"
eq "meta duration" "$(jq -r .duration_s "$D1/meta.json")" "3"
eq "meta title" "$(jq -r .title "$D1/meta.json")" "Tone Test"
eq "meta source" "$(jq -r .source "$D1/meta.json")" "import"
ID2=$($CLI import "$TMP/speech.wav"); eq "second import id" "$ID2" "2026-01-03_030405"
eq "title defaults to filename" "$(jq -r .title "$OMARECORDER_DIR/$ID2 speech/meta.json")" "speech"

}

t_levels() {
IDQ=$($CLI import "$TMP/quiet.wav" --title Quiet); IDH=$($CLI import "$TMP/hot.wav" --title Hot)
eq "quiet import not clipped" "$($CLI show "$IDQ" --json | jq -r '.levels.clipped')" "false"
eq "hot import flagged clipped" "$($CLI show "$IDH" --json | jq -r '.levels.clipped')" "true"
check "hot peak near 0 dBFS" bash -c "$CLI show '$IDH' --json | jq -e '.levels.peak_db > -0.5'"
eq "analyze re-measures" "$($CLI analyze "$IDH" | jq -r .clipped)" "true"
check "list marks clipped rows" bash -c "$CLI list | grep -q 'clipped.*Hot'"
check "list shows HH:MM:SS" bash -c "$CLI list | grep -q '00:00:03'"
$CLI delete "$IDQ" --yes >/dev/null; $CLI delete "$IDH" --yes >/dev/null

}

t_list() {
ensure_base
eq "list newest first" "$($CLI list --json | jq -r '.[0].id')" "$ID2"
eq "list has_transcript false" "$($CLI list --json | jq -r '.[-1].has_transcript')" "false"
eq "show --json dir" "$($CLI show "$ID1" --json | jq -r .dir)" "$D1"
fails "show unknown id fails" "$CLI" show 2000-01-01_000000

}

t_rename() {
ensure_base
V1=$(jq -r .version "$RUN/state.json")
$CLI rename "$ID1" "Renamed / Title  here" >/dev/null
D1B="$OMARECORDER_DIR/$ID1 Renamed - Title here"
check "folder renamed (sanitized)" test -d "$D1B"
check "old folder gone" bash -c "! test -d '$D1'"
eq "id stable after rename" "$($CLI show "$ID1" --json | jq -r .id)" "$ID1"
eq "meta title updated" "$(jq -r .title "$D1B/meta.json")" "Renamed - Title here"
V2=$(jq -r .version "$RUN/state.json")
check "state version bumped by mutations" test "$V2" -gt "$V1"

}

t_note() {
ensure_base
V2=$(jq -r .version "$RUN/state.json")
$CLI note "$ID1" "remember to trim the intro" >/dev/null
eq "note round-trips via show --json" "$($CLI show "$ID1" --json | jq -r .notes)" "remember to trim the intro"
eq "note appears in list --json" "$($CLI list --json | jq -r --arg id "$ID1" '.[] | select(.id==$id) | .notes')" "remember to trim the intro"
VN=$(jq -r .version "$RUN/state.json")
check "note bumps state version" test "$VN" -gt "$V2"
EVILNOTE='note $(touch note-pwned) `touch note-pwned2`; rm -rf x <b>bold'
$CLI note "$ID1" "$EVILNOTE" >/dev/null
eq "hostile note stored verbatim" "$($CLI show "$ID1" --json | jq -r .notes)" "$EVILNOTE"
check "no command executed from note" bash -c "! test -e '$TMP/note-pwned' && ! test -e '$TMP/note-pwned2'"
eq "newline in note collapsed" "$($CLI note "$ID1" $'line1\nline2' >/dev/null; $CLI show "$ID1" --json | jq -r .notes)" "line1 line2"
eq "slash kept in note (unlike titles)" "$($CLI note "$ID1" "a/b" >/dev/null; $CLI show "$ID1" --json | jq -r .notes)" "a/b"
LONGNOTE=$(printf 'n%.0s' $(seq 1 600))
$CLI note "$ID1" "$LONGNOTE" >/dev/null
eq "note capped at 500 chars" "$($CLI show "$ID1" --json | jq -r '.notes | length')" "500"
$CLI note "$ID1" "" >/dev/null
eq "empty text clears the note" "$($CLI show "$ID1" --json | jq -r .notes)" ""
IDN=$($CLI import "$TMP/quiet.wav" --title "Note Keeper")
$CLI note "$IDN" "sticks around" >/dev/null
$CLI rename "$IDN" "Note Keeper Renamed" >/dev/null
eq "note survives a rename" "$($CLI show "$IDN" --json | jq -r .notes)" "sticks around"
$CLI delete "$IDN" --yes >/dev/null

}

t_security() {
# Titles are data: shell metacharacters must round-trip untouched and never execute.
EVIL='notes $(touch pwned-marker) `touch pwned-marker2`; rm -rf x <b>bold'
IDE=$("$CLI" import "$TMP/quiet.wav" --title "$EVIL")
check "hostile title imported" test -n "$IDE"
eq "hostile title stored verbatim" "$("$CLI" show "$IDE" --json | jq -r .title)" "$EVIL"
check "no command executed from title" bash -c "! test -e '$TMP/pwned-marker' && ! test -e '$TMP/pwned-marker2'"
"$CLI" rename "$IDE" "$EVIL x" >/dev/null
eq "hostile rename round-trips" "$("$CLI" show "$IDE" --json | jq -r .title)" "$EVIL x"
printf '<!-- omarecorder model=base.en -->\nhello world\n' > "$("$CLI" show "$IDE" --json | jq -r .dir)/transcript.md"
eq "copy --print strips header, keeps text" "$("$CLI" copy "$IDE" --print)" "hello world"
check "still nothing executed" bash -c "! test -e '$TMP/pwned-marker' && ! test -e '$TMP/pwned-marker2'"
LONG=$(printf 'a%.0s' $(seq 1 120))
"$CLI" rename "$IDE" "$LONG" >/dev/null
eq "title capped at 80 chars" "$("$CLI" show "$IDE" --json | jq -r '.title | length')" "80"
eq "newline in title collapsed" "$("$CLI" rename "$IDE" $'line1\nline2' >/dev/null; "$CLI" show "$IDE" --json | jq -r .title)" "line1 line2"
# --from/--to are numbers or nothing
fails "transcribe rejects negative --from" "$CLI" transcribe "$IDE" --model base.en --from -3
fails "transcribe rejects non-numeric --from" "$CLI" transcribe "$IDE" --model base.en --from abc
fails "transcribe rejects --to <= --from" "$CLI" transcribe "$IDE" --model base.en --from 5 --to 2
fails "transcribe rejects option-looking --to" "$CLI" transcribe "$IDE" --model base.en --to "-y"
fails "play rejects non-numeric --from" "$CLI" play "$IDE" --from "0 -y"
eq "no job registered after rejected args" "$("$CLI" status --json | jq -r '.jobs|length')" "0"
# meta.json survives a broken measurement
DE=$("$CLI" show "$IDE" --json | jq -r .dir)
cp "$DE/meta.json" "$TMP/meta.before"
printf 'RIFF' > "$DE/audio.wav"   # truncated wav: ffprobe gives no duration
"$CLI" analyze "$IDE" >/dev/null 2>&1 || true
check "meta.json intact after failed analysis" jq -e .id "$DE/meta.json"
cp "$TMP/quiet.wav" "$DE/audio.wav"
# delete is never silent and never rm -rf behind a "trash" label
fails "delete without --yes and no tty refuses" "$CLI" delete "$IDE"
check "recording still there" test -d "$DE"
( PATH="$TMP/nogio:$PATH"; mkdir -p "$TMP/nogio"; printf '#!/bin/sh\nexit 1\n' > "$TMP/nogio/gio"; chmod +x "$TMP/nogio/gio"
  "$CLI" delete "$IDE" --yes >/dev/null 2>&1; echo $? > "$TMP/rc" )
check "delete refuses when trash is unavailable" test "$(cat "$TMP/rc")" -ne 0
check "recording survives failed trash" test -d "$DE"
check "delete --permanent works without trash" "$CLI" delete "$IDE" --yes --permanent
check "permanent delete removed folder" bash -c "! test -d '$DE'"
# files are private
IDP=$("$CLI" import "$TMP/quiet.wav" --title Private); DP=$("$CLI" show "$IDP" --json | jq -r .dir)
eq "audio.wav is 0600" "$(stat -c %a "$DP/audio.wav")" "600"
eq "meta.json is 0600" "$(stat -c %a "$DP/meta.json")" "600"
eq "recording folder is 0700" "$(stat -c %a "$DP")" "700"
eq "runtime dir is 0700" "$(stat -c %a "$RUN")" "700"
"$CLI" delete "$IDP" --yes >/dev/null
# runtime state lives under XDG_RUNTIME_DIR (never /tmp) when no test override points elsewhere
( export XDG_RUNTIME_DIR="$TMP/xdgrt"; unset OMARECORDER_RUN_DIR; install -d -m 700 "$XDG_RUNTIME_DIR"; "$CLI" status >/dev/null 2>&1 )
check "runtime state lands under XDG_RUNTIME_DIR" test -d "$TMP/xdgrt/omarecorder"   # status writes state.json only on a change; the dir and lock prove the path
eq "and that runtime dir is private" "$(stat -c %a "$TMP/xdgrt/omarecorder")" "700"
check "nothing under /tmp" bash -c "! test -d /tmp/omarecorder"
# config validation
fails "config get unknown key fails" "$CLI" config get bogus
fails "config set recordingsDir rejects missing dir" "$CLI" config set recordingsDir "$TMP/does-not-exist"
fails "import rejects unknown flag" "$CLI" import --bogus "$TMP/quiet.wav"
}

t_locking() {
# concurrent state writers do not lose bumps
V0=$(jq -r .version "$RUN/state.json")
for i in $(seq 1 20); do "$CLI" config set threads "$i" >/dev/null & done; wait
V1=$(jq -r .version "$RUN/state.json")
check "20 parallel config sets → 20 version bumps" test $((V1 - V0)) -ge 20
"$CLI" config set threads 0 >/dev/null
# the state lock: a waiting writer gets its turn; one that cannot must fail, never write unlocked
( flock 9; sleep 3 ) 9>>"$RUN/state.lock" &
LOCKER=$!
check "the holder has the lock" wait_for 5 bash -c "! flock -n '$RUN/state.lock' true"
check "state_set waits for a held lock" "$CLI" config set threads 7
wait "$LOCKER" 2>/dev/null
eq "and its write landed" "$("$CLI" config get threads)" "7"
( flock 9; sleep 4 ) 9>>"$RUN/state.lock" &
LOCKER=$!
wait_for 5 bash -c "! flock -n '$RUN/state.lock' true"
V_BEFORE=$(jq -r .version "$RUN/state.json")
fails "state_set refuses when the lock never frees (OMARECORDER_LOCK_WAIT=1)" env OMARECORDER_LOCK_WAIT=1 "$CLI" config set threads 8
wait "$LOCKER" 2>/dev/null
eq "state.json untouched by the refused write" "$(jq -r .version "$RUN/state.json")" "$V_BEFORE"
"$CLI" config set threads 0 >/dev/null
}

t_recovery() {
# crash recovery for a "both" take that died before the mix
IDB="2026-01-05_010203"; DB="$OMARECORDER_DIR/$IDB Both crash"; mkdir -p "$DB"
cp "$TMP/quiet.wav" "$DB/mic.wav"; cp "$TMP/quiet.wav" "$DB/system.wav"
jq -cn --arg id "$IDB" --arg dir "$DB" '{id:$id,title:"Both crash",source:"both",created:"2026-01-05T01:02:03+0000",duration_s:null,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$DB/meta.json"
jq -cn --arg id "$IDB" --arg dir "$DB" '{recording:{id:$id,source:"both",dir:$dir,started_at:0,pids:[999999],files:[]},jobs:[],version:1}' > "$RUN/state.json"
eq "status clears the dead recording" "$("$CLI" status)" "idle"
check "both crash recovery produced audio.wav" test -s "$DB/audio.wav"
eq "recovered both take has duration" "$(jq -r .duration_s "$DB/meta.json")" "3"
"$CLI" delete "$IDB" --yes >/dev/null
# orphan sweep: a crash between mkdir and the meta write leaves a folder with
# no meta.json. Reconcile removes an old husk, salvages one with real audio,
# and leaves a fresh folder alone (a recording could be starting right now).
IDO="2026-01-06_010101"; DO_="$OMARECORDER_DIR/$IDO Husk"; mkdir -p "$DO_"
touch -d "2026-01-06 01:01:01" "$DO_"
IDF="2026-01-07_020202"; DF="$OMARECORDER_DIR/$IDF Fresh"; mkdir -p "$DF"
IDS="2026-01-08_030303"; DS="$OMARECORDER_DIR/$IDS Salvage"; mkdir -p "$DS"
ffmpeg -v error -y -f lavfi -i "sine=frequency=330:duration=40" -ar 16000 -ac 1 "$DS/audio.wav"
touch -d "2026-01-08 03:03:03" "$DS"
IDM="2026-01-09_040404"; DM="$OMARECORDER_DIR/$IDM MicOnly"; mkdir -p "$DM"
ffmpeg -v error -y -f lavfi -i "sine=frequency=330:duration=40" -ar 16000 -ac 1 "$DM/mic.wav"
touch -d "2026-01-09 04:04:04" "$DM"
IDT_SHORT="2026-01-10_050505"; DTS="$OMARECORDER_DIR/$IDT_SHORT Short"; mkdir -p "$DTS"
ffmpeg -v error -y -f lavfi -i "sine=frequency=330:duration=2" -ar 16000 -ac 1 "$DTS/audio.wav"
touch -d "2026-01-10 05:05:05" "$DTS"
DX="$OMARECORDER_DIR/2026-01-11_060606 Not ours"; mkdir -p "$DX"
echo "somebody else's data" > "$DX/notes.txt"
touch -d "2026-01-11 06:06:06" "$DX"
DH="$OMARECORDER_DIR/2026-01-12_070707 Header only"; mkdir -p "$DH"
head -c 44 /dev/zero > "$DH/audio.wav"
touch -d "2026-01-12 07:07:07" "$DH"
"$CLI" status >/dev/null
check "old empty orphan folder swept" bash -c "! test -d \"$DO_\""
check "fresh meta-less folder left alone" test -d "$DF"
check "orphan with real audio salvaged, not deleted" test -s "$DS/audio.wav"
eq "salvaged take got its id back" "$(jq -r .id "$DS/meta.json")" "$IDS"
eq "salvaged take is marked recovered" "$(jq -r .source "$DS/meta.json")" "recovered"
eq "salvaged take has its duration" "$(jq -r .duration_s "$DS/meta.json")" "40"
check "lone mic track promoted to audio.wav" test -s "$DM/audio.wav"
check "a short take is salvaged too, size is not proof of a husk" test -s "$DTS/meta.json"
eq "short salvaged take has its duration" "$(jq -r .duration_s "$DTS/meta.json")" "2"
check "a look-alike folder with foreign content is not touched" test -s "$DX/notes.txt"
check "and gets no meta.json written into it" bash -c "! test -e \"$DX/meta.json\""
check "a header-only stub folder is removed" bash -c "! test -d \"$DH\""
rm -rf "$DX"
rm -rf "$DF"; "$CLI" delete "$IDS" --yes >/dev/null; "$CLI" delete "$IDM" --yes >/dev/null; "$CLI" delete "$IDT_SHORT" --yes >/dev/null

}

t_export() {
# A fake Obsidian install: vault A is open and files new notes under inbox/,
# vault B is closed and newer, vault C is listed but no longer exists.
OBS="$XDG_CONFIG_HOME/obsidian"; mkdir -p "$OBS" "$TMP/vaults/a/.obsidian" "$TMP/vaults/b"
printf '{"newFileLocation":"folder","newFileFolderPath":"inbox"}' > "$TMP/vaults/a/.obsidian/app.json"
jq -cn --arg a "$TMP/vaults/a" --arg b "$TMP/vaults/b" --arg c "$TMP/vaults/gone" \
  '{vaults:{"aaa":{path:$a,ts:100,open:true},"bbb":{path:$b,ts:200},"ccc":{path:$c,ts:300}}}' > "$OBS/obsidian.json"
eq "vaults --json: open vault first, missing one dropped" "$("$CLI" vaults --json | jq -r '.[].name' | paste -sd,)" "a,b"
eq "vaults: folder follows newFileFolderPath" "$("$CLI" vaults --json | jq -r '.[0].folder')" "$TMP/vaults/a/inbox"
eq "vaults: no app.json → vault root" "$("$CLI" vaults --json | jq -r '.[1].folder')" "$TMP/vaults/b"
eq "vaults: open flag is a boolean" "$("$CLI" vaults --json | jq -c 'map(.open)')" "[true,false]"
check "vaults: human output stars the open vault" bash -c "\"$CLI\" vaults | grep -q '^\* a  '"
IDX=$("$CLI" import "$TMP/quiet.wav" --title "Tone: Test?"); DX=$("$CLI" show "$IDX" --json | jq -r .dir)
fails "export without transcript fails" "$CLI" export "$IDX" --no-open
printf '<!-- omarecorder model=base.en -->\nhello world\n' > "$DX/transcript.md"
NOTE=$("$CLI" export "$IDX" --no-open)
eq "export lands in the open vault's new-note folder" "$NOTE" "$TMP/vaults/a/inbox/Tone- Test-.md"
check "note written" test -s "$NOTE"
eq "note is private (0600)" "$(stat -c %a "$NOTE")" "600"
check "frontmatter starts the file" bash -c "head -1 '$NOTE' | grep -qx -- '---'"
check "frontmatter has the recording id" grep -qx "omarecorder: $IDX" "$NOTE"
check "frontmatter keeps the real title" grep -qxF 'title: "Tone: Test?"' "$NOTE"
eq "frontmatter source" "$(sed -n 's/^source: //p' "$NOTE")" "imported"
eq "frontmatter duration" "$(sed -n 's/^duration: //p' "$NOTE")" "00:00:03"
eq "frontmatter date is meta.created" "$(sed -n 's/^date: //p' "$NOTE")" "$(jq -r .created "$DX/meta.json")"
check "frontmatter tags" grep -qx 'tags: \[omarecorder\]' "$NOTE"
check "body has no header comment" bash -c "! grep -q '<!--' '$NOTE'"
check "body has the transcript text" grep -qx "hello world" "$NOTE"
eq "meta.exported_to set" "$(jq -r .exported_to "$DX/meta.json")" "$NOTE"
check "meta.exported_at set" bash -c "jq -e '.exported_at | length > 0' '$DX/meta.json'"
eq "second export gets (2)" "$("$CLI" export "$IDX" --no-open)" "$TMP/vaults/a/inbox/Tone- Test- (2).md"
eq "--vault picks that vault's folder" "$("$CLI" export "$IDX" --vault "$TMP/vaults/b" --no-open)" "$TMP/vaults/b/Tone- Test-.md"
eq "--dir exports anywhere" "$("$CLI" export "$IDX" --dir "$TMP/exports" --no-open)" "$TMP/exports/Tone- Test-.md"
fails "--vault /nonexistent fails" "$CLI" export "$IDX" --vault "$TMP/nonexistent" --no-open
check "config set obsidianVault" "$CLI" config set obsidianVault "$TMP/vaults/b"
eq "configured vault wins over the open one" "$("$CLI" export "$IDX" --no-open)" "$TMP/vaults/b/Tone- Test- (2).md"
fails "config set obsidianVault rejects missing dir" "$CLI" config set obsidianVault "$TMP/does-not-exist"
check "config set obsidianVault '' → automatic" "$CLI" config set obsidianVault ""
eq "config get obsidianVault empty again" "$("$CLI" config get obsidianVault)" ""
eq "automatic again: the open vault" "$("$CLI" export "$IDX" --no-open)" "$TMP/vaults/a/inbox/Tone- Test- (3).md"
CREATED=$(jq -r .created "$DX/meta.json")   # read before the rename: an untitled folder is just "<id>"
"$CLI" rename "$IDX" "" >/dev/null
eq "untitled → Recording <date> <time>" "$("$CLI" export "$IDX" --no-open)" "$TMP/vaults/a/inbox/Recording ${CREATED:0:10} ${CREATED:11:2}-${CREATED:14:2}.md"
"$CLI" rename "$IDX" "Tone: Test?" >/dev/null
rm "$OBS/obsidian.json"
eq "no Obsidian: note lands in the recording folder" "$("$CLI" export "$IDX" --no-open)" "$DX/Tone- Test-.md"
check "config set exportDir" "$CLI" config set exportDir "$TMP/exports2"
eq "exportDir used when no vault" "$("$CLI" export "$IDX" --no-open)" "$TMP/exports2/Tone- Test-.md"
"$CLI" config set exportDir "" >/dev/null
eq "vaults --json without obsidian.json" "$("$CLI" vaults --json | jq -c .)" "[]"
"$CLI" delete "$IDX" --yes >/dev/null

}

t_trim() {
# Import ids come from the file mtime: give each fixture its own second.
cp "$TMP/tone48.wav" "$TMP/trim.wav"; touch -d "2026-01-06 03:04:05" "$TMP/trim.wav"
cp "$TMP/quiet.wav" "$TMP/trim2.wav"; touch -d "2026-01-07 03:04:05" "$TMP/trim2.wav"
IDT=$($CLI import "$TMP/trim.wav" --title "Trim Test"); DT="$OMARECORDER_DIR/$IDT Trim Test"
eq "import makes waveform.png" "$(ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 "$DT/waveform.png")" "png,2400,128"
eq "show --json has waveform path" "$($CLI show "$IDT" --json | jq -r .waveform)" "$DT/waveform.png"
eq "has_orig false before trim" "$($CLI show "$IDT" --json | jq -r .has_orig)" "false"
# A strip drawn at the old, softer 800x64 (pre-1.1.2) is redrawn once by list,
# then left alone on later lists.
ffmpeg -v error -y -f lavfi -i "color=c=gray:s=800x64:d=1" -frames:v 1 -update 1 "$DT/waveform.png"
$CLI list >/dev/null
eq "old 800px strip redrawn by list" "$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$DT/waveform.png")" "2400,128"
touch "$TMP/wave.marker"
$CLI list >/dev/null
check "right-size strip left alone by list" bash -c "! find '$DT' -maxdepth 1 -name waveform.png -newer '$TMP/wave.marker' | grep -q ."
cp "$TMP/quiet.wav" "$DT/mic.wav"   # a raw take must never be touched by trim
touch "$TMP/trim.marker"
eq "trim 1–2 s → duration 1" "$($CLI trim "$IDT" --from 1 --to 2)" "$IDT (00:00:01)"
eq "audio.orig.wav kept, 3 s" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DT/audio.orig.wav" | cut -d. -f1)" "3"
eq "meta.trim.from == 1" "$(jq -r .trim.from "$DT/meta.json")" "1"
eq "meta.trim.original true" "$(jq -r .trim.original "$DT/meta.json")" "true"
check "waveform regenerated" bash -c "find '$DT' -maxdepth 1 -name waveform.png -newer '$TMP/trim.marker' | grep -q ."
eq "has_orig true" "$($CLI show "$IDT" --json | jq -r .has_orig)" "true"
check "mic.wav untouched" cmp -s "$TMP/quiet.wav" "$DT/mic.wav"
check "levels re-measured after trim" bash -c "jq -e '.levels.peak_db' '$DT/meta.json'"
$CLI trim "$IDT" --from 0 --to 0.5 >/dev/null
eq "second trim keeps the FIRST original" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DT/audio.orig.wav" | cut -d. -f1)" "3"
eq "meta.trim.to == 0.5" "$(jq -r .trim.to "$DT/meta.json")" "0.5"
# --replace on a fresh import: no original is kept
IDT2=$($CLI import "$TMP/trim2.wav" --title "Trim Replace"); DT2="$OMARECORDER_DIR/$IDT2 Trim Replace"
fails "trim rejects to<=from" "$CLI" trim "$IDT2" --from 2 --to 2
fails "trim rejects negative" "$CLI" trim "$IDT2" --from -1 --to 2
fails "trim rejects non-numeric" "$CLI" trim "$IDT2" --from abc --to 2
fails "trim rejects to beyond duration+1" "$CLI" trim "$IDT2" --from 0 --to 5
fails "trim needs both --from and --to" "$CLI" trim "$IDT2" --from 1
fails "trim rejects unknown flag" "$CLI" trim "$IDT2" --from 0 --to 1 --bogus
check "nothing changed after rejected trims" bash -c "! test -e '$DT2/audio.orig.wav' && [ \"\$(jq -r .duration_s '$DT2/meta.json')\" = 3 ]"
set_state null "[$(tx_job "$IDT2")]"
fails "trim refused while a transcription runs" "$CLI" trim "$IDT2" --from 0 --to 1
"$CLI" cancel "$IDT2" >/dev/null
eq "trim --replace (to may overshoot by ≤1 s)" "$($CLI trim "$IDT2" --from 1 --to 4 --replace)" "$IDT2 (00:00:02)"
check "trim --replace leaves no original" bash -c "! test -e '$DT2/audio.orig.wav'"
eq "meta.trim.original false" "$(jq -r .trim.original "$DT2/meta.json")" "false"
fails "restore without original fails" "$CLI" trim "$IDT2" --restore
rm -f "$DT2/waveform.png"
eq "waveform null when the file is missing" "$($CLI show "$IDT2" --json | jq -r .waveform)" "null"
# --restore puts the first original back
eq "trim --restore → duration 3" "$($CLI trim "$IDT" --restore)" "$IDT (00:00:03)"
check "orig gone after restore" bash -c "! test -e '$DT/audio.orig.wav'"
eq "meta.trim absent after restore" "$(jq -r 'has("trim")' "$DT/meta.json")" "false"
eq "has_orig false after restore" "$($CLI show "$IDT" --json | jq -r .has_orig)" "false"
check "mic.wav still untouched" cmp -s "$TMP/quiet.wav" "$DT/mic.wav"
if command -v voxtype >/dev/null && [[ -f "${VOXTYPE_MODELS_DIR:-$HOME/.local/share/voxtype/models}/ggml-base.en.bin" ]]; then
  jq -c '.transcript = {model:"base.en"}' "$DT/meta.json" > "$DT/meta.json.t" && mv -f "$DT/meta.json.t" "$DT/meta.json"
  $CLI trim "$IDT" --from 0 --to 2 >/dev/null
  eq "trim marks the transcript stale" "$(jq -r .transcript.stale "$DT/meta.json")" "true"
  check "transcribe after trim" "$CLI" transcribe "$IDT" --model base.en
  eq "new transcript clears stale" "$(jq -r '.transcript.stale // "absent"' "$DT/meta.json")" "absent"
  eq "stale set again by --restore" "$($CLI trim "$IDT" --restore >/dev/null; jq -r .transcript.stale "$DT/meta.json")" "true"
else
  skip "voxtype/base.en not available"
fi
$CLI delete "$IDT" --yes >/dev/null; $CLI delete "$IDT2" --yes >/dev/null

}

t_tidy() {
IDT=$("$CLI" import "$TMP/quiet.wav" --title "Tidy Test"); DT2=$("$CLI" show "$IDT" --json | jq -r .dir)
# A raw transcript the way voxtype produces it: one run-on line per piece, a
# whisper loop in the middle, pieces separated by a blank line.
{
  printf '<!-- omarecorder model=base.en language=en created=x range=0-end chunks=2 -->\n'
  printf 'We start the session with the party at the gate. The guard asks for papers. Nobody has papers. '
  for _ in $(seq 1 30); do printf 'Sentence number %s about the plan, which is long enough to matter. ' "$_"; done
  printf 'Then he says we need to go around the back and try the door. we need to go around the back and try the door. we need to go around the back and try the door. we need to go around the back and try the door. That is what he said.\n'
  printf '\n'
  printf 'Second piece begins here. It has a few sentences. And then it ends.\n'
} > "$DT2/transcript.md"
check "tidy runs" "$CLI" tidy "$IDT"
check "writes transcript.tidy.md" test -s "$DT2/transcript.tidy.md"
eq "raw transcript untouched" "$(grep -o 'go around the back' "$DT2/transcript.md" | wc -l)" "4"
eq "loop collapsed to one copy" "$(grep -o 'go around the back' "$DT2/transcript.tidy.md" | wc -l)" "1"
check "keeps the sentence after the loop" grep -q 'That is what he said' "$DT2/transcript.tidy.md"
check "paragraphs: more than one blank-line break" bash -c "[ \"\$(grep -c '^$' '$DT2/transcript.tidy.md')\" -ge 3 ]"
check "piece boundary kept as a paragraph break" bash -c "grep -q '^Second piece begins here' '$DT2/transcript.tidy.md'"
check "tidy header line" bash -c "head -1 '$DT2/transcript.tidy.md' | grep -q '<!-- omarecorder tidy'"
check "meta records the tidy stats" bash -c "jq -e '.transcript.tidy.repeats_removed > 0 and .transcript.tidy.paragraphs > 1' '$DT2/meta.json'"
check "marker at the collapse point with the copy count" grep -Fq 'we need to go around the back and try the door (repeated 4x).' "$DT2/transcript.tidy.md"
eq "marker appears exactly once" "$(grep -o '(repeated' "$DT2/transcript.tidy.md" | wc -l)" "1"
eq "raw transcript carries no marker" "$(grep -o '(repeated' "$DT2/transcript.md" | wc -l)" "0"
# Files tidied before the marker era have no "loops" field in the header;
# list rebuilds them once and the new meta fields appear.
sed -i '1s/.*/<!-- omarecorder tidy: 2 paragraphs, 33 repeated words removed, created=old -->/' "$DT2/transcript.tidy.md"
jq 'del(.transcript.tidy.loops, .transcript.tidy.longest_run_words, .transcript.tidy.loop_warning)' "$DT2/meta.json" > "$DT2/meta.json.old" && mv "$DT2/meta.json.old" "$DT2/meta.json"
$CLI list >/dev/null
check "legacy tidy rebuilt by list" grep -q " loops," "$DT2/transcript.tidy.md"
check "legacy rebuild fills the new meta" bash -c "jq -e '.transcript.tidy.longest_run_words == 33' '$DT2/meta.json'"
check "meta counts one collapse point" bash -c "jq -e '.transcript.tidy.loops == 1' '$DT2/meta.json'"
check "meta records the longest run" bash -c "jq -e '.transcript.tidy.longest_run_words == 33' '$DT2/meta.json'"
check "33 removed words stay under the loop warning" bash -c "jq -e '.transcript.tidy.loop_warning == false' '$DT2/meta.json'"
check "show --json has tidy_path and tidy_text" bash -c "\"$CLI\" show '$IDT' --json | jq -e '.tidy_path and (.tidy_text | length > 0)'"
eq "copy --print gives the tidy text" "$("$CLI" copy "$IDT" --print | grep -o 'go around the back' | wc -l)" "1"
eq "copy --raw --print gives the raw text" "$("$CLI" copy "$IDT" --raw --print | grep -o 'go around the back' | wc -l)" "4"
check "export uses the tidy text" bash -c "\"$CLI\" export '$IDT' --dir '$TMP/exp-tidy' --no-open >/dev/null && grep -o 'go around the back' '$TMP/exp-tidy/'*.md | wc -l | grep -qx 1"
check "export --raw uses the raw text" bash -c "\"$CLI\" export '$IDT' --dir '$TMP/exp-raw' --raw --no-open >/dev/null && grep -o 'go around the back' '$TMP/exp-raw/'*.md | wc -l | grep -qx 4"
check "list backfills tidy for an old transcript" bash -c "rm -f '$DT2/transcript.tidy.md'; \"$CLI\" list >/dev/null; test -s '$DT2/transcript.tidy.md'"
check "warn threshold at 33 flips the flag" bash -c "OMARECORDER_LOOP_WARN_WORDS=33 \"$CLI\" tidy '$IDT' >/dev/null && jq -e '.transcript.tidy.loop_warning == true' '$DT2/meta.json'"
check "warn threshold at 34 leaves it off" bash -c "OMARECORDER_LOOP_WARN_WORDS=34 \"$CLI\" tidy '$IDT' >/dev/null && jq -e '.transcript.tidy.loop_warning == false' '$DT2/meta.json'"
"$CLI" delete "$IDT" --yes >/dev/null
# A genuine whisper death loop: six copies of an 11-word phrase, 55 words gone
# at a single collapse point, well over the default 40-word warning threshold.
IDL=$("$CLI" import "$TMP/quiet.wav" --title "Loop Test"); DL=$("$CLI" show "$IDL" --json | jq -r .dir)
{
  printf '<!-- omarecorder model=base.en language=en created=x range=0-end chunks=1 -->\n'
  printf 'The scene opens on the bridge. '
  for _ in $(seq 1 6); do printf 'we need to go around the back and try the door. '; done
  printf 'And the loop ends there.\n'
} > "$DL/transcript.md"
check "tidy runs on the loopy take" "$CLI" tidy "$IDL"
check "a 55 word run trips the loop warning" bash -c "jq -e '.transcript.tidy.longest_run_words == 55 and .transcript.tidy.loop_warning == true' '$DL/meta.json'"
check "loopy marker counts six copies" grep -Fq 'try the door (repeated 6x).' "$DL/transcript.tidy.md"
"$CLI" delete "$IDL" --yes >/dev/null

}

t_dictionary() {
# The first dictionary command seeds the starter file; an existing file is
# never touched again, however it got there.
check "dictionary seeds the starter file" bash -c "\"$CLI\" dictionary >/dev/null && test -s \"$DICT\""
check "starter teaches the safety rule" grep -q 'never map a word' "$DICT"
check "starter corrects the app's own name" grep -Fq 'oma record -> OmaRecorder' "$DICT"
NSEED=$("$CLI" dictionary --json | jq -r '.count')
eq "count matches the entry lines in the file" "$(grep -Evc '^[[:space:]]*(#|$)' "$DICT")" "$NSEED"
printf '# mine\n' > "$DICT"
"$CLI" dictionary >/dev/null
eq "an existing file is never reseeded" "$(cat "$DICT")" "# mine"
check "help mentions dictionary" bash -c "\"$CLI\" help | grep -q dictionary"
# A controlled dictionary exercises matching; entries are literal,
# case-insensitive, whole words and phrases only.
{
  printf '# test entries\n'
  printf 'hyper land -> Hyprland\n'
  printf 'speed run -> speedrun\n'
  printf 'peller -> Pelor\n'
} > "$DICT"
IDD=$("$CLI" import "$TMP/quiet.wav" --title "Dict Test"); DD=$("$CLI" show "$IDD" --json | jq -r .dir)
{
  printf '<!-- omarecorder model=base.en language=en created=x range=0-end chunks=1 -->\n'
  printf 'We booted hyper land on the laptop. My speed run failed. HYPER LAND again. It ran hyper\n'
  printf 'land fine.\n'
  printf '\n'
  printf 'The cleric of peller kept the speed running mark. Peller helps. That is peller'\''s shield.\n'
} > "$DD/transcript.md"
check "tidy applies the dictionary" "$CLI" tidy "$IDD"
eq "phrase corrected, case-insensitive, across a line break" "$(grep -o 'Hyprland' "$DD/transcript.tidy.md" | wc -l)" "3"
check "whole sentence reads corrected" grep -Fq 'My speedrun failed.' "$DD/transcript.tidy.md"
check "no match inside a longer word" grep -Fq 'speed running' "$DD/transcript.tidy.md"
eq "single word corrected, possessive included" "$(grep -o 'Pelor' "$DD/transcript.tidy.md" | wc -l)" "3"
eq "raw transcript untouched by the dictionary" "$(grep -o 'hyper land' "$DD/transcript.md" | wc -l)" "1"
check "meta counts the corrections" bash -c "jq -e '.transcript.tidy.dict_replacements >= 5' '$DD/meta.json'"
# add: appends one validated entry
check "dictionary add appends" bash -c "\"$CLI\" dictionary add 'oh ma' 'Omarchy' >/dev/null && grep -Fq 'oh ma -> Omarchy' \"$DICT\""
fails "add rejects a duplicate heard form" "$CLI" dictionary add 'oh ma' 'OmaRecorder'
fails "add rejects an empty heard form" "$CLI" dictionary add '' 'x'
fails "add rejects an arrow in the heard form" "$CLI" dictionary add 'a -> b' 'c'
eq "dictionary --json counts four entries" "$("$CLI" dictionary --json | jq -r '.count')" "4"
# prompt: ready to paste, with the current entries inlined
check "prompt embeds the current entries" bash -c "\"$CLI\" dictionary prompt | grep -Fq 'hyper land -> Hyprland'"
check "prompt carries the phrase safety example" bash -c "\"$CLI\" dictionary prompt | grep -Fq 'get push'"
# export writes a byte-identical copy
check "export writes a copy" bash -c "\"$CLI\" dictionary export '$TMP/dict.copy' >/dev/null && diff -q \"$DICT\" '$TMP/dict.copy' >/dev/null"
# import merges: new added, duplicates skipped, conflicts keep the existing
# entry, malformed lines reported by number, all in one summary
{
  printf 'hyper land -> HyprLand\n'
  printf 'speed run -> speedrun\n'
  printf 'quick shell -> Quickshell\n'
  printf 'garbage line without an arrow\n'
} > "$TMP/dict.new"
IMPOUT=$("$CLI" dictionary import "$TMP/dict.new")
check "import adds the new entry" grep -Fq 'quick shell -> Quickshell' "$DICT"
check "conflict keeps the existing correction" grep -Fq 'hyper land -> Hyprland' "$DICT"
check "conflicting new form is not imported" bash -c "! grep -Fq 'HyprLand' \"$DICT\""
check "summary counts one added" grep -q '1 added' <<<"$IMPOUT"
check "summary counts one duplicate" grep -q '1 duplicate' <<<"$IMPOUT"
check "summary counts one conflict" grep -q '1 conflict' <<<"$IMPOUT"
check "summary names the malformed line" grep -q 'line 4' <<<"$IMPOUT"
fails "import with nothing usable fails" bash -c "printf 'junk\n' > '$TMP/dict.junk' && \"$CLI\" dictionary import '$TMP/dict.junk'"
# self-heal: a dictionary newer than a tidy file rebuilds it on list
touch -d '-5 seconds' "$DD/transcript.tidy.md"
check "list refreshes tidy when the dictionary is newer" bash -c "\"$CLI\" dictionary add 'the laptop' 'the ThinkPad' >/dev/null && \"$CLI\" list >/dev/null && grep -q 'ThinkPad' '$DD/transcript.tidy.md'"
"$CLI" delete "$IDD" --yes >/dev/null
# Upgrade path: tidy files are current but the dictionary does not exist yet.
# A plain list must seed the starter and refresh the stale tidies in the same
# pass ("owl bear" is a starter entry the test dictionary above lacks).
IDU=$("$CLI" import "$TMP/quiet.wav" --title "Upgrade Test"); DU=$("$CLI" show "$IDU" --json | jq -r .dir)
printf '<!-- omarecorder model=base.en language=en created=x range=0-end chunks=1 -->\nThe owl bear waited by the door.\n' > "$DU/transcript.md"
"$CLI" tidy "$IDU" >/dev/null
rm -f "$DICT"; touch -d '-5 seconds' "$DU/transcript.tidy.md"
"$CLI" list >/dev/null
check "list seeds the dictionary on upgrade" test -s "$DICT"
check "and refreshes existing tidies with the starter" grep -q 'owlbear' "$DU/transcript.tidy.md"
"$CLI" delete "$IDU" --yes >/dev/null

}

t_polish() {
eq "empty list is script-clean" "$(OMARECORDER_DIR="$TMP/EmptyRoot" "$CLI" list)" ""
check "dictionary list --json is JSON too" bash -c "\"$CLI\" dictionary list --json | jq -e '.count >= 0' >/dev/null"
printf 'alpha -> beta -> gamma\n' > "$TMP/dict.arrows"
"$CLI" dictionary import "$TMP/dict.arrows" >/dev/null
check "json splits at the first arrow like the engine" bash -c "\"$CLI\" dictionary --json | jq -e '.entries[] | select(.heard==\"alpha\" and .written==\"beta -> gamma\")' >/dev/null"
check "export failure dies in the house voice" bash -c "! \"$CLI\" dictionary export /nonexistent-dir/x 2>/dev/null && \"$CLI\" dictionary export /nonexistent-dir/x 2>&1 | grep -q 'omarecorder:'"
printf 'junk one\njunk two\nreal -> entry\n' > "$TMP/dict.bad2"
check "import names multiple malformed lines grammatically" bash -c "\"$CLI\" dictionary import '$TMP/dict.bad2' | grep -q 'lines 1, 2'"
check "prompt defuses its own placeholder" bash -c "\"$CLI\" dictionary prompt | grep -Fq 'ask me what I talk about'"
IDX=$("$CLI" import "$TMP/quiet.wav" --title "Hint Test")
# The hint comes after the engine check, so a stand-in voxtype keeps this honest where the real one is absent (CI).
mkdir -p "$TMP/voxok"; printf '#!/bin/sh\nexit 0\n' > "$TMP/voxok/voxtype"; chmod +x "$TMP/voxok/voxtype"
check "bogus model hint does not suggest an impossible download" bash -c "OUT=\$(PATH=\"$TMP/voxok:\$PATH\" VOXTYPE_MODELS_DIR=\"$TMP/nomodels\" \"$CLI\" transcribe '$IDX' --model bogus 2>&1); ! grep -q 'model download bogus' <<<\"\$OUT\" && grep -q 'not in the catalog' <<<\"\$OUT\""
"$CLI" delete "$IDX" --yes >/dev/null
printf '# emptied by the test suite\n' > "$DICT"

}

t_guards() {
IDG=$("$CLI" import "$TMP/quiet.wav" --title "Guard Test")
set_state null "[$(tx_job "$IDG")]"
fails "rename refused while transcribing" "$CLI" rename "$IDG" "New Name"
fails "note refused while transcribing" "$CLI" note "$IDG" "not now"
fails "delete refused while transcribing" "$CLI" delete "$IDG" --yes
fails "second transcribe refused" "$CLI" transcribe "$IDG" --model base.en
eq "and the existing job survives the refusal" "$(jq -r '.jobs|length' "$RUN/state.json")" "1"
"$CLI" cancel "$IDG" >/dev/null
check "show exits 0 without a transcript" "$CLI" show "$IDG"
fails "cancel rejects a malformed id" "$CLI" cancel "../escape"
fails "play rejects trailing garbage" "$CLI" play "$IDG" garbage
"$CLI" delete "$IDG" --yes >/dev/null
mkdir -p "$TMP/novox"; printf '#!/bin/sh\nexit 1\n' > "$TMP/novox/voxtype"; chmod +x "$TMP/novox/voxtype"
check "setup check survives a voxtype that fails" bash -c "PATH=\"$TMP/novox:\$PATH\" \"$CLI\" setup check --json | jq -e '.version' >/dev/null"

}

t_models() {
ensure_base
check "models --json lists base.en" bash -c "$CLI models --json | jq -e '.[] | select(.name==\"base.en\")'"
eq "estimate uses default rtf" "$($CLI estimate "$ID1" --model base.en | jq -r '.rtf, .source' | paste -sd,)" "10,default"
fails "estimate rejects unknown model" "$CLI" estimate "$ID1" --model nope

}

t_download() {
# A stub voxtype plus an empty scratch model dir gives full control of the
# download worker's success predicate (child exit 0 AND the ggml file exists),
# so the whole download-then-transcribe chain runs without the real engine.
IDD=$("$CLI" import "$TMP/quiet.wav" --title "Chain Test")
DD="$OMARECORDER_DIR/$IDD Chain Test"
DLM="$TMP/dlmodels"; mkdir -p "$DLM"

# The intent lands on the download job, nested (never a top-level id).
( PATH="$STUBSNAP:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --from 0 --to 2 --download >/dev/null 2>&1 )
eq "download job carries then.id" "$(jq -r '.jobs[0]."then".id' "$TMP/state.mid")" "$IDD"
eq "then.language recorded" "$(jq -r '.jobs[0]."then".language' "$TMP/state.mid")" "en"
eq "then keeps the requested range" "$(jq -r '.jobs[0]."then" | "\(.from)-\(.to)"' "$TMP/state.mid")" "0-2"
eq "download job keeps no top-level id" "$(jq -r '.jobs[0].id // "absent"' "$TMP/state.mid")" "absent"
eq "failed download leaves no job behind" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"

# Pressing again during a download re-aims the chain on the running job.
jq -cn --arg id "$IDD" --argjson t "$(date +%s)" \
  '{recording:null,jobs:[{type:"download",model:"small.en",unit:"omarecorder-dl-small-en",started_at:$t,expected_bytes:1,"then":{id:"other",language:"en",threads:""}}],version:1}' > "$RUN/state.json"
( PATH="$STUBSNAP:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --download >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "attach to a running download exits 0" "$(cat "$TMP/rc")" "0"
eq "still exactly one download job" "$(jq -r '[.jobs[]|select(.type=="download")]|length' "$RUN/state.json")" "1"
eq "chain re-aimed to the last press" "$(jq -r '[.jobs[]|select(.type=="download")][0]."then".id' "$RUN/state.json")" "$IDD"

# Download failure: no transcribe job is ever created, the then dies with the job.
set_state
( PATH="$STUBFAIL:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --download >/dev/null 2>&1 )
eq "failed chain leaves no jobs" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"
check "and no transcript" bash -c "! test -f \"$DD/transcript.md\""

# The full chain: download lands, transcription follows on its own, with the
# requested range replayed.
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --from 0 --to 2 --download >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "chained download and transcribe exits 0" "$(cat "$TMP/rc")" "0"
check "chained transcript written" bash -c "grep -q 'chained stub text' \"$DD/transcript.md\""
eq "chained transcript records the model" "$(jq -r .transcript.model "$DD/meta.json")" "small.en"
check "chained transcript keeps the range" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'range=0-2'"
eq "raw state holds no jobs afterwards" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"

# A chain whose recording is gone: model still lands, no transcribe job, logged.
jq -cn --argjson t "$(date +%s)" \
  '{recording:null,jobs:[{type:"download",model:"small.en",unit:"u1",started_at:$t,expected_bytes:1,"then":{id:"1999-01-01_000000",language:"en",threads:""}}],version:1}' > "$RUN/state.json"
rm -f "$DLM/ggml-small.en.bin"
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" _dl-worker small.en >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "worker survives a refused chain" "$(cat "$TMP/rc")" "0"
eq "refused chain leaves no jobs" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"
check "refused chain is logged" bash -c "grep -q 'download chain FAILED' \"$XDG_STATE_HOME/omarecorder/omarecorder.log\""

# Plain model download now removes its own job with no reconcile call
# (before, the job lingered and the UI said Downloading forever).
set_state
DLM2="$TMP/dlmodels2"; mkdir -p "$DLM2"
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM2" "$CLI" model download small.en >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "plain download exits 0" "$(cat "$TMP/rc")" "0"
eq "and its job is gone from the raw state" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"

# The chunk override (#38): validated, recorded in meta, parked and replayed.
fails "chunk-s rejects zero" bash -c "PATH=\"$STUB:\$PATH\" VOXTYPE_MODELS_DIR=\"$DLM\" \"$CLI\" transcribe \"$IDD\" --model small.en --chunk-s 0"
fails "chunk-s rejects non-numeric" bash -c "PATH=\"$STUB:\$PATH\" VOXTYPE_MODELS_DIR=\"$DLM\" \"$CLI\" transcribe \"$IDD\" --model small.en --chunk-s abc"
set_state
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --chunk-s 1 >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "chunk override run exits 0" "$(cat "$TMP/rc")" "0"
check "1 s pieces split the 3 s clip in three" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'chunks=3'"
eq "meta records the chunk length used" "$(jq -r .transcript.chunk_s "$DD/meta.json")" "1"
mkdir -p "$TMP/dlm3"
( PATH="$STUBSNAP:$PATH" VOXTYPE_MODELS_DIR="$TMP/dlm3" "$CLI" transcribe "$IDD" --model small.en --chunk-s 7 --download >/dev/null 2>&1 )
eq "then carries chunk_s" "$(jq -r '.jobs[0]."then".chunk_s' "$TMP/state.mid")" "7"
mkdir -p "$TMP/dlm4"; set_state
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$TMP/dlm4" "$CLI" transcribe "$IDD" --model small.en --chunk-s 1 --download >/dev/null 2>&1 )
check "replayed chunk override splits in three" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'chunks=3'"

# The audio cleanup pass (#48): a temporary copy is enhanced (highpass,
# afftdn, two-pass loudnorm) and transcribed; audio.wav is never modified.
eq "enhanceAudio defaults to false" "$($CLI config get enhanceAudio)" "false"
check "enhanceAudio accepts true" "$CLI" config set enhanceAudio true
check "enhanceAudio stored as a real boolean" bash -c "\"$CLI\" config get --json | jq -e '.enhanceAudio == true' >/dev/null"
fails "enhanceAudio rejects other values" "$CLI" config set enhanceAudio maybe
"$CLI" config set enhanceAudio false >/dev/null
cp "$DD/audio.wav" "$TMP/enh.before.wav"
set_state
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --enhance >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "transcribe --enhance exits 0" "$(cat "$TMP/rc")" "0"
check "header records the cleanup pass" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'enhanced=true'"
eq "meta records enhanced true" "$(jq -r .transcript.enhanced "$DD/meta.json")" "true"
check "audio.wav untouched by the pass" cmp -s "$TMP/enh.before.wav" "$DD/audio.wav"
check "no enhance temp left behind" bash -c "! ls \"$DD\"/audio.tx.* >/dev/null 2>&1"
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en >/dev/null 2>&1 )
check "off by default: header has no enhanced tag" bash -c "! head -1 \"$DD/transcript.md\" | grep -q enhanced"
eq "meta records enhanced false" "$(jq -r .transcript.enhanced "$DD/meta.json")" "false"
"$CLI" config set enhanceAudio true >/dev/null
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en >/dev/null 2>&1 )
check "config true turns the pass on" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'enhanced=true'"
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --no-enhance >/dev/null 2>&1 )
eq "--no-enhance overrides the config" "$(jq -r .transcript.enhanced "$DD/meta.json")" "false"
"$CLI" config set enhanceAudio false >/dev/null
# Chunked long take: the cleanup runs once on the tx input, before the split.
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --chunk-s 1 --enhance >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "enhanced chunked run exits 0" "$(cat "$TMP/rc")" "0"
check "still split into three pieces" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'chunks=3'"
check "and carries the enhanced tag" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'enhanced=true'"
# Parked on a download: the resolved choice rides the then intent and replays.
mkdir -p "$TMP/dlm5"
( PATH="$STUBSNAP:$PATH" VOXTYPE_MODELS_DIR="$TMP/dlm5" "$CLI" transcribe "$IDD" --model small.en --enhance --download >/dev/null 2>&1 )
eq "then carries enhance" "$(jq -r '.jobs[0]."then".enhance' "$TMP/state.mid")" "true"
mkdir -p "$TMP/dlm6"; set_state
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$TMP/dlm6" "$CLI" transcribe "$IDD" --model small.en --enhance --download >/dev/null 2>&1 )
check "replayed chain keeps the enhanced tag" bash -c "head -1 \"$DD/transcript.md\" | grep -q 'enhanced=true'"
# A failing cleanup falls back to the original audio instead of failing the job.
FFENH="$TMP/ffenh"; mkdir -p "$FFENH"
REAL_FFMPEG=$(command -v ffmpeg)
cat > "$FFENH/ffmpeg" <<FFEOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *afftdn*) exit 1 ;; esac; done
exec "$REAL_FFMPEG" "\$@"
FFEOF
chmod +x "$FFENH/ffmpeg"
set_state
( PATH="$FFENH:$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" transcribe "$IDD" --model small.en --enhance >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "failed cleanup still transcribes" "$(cat "$TMP/rc")" "0"
eq "and records enhanced false" "$(jq -r .transcript.enhanced "$DD/meta.json")" "false"
check "fallback is logged" bash -c "grep -q 'enhance failed' \"$XDG_STATE_HOME/omarecorder/omarecorder.log\""

# model cancel (#39): validated, idempotent, atomic job + chain removal.
fails "cancel unknown model" "$CLI" model cancel bogus
set_state
check "cancel with nothing running exits 0" "$CLI" model cancel small.en
jq -cn --argjson t "$(date +%s)" \
  '{recording:null,jobs:[{type:"download",model:"small.en",unit:"omarecorder-dl-small-en",started_at:$t,expected_bytes:1,"then":{id:"x",language:"en",threads:""}}],version:1}' > "$RUN/state.json"
touch "$DLM/ggml-small.en.bin.part"
mkdir -p "$TMP/nosysd"; printf '#!/bin/sh\nexit 0\n' > "$TMP/nosysd/systemctl"; chmod +x "$TMP/nosysd/systemctl"   # never stop a unit on the real user manager
check "cancel a chained download exits 0" bash -c "PATH=\"$TMP/nosysd:\$PATH\" VOXTYPE_MODELS_DIR=\"$DLM\" \"$CLI\" model cancel small.en"
eq "cancelled download job removed" "$(jq -r '.jobs|length' "$RUN/state.json")" "0"
check "partial file left for voxtype to resume" test -f "$DLM/ggml-small.en.bin.part"
check "cancel is logged" bash -c "grep -q 'download cancelled small.en' \"$XDG_STATE_HOME/omarecorder/omarecorder.log\""

# Auto-transcribe on stop (#40): default off, typed storage, fires only when
# the default model is already on disk.
eq "autoTranscribe defaults to false" "$($CLI config get autoTranscribe)" "false"
check "autoTranscribe accepts true" "$CLI" config set autoTranscribe true
check "stored as a real boolean" bash -c "\"$CLI\" config get --json | jq -e '.autoTranscribe == true' >/dev/null"
fails "autoTranscribe rejects other values" "$CLI" config set autoTranscribe maybe
head -c 100 /dev/zero > "$DLM/ggml-base.en.bin"   # default model "installed" for the stub
AD=$(mkstoprec 2026-01-06_010101 AutoOn)
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" record stop >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "stop with autoTranscribe on exits 0" "$(cat "$TMP/rc")" "0"
check "transcription followed the stop" bash -c "grep -q 'chained stub text' \"$AD/transcript.md\""
AD=$(mkstoprec 2026-01-06_020202 AutoMissing)
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$TMP/nomodels" "$CLI" record stop >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "stop with the model missing exits 0" "$(cat "$TMP/rc")" "0"
check "and does not transcribe (notification fallback)" bash -c "! test -f \"$AD/transcript.md\""
"$CLI" config set autoTranscribe false >/dev/null
AD=$(mkstoprec 2026-01-06_030303 AutoOff)
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$DLM" "$CLI" record stop >/dev/null 2>&1 )
check "stop with autoTranscribe off does not transcribe" bash -c "! test -f \"$AD/transcript.md\""

# Guard rails unchanged.
( PATH="$STUB:$PATH" VOXTYPE_MODELS_DIR="$TMP/nomodels" "$CLI" transcribe "$IDD" --model small.en >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "without --download still exit 3" "$(cat "$TMP/rc")" "3"
fails "unknown model refused even with --download" bash -c "PATH=\"$STUB:\$PATH\" VOXTYPE_MODELS_DIR=\"$TMP/nomodels\" \"$CLI\" transcribe \"$IDD\" --model bogus --download"
"$CLI" delete "$IDD" --yes >/dev/null

}

t_search() {
SA=$("$CLI" import "$TMP/quiet.wav" --title "Search A")
SB=$("$CLI" import "$TMP/quiet.wav" --title "Search B")
SAD="$OMARECORDER_DIR/$SA Search A"
printf '<!-- omarecorder model=base.en -->\nthe blue heron landed\n' > "$SAD/transcript.md"
fails "search requires a query" "$CLI" search
eq "search finds the transcript word" "$("$CLI" search heron)" "[\"$SA\"]"
eq "search is case-insensitive" "$("$CLI" search HERON)" "[\"$SA\"]"
eq "no match returns an empty array" "$("$CLI" search walrus)" "[]"
eq "regex text is inert (fixed strings)" "$("$CLI" search '.*')" "[]"
eq "a leading dash is a query, not an option" "$("$CLI" search '-heron')" "[]"
check "the header line is not searched" bash -c "[ \"\$(\"$CLI\" search omarecorder)\" = '[]' ]"
# Tidy is preferred once it exists: search follows what the user reads.
printf '<!-- 1 paragraphs, 0 repeats, 0 loops, -->\na walrus instead\n' > "$SAD/transcript.tidy.md"
eq "tidy text wins once present" "$("$CLI" search walrus)" "[\"$SA\"]"
eq "raw-only text no longer matches" "$("$CLI" search heron)" "[]"
# An early match in a transcript larger than the pipe buffer must not be lost
# to pipefail when grep short-circuits (the SIGPIPE-vs-pipefail trap).
{ printf '<!-- 1 paragraphs, 0 repeats, 0 loops, -->\nneedle early\n'; yes 'filler words to inflate the file' | head -20000; } > "$SAD/transcript.tidy.md"
eq "early match in a large transcript still found" "$("$CLI" search needle)" "[\"$SA\"]"
"$CLI" delete "$SA" --yes >/dev/null; "$CLI" delete "$SB" --yes >/dev/null

}

t_resume() {
set_state

fails "the resumeWindow key is gone" "$CLI" config get resumeWindow
fails "and cannot be set either" "$CLI" config set resumeWindow 60
fails "record resume with nothing stopped" "$CLI" record resume
fails "record resume rejects extra arguments" "$CLI" record resume now

# A clean stop arms the offer; the state survives unrelated mutations.
RID=$(PATH="$FAKEPATH" "$CLI" record start --title "Resume Take")
check "fake stack records" test -n "$RID"
RD="$OMARECORDER_DIR/$RID Resume Take"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "stop arms the resume offer" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$RID"
eq "the offer carries the title" "$(jq -r '.last_stop.title' "$RUN/state.json")" "Resume Take"
eq "the offer starts resumable" "$(jq -r '.last_stop.resumable' "$RUN/state.json")" "true"
check "the offer records the stop moment and no expiry" bash -c "jq -e '.last_stop.stopped_at > 0 and (.last_stop | has(\"resume_until\") | not)' '$RUN/state.json'"
"$CLI" config set threads 0 >/dev/null
eq "the offer survives unrelated state writes" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$RID"
eq "status --json makes the offer" "$("$CLI" status --json | jq -r '.resume.id')" "$RID"
check "and says how long ago the stop was" bash -c "\"$CLI\" status --json | jq -e '.resume.stopped_ago_s >= 0'"
"$CLI" rename "$RID" "Renamed Take" >/dev/null
eq "rename keeps the offer's title current" "$(jq -r '.last_stop.title' "$RUN/state.json")" "Renamed Take"
"$CLI" rename "$RID" "Resume Take" >/dev/null

# The happy path: resume records a separate segment, stop joins it losslessly.
eq "stopped take is 3 s" "$(jq -r .duration_s "$RD/meta.json")" "3"
jq -c '.transcript = {model:"base.en"}' "$RD/meta.json" > "$RD/meta.json.t" && mv -f "$RD/meta.json.t" "$RD/meta.json"
touch "$TMP/resume.marker"
check "record resume continues the take" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record resume >/dev/null"
check "the continuation is a separate segment file" test -s "$RD/audio.seg.wav"
eq "the original is untouched while resuming" "$(jq -r .duration_s "$RD/meta.json")" "3"
eq "state marks the recording as a resume" "$("$CLI" status --json | jq -r '.recording.resume')" "true"
eq "no offer while recording" "$("$CLI" status --json | jq -r '.resume')" "null"
eq "the offer is consumed by the resume" "$(jq -r '.last_stop' "$RUN/state.json")" "null"
fails "a second resume is refused while recording" env PATH="$FAKEPATH" "$CLI" record resume
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "joined take is 6 s" "$(jq -r .duration_s "$RD/meta.json")" "6"
eq "audio.wav really is 6 s" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RD/audio.wav" | cut -d. -f1)" "6"
eq "the seam offset is recorded" "$(jq -c .resume_seams "$RD/meta.json")" "[3]"
eq "size updated after the join" "$(jq -r .size_bytes "$RD/meta.json")" "$(stat -c %s "$RD/audio.wav")"
eq "the transcript is flagged stale" "$(jq -r .transcript.stale "$RD/meta.json")" "true"
check "levels re-measured" bash -c "jq -e '.levels.peak_db' '$RD/meta.json'"
check "waveform regenerated" bash -c "find '$RD' -maxdepth 1 -name waveform.png -newer '$TMP/resume.marker' | grep -q ."
check "segment files cleaned up" bash -c "! ls '$RD'/*.seg.wav >/dev/null 2>&1"
eq "the resumed take is offered again" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$RID"
check "a second resume appends a second seam" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record resume >/dev/null && PATH=\"$FAKEPATH\" \"$CLI\" record stop >/dev/null"
eq "two seams now" "$(jq -c .resume_seams "$RD/meta.json")" "[3,6]"
eq "9 s after two resumes" "$(jq -r .duration_s "$RD/meta.json")" "9"

# Never automatic: toggle and start always begin a new recording.
check "toggle with an offer armed starts fresh" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record toggle >/dev/null"
NEWID=$("$CLI" status --json | jq -r '.recording.id')
check "and it is a new take, not the resumable one" test "$NEWID" != "$RID"
eq "starting a new recording clears the offer" "$(jq -r '.last_stop' "$RUN/state.json")" "null"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "the new take is the one offered now" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$NEWID"
"$CLI" delete "$NEWID" --yes >/dev/null
eq "deleting the offered take clears the offer" "$(jq -r '.last_stop' "$RUN/state.json")" "null"

# No time limit: only the popup button and the hotkey resume, and the bar
# right-click always starts fresh, so the offer simply stands until it is
# consumed, a new recording starts, or the take is trimmed or deleted.
NOW=$(date +%s)
armresume "$RID" "$((NOW - 100000))"
eq "an offer from yesterday still stands" "$("$CLI" status --json | jq -r '.resume.id')" "$RID"
eq "and reconcile leaves it alone" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$RID"
check "a day-old offer still resumes" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record resume >/dev/null && PATH=\"$FAKEPATH\" \"$CLI\" record stop >/dev/null"
eq "day-old resume added its seam" "$(jq -c '.resume_seams | length' "$RD/meta.json")" "3"

# A trimmed take is not resumable; restore brings the offer back.
armresume "$RID"
"$CLI" trim "$RID" --from 0 --to 2 >/dev/null
eq "trim turns the offer off" "$(jq -r '.last_stop.resumable' "$RUN/state.json")" "false"
eq "a trimmed offer is hidden from status" "$("$CLI" status --json | jq -r '.resume')" "null"
fails "resume of a trimmed take is refused" env PATH="$FAKEPATH" "$CLI" record resume
"$CLI" trim "$RID" --restore >/dev/null
eq "restore turns the offer back on" "$(jq -r '.last_stop.resumable' "$RUN/state.json")" "true"
check "and resume works again after the restore" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record resume >/dev/null && PATH=\"$FAKEPATH\" \"$CLI\" record stop >/dev/null"
eq "four seams after the restore-and-recut path" "$(jq -c '.resume_seams | length' "$RD/meta.json")" "4"
# The disk is the truth: a restore point on disk refuses even an armed offer.
armresume "$RID"
touch "$RD/audio.orig.wav"
fails "a restore point on disk refuses the resume" env PATH="$FAKEPATH" "$CLI" record resume
rm -f "$RD/audio.orig.wav"
set_state
"$CLI" delete "$RID" --yes >/dev/null

# A "both" take: the segment pair is mixed and all three tracks are joined.
BID=$(PATH="$FAKEPATH" "$CLI" record start --source both --title "Both Resume")
BD="$OMARECORDER_DIR/$BID Both Resume"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "both take mixed to 3 s" "$(jq -r .duration_s "$BD/meta.json")" "3"
check "both resume starts" bash -c "PATH=\"$FAKEPATH\" \"$CLI\" record resume >/dev/null"
check "a segment pair is recording" test -s "$BD/mic.seg.wav" -a -s "$BD/system.seg.wav"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "both: the mix is 6 s" "$(jq -r .duration_s "$BD/meta.json")" "6"
eq "both: mic.wav joined too" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BD/mic.wav" | cut -d. -f1)" "6"
eq "both: system.wav joined too" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BD/system.wav" | cut -d. -f1)" "6"
eq "both: seam recorded" "$(jq -c .resume_seams "$BD/meta.json")" "[3]"
check "both: segments cleaned up" bash -c "! ls '$BD'/*.seg.wav >/dev/null 2>&1"
"$CLI" delete "$BID" --yes >/dev/null

# A crash mid-resume: the original is untouched and the segment is joined by
# the existing crash-recovery path on the next command.
CID="2026-02-01_010101"; CD="$OMARECORDER_DIR/$CID Crash Resume"; mkdir -p "$CD"
cp "$TMP/quiet.wav" "$CD/audio.wav"; cp "$TMP/quiet.wav" "$CD/audio.seg.wav"
jq -cn --arg id "$CID" '{id:$id,title:"Crash Resume",source:"mic",created:"2026-02-01T01:01:01+0000",duration_s:3,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$CD/meta.json"
jq -cn --arg id "$CID" --arg dir "$CD" '{recording:{id:$id,source:"mic",dir:$dir,started_at:0,pids:[999999],files:[],resume:true},jobs:[],version:1}' > "$RUN/state.json"
eq "status clears the dead resume" "$("$CLI" status)" "idle"
eq "the crashed segment was joined" "$(jq -r .duration_s "$CD/meta.json")" "6"
eq "recovery records the seam" "$(jq -c .resume_seams "$CD/meta.json")" "[3]"
check "no segment left after recovery" bash -c "! ls '$CD'/*.seg.wav >/dev/null 2>&1"
"$CLI" delete "$CID" --yes >/dev/null
# A husk of a segment (nothing beyond a header) is dropped, take unchanged.
CID2="2026-02-02_020202"; CD2="$OMARECORDER_DIR/$CID2 Husk Resume"; mkdir -p "$CD2"
cp "$TMP/quiet.wav" "$CD2/audio.wav"; head -c 44 /dev/zero > "$CD2/audio.seg.wav"
jq -cn --arg id "$CID2" '{id:$id,title:"Husk Resume",source:"mic",created:"2026-02-02T02:02:02+0000",duration_s:3,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$CD2/meta.json"
jq -cn --arg id "$CID2" --arg dir "$CD2" '{recording:{id:$id,source:"mic",dir:$dir,started_at:0,pids:[999999],files:[],resume:true},jobs:[],version:1}' > "$RUN/state.json"
"$CLI" status >/dev/null
eq "a husk segment is dropped, take unchanged" "$(jq -r .duration_s "$CD2/meta.json")" "3"
check "husk segment removed" bash -c "! test -e '$CD2/audio.seg.wav'"
"$CLI" delete "$CID2" --yes >/dev/null
# A crashed "both" resume joins all three tracks.
CID3="2026-02-03_030303"; CD3="$OMARECORDER_DIR/$CID3 Both Crash Resume"; mkdir -p "$CD3"
cp "$TMP/quiet.wav" "$CD3/audio.wav"; cp "$TMP/quiet.wav" "$CD3/mic.wav"; cp "$TMP/quiet.wav" "$CD3/system.wav"
cp "$TMP/quiet.wav" "$CD3/mic.seg.wav"; cp "$TMP/quiet.wav" "$CD3/system.seg.wav"
jq -cn --arg id "$CID3" '{id:$id,title:"Both Crash Resume",source:"both",created:"2026-02-03T03:03:03+0000",duration_s:3,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$CD3/meta.json"
jq -cn --arg id "$CID3" --arg dir "$CD3" '{recording:{id:$id,source:"both",dir:$dir,started_at:0,pids:[999999],files:[],resume:true},jobs:[],version:1}' > "$RUN/state.json"
"$CLI" status >/dev/null
eq "both crash: the mix is 6 s" "$(jq -r .duration_s "$CD3/meta.json")" "6"
eq "both crash: mic.wav joined" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CD3/mic.wav" | cut -d. -f1)" "6"
eq "both crash: system.wav joined" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CD3/system.wav" | cut -d. -f1)" "6"
"$CLI" delete "$CID3" --yes >/dev/null
set_state

# Overlapping resumes: the offer must be consumed under the lock before any
# shared segment file is touched, so the loser of a double-press can never
# unlink the winner's live segment. The first caller's recorder is held back
# so the second lands squarely in the old danger window between the unlocked
# pre-checks and the claim.
RVID=$(PATH="$FAKEPATH" "$CLI" record start --title "Race Take")
RVD="$OMARECORDER_DIR/$RVID Race Take"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
( PATH="$FAKEPATH" PWREC_DELAY=2.5 "$CLI" record resume >/dev/null 2>&1; echo $? > "$TMP/rc.a" ) &
RACER=$!
wait_for 2 bash -c "[ \"\$(jq -r '.last_stop' '$RUN/state.json')\" = null ]"
# The first caller is still parked waiting for its recorder's file here; the
# offer must already be gone from the state, or a second caller could pass
# its own checks and race for the same segment paths.
eq "the offer is consumed before the recorder even starts" "$(jq -r '.last_stop' "$RUN/state.json")" "null"
( PATH="$FAKEPATH" "$CLI" record resume >/dev/null 2>&1; echo $? > "$TMP/rc.b" )
wait "$RACER" 2>/dev/null
check "exactly one of two overlapping resumes wins" bash -c "A=\$(cat '$TMP/rc.a'); B=\$(cat '$TMP/rc.b'); { [ \"\$A\" = 0 ] && [ \"\$B\" != 0 ]; } || { [ \"\$A\" != 0 ] && [ \"\$B\" = 0 ]; }"
eq "the winner is recording its segment" "$("$CLI" status --json | jq -r '.recording.resume')" "true"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "stopping the winner still finds its segment" "$(cat "$TMP/rc")" "0"
eq "race take joined to 6 s" "$(jq -r .duration_s "$RVD/meta.json")" "6"
# A resume whose recorder cannot start gives the offer back (nothing else
# moved, so the user can fix the device and try again).
BROKEN="$TMP/brokenrec"; mkdir -p "$BROKEN"
cp "$FAKEAUDIO/pactl" "$BROKEN/pactl"
printf '#!/bin/bash\nexit 1\n' > "$BROKEN/pw-record"; chmod +x "$BROKEN/pw-record"
NOW=$(date +%s); armresume "$RVID"
fails "resume with a broken recorder fails" env PATH="$BROKEN:$PATH" "$CLI" record resume
eq "and the offer is given back" "$(jq -r '.last_stop.id' "$RUN/state.json")" "$RVID"
"$CLI" delete "$RVID" --yes >/dev/null

# A stop that finishes late must not clobber a newer offer: finalizing can be
# slow (mixing, waveform, levels), and a newer take can start and stop in the
# meantime. The armed offer here carries a stopped_at later than this stop's,
# standing in for that newer take; the late arm has to lose.
NOW=$(date +%s)
SID="2026-02-04_040404"; SD="$OMARECORDER_DIR/$SID Slow Stop"; mkdir -p "$SD"
cp "$TMP/quiet.wav" "$SD/audio.wav"
jq -cn --arg id "$SID" '{id:$id,title:"Slow Stop",source:"mic",created:"2026-02-04T04:04:04+0000",duration_s:null,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$SD/meta.json"
sleep 60 >/dev/null 2>&1 & SPID=$!
jq -cn --arg id "$SID" --arg dir "$SD" --argjson p "$SPID" --argjson t "$NOW" \
  '{recording:{id:$id,dir:$dir,source:"mic",pids:[$p],started_at:$t},jobs:[],version:1,
    last_stop:{id:"2026-02-05_050505",title:"Newer",stopped_at:($t+50),resumable:true}}' > "$RUN/state.json"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
eq "a late arm never clobbers a newer offer" "$(jq -r '.last_stop.id' "$RUN/state.json")" "2026-02-05_050505"
"$CLI" delete "$SID" --yes >/dev/null

# While a resume is still starting (its recorder held back), the take must
# already be reserved in the state: a trim, rename, delete or stop in that
# window would edit or move audio the continuation is about to append to.
RSID=$(PATH="$FAKEPATH" "$CLI" record start --title "Reserve Take")
RSD="$OMARECORDER_DIR/$RSID Reserve Take"
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1 )
( PATH="$FAKEPATH" PWREC_DELAY=2.5 "$CLI" record resume >/dev/null 2>&1 ) &
RESUMER=$!
wait_for 2 bash -c "[ \"\$(\"$CLI\" status --json | jq -r '.recording.id')\" = '$RSID' ]"
eq "the take is reserved while the resume starts" "$("$CLI" status --json | jq -r '.recording.id')" "$RSID"
fails "trim is refused during the resume start" "$CLI" trim "$RSID" --from 0 --to 1
fails "rename is refused during the resume start" "$CLI" rename "$RSID" "Nope"
fails "delete is refused during the resume start" "$CLI" delete "$RSID" --yes
fails "stop during the start window is refused, not orphaned" "$CLI" record stop
wait "$RESUMER" 2>/dev/null
( PATH="$FAKEPATH" "$CLI" record stop >/dev/null 2>&1; echo $? > "$TMP/rc" )
eq "the reserved resume still lands cleanly" "$(cat "$TMP/rc")" "0"
eq "reserved take joined to 6 s" "$(jq -r .duration_s "$RSD/meta.json")" "6"
"$CLI" delete "$RSID" --yes >/dev/null

# A take that is being transcribed cannot be resumed right now, so no offer
# is made while its job runs; it comes back when the job ends.
NOW=$(date +%s)
jq -cn --argjson t "$NOW" '{recording:null,version:1,
  jobs:[{type:"transcribe",id:"2026-02-07_070707",model:"base.en",started_at:$t}],
  last_stop:{id:"2026-02-07_070707",title:"Busy",stopped_at:$t,resumable:true}}' > "$RUN/state.json"
eq "no offer while the take is transcribing" "$("$CLI" status --json | jq -r '.resume')" "null"
fails "resume refused while the take transcribes" env PATH="$FAKEPATH" "$CLI" record resume
jq -cn --argjson t "$NOW" '{recording:null,version:1,jobs:[],
  last_stop:{id:"2026-02-07_070707",title:"Busy",stopped_at:$t,resumable:true}}' > "$RUN/state.json"
eq "the offer returns when the job ends" "$("$CLI" status --json | jq -r '.resume.id')" "2026-02-07_070707"
set_state

}

t_transcribe() {
if command -v voxtype >/dev/null && [[ -f "${VOXTYPE_MODELS_DIR:-$HOME/.local/share/voxtype/models}/ggml-base.en.bin" && -f "$TMP/speech12.wav" ]]; then
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
  check "transcription also writes transcript.tidy.md" test -s "$D3/transcript.tidy.md"
  check "and records the tidy stats in meta" bash -c "jq -e '.transcript.tidy.paragraphs >= 1' '$D3/meta.json'"
  check "short clip does not train the estimate" bash -c "! test -f '$XDG_STATE_HOME/omarecorder/bench.json'"
  check "elapsed_s recorded with sub-second precision" bash -c "jq -e '.transcript.elapsed_s > 0' '$D3/meta.json'"
  ID6=$($CLI import "$TMP/speech60.wav" --title "Speech 60s")
  check "transcribe 60 s clip" "$CLI" transcribe "$ID6" --model base.en
  check "bench.json learned rtf from 60 s clip" bash -c "jq -e '.[\"base.en\"].rtf > 0' '$XDG_STATE_HOME/omarecorder/bench.json'"
  eq "estimate now measured" "$($CLI estimate "$ID3" --model base.en | jq -r .source)" "measured"
  eq "list has_transcript true" "$($CLI show "$ID3" --json | jq -r .has_transcript)" "true"
  check "show --json includes text" bash -c "$CLI show '$ID3' --json | jq -e '.transcript_text | length > 0'"
  eq "no jobs left in state" "$($CLI status --json | jq -r '.jobs|length')" "0"
  eq "has_prev false before a re-run" "$($CLI show "$ID3" --json | jq -r .has_prev)" "false"
  check "range transcribe" "$CLI" transcribe "$ID3" --model base.en --from 0 --to 3
  check "range header" bash -c "head -1 '$D3/transcript.md' | grep -q 'range=0-3'"
  # The big WAV temps (range cut, chunks) go next to the recording, never into
  # tmpfs, and are cleaned up either way.
  check "no WAV temps under \$RUN_DIR after a range transcribe" bash -c "! ls '$RUN'/tx-*.wav >/dev/null 2>&1"
  check "no audio.tx temps left in the recording folder" bash -c "! ls '$D3'/audio.tx.* >/dev/null 2>&1"
  check "previous transcript kept on re-run" bash -c "head -1 '$D3/transcript.prev.md' | grep -q 'range=0-end'"
  eq "has_prev true after a re-run" "$($CLI show "$ID3" --json | jq -r .has_prev)" "true"
  check "show --json has prev_path and prev_text" bash -c "\"$CLI\" show '$ID3' --json | jq -e '.prev_path and (.prev_text | length > 0)'"

  echo "== transcribe (cleanup pass, real engine)"
  cp "$D3/audio.wav" "$TMP/enh.real.before.wav"
  check "enhanced transcribe (real) succeeds" "$CLI" transcribe "$ID3" --model base.en --enhance
  check "real enhanced header tag" bash -c "head -1 '$D3/transcript.md' | grep -q 'enhanced=true'"
  check "enhanced transcript still mentions 'right'" bash -c "grep -qi right '$D3/transcript.md'"
  check "recording unchanged by the real pass" cmp -s "$TMP/enh.real.before.wav" "$D3/audio.wav"
  check "no enhance temps after the real pass" bash -c "! ls '$D3'/audio.tx.* >/dev/null 2>&1"

  echo "== transcribe (bad OMARECORDER_CHUNK_S falls back)"
  check "non-numeric OMARECORDER_CHUNK_S still transcribes" env OMARECORDER_CHUNK_S=abc "$CLI" transcribe "$ID3" --model base.en
  eq "with the default single piece" "$(jq -r '.transcript.chunks' "$D3/meta.json")" "1"
  eq "and leaves no job behind" "$("$CLI" status --json | jq -r '.jobs|length')" "0"

  echo "== transcribe (chunked, OMARECORDER_CHUNK_S=25 on the 60 s clip)"
  D6="$OMARECORDER_DIR/$ID6 Speech 60s"
  check "chunked transcribe succeeds" env OMARECORDER_CHUNK_S=25 "$CLI" transcribe "$ID6" --model base.en
  eq "60 s clip split into 3 pieces" "$(jq -r '.transcript.chunks' "$D6/meta.json")" "3"
  eq "all pieces done" "$(jq -r '.transcript.chunks_done' "$D6/meta.json")" "3"
  eq "not partial" "$(jq -r '.transcript.partial' "$D6/meta.json")" "false"
  check "final header has chunks=3, no partial" bash -c "head -1 '$D6/transcript.md' | grep -q 'chunks=3' && ! head -1 '$D6/transcript.md' | grep -q partial"
  check "chunked transcript mentions 'right'" bash -c "grep -qi right '$D6/transcript.md'"
  check "progress line gone from state" bash -c "[ \"\$(\"$CLI\" status --json | jq -r '.jobs|length')\" = 0 ]"
  check "range + chunks" env OMARECORDER_CHUNK_S=25 "$CLI" transcribe "$ID6" --model base.en --from 0 --to 50
  eq "50 s range → 2 pieces" "$(jq -r '.transcript.chunks' "$D6/meta.json")" "2"
  # cancel keeps the pieces that finished: run the worker directly, TERM it mid-chunk
  rm -f "$D6/transcript.md"
  set_state null "[$(tx_job "$ID6")]"
  OMARECORDER_CHUNK_S=25 setsid "$CLI" _tx-worker "$ID6" base.en en 0 "" "" >/dev/null 2>&1 < /dev/null &
  WPID=$!
  # "transcript.md exists" is not enough: a fast machine can finish every piece
  # before the kill lands. Wait until progress names a chunk that is not the
  # last, so the TERM provably arrives while a later piece is still running.
  MID=""
  for _ in $(seq 1 120); do
    MID=$("$CLI" status --json | jq -r '.jobs[0].progress // empty | select(.chunk > 1 and .chunk < .chunks) | .chunk')
    [[ -n "$MID" && -s "$D6/transcript.md" ]] && break
    sleep 0.5
  done
  check "worker mid-flight on a non-final chunk" test -n "$MID"
  check "partial transcript published after piece 1" test -s "$D6/transcript.md"
  eq "state shows piece progress" "$("$CLI" status --json | jq -r '.jobs[0].progress.chunks')" "3"
  kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WRC=$?
  eq "cancelled worker exits 0" "$WRC" "0"
  check "partial header" bash -c "head -1 '$D6/transcript.md' | grep -q 'partial=true'"
  eq "meta says partial" "$(jq -r '.transcript.partial' "$D6/meta.json")" "true"
  check "no chunk temp files left" bash -c "! ls '$RUN/'tx-* 2>/dev/null | grep -q ."
  "$CLI" cancel "$ID6" >/dev/null

  echo "== transcribe (detached systemd-run unit)"
  if command -v systemd-run >/dev/null && systemctl --user show -p Version >/dev/null 2>&1; then
    rm -f "$D3/transcript.md"
    check "detached transcribe starts" env OMARECORDER_SYNC=0 OMARECORDER_CHUNK_S=5 "$CLI" transcribe "$ID3" --model base.en
    eq "job registered with its unit" "$("$CLI" status --json | jq -r '.jobs[0].unit')" "omarecorder-tx-$ID3"
    for _ in $(seq 1 120); do [[ "$("$CLI" status --json | jq -r '.jobs|length')" == "0" ]] && break; sleep 0.5; done
    eq "job drained when the unit finished" "$("$CLI" status --json | jq -r '.jobs|length')" "0"
    check "transcript written by the unit" test -s "$D3/transcript.md"
    check "OMARECORDER_CHUNK_S reached the unit (12 s at 5 s pieces = 3)" bash -c "jq -e '.transcript.chunks >= 2' '$D3/meta.json'"
    check "unit is gone (collected)" bash -c "! systemctl --user show -p ActiveState --value 'omarecorder-tx-$ID3' | grep -qE '^(active|activating)$'"
  else
    skip "no user systemd manager"
  fi
else
  skip "voxtype/base.en/fixture not available"
fi

}

t_meter() {
printf 'frame:0 pts:0 pts_time:0.2\nlavfi.astats.Overall.Peak_level=-0.1\nlavfi.astats.Overall.Peak_count=69\n' | "$CLI" _meter-loop "$TMP/level" ""
check "start transient (t<1 s) writes nothing" bash -c "! test -e '$TMP/level'"
printf 'frame:4 pts:16000 pts_time:1.0\nlavfi.astats.Overall.Peak_level=-12.5\nlavfi.astats.Overall.Peak_count=0\n' | "$CLI" _meter-loop "$TMP/level" "" --keep
eq "meter parses peak" "$(jq -r .peak_db "$TMP/level")" "-12.5"
eq "quiet frame not clipping" "$(jq -r .clip "$TMP/level")" "false"
printf 'frame:8 pts:32000 pts_time:2.0\nlavfi.astats.Overall.Peak_level=-0.1\nlavfi.astats.Overall.Peak_count=40\n' | "$CLI" _meter-loop "$TMP/level" "" --keep
eq "railed frame sets clip" "$(jq -r .clip "$TMP/level")" "true"
printf 'frame:8 pts:32000 pts_time:2.0\nlavfi.astats.Overall.Peak_level=-inf\nlavfi.astats.Overall.Peak_count=0\n' | "$CLI" _meter-loop "$TMP/level" "" --keep
eq "silence (-inf) becomes -99" "$(jq -r .peak_db "$TMP/level")" "-99"
rm -f "$TMP/level"

}

t_record() {
if pactl list short sources 2>/dev/null | grep -qv '\.monitor'; then
  IDR=$($CLI record start --title "Mic check")
  check "record start returns id" test -n "$IDR"
  eq "status shows recording" "$($CLI status --json | jq -r .recording.id)" "$IDR"
  fails "start refused while recording" "$CLI" record start
  fails "transcribe refused while recording" "$CLI" transcribe "$IDR" --model base.en
  MPID=$("$CLI" status --json | jq -r '.recording.meter_pid')
  check "state has meter_pid" test "$MPID" -gt 0
  for _ in $(seq 1 30); do jq -e '.t > 0' "$RUN/level" >/dev/null 2>&1 && break; sleep 0.2; done
  check "level file updates while recording" jq -e '.t > 0 and (.peak_db|type)=="number"' "$RUN/level"
  sleep 1
  check "record stop" "$CLI" record stop
  DR="$OMARECORDER_DIR/$IDR Mic check"
  eq "wav header valid" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$DR/audio.wav")" "pcm_s16le,16000,1"
  DUR=$(jq -r .duration_s "$DR/meta.json"); check "duration 2–10 s" test "$DUR" -ge 1 -a "$DUR" -le 10
  check "levels measured on stop" bash -c "jq -e '.levels.peak_db' '$DR/meta.json'"
  eq "state cleared" "$($CLI status)" "idle"
  sleep 0.5
  check "meter process gone after stop" bash -c "! kill -0 $MPID 2>/dev/null"
  check "level file removed after stop" bash -c "! test -e '$RUN/level'"
  check "toggle starts" "$CLI" record toggle --source mic
  sleep 1
  check "toggle stops" "$CLI" record toggle
  # resume on real hardware: the segment comes from the real recorder
  IDRR=$("$CLI" record start --title "Resume real"); sleep 1
  "$CLI" record stop >/dev/null
  check "real resume starts" "$CLI" record resume
  sleep 1
  "$CLI" record stop >/dev/null
  DRR="$OMARECORDER_DIR/$IDRR Resume real"
  eq "real resume recorded one seam" "$(jq -r '.resume_seams | length' "$DRR/meta.json")" "1"
  check "joined take runs past the seam" bash -c "jq -e '.duration_s >= .resume_seams[0]' '$DRR/meta.json'"
  eq "real resumed audio is one valid wav" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$DRR/audio.wav")" "pcm_s16le,16000,1"
  "$CLI" delete "$IDRR" --yes >/dev/null
  # long-take stop confirmation: past the threshold the first stop only arms,
  # a second inside 10 s goes through, and --force (the popup button) skips it
  IDL=$(OMARECORDER_STOP_CONFIRM_S=1 "$CLI" record start --title "Long take")
  sleep 2
  eq "stop past the threshold asks to confirm" "$(OMARECORDER_STOP_CONFIRM_S=1 "$CLI" record stop)" "confirm"
  eq "still recording after the first stop" "$("$CLI" status --json | jq -r .recording.id)" "$IDL"
  check "second stop inside the window goes through" env OMARECORDER_STOP_CONFIRM_S=1 "$CLI" record stop
  eq "state cleared after the confirmed stop" "$($CLI status)" "idle"
  IDL2=$(OMARECORDER_STOP_CONFIRM_S=1 "$CLI" record start --title "Long take 2")
  sleep 2
  check "stop --force skips the confirmation" env OMARECORDER_STOP_CONFIRM_S=1 "$CLI" record stop --force
  eq "state cleared after the forced stop" "$($CLI status)" "idle"
  fails "stop rejects an unknown flag" "$CLI" record stop --bogus
  "$CLI" delete "$IDL" --yes >/dev/null; "$CLI" delete "$IDL2" --yes >/dev/null
  if pactl get-default-sink >/dev/null 2>&1; then
    IDS=$("$CLI" record start --source system --title "System check"); sleep 1.5
    # The recorder must hang off the sink's monitor ports, not the microphone.
    check "system source links to the sink monitor" bash -c "pw-link -l | grep -A1 ':monitor_FL' | grep -q 'pw-record'"
    check "system source does not link to the mic" bash -c "! pw-link -l | grep -A1 'alsa_input.*:capture_FL' | grep -q 'pw-record'"
    "$CLI" record stop >/dev/null
    DS="$OMARECORDER_DIR/$IDS System check"
    eq "system source recorded" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$DS/audio.wav")" "pcm_s16le"
    eq "system source stored in meta" "$(jq -r .source "$DS/meta.json")" "system"
    IDB2=$("$CLI" record start --source both --title "Both check")
    eq "both: meter runs on the mic" "$("$CLI" status --json | jq -r '.recording.meter_pid > 0')" "true"
    check "both: one recorder on the mic, one on the monitor" bash -c "pw-link -l | grep -A1 ':monitor_FL' | grep -q 'pw-record' && pw-link -l | grep -A1 'alsa_input.*:capture_FL' | grep -q 'pw-record'"
    sleep 1.5; "$CLI" record stop >/dev/null
    DB2="$OMARECORDER_DIR/$IDB2 Both check"
    check "both: mic.wav + system.wav kept" test -s "$DB2/mic.wav" -a -s "$DB2/system.wav"
    eq "both: audio.wav is the mix" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$DB2/audio.wav")" "pcm_s16le,16000,1"
    check "both: waveform made" test -s "$DB2/waveform.png"
    "$CLI" delete "$IDS" --yes >/dev/null; "$CLI" delete "$IDB2" --yes >/dev/null
  else
    skip "no default sink for system/both sources"
  fi
else
  skip "no microphone source"
fi

}

t_delete() {
ensure_base
DDEL=$("$CLI" show "$ID1" --json | jq -r .dir)
check "delete --yes" "$CLI" delete "$ID1" --yes
check "folder gone" bash -c "! test -d '$DDEL'"
fails "delete unknown fails" "$CLI" delete 2000-01-01_000000 --yes

}

t_setup() {
check "setup check --json runs" bash -c "$CLI setup check --json | jq -e '.version'"
# setup check reports what is missing, with the package to install
check "setup check lists tools" bash -c "\"$CLI\" setup check --json | jq -e '.tools | length > 5'"
mkdir -p "$TMP/nowl"; ln -s /usr/bin/* "$TMP/nowl/" 2>/dev/null; rm -f "$TMP/nowl/wl-copy"
( PATH="$TMP/nowl" "$CLI" setup check --json > "$TMP/setup.json" 2>/dev/null || true )
eq "missing wl-copy reported with package" "$(jq -r '.missing[] | select(.tool=="wl-copy") | .package' "$TMP/setup.json")" "wl-clipboard"
}

# -------------------------------------------------------------------- run ---
SECTIONS=(basics import levels list rename note security locking recovery export trim tidy dictionary polish
          guards models download search resume transcribe meter record delete setup)
if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${SECTIONS[@]}"; exit 0; fi
# A misspelt filter must not pass as "passed: 0 failed: 0".
if [[ -n "${OMARECORDER_TEST_ONLY:-}" ]]; then
  IFS=, read -ra _only <<<"${OMARECORDER_TEST_ONLY// /}"
  for s in "${_only[@]}"; do
    [[ " ${SECTIONS[*]} " == *" $s "* ]] || { echo "unknown section '$s' in OMARECORDER_TEST_ONLY (valid: ${SECTIONS[*]})" >&2; exit 2; }
  done
fi
want() { [[ -z "${OMARECORDER_TEST_ONLY:-}" ]] || [[ ",${OMARECORDER_TEST_ONLY// /}," == *",$1,"* ]]; }
for s in "${SECTIONS[@]}"; do
  want "$s" || continue
  echo "== $s"; t0=$SECONDS
  fresh_state; "t_$s"
  (( SECONDS - t0 >= 10 )) && echo "   ($((SECONDS - t0)) s)"
done

echo
echo "passed: $pass  failed: $fail  skipped: $skipped"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "CLI tests: passed $pass, failed $fail, skipped $skipped" >> "$GITHUB_STEP_SUMMARY"
[[ $fail == 0 ]]
