# AGENTS.md — omarecorder

Instructions for Codex (and any other agent that reads AGENTS.md). Claude Code
works from the design specs in `docs/superpowers/specs/`; keep both in step.

## What this is

An Omarchy (Arch + Hyprland) shell plugin that records audio from the bar and
transcribes it locally, later, with the voxtype/whisper engine Omarchy ships.
Users are Omarchy desktop users recording meetings and tabletop game sessions.
"Working" means: one click records, the take lands in `~/Recordings/<id> <title>/`
with `audio.wav` + `meta.json`, transcription runs detached and survives the
shell restarting, and nothing ever leaves the machine.

## Stack and layout

| Path | What it is |
|---|---|
| `bin/omarecorder` | The whole backend: a single bash CLI (`set -euo pipefail`, jq for JSON). Every UI action is a CLI command. |
| `Service.qml` | Shell-side state: watches one small state file, exposes properties to the widgets. No polling loops. |
| `Panel.qml`, `Library.qml`, `ui/*.qml` | Qt Quick UI on the omarchy-shell framework (`Panel`, `BarWidget`, `WidgetButton`). |
| `manifest.json` | Plugin manifest (id `io.github.coreytyhurst.omarecorder`). |
| `tests/cli.test.sh` | CLI tests against a throwaway XDG tree. |
| `scripts/dev-install.sh` | rsync into the plugin dir + rescan. |

External commands the CLI shells out to: `pw-record`, `pactl`, `wpctl`,
`ffmpeg`, `voxtype`, `systemd-run`, `jq`, `mpv`/`pw-play`, `notify-send`.

## Run and test

```bash
bash tests/cli.test.sh          # transcription tests skip if voxtype/base.en is absent — that is expected
scripts/dev-install.sh --enable # deploy to ~/.config/omarchy/plugins/… (QML changes also need omarchy-restart-shell)
```

There is no QML test harness; review QML by reading it. Do not claim QML
changes were verified unless a screenshot or a shell restart was actually done.

## Review priorities (in order)

Flag P0/P1 only. The last two hardening passes were about exactly these, so
hold new code to the same bar:

1. **Shell safety in `bin/omarecorder`** — every user string (titles, paths,
   ids, model names) must be passed as an argument, never interpolated into a
   command string, `eval`, `jq` filter text, or `systemd-run` unit body. `jq`
   gets data via `--arg`/`--rawfile`. Watch `set -u` against optional vars.
2. **State and files** — state lives in `$XDG_RUNTIME_DIR/omarecorder`
   (mode 700), config in `$XDG_CONFIG_HOME/omarecorder`, never `/tmp`. Writes to
   `meta.json` must be atomic (temp + `mv`). Recording folders are renamed as a
   unit; `delete` must only remove inside `~/Recordings` and only with `--yes`.
3. **Detached jobs** — transcription runs under `systemd-run --user`; it must
   survive shell restarts, be cancellable, and update state on both success and
   failure so the UI never shows a stuck "transcribing".
4. **QML robustness** — user strings render as plain text (no rich text), every
   model-backed action null-guards the current row, and no binding assigns
   `undefined` to a typed property.
5. **Tests** — CLI behaviour changes need a case in `tests/cli.test.sh`.
6. **Docs** — `README.md` CLI table and `CHANGELOG.md` `[Unreleased]` must reflect
   user-visible changes.

Do not comment on style, formatting, QML layout aesthetics, or naming unless
it hides a bug. Do not suggest refactors outside the diff.

## Conventions

- Commit subjects: `type(scope): summary` — `feat`, `fix`, `ux`, `security`, `docs`, `chore`.
- CHANGELOG follows Keep a Changelog; user-facing changes go under `[Unreleased]`.
- Branches: `feat/*`, `release/*`; PRs target `main`.

## Do not touch

- `preview.png` (binary asset), `docs/superpowers/specs/*` (design records —
  history, not code), `.claude/` (ignored).
