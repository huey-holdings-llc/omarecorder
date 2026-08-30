# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow SemVer.

## [Unreleased]

Third persona pass (an efficiency-minded enthusiast): say each fact once.

### Changed
- Popup hero: names the job ("Transcribing 00:24:36 · Sons of Suds…") with an
  hourglass icon; the take being recorded is no longer repeated in Recent; the
  hero toggle switch is gone (the Start/Stop button with its `r` hint remains).
- Recent rows show the transcription's elapsed time; the Library shows it once
  (progress line) and the Cancel button is just "Cancel".
- Settings no longer duplicate the popup's Source control.
- Library: rename hint shown once; re-transcribe preselects the model that made
  the visible transcript; "▶ playing" in the meta line while playback runs.
- Library: "open in editor" and "copy transcript" moved from the icon strip to
  the top-left of the transcript box, outside the scroll area, with a brief
  "Copied" confirmation.
- Library action row: no "Model" label row; the picker is sized to its longest
  option ("Accurate · large-v3-turbo · ≈ 52m", "Balanced · small.en · 466 MB
  download"); "Re-transcribe"; list rows no longer repeat the model (the detail
  meta line keeps it); list narrowed to 300 px so the detail pane breathes.
- Model choice is just the three presets — Fast (base.en), Balanced (small.en),
  Accurate (large-v3-turbo); missing ones still show "download N MB".
- Clipping detection skips the first 2 s (the ADC rails briefly when capture
  starts) and decides on the share of samples at the rail (`levels.clipped_pct`,
  > 0.05 %) rather than flatness alone. README now recommends 30–40 % input for
  laptop mics (measured on an ALC285: 55 % still clipped, 30 % peaks at −1 dB).

## [0.1.1] - 2026-08-30

First polish round, driven by two persona walkthroughs (a first-time user and
a professional audio recordist — the first-time user's notes weighed more).

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
  "Renaming — Enter saves, Esc cancels" cue, Space types into a non-empty search.

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

## [0.1.0] — 2026-08-29

### Added

* `bin/omarecorder` CLI: record (mic / system / both via `pw-record`), import, list, rename, delete (trash),
  transcribe with voxtype in a detached `systemd-run` unit, model catalog + background downloads,
  per-machine speed calibration for estimates, config, setup check.
* Bar widget + popup: record/stop toggle with timer, source picker, recent recordings, settings, setup card.
* Library overlay: search, list, editable title, model picker with estimates, transcribe/cancel, play,
  open/copy transcript, open folder, delete with confirmation, transcript view.
* Design spec: `docs/superpowers/specs/2026-08-29-omarecorder-design.md`.
