# OmaRecorder — design spec (2026-08-29)

Approved design for v0.1. Source of truth for behaviour; see README for usage.

## Context

Tonight's D&D session proved the primitives: `pw-record` captures for hours, voxtype's whisper transcribes locally on this hardware, and a bar toggle (`~/.local/bin/dnd-record` + a `type: "command"` module in `shell.json`) is enough to record. What's missing is *usability*: browse recordings, rename/delete/trim, decide what to transcribe with a light accuracy-vs-speed choice, and read the transcript beside the audio. D&D is one use case; the tool is "record any conversation or meeting, save the audio, transcribe some or all of it."

Constraints the user set: local-first; near-zero new dependencies (leverage what Omarchy ships); fully in the Omarchy ecosystem (theme-adaptive, movable in the bar, `omarchy plugin add/remove`, publishable to omarchyplugins.com); performant, minimal bloat; runs on most hardware Omarchy runs on. Engine for v1 = **voxtype only** (whatever models/settings it offers). MVP = "I can see my recordings, decide to transcribe them or not, and if transcribed, see the transcript next to it." Repo `~/projects/omarecorder`, private GitHub, MIT, id `io.github.coreytyhurst.omarecorder`.

Decisions from the design discussion (2026-08-29):

* Architecture **A**: thin QML views over a bash CLI; detached jobs; state via watched JSON files.
* Surfaces in v0.1: bar widget + popup (record/stop, source, last few recordings) **and** a fullscreen Library overlay (list + transcript).
* Recorder: **`pw-record` always**; "both" = two pw-record processes (mic.wav + system.wav) mixed by ffmpeg after stop. ffmpeg is offline-only (mix, trim, waveform).
* Trim v1 = start/end with preview (ships in v0.2, after a playback spike).
* Storage: `~/Recordings/<id>[ <title>]/` folder per recording; rename renames the folder.
* SamuraiScribe: no VM; design from its two public screenshots + anarlog (open-source, Linux) as runnable reference.

## Facts that constrain the design (verified on this machine 2026-08-29)

* `voxtype transcribe <file>` → **plain text, no timestamps**; accepts any WAV (resamples); stdout has 4 preamble lines even with `-q` → filter with `awk 'seen{print} /^$/{seen=1}'`; stderr has whisper spew. Root-level flags (must precede the subcommand): `--model`, `--language`, `--threads`, `--initial-prompt`, `--gpu-isolation`. Cold start ≈1.2 s; coexists with the running daemon on the Vulkan device. No progress output → we keep our own state.
* Models: `voxtype setup --download --model <name> --quiet --no-post-install` (non-interactive; what `omarchy-voxtype-install` uses). Names: `tiny|base|small|medium|large-v3|large-v3-turbo` (+`.en`). Files land in `~/.local/share/voxtype/models/ggml-<name>.bin`. `voxtype setup model --list` lists installed. `/usr/bin/voxtype` is a symlink maintained by `voxtype setup gpu|onnx` → always call it, never a variant. Never run `voxtype setup onnx --enable` (global, sudo, swaps engine).
* `pw-record --target <node>` records a mic source *or* a sink monitor (`<sink>.monitor`); SIGINT finalizes the WAV header; no duration flag. `pactl get-default-source` currently points at an absent USB webcam → resolve targets from `pactl list short sources` and fall back to the first non-monitor source.
* ffmpeg 9: `-ss/-to -c copy` lossless WAV trim (verified); `showwavespic=s=WxH` PNG (verified, needs `-frames:v 1 -update 1`); `amix` for mic+system; `-af loudnorm` optional.
* Quickshell 0.3.1: **no audio playback API** (Pipewire service = volume/mute only); `QtMultimedia` QML module is installed but unproven inside the shell → spike before designing seek/trim UI; fallback `pw-play`/`mpv` via `execDetached`. `FileView { watchChanges: true }` gives event-driven state without polling.
* Shell plugin contract (`/usr/share/omarchy/shell/README.md`, `services/PluginRegistry.qml`, `/usr/bin/omarchy-plugin-validate`): `manifest.json` at repo root; `schemaVersion: 1`; `id` not starting with `omarchy.`; kinds → entryPoints (`bar-widget:barWidget`, `overlay:overlay`, `service:service`); no symlinks anywhere in the plugin tree; plugin dir name == id; `barWidget.schema` is inert in this build (no settings renderer) → settings UI must be in-panel; `defaults` not auto-applied → always `setting(key, fallback)`. Overlays are fullscreen layer surfaces summoned by `omarchy-shell shell summon <id> '<json>'` / `toggle`.
* `qs.Ui` kit: `Panel`, `BarIconButton`, `KeyboardPanel` (`fittedContentWidth/Height`, caps ≈360×560), `PanelKeyCatcher` (set `blocked` while a TextField has focus), `PanelHero`, `PanelSectionHeader`, `PanelSeparator`, `PanelActionButton`, `Button`, `Dropdown`, `TextField`, `Toggle`, `ToggleSwitch`, `ConfirmDialog`, `PanelSlider`, `CursorSurface`. Theme: `bar.barForeground` for bar glyphs, `bar.foreground/urgent/fontFamily` in panels, `Color.*`/`Style.*` singletons live-reload. Vertical bars: text widgets must collapse to icon-only. Per-monitor duplication: keep mutable state in the `service` singleton (`bar.shell.serviceFor(moduleName)`).
* Long-running children of the shell die on shell restart → recorder and transcription jobs run detached (`setsid` / `systemd-run --user`); the shell only watches files.
* Marketplace (omarchyplugins.com, HANCORE-linux/omarchy-plugin-marketplace): public repo, one plugin/repo, README with install **and removal**, LICENSE listing external deps, `preview.png`, id `io.github.<user>.<name>`, state in `$XDG_RUNTIME_DIR` (not `/tmp`), no bundled binaries / `curl|sh`; catalog refreshes from `main` daily; run `omarchy plugin validate .` first. Category `Productivity`, tags `media, quickshell, ai`.
* Prior art (cite in README): rmacy/omarchy-voxtype-osd (level meter), iamcheyan/omarchy-voxtype-enhance (model-download cards), Aryan-Techie/omarchy-todoist + robzolkos/omarchy-github (panel/manifest conventions), ilyazar syncthing (Service+Panel split, test suite). Nothing in the ecosystem does record → keep → transcribe → browse.
* Tooling present: gh (authed), jq, mpv, gio, rsync, shellcheck, gum, qml6. Absent: qmllint, bats.

