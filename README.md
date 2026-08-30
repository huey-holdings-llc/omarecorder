# Omarecorder

Record conversations and meetings from the Omarchy bar, keep the audio, and
transcribe them **locally, later** — with the voxtype/whisper engine Omarchy
already ships. One click to record, a library to browse, a transcript beside
every recording, a note in Obsidian when you want one. Nothing leaves your machine.

![Omarecorder](preview.png)

* **Bar widget** — record/stop with a running timer and a live input meter that
  says **CLIP** when the mic is too hot; source picker (microphone / system
  audio / both); recent recordings; import; settings.
* **Library overlay** — every recording with date, duration and status; rename,
  play and scrub on the waveform, trim losslessly with the original kept,
  transcribe (Fast / Balanced / Accurate with time estimates learned from
  *your* hardware), read, copy, send to Obsidian, delete.
* **Long takes** — anything over 30 minutes is transcribed in pieces; the
  transcript fills in piece by piece and a cancel keeps what is done.
* **CLI** — everything the UI does is `omarecorder <command>`, so keybindings,
  the Omarchy menu and scripts get the same behaviour.
* **Local-first, zero bloat** — no daemons, no polling. Recording is
  `pw-record`; transcription is `voxtype transcribe` in a detached
  `systemd-run --user` unit; the shell watches one small state file.

## Requirements

Every external tool the CLI calls, and the Arch package that provides it. All
of them ship with Omarchy 4 except voxtype, which `omarchy install dictation`
adds. `omarecorder setup check` tells you what is missing.

| Tool | Package | Used for | Omarchy 4 base |
|---|---|---|---|
| `voxtype` | `omarchy install dictation` | transcription engine, model downloads | no — one command |
| `pw-record`, `pw-play` | `pipewire` | recording; playback fallback | yes |
| `pactl` | `libpulse` | finding the microphone / monitor | yes (with pipewire-pulse) |
| `ffmpeg`, `ffprobe` | `ffmpeg` | import, mixing, levels, live meter, waveform, trim, chunking | yes (via omacut) |
| `jq` | `jq` | all state and metadata | yes |
| `systemd-run`, `systemctl`, `systemd-inhibit` | `systemd` | detached jobs, keep-awake | yes |
| `flock`, `setsid` | `util-linux` | state locking, detaching | yes |
| `mpv` | `mpv` | playback from the CLI (`pw-play` if absent) | yes |
| `wl-copy` | `wl-clipboard` | `copy` to the clipboard | yes |
| `gio` | `glib2` | `delete` moves to the trash | yes |
| `xdg-open` | `xdg-utils` | open folder, `obsidian://` links | yes |
| `omarchy-notification-send` (`notify-send` fallback), `omarchy-launch-editor`, `omarchy-shell` | Omarchy | notifications, open transcript, Library toggle | yes |
| Obsidian | `obsidian` | *Send to Obsidian* (optional; without it the note lands next to the recording) | yes |

Only voxtype, pw-record, pactl, ffmpeg/ffprobe and jq are required; each of the
others switches off one feature when missing.

## Install

```bash
omarchy plugin add https://github.com/coreytyhurst/omarecorder --enable
```

Pick a bar section when asked (or later: `omarchy bar move io.github.coreytyhurst.omarecorder --section right`).

Optional — only needed for keybindings, the menu and scripts. The widget and
the Library call the CLI by its own path and work without it:

```bash
ln -s ~/.config/omarchy/plugins/io.github.coreytyhurst.omarecorder/bin/omarecorder ~/.local/bin/omarecorder
```

First run: open the popup. If a requirement is missing (no whisper model yet,
a tool not installed, no microphone), a **Setup needed** card lists each one
with the command that fixes it, and downloads the default model with one click.

## Update

```bash
omarchy plugin update io.github.coreytyhurst.omarecorder
```

## Remove

```bash
omarchy plugin remove io.github.coreytyhurst.omarecorder
rm -f ~/.local/bin/omarecorder   # if you made the symlink
```

Your recordings in `~/Recordings` and `~/.config/omarecorder` are left untouched.

