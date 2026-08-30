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
fails() { # fails <desc> <cmd...> — passes when command exits non-zero
  local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d" "unexpectedly succeeded: $*"; else ok "$d"; fi
}
# A missing fixture/engine is a failure unless the caller opted into skipping
# (CI has no voxtype/mic): OMARECORDER_TEST_ALLOW_SKIP=1.
skip() { if [[ "${OMARECORDER_TEST_ALLOW_SKIP:-0}" == "1" ]]; then echo "  (skipped: $1)"; else bad "skipped: $1"; fi; }
MANIFEST_VERSION=$(jq -r .version "$HERE/../manifest.json")

# Fixtures: short speech clip (ships with alsa-utils) and a 12 s version of it
SPEECH=/usr/share/sounds/alsa/Front_Right.wav
if [[ -f "$SPEECH" ]]; then
  ffmpeg -v error -y -i "$SPEECH" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/speech.wav"
  ffmpeg -v error -y -stream_loop 7 -i "$TMP/speech.wav" -c copy "$TMP/speech12.wav"
  ffmpeg -v error -y -stream_loop 4 -i "$TMP/speech12.wav" -c copy "$TMP/speech60.wav"
fi
# Level fixtures: a quiet tone and the same tone driven 20 dB into the rails.
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -af volume=-12dB -ar 16000 -ac 1 "$TMP/quiet.wav"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -af volume=20dB -ar 16000 -ac 1 "$TMP/hot.wav"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" -ar 48000 -ac 2 "$TMP/tone48.wav"
touch -d "2026-01-02 03:04:05" "$TMP/tone48.wav"
touch -d "2026-01-03 03:04:05" "$TMP/speech.wav" 2>/dev/null

echo "== basics"
eq "version" "$("$CLI" version)" "$MANIFEST_VERSION"
check "help exits 0" "$CLI" help
eq "config default source" "$($CLI config get defaultSource)" "mic"
check "config set" "$CLI" config set defaultSource both
eq "config persisted" "$($CLI config get defaultSource)" "both"
fails "config rejects bad value" "$CLI" config set defaultSource bogus
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

echo "== levels"
IDQ=$($CLI import "$TMP/quiet.wav" --title Quiet); IDH=$($CLI import "$TMP/hot.wav" --title Hot)
eq "quiet import not clipped" "$($CLI show "$IDQ" --json | jq -r '.levels.clipped')" "false"
eq "hot import flagged clipped" "$($CLI show "$IDH" --json | jq -r '.levels.clipped')" "true"
check "hot peak near 0 dBFS" bash -c "$CLI show '$IDH' --json | jq -e '.levels.peak_db > -0.5'"
eq "analyze re-measures" "$($CLI analyze "$IDH" | jq -r .clipped)" "true"
check "list marks clipped rows" bash -c "$CLI list | grep -q 'clipped.*Hot'"
check "list shows HH:MM:SS" bash -c "$CLI list | grep -q '00:00:03'"
$CLI delete "$IDQ" --yes >/dev/null; $CLI delete "$IDH" --yes >/dev/null

echo "== list / show"
eq "list newest first" "$($CLI list --json | jq -r '.[0].id')" "${ID2:-$ID1}"
eq "list has_transcript false" "$($CLI list --json | jq -r '.[-1].has_transcript')" "false"
eq "show --json dir" "$($CLI show "$ID1" --json | jq -r .dir)" "$D1"
fails "show unknown id fails" "$CLI" show 2000-01-01_000000

echo "== rename"
$CLI rename "$ID1" "Renamed / Title  here" >/dev/null
D1B="$OMARECORDER_DIR/$ID1 Renamed - Title here"
check "folder renamed (sanitized)" test -d "$D1B"
check "old folder gone" bash -c "! test -d '$D1'"
eq "id stable after rename" "$($CLI show "$ID1" --json | jq -r .id)" "$ID1"
eq "meta title updated" "$(jq -r .title "$D1B/meta.json")" "Renamed - Title here"
V2=$(jq -r .version "$XDG_RUNTIME_DIR/omarecorder/state.json")
check "state version bumped by mutations" test "$V2" -gt "$V1"