## Design

### Components

```
~/projects/omarecorder/                      (git; mirrored into ~/.config/omarchy/plugins/<id>/ for the shell)
├── manifest.json        kinds: ["service","bar-widget","overlay"]; keepLoaded: true
├── Service.qml          state singleton: watches state.json, loads list/models/config via CLI
├── Panel.qml            bar widget + KeyboardPanel popup
├── Library.qml          fullscreen overlay: list + detail/transcript
├── ui/                  RecordingRow.qml, TranscriptView.qml, ModelPicker.qml, SetupCard.qml, SettingsSection.qml
├── bin/omarecorder      bash CLI — the only place logic lives
├── tests/cli.test.sh    bash tests with ffmpeg-generated fixtures; tests/run.qml load-check
├── docs/superpowers/specs/2026-08-29-omarecorder-design.md   (this Design section, committed)
├── README.md  LICENSE (MIT)  CHANGELOG.md  preview.png  .gitignore
```

### Data model

* Root: `${OMARECORDER_DIR:-$HOME/Recordings}` (setting `recordingsDir`).
* Recording folder: `<id>` = `YYYY-MM-DD_HHMMSS`; renamed to `<id> <title>` (title sanitized: no `/`, trimmed, ≤80 chars). `id` = first 17 chars of the folder name — stable across renames.
* Contents: `audio.wav` (16 kHz mono s16 — whisper-native, 32 KB/s), `meta.json`, `transcript.md`, `waveform.png` (v0.2), and for source=both: `mic.wav` + `system.wav` (kept; `audio.wav` is the mix).
* `meta.json`: `{ id, title, source, created, duration_s, size_bytes, sample_rate, transcript: { model, language, created, elapsed_s, rtf } | null, notes: "" }`.
* `transcript.md`: front line `<!-- omarecorder model=small.en language=en created=… -->` then plain text paragraphs (voxtype gives no timestamps; keep the format forward-compatible with `[HH:MM:SS]` lines later).
* Config: `~/.config/omarecorder/config.json` — `recordingsDir`, `defaultSource` (mic|system|both), `defaultModel`, `language` (en|auto), `keepAwake` (bool), `threads` (0=auto). CLI `config get|set` is the only writer; panel calls it.
* Runtime state: `$XDG_RUNTIME_DIR/omarecorder/state.json` — `{ recording: {id, source, started_at, pids[], files[]} | null, jobs: [{type: transcribe|download, id|model, unit, started_at, expected_bytes?}] , version: n }`. Every CLI mutation bumps `version`; QML watches this file.
* Bench: `~/.local/state/omarecorder/bench.json` — per model `rtf` (audio seconds per wall second) learned after each transcription; defaults seeded (base 10, small 4, medium 1.5, large-v3-turbo 3, large-v3 1 — overwritten by first real run). Estimate = duration / rtf.