## Use

* **Bar icon** — a microphone when idle: left-click opens the popup, right-click
  starts/stops recording. Recording turns it into a red record glyph with a
  running `HH:MM:SS` — replaced by **CLIP** while the input is on the rails.
  An hourglass means a transcription is running.
* **Popup keys** — `r` record/stop · `l` library · `i` import · `s` settings · `↑↓` `Enter` on recent rows · `Esc`.
* **Library keys** — type to search · `↑↓` `PgUp` `PgDn` `Home` `End` select · `Enter` open the transcript (or transcribe; `Shift+Enter` re-transcribes) · `Space` play/pause · `←` `→` ±5 s (with an empty search box) · `F2` rename · `F3` trim · `Del` move to trash (confirmed, defaults to Cancel) · `Esc` leaves trim mode, clears the search, then closes.
* **Notifications** — "Recording saved · 00:24:36" is clickable: it transcribes
  with your default model. "Transcript ready" is clickable: it opens the text.
  A take whose recorder died (power loss, shell killed) is repaired and
  reported as "Recording recovered" on the next command.
* **Live meter + clipping** — while recording, an `ffmpeg astats` reader on the
  same source writes `$XDG_RUNTIME_DIR/omarecorder/level` a few times a second;
  the popup, the Library and the bar show it. After stop and import every take
  is measured again; a clipped one gets "⚠ clipped" in the lists and a "mic
  gain too high" notification. Fix it at the source: lower the input level
  (Audio popup → Input, or `wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 0.30`) and
  check a short take with `omarecorder analyze <id>` (`clipped: false`).
  Laptop mics commonly ship far too hot — 30–40 % is a normal starting point,
  and whisper copes with quiet audio far better than with distorted audio.
* **Transcribing** — Fast / Balanced / Accurate; a preset you don't have yet
  shows "N MB download" and fetches in the background with a progress bar.
  Takes over 30 minutes (`OMARECORDER_CHUNK_S`, default 1800) are cut into
  equal pieces, seams snapped to the nearest silence, and transcribed one after
  another inside one `systemd-run --user` unit. The Library shows "2/4" and the
  transcript grows as pieces finish; **Cancel** keeps the finished pieces and
  marks the transcript partial. Re-transcribing keeps the old text as
  `transcript.prev.md`.
* **Play and trim** — the waveform strip in the Library is a scrubber: click to
  seek, `Space` to play/pause. Playback is in-process (QtMultimedia, loaded
  only while the Library is open); `omarecorder play` uses mpv instead. The
  scissors button (or `F3`) enters trim mode with two drag handles; **Preview**
  plays the range, **Trim** asks once ("Keep 00:12 – 24:36 and cut the rest?")
  and cuts losslessly (`-c copy`). The first original is kept as
  `audio.orig.wav`; a restore button appears while it exists. The meta line
  says "· trimmed", an existing transcript is flagged stale until you
  re-transcribe, and the raw `mic.wav` / `system.wav` of a "both" take are
  never touched. Recordings made before 1.0 get their waveform drawn the first
  time the Library lists them.
