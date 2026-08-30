# Omarecorder

Record conversations and meetings from the Omarchy bar, keep the audio, and
transcribe them **locally, later** — with the voxtype/whisper engine Omarchy
already ships. One click to record, a library to browse, a transcript beside
every recording. Nothing leaves your machine.

![Omarecorder popup and library](preview.png)

* **Bar widget** — record/stop toggle with a running timer, source picker
  (microphone / system audio / both), your recent recordings, settings.
* **Library overlay** — every recording with date, duration and status; rename,
  play, transcribe (Fast / Balanced / Accurate presets with honest time
  estimates learned from *your* hardware), read or copy the transcript, delete.
* **CLI** — everything the UI does is `omarecorder <command>`, so keybindings,
  the Omarchy menu and scripts get the same behaviour.
* **Local-first, zero bloat** — no daemons, no polling. Recording is
  `pw-record`; transcription is `voxtype transcribe` in a detached
  `systemd-run` unit; the shell just watches one small state file.

## Requirements

Everything ships with Omarchy 4 (Quattro):

| Dependency | Used for |
|---|---|
| `voxtype` (installed by `omarchy install dictation`) | transcription engine + model downloads; adapts to CPU/Vulkan/CUDA |
| `pipewire` (`pw-record`, `pactl`) | recording |
| `ffmpeg` | import/convert, mixing mic + system audio, trimming |
| `jq`, `systemd` | state, detached jobs |
| `mpv` (optional) | playback; falls back to `pw-play` |

## Install

```bash
omarchy plugin add https://github.com/coreytyhurst/omarecorder --enable
```

Pick a bar section when asked (or later: `omarchy bar move io.github.coreytyhurst.omarecorder --section right`).

Put the CLI on your `PATH` so keybindings and the menu can use it:

```bash
ln -s ~/.config/omarchy/plugins/io.github.coreytyhurst.omarecorder/bin/omarecorder ~/.local/bin/omarecorder
```

First run: open the popup. If a requirement is missing (no whisper model yet,
no microphone), a **Setup** card tells you and offers the one-click fix.

## Use

* **Bar icon** — a microphone when idle: left-click opens the popup, right-click
  starts/stops recording. While recording it turns into a red record glyph
  with a running `HH:MM:SS`.
* **Popup keys** — `r` record/stop · `l` library · `s` settings · `↑↓` `Enter` on recent rows · `Esc`.
* **Library keys** — type to search · `↑↓` select · `Enter` transcribe (or open the transcript) · `Space` play/stop · `F2` rename · `Del` delete · `Esc`.
* **Notifications** — "Recording saved" is clickable: it transcribes with your default model.
* **Clipping check** — every recording is measured after stop; if the mic was
  driven into the rails you get "⚠ clipped" in the lists and a warning in the
  notification. Fix it at the source: lower the input level (Audio popup →
  Input, or `wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.30`) and re-check with a
  short test take (`omarecorder analyze <id>` should print `clipped: false`).
  Laptop mics are commonly shipped far too hot — 30–40 % is a normal starting
  point, and whisper copes with quiet audio far better than with distorted audio.

### Where things live

```
~/Recordings/
└── 2026-08-29_193012 Sons of Suds/     ← id + title; rename = folder rename
    ├── audio.wav                       16 kHz mono (whisper-native, ~115 MB/hour)
    ├── meta.json                       title, source, duration, model used…
    ├── transcript.md                   plain text (voxtype gives no timestamps yet)
    └── mic.wav + system.wav            only for "both" — kept, audio.wav is the mix
```

Config: `~/.config/omarecorder/config.json` (edit from the popup's ⚙ or `omarecorder config set …`).
Runtime state: `$XDG_RUNTIME_DIR/omarecorder/state.json`. Speed measurements: `~/.local/state/omarecorder/bench.json`.

### Models

Three presets, mapped to voxtype's whisper models: **Fast** = `base.en`,
**Balanced** = `small.en`, **Accurate** = `large-v3-turbo`. A preset you don't
have yet shows "download N MB" and fetches in the background with a progress
bar (`voxtype setup --download`).
The first transcription with each model calibrates the estimate for your machine.

### CLI

```
omarecorder record start [--source mic|system|both] [--title T] | stop | toggle | status [--json]
omarecorder import <file> [--move] [--title T]
omarecorder list [--json] | show <id> [--json] | rename <id> <title> | delete <id> [--yes] | analyze <id>
omarecorder transcribe <id> [--model M] [--language L] [--from s --to s] | cancel <id>
omarecorder models [--json] | model download <name> | estimate <id> --model M
omarecorder play <id> | stop-play | open <id> | folder <id> | library
omarecorder config get [key|--json] | config set <key> <value> | setup check [--json]
```

### Keybinding and menu (optional)

`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + R", "Record audio", "omarecorder record toggle")
```

`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"trigger.record": { "icon": "󰑊", "label": "Record Audio", "aliases": ["record"],
  "action": "omarecorder record toggle" },
"trigger.record.library": { "icon": "󰈔", "label": "Recording Library",
  "action": "omarchy-shell shell toggle io.github.coreytyhurst.omarecorder" }
```

The plugin never edits these files for you.

## Remove

```bash
omarchy plugin remove io.github.coreytyhurst.omarecorder
rm -f ~/.local/bin/omarecorder
```

Your recordings in `~/Recordings` and `~/.config/omarecorder` are left untouched.

## Privacy

Audio and transcripts stay on disk. Transcription runs on your CPU/GPU via
voxtype. The only network activity is voxtype's model download when you ask for
a model you don't have.

## Development

```bash
git clone https://github.com/coreytyhurst/omarecorder ~/projects/omarecorder
cd ~/projects/omarecorder
scripts/dev-install.sh --enable   # rsync into the plugin dir, validate, rescan plugins
omarchy-restart-shell             # QML changes need this: rescan keeps Qt's component cache
bash tests/cli.test.sh            # CLI tests (uses real voxtype + base.en when present)
```

Design spec: `docs/superpowers/specs/2026-08-29-omarecorder-design.md`.

## Prior art and thanks

voxtype (engine), rmacy/omarchy-voxtype-osd (level meter ideas),
iamcheyan/omarchy-voxtype-enhance (model-download cards),
Aryan-Techie/omarchy-todoist and robzolkos/omarchy-github (panel conventions),
ilyazar/omarchy-syncthing (service/panel split). SamuraiScribe and anarlog for
the "session library" shape.

## Roadmap

* v0.2 — transcript that fills in as it goes (takes over 30 min are transcribed in ≤30-min pieces behind the scenes), live input level meter with clip indicator, trim (start/end with preview), waveform strip, playback scrubber, import from the popup, marketplace listing
* v0.3 — AI clean-up and summary of a transcript via the AI provider your Omarchy system already uses, with an optional pass that re-checks doubtful passages against the audio; hand the result to Obsidian (ships with Omarchy) as a note; optional `whisper-cpp` engine for timestamps (click-to-seek, SRT) and VAD, speaker attribution, per-track transcripts for "both"

## License

MIT — see `LICENSE`.