### CLI (`bin/omarecorder`) — bash + jq, shellcheck-clean, `set -euo pipefail`

```
omarecorder record start [--source mic|system|both] [--title T]
omarecorder record stop | toggle | status [--json]
omarecorder import <audio-file> [--move] [--title T]          # any format → ffmpeg → audio.wav
omarecorder list [--json] | show <id> [--json]
omarecorder rename <id> <title> | delete <id> [--yes]           # delete → gio trash, fallback rm -rf
omarecorder transcribe <id> [--model M] [--language L] [--from s --to s]   # detached systemd-run unit
omarecorder cancel <id>                                          # systemctl --user stop unit
omarecorder models [--json] | model download <name> | estimate <id> --model M
omarecorder trim <id> --from s --to s [--replace]                # v0.2; ffmpeg -c copy; keeps original as audio.orig.wav unless --replace
omarecorder play <id> [--from s] | stop-play                     # mpv --no-video (IPC socket later) ; fallback pw-play
omarecorder open <id>          # omarchy-launch-editor transcript.md ; folder <id> → xdg-open
omarecorder config get|set <key> [value] | setup check [--json] | library (summon overlay) | version
```

Behaviours:

* `record start`: resolve targets (`pactl list short sources`: mic = default source if present and not `.monitor`, else first non-monitor; system = `$(pactl get-default-sink).monitor`); `mkdir` folder; per input `setsid pw-record --target <node> --rate 16000 --channels 1 --format s16 <file>` (system audio recorded mono too — transcript use); `keepAwake` → `setsid systemd-inhibit --what=idle:sleep --who=omarecorder tail --pid=<pid> -f /dev/null`; wait until file exists; write state; `omarchy-notification-send`.
* `record stop`: SIGINT each pid, poll ≤10 s, SIGTERM fallback; if both → `ffmpeg -i mic.wav -i system.wav -filter_complex amix=inputs=2:duration=longest:normalize=0 -ar 16000 -ac 1 audio.wav`; `ffprobe` duration → meta; clear state; notification with `--exec omarecorder transcribe <id>` ("click to transcribe with default model").
* `transcribe`: refuse if model not installed (exit 3, message "model X not downloaded"); `systemd-run --user --collect --service-type=oneshot -u omarecorder-tx-<id> bash -c '…'`: optional range → ffmpeg trim to `$XDG_RUNTIME_DIR` tmp; `voxtype -q --model M --language L [--threads N] transcribe <wav> 2>/dev/null | awk 'seen{print} /^$/{seen=1}' > transcript.md.tmp` → mv; measure elapsed → bench rtf; meta update; state update; notification. Job registered in state; `status` reports it; stale units cleaned on `status`.
* `model download`: `systemd-run --user … voxtype setup --download --model <name> --quiet --no-post-install`; progress = size of `ggml-<name>.bin` (or `.part`) vs catalog size table; state job entry.
* `models --json`: `{ name, installed, size_mb, rtf, label }` for the whisper family; labels: Fast (base.en), Balanced (small.en), Accurate (large-v3-turbo) + the rest under "More".
* `setup check --json`: voxtype present + backend (`voxtype setup gpu --status`), installed models, mic available, ffmpeg/jq/pw-record present, recordingsDir writable → the panel shows a SetupCard until all pass.
* Every command that changes anything bumps `state.json.version` (atomic write via tmp+mv).
* `--json` everywhere the QML consumes output; human output otherwise.

### Service.qml (kind `service`, keepLoaded)

* `FileView { path: stateFile; watchChanges: true }` → `state` object; `Timer` (1 s) only while `state.recording` for elapsed.
* `Process` runs `omarecorder list --json` on: service start, state `version` change, library open, explicit `refresh()`. `Process` runs `models --json`, `config get --json`, `setup check --json` on start and after relevant mutations.
* Exposes functions: `startRecording(source)`, `stopRecording()`, `transcribe(id, model, lang)`, `rename(id, title)`, `remove(id)`, `download(model)`, `setConfig(k, v)`, `openLibrary()` — each `Quickshell.execDetached(["omarecorder", …])` (or `Process` when we need the exit code/message). Errors surface as `lastError` string shown in the panel.
* `broadcast()`-safe: all state lives here; Panel instances per monitor are views.