* **Send to Obsidian** — the button above the transcript writes a Markdown note
  (YAML frontmatter: title, date, duration, source, model, recording id,
  `tags: [omarecorder]`) into the folder where Obsidian itself files new notes
  (it reads the vault's `.obsidian/app.json`), then opens it via
  `obsidian://`. The open vault is used unless Settings → *Obsidian vault* picks
  one; with no Obsidian at all the note lands next to the recording. The Library
  meta line says "· in Obsidian" afterwards.
* **Import** — press `i` in the popup and type a path (`~/Downloads/meeting.m4a`),
  or `omarecorder import <file>`. Anything ffmpeg reads is converted to 16 kHz
  mono; the id comes from the file's mtime. There is deliberately no graphical
  file picker: a QtQuick FileDialog crashes Quickshell on Omarchy 4.

### Where things live

```
~/Recordings/
└── 2026-08-29_193012 Sons of Suds/     ← id + title; rename = folder rename
    ├── audio.wav                       16 kHz mono s16 (whisper-native, ~115 MB/hour)
    ├── audio.orig.wav                  only after a trim (unless --replace)
    ├── waveform.png                    800×64 strip, redrawn on stop/import/trim/analyze
    ├── meta.json                       title, source, duration, levels, transcript, trim, exported_to…
    ├── transcript.md                   header line + plain text (voxtype gives no timestamps)
    ├── transcript.prev.md              the previous transcript, kept on re-transcribe
    └── mic.wav + system.wav            only for "both" — kept; audio.wav is the mix
```

`transcript.md` starts with one comment line:
`<!-- omarecorder model=base.en language=en created=… range=0-end chunks=1 -->`
(`partial=true` while pieces are still missing). `copy`, the Library and
*Send to Obsidian* strip it.

| What | Where |
|---|---|
| Config | `~/.config/omarecorder/config.json` — popup ⚙ or `omarecorder config set …` |
| Speed measurements | `~/.local/state/omarecorder/bench.json` (per model, from takes ≥ 60 s) |
| Log | `~/.local/state/omarecorder/omarecorder.log`, rotated to `.log.1` at 1 MB |
| whisper stderr of a failed job | `~/.local/state/omarecorder/tx-<id>.err` (kept only on failure) |
| Runtime state | `$XDG_RUNTIME_DIR/omarecorder/` — `state.json`, `level`, `state.lock`, temp chunks; never `/tmp` |

Config keys (`omarecorder config get --json`): `recordingsDir` (`~/Recordings`),
`defaultSource` (`mic`), `defaultModel` (`base.en`), `language` (`en`),
`keepAwake` (`true` — a systemd idle/sleep inhibitor while recording),
`threads` (`0` = voxtype's default), `obsidianVault` (`""` = the open vault),
`exportDir` (`""` = automatic). Env: `OMARECORDER_DIR` overrides
`recordingsDir`; `OMARECORDER_CHUNK_S` sets the piece length.

### Models

Three presets, mapped to voxtype's whisper models: **Fast** = `base.en` (142 MB),
**Balanced** = `small.en` (466 MB), **Accurate** = `large-v3-turbo` (1.6 GB).
Downloads run `voxtype setup --download` in a `systemd-run --user` unit.
Estimates start from a default speed and are replaced by what your machine
measured the first time each model transcribes a take of 60 s or more.

### CLI

```
omarecorder record start [--source mic|system|both] [--title T]   start a recording
omarecorder record stop | toggle | status [--json]                 control / inspect
omarecorder import <file> [--move] [--title T]                     bring an existing audio file in
omarecorder list [--json] | show <id> [--json] | analyze <id>      browse / measure levels
omarecorder rename <id> <title> | delete <id> [--yes] [--permanent] manage (delete → trash)
omarecorder trim <id> --from s --to s [--replace] | trim <id> --restore  cut the audio (first original kept)
omarecorder copy <id> [--print]                                    transcript text → clipboard
omarecorder export <id> [--vault P | --dir P] [--no-open]           transcript → Obsidian note
omarecorder vaults [--json]                                        Obsidian vaults on this machine (* = open)
omarecorder transcribe <id> [--model M] [--language L] [--from s --to s]
omarecorder cancel <id> | estimate <id> --model M
omarecorder models [--json] | model download <name>
omarecorder play <id> [--from s] | stop-play | open <id> | folder <id>
omarecorder config get [key|--json] | config set <key> <value>
omarecorder setup check [--json] | library | status [--json] | version
```

`delete` moves the folder to the trash with `gio` and refuses if it can't;
`--permanent` is the only path to `rm -rf`. Without a terminal it needs
`--yes`. `setup check --json` returns `tools[]` and `missing[]` with the
package for each tool and exits non-zero until everything needed is there.
`version` is read from `manifest.json`.

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

## Privacy & security

* Audio and transcripts stay on disk. Transcription runs on your CPU/GPU via
  voxtype. The only network activity is voxtype's model download when you ask
  for a model you don't have.
* Everything the plugin writes is private to your user: `umask 077`, so
  recordings, transcripts, notes, config and state are `0600` in `0700` folders.
* Runtime state (pids, jobs, the live level) lives only in
  `$XDG_RUNTIME_DIR/omarecorder/` (`0700`). It never falls back to `/tmp`; with
  no runtime dir the CLI stops instead.
* Titles, paths and ids are data: they travel as arguments and `jq --arg`,
  never inside a shell string, a `jq` filter or a unit body. whisper's stderr
  (which can echo decoded text) goes to a per-job file, not the shared log.
* It does **not**: edit your Hyprland, Omarchy or Obsidian configuration
  (Obsidian's `obsidian.json` and `app.json` are only read); delete anything
  outside a recording folder; `rm -rf` a recording without `--permanent`; run
  a daemon or poll; upload anything.

## Troubleshooting

* **"⚠ clipped" / CLIP in the bar** — mic gain too high; see *Live meter +
  clipping* above.
* **"Model … is not downloaded"** — the popup's Setup card downloads it;
  `omarecorder model download base.en` does the same. `transcribe` exits 3 in
  this case.
* **Something missing?** — `omarecorder setup check` lists every tool with its
  package and whether a microphone and the recordings folder are usable.
* **A transcription looks stuck** — `systemctl --user status omarecorder-tx-<id>`
  (downloads: `omarecorder-dl-<model>` with dots replaced by dashes). `omarecorder
  status` drops finished units from the state on its own; `omarecorder cancel <id>`
  stops one.
* **Logs** — `~/.local/state/omarecorder/omarecorder.log`; a failed job leaves
  `~/.local/state/omarecorder/tx-<id>.err`.
* **"both" saved but mixing failed** — `mic.wav` and `system.wav` are kept in
  the folder; the notification names the log with ffmpeg's error.

## Development

```bash
git clone https://github.com/coreytyhurst/omarecorder ~/projects/omarecorder
cd ~/projects/omarecorder
scripts/dev-install.sh --enable   # rsync into the plugin dir, validate, symlink the CLI, rescan plugins
omarchy-restart-shell             # QML changes need this: rescan keeps Qt's component cache
bash tests/cli.test.sh            # CLI tests against a throwaway XDG tree (≈3 min)
bash tests/lint.sh                # shellcheck, manifest schema, QML hygiene, README sections
```

The tests use the real microphone, ffmpeg and voxtype with `base.en`; a
missing engine, model or mic is a failure unless `OMARECORDER_TEST_ALLOW_SKIP=1`
(CI runs `tests/lint.sh` and the CLI tests that way in an Arch container).
`OMARECORDER_SYNC=1` runs jobs inline instead of under `systemd-run`;
`OMARECORDER_RUN_DIR` (tests only) moves the runtime state out of
`$XDG_RUNTIME_DIR` so the real user manager stays reachable. There is
no QML test harness — review QML by reading it and restarting the shell; the
screenshots in `docs/screenshots/` are the reference for how it should look.

Design specs: `docs/superpowers/specs/2026-08-29-omarecorder-design.md`,
`docs/superpowers/specs/2026-08-30-v1.0-design.md`.

## Roadmap

**1.x**

* AI clean-up and summary of a transcript via the AI provider your Omarchy
  system already uses.
* Speaker attribution and per-track transcripts for "both" — only if Omarchy
  ships an engine for it. No new packages is a rule.
* A graphical import picker once the Quickshell FileDialog crash is fixed upstream.

Not planned: bundling `whisper-cpp` or `sherpa-onnx` — voxtype is the engine.

## Prior art and thanks

voxtype (engine), rmacy/omarchy-voxtype-osd (level meter ideas),
iamcheyan/omarchy-voxtype-enhance (model-download cards),
Aryan-Techie/omarchy-todoist and robzolkos/omarchy-github (panel conventions),
ilyazar/omarchy-syncthing (service/panel split). SamuraiScribe and anarlog for
the "session library" shape.

## License

MIT — see `LICENSE`.