echo "== security / robustness"
# Titles are data: shell metacharacters must round-trip untouched and never execute.
EVIL='notes $(touch pwned-marker) `touch pwned-marker2`; rm -rf x <b>bold'
cd "$TMP" || exit 1   # a stray relative touch would land here
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
eq "runtime dir is 0700" "$(stat -c %a "$XDG_RUNTIME_DIR/omarecorder")" "700"
"$CLI" delete "$IDP" --yes >/dev/null
# runtime state never falls back to /tmp
( unset XDG_RUNTIME_DIR; "$CLI" status >/dev/null 2>&1; echo $? > "$TMP/rc" )
check "no XDG_RUNTIME_DIR: uses /run/user or fails, never /tmp" bash -c "! test -d /tmp/omarecorder"
# config validation
fails "config get unknown key fails" "$CLI" config get bogus
fails "config set recordingsDir rejects missing dir" "$CLI" config set recordingsDir "$TMP/does-not-exist"
fails "import rejects unknown flag" "$CLI" import --bogus "$TMP/quiet.wav"
# concurrent state writers do not lose bumps
V0=$(jq -r .version "$XDG_RUNTIME_DIR/omarecorder/state.json")
for i in $(seq 1 20); do "$CLI" config set threads "$i" >/dev/null & done; wait
V1=$(jq -r .version "$XDG_RUNTIME_DIR/omarecorder/state.json")
check "20 parallel config sets → 20 version bumps" test $((V1 - V0)) -ge 20
"$CLI" config set threads 0 >/dev/null
# crash recovery for a "both" take that died before the mix
IDB="2026-01-05_010203"; DB="$OMARECORDER_DIR/$IDB Both crash"; mkdir -p "$DB"
cp "$TMP/quiet.wav" "$DB/mic.wav"; cp "$TMP/quiet.wav" "$DB/system.wav"
jq -cn --arg id "$IDB" --arg dir "$DB" '{id:$id,title:"Both crash",source:"both",created:"2026-01-05T01:02:03+0000",duration_s:null,size_bytes:0,sample_rate:16000,transcript:null,notes:""}' > "$DB/meta.json"
jq -cn --arg id "$IDB" --arg dir "$DB" '{recording:{id:$id,source:"both",dir:$dir,started_at:0,pids:[999999],files:[]},jobs:[],version:1}' > "$XDG_RUNTIME_DIR/omarecorder/state.json"
eq "status clears the dead recording" "$("$CLI" status)" "idle"
check "both crash recovery produced audio.wav" test -s "$DB/audio.wav"
eq "recovered both take has duration" "$(jq -r .duration_s "$DB/meta.json")" "3"
"$CLI" delete "$IDB" --yes >/dev/null
# setup check reports what is missing, with the package to install
check "setup check lists tools" bash -c "\"$CLI\" setup check --json | jq -e '.tools | length > 5'"
mkdir -p "$TMP/nowl"; ln -s /usr/bin/* "$TMP/nowl/" 2>/dev/null; rm -f "$TMP/nowl/wl-copy"
( PATH="$TMP/nowl" "$CLI" setup check --json > "$TMP/setup.json" 2>/dev/null || true )
eq "missing wl-copy reported with package" "$(jq -r '.missing[] | select(.tool=="wl-copy") | .package' "$TMP/setup.json")" "wl-clipboard"

echo "== export"
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

echo "== models / estimate"
check "models --json lists base.en" bash -c "$CLI models --json | jq -e '.[] | select(.name==\"base.en\")'"
eq "estimate uses default rtf" "$($CLI estimate "$ID1" --model base.en | jq -r '.rtf, .source' | paste -sd,)" "10,default"
fails "estimate rejects unknown model" "$CLI" estimate "$ID1" --model nope

echo "== transcribe"
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
  check "short clip does not train the estimate" bash -c "! test -f '$XDG_STATE_HOME/omarecorder/bench.json'"
  check "elapsed_s recorded with sub-second precision" bash -c "jq -e '.transcript.elapsed_s > 0' '$D3/meta.json'"
  ID6=$($CLI import "$TMP/speech60.wav" --title "Speech 60s")
  check "transcribe 60 s clip" "$CLI" transcribe "$ID6" --model base.en
  check "bench.json learned rtf from 60 s clip" bash -c "jq -e '.[\"base.en\"].rtf > 0' '$XDG_STATE_HOME/omarecorder/bench.json'"
  eq "estimate now measured" "$($CLI estimate "$ID3" --model base.en | jq -r .source)" "measured"
  eq "list has_transcript true" "$($CLI show "$ID3" --json | jq -r .has_transcript)" "true"
  check "show --json includes text" bash -c "$CLI show '$ID3' --json | jq -e '.transcript_text | length > 0'"
  eq "no jobs left in state" "$($CLI status --json | jq -r '.jobs|length')" "0"
  check "range transcribe" "$CLI" transcribe "$ID3" --model base.en --from 0 --to 3
  check "range header" bash -c "head -1 '$D3/transcript.md' | grep -q 'range=0-3'"
  check "previous transcript kept on re-run" bash -c "head -1 '$D3/transcript.prev.md' | grep -q 'range=0-end'"

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
  # cancel keeps the pieces that finished: run the worker directly, TERM it after piece 1
  rm -f "$D6/transcript.md"
  jq -cn --arg id "$ID6" '{recording:null,jobs:[{type:"transcribe",id:$id,model:"base.en",started_at:0}],version:1}' > "$XDG_RUNTIME_DIR/omarecorder/state.json"
  OMARECORDER_CHUNK_S=25 setsid "$CLI" _tx-worker "$ID6" base.en en 0 "" "" >/dev/null 2>&1 < /dev/null &
  WPID=$!
  for _ in $(seq 1 120); do [[ -s "$D6/transcript.md" ]] && break; sleep 0.5; done
  check "partial transcript published after piece 1" test -s "$D6/transcript.md"
  eq "state shows piece progress" "$("$CLI" status --json | jq -r '.jobs[0].progress.chunks')" "3"
  kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WRC=$?
  eq "cancelled worker exits 0" "$WRC" "0"
  check "partial header" bash -c "head -1 '$D6/transcript.md' | grep -q 'partial=true'"
  eq "meta says partial" "$(jq -r '.transcript.partial' "$D6/meta.json")" "true"
  check "no chunk temp files left" bash -c "! ls '$XDG_RUNTIME_DIR/omarecorder/'tx-* 2>/dev/null | grep -q ."
  "$CLI" cancel "$ID6" >/dev/null
else
  skip "voxtype/base.en/fixture not available"
fi

echo "== level meter (parser)"
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

echo "== record (real mic, 2 s)"
if pactl list short sources 2>/dev/null | grep -qv '\.monitor'; then
  IDR=$($CLI record start --title "Mic check")
  check "record start returns id" test -n "$IDR"
  eq "status shows recording" "$($CLI status --json | jq -r .recording.id)" "$IDR"
  fails "start refused while recording" "$CLI" record start
  fails "transcribe refused while recording" "$CLI" transcribe "$IDR" --model base.en
  MPID=$("$CLI" status --json | jq -r '.recording.meter_pid')
  check "state has meter_pid" test "$MPID" -gt 0
  for _ in $(seq 1 30); do jq -e '.t > 0' "$XDG_RUNTIME_DIR/omarecorder/level" >/dev/null 2>&1 && break; sleep 0.2; done
  check "level file updates while recording" jq -e '.t > 0 and (.peak_db|type)=="number"' "$XDG_RUNTIME_DIR/omarecorder/level"
  sleep 1
  check "record stop" "$CLI" record stop
  DR="$OMARECORDER_DIR/$IDR Mic check"
  eq "wav header valid" "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$DR/audio.wav")" "pcm_s16le,16000,1"
  DUR=$(jq -r .duration_s "$DR/meta.json"); check "duration 2–10 s" test "$DUR" -ge 1 -a "$DUR" -le 10
  check "levels measured on stop" bash -c "jq -e '.levels.peak_db' '$DR/meta.json'"
  eq "state cleared" "$($CLI status)" "idle"
  sleep 0.5
  check "meter process gone after stop" bash -c "! kill -0 $MPID 2>/dev/null"
  check "level file removed after stop" bash -c "! test -e '$XDG_RUNTIME_DIR/omarecorder/level'"
  check "toggle starts" "$CLI" record toggle --source mic
  sleep 1
  check "toggle stops" "$CLI" record toggle
else
  skip "no microphone source"
fi

echo "== delete"
check "delete --yes" "$CLI" delete "$ID1" --yes
check "folder gone" bash -c "! test -d '$D1B'"
fails "delete unknown fails" "$CLI" delete 2000-01-01_000000 --yes

echo "== setup"
check "setup check --json runs" bash -c "$CLI setup check --json | jq -e '.version'"

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