### Panel.qml (bar widget + popup)

* Bar glyph: idle `󰑊` dim; recording `󰑊` in `bar.urgent` + `HH:MM:SS` (icon-only when `bar.vertical`); transcribing `󰔟` spinning; tooltip with state. Left click → popup; right click → toggle recording (mirrors the screen-recording indicator).
* Popup (`KeyboardPanel`, ≤360×560): `PanelHero` (title "Recorder", meta = state, trailing `ToggleSwitch` = record/stop) · source `Dropdown` (mic/system/both) · "RECENT" section: last 5 `RecordingRow`s (title · date · duration · status glyph ✓ transcribed / ⏳ / –; actions: transcribe (default model), open transcript) · `Button` "Open Library (l)" · gear → `SettingsSection` (recordings dir, default source/model, language, keep awake) · `SetupCard` when `setup check` fails (download-model button with progress bar; mic missing hint).
* Keys: `r` record/stop, `l` library, arrows/j/k, Enter, Esc, Tab → neighbouring panel.

### Library.qml (kind `overlay`, fullscreen, on-demand)

* Two panes. Left: search `TextField` (filters title/date), list of all recordings (newest first) with title/date/duration/status; keyboard nav. Right: header with editable title (`TextField` → `rename` on accept), meta line (date · duration · size · source · model used), action bar: **Transcribe** (`ModelPicker`: Fast/Balanced/Accurate + More, each with "≈ N min" estimate and "download 1.6 GB" when missing) · Play/Stop · Open folder · Open in editor · Copy transcript (`wl-copy`) · Delete (`ConfirmDialog`). Body: `TranscriptView` (Flickable, selectable read-only text) or empty state "Not transcribed yet — pick a model above". While a job runs: progress row (elapsed vs estimate) + Cancel.
* Summon: `omarchy-shell shell summon io.github.coreytyhurst.omarecorder` (overlay entry) — wired to the popup button and `omarecorder library`.
* v0.2 adds: `waveform.png` strip, `PanelSlider` seek + trim in/out with preview (pending the playback spike), import button.

### Integration & lifecycle

* Install: `omarchy plugin add https://github.com/coreytyhurst/omarecorder --enable` (section chooser) · remove: `omarchy plugin remove io.github.coreytyhurst.omarecorder` (leaves `~/Recordings` untouched; README says so).
* Dev loop: repo in `~/projects/omarecorder`; `scripts/dev-install.sh` = `rsync -a --delete --exclude .git` into `~/.config/omarchy/plugins/<id>/` + `omarchy-shell shell rescanPlugins` (symlinks are rejected by validate, so no symlink). `omarchy plugin validate .` in CI/tests.
* CLI on PATH: README documents `ln -s ~/.config/omarchy/plugins/<id>/bin/omarecorder ~/.local/bin/` (or the panel's setup card offers to do it) so keybinds/menu work: Hyprland `o.bind("SUPER + ALT + R", "Record audio", "omarecorder record toggle")`; menu snippet for `~/.config/omarchy/extensions/omarchy-menu.jsonc` (`trigger.record`). Plugin never writes user config without consent.
* Retire `dnd-record`: `omarecorder import ~/recording/*.wav` (or move), remove the `dnd-record` command module from `shell.json` and the script; update hp-laptop-config allowlist accordingly.
* Performance: no idle processes; one `FileView` watch; list scan on demand (jq over meta.json files; fine for hundreds of recordings); overlay not keepLoaded; heavy work never in QML.
* Hardware: voxtype's tiered binary is the adapter; `setup check` reports backend (Vulkan/CPU) and the bench learns real speed per machine → honest estimates everywhere.

### Out of scope for v0.1 (roadmap)

* v0.2: trim + waveform + playback scrubber (QtMultimedia spike; else mpv IPC), setup wizard polish, import from popup, marketplace submission.
* v0.3: optional `whisper-cpp` engine (timestamps → click-to-seek, SRT export, glossary prompt); speaker attribution via sherpa-onnx; per-track transcripts for "both".
* Later: summaries via Ollama; upstream idea — audio-only flag for `omarchy-capture-screenrecording`.

