# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

### Changed
- The Recent list folds away while the popup settings are open, so on smaller
  displays the settings are in reach without scrolling past it. The section
  header stays put and says where the list went. (#15)

## [1.2.0] - 2026-09-02

### Added
- Every recording can carry a short note. `omarecorder note <id> <text>` sets
  it (empty text clears it), it shows up in `show --json` and `list --json`,
  and the Library detail pane has a quiet "Add a note" box under the metadata
  line. Notes are capped at 500 characters and stored in meta.json, so they
  stay with the recording through renames. (#9)
- Tidy now marks every spot where it collapsed a back-to-back repeated phrase
  with "(repeated Nx)" on the last kept word, so the reader knows the raw text
  holds more there. The markers flow into `copy` and `export` output like the
  rest of the tidy text; the `--raw` variants avoid them. (#14)
- Transcripts that contained a long repetition loop are flagged: when one
  collapse removed at least 40 words (tunable via `OMARECORDER_LOOP_WARN_WORDS`),
  `tidy` records `loop_warning` in the metadata and the Library shows a banner
  suggesting a re-transcribe with a larger model or a shorter chunk length.
  Tidy also records the number of collapse points and the longest run of
  removed words. (#20)

## [1.1.2] - 2026-09-02

### Fixed
- Library playback no longer stops when the recording list refreshes in the
  background (a transcription or download finishing, a rename). The selection
  handler now compares recording ids instead of row object identity, so only
  genuinely moving to a different recording resets playback and view state.
  (#30)
- The waveform strip is drawn at 2400x128 instead of 800x64, so it stays sharp
  on wide windows and high-DPI screens. Existing recordings get their strip
  redrawn once, the first time the list sees the old size. (#17)

### Removed
- `AGENTS.md` is no longer tracked in git. The marketplace review flagged it:
  a plugin install is a plain git clone, so a tracked agent-instruction file
  would land in every user's plugin directory and quietly steer any coding
  agent run there. The file stays in the maintainer's working copy for the
  review workflow; nothing about the plugin itself changes.

### Changed
- The idle bar icon is now a pair of tape reels instead of a microphone, so it
  no longer looks like a mic on/off toggle. Suggested by a Reddit reader who
  had already swapped theirs for a record dot. The panel hero and the Library
  header use the same reels; recording keeps the red dot and timer, and
  transcribing keeps the hourglass.

## [1.1.1] - 2026-08-30

### Fixed
- The orphan sweep no longer uses a recursive delete at all. The only folders
  it may remove are empty or hold nothing but the recorder's own header-stub
  WAV files, so it now removes exactly those files and `rmdir`s the folder,
  which refuses if anything unexpected appeared in the meantime. Found by a
  second-model review of the full 1.1.0 diff.

## [1.1.0] - 2026-08-30

The first evening of the public roadmap: everything below came off the issue
tracker (the pinned overview is issue #25), including two data-loss holes a
second-model review caught before they ever shipped.

### Added
- **Long-take stop guard.** Once a recording passes an hour, the keybinding,
  the bar right-click and `r` ask for a second stop within 10 seconds instead
  of stopping outright. The popup's Stop button and `record stop --force`
  still stop in one click. `OMARECORDER_STOP_CONFIRM_S` moves the threshold
  (0 disables).
- **Previous transcript in the Library.** Re-transcribing keeps the old text
  as `transcript.prev.md`; a "Previous" switch next to Raw / Tidy now shows
  it, with a notice that copy and export still use the current text.
  `list --json` / `show --json` gain `has_prev`, `prev_path` and `prev_text`.
- **Playback position readout.** "00:12 / 00:33" sits in the Library action
  row while a recording plays.
- Accessible names on every icon-only button and on the bar widget, derived
  from the tooltips they already had.

### Changed
- The Library's recording list scales with the card (30 % with a floor)
  instead of a fixed width. At the default card cap nothing moves; narrow
  screens keep a usable detail pane and scaled themes get more room.
- CI fully upgrades the Arch container (`pacman -Syu`) before installing.

### Fixed
- A crash between mkdir and the meta write left an orphan recording folder
  that the list skipped but whose id stayed blocked forever. Reconcile now
  sweeps them, carefully: folders younger than five minutes and folders
  holding anything the recorder did not write are never touched, anything
  with audio in it is salvaged through the normal crash recovery, and only
  an empty husk is removed.
- Two transcriptions finishing together could lose a `bench.json` speed
  measurement; the update now runs under the same lock as `state.json`.
- The transcription worker wrote its range-cut and chunk WAVs into
  `$XDG_RUNTIME_DIR`, which is RAM; a long take could push hundreds of MB
  there. They now live next to the recording as `audio.tx.*` and are cleaned
  on start, finish, cancel and the kill trap.
- The cancel-mid-chunk test could race on a very fast machine; it now waits
  until the worker is provably mid-flight on a non-final chunk.
- The 1.0.0 notes claimed in-process QtMultimedia playback; Library playback
  runs in mpv over its IPC socket and the notes now say so.

## [1.0.0] - 2026-08-30

First public release, on the Omarchy plugin marketplace. Everything below was
built on top of 0.1.1 in one sprint: the v0.2 roadmap, one v0.3 item (Obsidian),
a security pass, and a documentation rewrite in which every claim was checked
against the code.

### Added
- **Chunked transcription.** Takes longer than 30 minutes (`OMARECORDER_CHUNK_S`)
  are transcribed in equal pieces inside the one `systemd-run --user` unit, seams
  snapped to the nearest silence. `transcript.md` is republished after every
  piece, the Library shows "2/4 · 00:12", and **Cancel keeps the finished pieces**
  (`meta.transcript.partial`, "partial transcript" in the lists, a notice above
  the text). The speed estimate still learns from a cancelled run. This is also
  the mitigation for whisper's repetition loops on long inputs.
- **Live input meter.** While recording, an `ffmpeg -f pulse … astats` reader
  writes `$XDG_RUNTIME_DIR/omarecorder/level` four times a second; the popup and
  the Library show a level bar, and the bar widget reads **CLIP** instead of the
  timer while the input sits on the rails (held 1.5 s). Independent of the shell;
  it dies with the recorder.
- **Waveform strip, scrubber and trim.** `waveform.png` (800×64) is drawn on
  stop/import (and once, lazily, for recordings made before 1.0). In the Library
  the strip is a scrubber (click, `Space`, `←`/`→` ±5 s; playback runs in mpv
  outside the shell, driven over its IPC socket). `F3` / the scissors enter trim
  mode with two drag handles, **Preview**, and **Trim** (confirmed). `omarecorder
  trim <id> --from s --to s [--replace] | --restore`: lossless `-c copy`, the first
  original kept as `audio.orig.wav`, transcript flagged stale until re-transcribed.
- **Send to Obsidian.** `omarecorder export <id>` writes a note (YAML frontmatter
  + transcript) into the folder where Obsidian itself files new notes (read from
  the vault's `.obsidian/app.json`, never overridden), then opens it via
  `obsidian://`. `omarecorder vaults` lists vaults; Settings gets a vault picker;
  config `obsidianVault` / `exportDir`; without Obsidian the note lands next to
  the recording.
- **Tidy transcripts.** Every transcription also writes `transcript.tidy.md`:
  paragraphs at sentence ends and piece boundaries, and phrases whisper repeated
  back to back collapsed to one copy (a deterministic awk script, local, raw file
  untouched). The Library shows it by default with a Raw / Tidy switch; `copy` and
  `export` use it unless `--raw`; `omarecorder tidy <id>` rebuilds it; older
  transcripts get one on the next listing.
- **Import from the popup** (`i`): a path field that runs `omarecorder import`.
- `omarecorder copy <id>` (transcript → clipboard), `delete --permanent`,
  `import` accepts `~`, `setup check --json` reports `tools[]` / `missing[]` with
  the package for each tool; the Setup card lists them.
- Download progress is published into the state file by the download worker.
- `tests/lint.sh` (shellcheck, manifest schema, QML hygiene, README sections) and
  a GitHub Actions workflow that runs it plus the CLI tests in an Arch container.
- `AGENTS.md` for second-model code review.

### Changed
- **No polling, for real.** The shell no longer re-runs `list --json` every
  second while a job runs; every update arrives through the watched state file,
  the level file and the transcript file.
- `state.json` read-modify-write runs under `flock`; workers receive
  `XDG_RUNTIME_DIR`/`HOME`; the transcription worker only ever signals its own
  child, never the process group.
- `delete` says what it does: it moves to the trash with `gio` and **refuses**
  when that is impossible; `--permanent` is the only path to `rm -rf`. Without a
  terminal it requires `--yes`.
- "both": crash recovery mixes `mic.wav` + `system.wav`; a failed mix is a
  reported error, never a 0-second "saved".
- whisper's stderr goes to a per-job file (kept only on failure as
  `~/.local/state/omarecorder/tx-<id>.err`); the log rotates at 1 MB and is no
  longer mined for failure messages.
- The version is read from `manifest.json` (one source). Manifest gains
  `homepage`.
- Tests: 67 → 200+ assertions; a missing engine/model/mic is a failure unless
  `OMARECORDER_TEST_ALLOW_SKIP=1`; new coverage for hostile titles, `--from/--to`,
  delete safety, file modes, concurrency, `both` crash recovery, chunking and
  cancel, the meter parser and a live meter, `system`/`both` sources, the real
  systemd path, trim/restore, vaults/export.
- Popup hero names the job ("Transcribing 00:24:36 · Sons of Suds…"); the take
  being recorded is no longer repeated in Recent; the hero toggle switch is gone.
- Recent rows show the transcription's elapsed time; the Library shows it once.
- Settings no longer duplicate the popup's Source control; rename hint shown
  once; re-transcribe preselects the model that made the visible transcript.
- Library: "open in editor" / "copy transcript" / "send to Obsidian" sit at the
  top-left of the transcript box, outside the scroll area, with "Copied" / "Sent"
  confirmations; the action row is compact (three presets, "Re-transcribe").
- Clipping detection skips the first 2 s and decides on the share of samples at
  the rail (`levels.clipped_pct` > 0.05 %). README recommends 30–40 % input for
  laptop mics.

### Fixed
- "System audio" recorded the microphone. `pw-record --target <sink>.monitor` silently
  falls back to the default source because PipeWire has no node by that name; the
  recorder now targets the sink with `stream.capture.sink=true` and the tests check
  the live PipeWire links. "Mic + system audio" had been two copies of the mic.
- `show --json` failed with "Argument list too long" on a long transcript.
- Newlines in a title were deleted instead of becoming spaces; two same-second
  recordings could share an id; `import` swallowed unknown flags; `config get`
  of an unknown key printed `null`; `recordingsDir` accepted any string.
- `meta.json` could be blanked by a failing measurement (empty JSON is refused;
  values go through `--arg`/`--argjson`).
- A first import on a fresh profile skipped the waveform (`$STATE_DIR` did not
  exist yet).
- A home directory with a space broke every CLI call from the shell.

### Security
- **Command injection** via a recording title in "Copy transcript"
  (`bash -c "sed … <path> | wl-copy"`; an imported file with a hostile name was
  enough). The clipboard copy is a CLI command called with an argv array; no
  shell string is built from data anywhere.
- **No `/tmp` fallback** for runtime state: `$XDG_RUNTIME_DIR` (or
  `/run/user/UID`) only, `0700`; the CLI refuses to run without one.
- **Private files**: `umask 077` for recordings, transcripts, notes, config and state.
- `--from`/`--to` (transcribe, play, trim) validated as non-negative numbers and
  passed as arguments, never word-split into ffmpeg/mpv.
- User strings render as plain text in every QML `Text` (titles, meta line,
  errors, dialogs).
- `stop-play` only signals a pid whose `comm` is `mpv`/`pw-play`.

### Removed
- The graphical file picker that was planned for popup import: a QtQuick
  `FileDialog` crashes Quickshell on Omarchy 4 (in-shell and in its own
  process). Back once that is fixed upstream.
- From the roadmap: `whisper-cpp` and `sherpa-onnx` engines: they would be new packages.

## [0.1.1] - 2026-08-30

First polish round, driven by two persona walkthroughs (a first-time user and
a professional audio recordist; the first-time user's notes weighed more).

### Added
- Clipping detection: every stop/import measures peak/RMS/flatness with
  `ffmpeg astats` and stores `levels` in `meta.json`. Clipped takes get a
  "⚠ clipped" mark in every list, a note in the Library, and a "mic gain too
  high" warning in the saved notification. `omarecorder analyze <id>` measures
  existing recordings.
- Crash recovery: if the recorder died (power loss, shell killed), the next
  command repairs the WAV header, fills in the duration/levels and notifies.
- Re-transcribing keeps the previous text as `transcript.prev.md`.
- Friendly names for untitled recordings ("Recording · Aug 29, 23:56").
- The in-progress take shows live in Recent and the Library ("Recording… 00:04:25");
  it cannot be transcribed or deleted until it is stopped.
- Library: search box in the header, recording count, key hints in a footer,
  "Renaming: Enter saves, Esc cancels" cue, Space types into a non-empty search.

### Changed
- Bar: the slot grows with the timer instead of overflowing into neighbours;
  idle shows a microphone glyph (recording = red record glyph + timer).
- Popup rows use words for the main action ("Transcribe" / "Open") instead of
  icons only; opening settings scrolls them into view.
- Library uses the theme's `[popups]` chrome (same as the bar popup); newest
  recording is selected on open; delete dialog says "Move to trash" and
  defaults to Cancel.
- Notifications name the recording and say what happens next; cancelling a
  transcription produces "Transcription cancelled" instead of a failed unit.
- Speed estimates: "≈ 2m (est.)" until measured; the estimate learns only from
  clips ≥ 60 s and uses sub-second timing.
- `omarecorder list` prints durations as HH:MM:SS.

### Fixed
- Importing two files with the same mtime second failed (`date` parse error).
- Recent rows showed "0s" right after stopping (state bumped after finalize).
- Cancelling a transcription no longer trips the systemd "failed unit" toast.

## [0.1.0] - 2026-08-29

### Added

* `bin/omarecorder` CLI: record (mic / system / both via `pw-record`), import, list, rename, delete (trash),
  transcribe with voxtype in a detached `systemd-run` unit, model catalog + background downloads,
  per-machine speed calibration for estimates, config, setup check.
* Bar widget + popup: record/stop toggle with timer, source picker, recent recordings, settings, setup card.
* Library overlay: search, list, editable title, model picker with estimates, transcribe/cancel, play,
  open/copy transcript, open folder, delete with confirmation, transcript view.
* Design spec: `docs/superpowers/specs/2026-08-29-omarecorder-design.md`.

