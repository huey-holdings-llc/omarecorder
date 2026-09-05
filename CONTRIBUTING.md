# Contributing to OmaRecorder

Thank you for looking at this. OmaRecorder is a part-time hobby project, built
with AI assistance by someone who is not a professional developer. Pull requests
from people who know this territory better are the best thing that can happen
to it. Issues and pull requests are handled as time allows, so please be patient,
and feel free to fork if you would rather move at your own pace.

## Principles

These are the rules the project has followed so far. A pull request that keeps
to them is easy to merge; one that breaks them will get a conversation first.

1. **Base Omarchy first.** The plugin should work on a fresh Omarchy install
   with nothing added except `omarchy install dictation` for voxtype. If a
   feature needs a new package, it does not go in. Prefer what Omarchy already
   ships (pipewire, ffmpeg, jq, systemd, mpv, wl-clipboard, glib2, Obsidian,
   Quickshell and Qt) over anything else, and prefer Omarchy's own commands
   (`omarchy-notification-send`, `omarchy-launch-editor`, `omarchy-shell`) over
   generic ones where they exist.
2. **Simplicity and efficiency over features.** No daemons, no polling, no
   background work the user did not ask for. The shell watches a few small
   files; everything else happens in the CLI, on demand, and exits. A feature
   that costs idle CPU, a permanent process, or a second copy of the audio
   needs a very good reason.
3. **Follow Omarchy's design and theming.** Use the shell's `qs.Ui` kit
   (`Panel`, `KeyboardPanel`, `Button`, `Dropdown`, `TextField`,
   `ConfirmDialog`, and so on) and the theme tokens (`Color.*`, `Style.*`,
   `bar.foreground` and friends) rather than hard-coded colours, fonts or
   sizes. Every surface must look right in every Omarchy theme, light or dark,
   and every action must be reachable from the keyboard with the shortcut shown
   on screen.
4. **The CLI is the product; QML is a view.** Anything the UI can do must be an
   `omarecorder` command first, with a test in `tests/cli.test.sh`. QML files
   render state and call commands; they hold no logic that a keybinding or a
   script could not reach.
5. **Local-first and private by default.** Nothing leaves the machine. Files
   are created private to the user (`umask 077`), runtime state lives only in
   `$XDG_RUNTIME_DIR`, and the plugin never edits the user's Hyprland, Omarchy
   or Obsidian configuration. Read those, do not write them.
6. **Data is never code.** Titles, paths and ids go through argument arrays and
   `jq --arg`, never into a shell string, a `jq` filter or a systemd unit body.
   `tests/lint.sh` greps for `bash -c` in QML and will fail the build if one
   appears.
7. **Say what it does.** A button that says "Move to trash" must never
   `rm -rf`. A README sentence must describe what the code does today, not what
   is planned. If you change behaviour, change the README and the CHANGELOG in
   the same pull request.

## Practical bits

* **Dev loop**: `scripts/dev-install.sh --enable`, then `omarchy-restart-shell`
  for QML changes. `bash tests/cli.test.sh` (about three minutes, uses the real
  microphone and voxtype) and `bash tests/lint.sh` must both pass. No mic or
  voxtype on your machine? `OMARECORDER_TEST_ALLOW_SKIP=1` turns those blocks
  into counted skips; that is how CI runs the suite in an Arch container.
* **Tests first** for CLI changes. The harness is plain bash (`check`, `eq`,
  `fails`, `run_cli`, `wait_for`); fixtures are generated with ffmpeg; the
  sandbox is a throwaway XDG tree that is kept when anything fails. The suite
  is split into sections that each start from a clean state, so
  `OMARECORDER_TEST_ONLY=export,tidy bash tests/cli.test.sh` runs just the
  ones you are working on (`--list` prints the names).
* **Small pull requests** with one change each merge faster than one big one.
* **Second-model review**: larger pull requests get a review from OpenAI
  Codex, requested by the maintainer with a `@codex review` comment. Treat its
  findings as a starting point for the discussion, not as a verdict either way.
  (The review instructions used to live in a tracked `AGENTS.md`; the Omarchy
  marketplace does not allow agent-instruction files in a distributed plugin,
  since an install is a plain git clone, so the file is kept out of git now.)
* **Style**: bash with `set -euo pipefail` and shellcheck clean; QML in the
  style of the existing files; plain, direct English in docs and messages.
* **Reporting a bug**: include `omarecorder setup check --json`, the relevant
  lines of `~/.local/state/omarecorder/omarecorder.log`, and, for a failed
  transcription, `~/.local/state/omarecorder/tx-<id>.err`. Never paste a
  transcript you would not want public.

## Help wanted

Pull requests are welcome anywhere, but these are the areas where the project
most needs someone who knows more than its author:

* **Languages other than English.** The presets are the `.en` whisper models.
  voxtype also ships multilingual ones (`base`, `small`, `large-v3-turbo`) and
  a language setting exists, but nobody has tested a non-English take end to
  end, the UI strings are English only, and `language: auto` has had no real
  use. Someone who records in another language would find the gaps in an hour.
* **UI improvements that keep it simple.** The popup and the Library were built
  by one person against one theme on one laptop. Reviews from people who use
  other Omarchy themes, a vertical bar, more than one monitor, or a high-DPI
  screen are all valuable. So is anything that makes a screen easier to read
  without adding controls.
* **Accessibility.** Keyboard reach is good; screen reader behaviour and
  contrast under every theme have not been checked.
* **Other hardware.** CPU-only machines, CUDA, different microphones and USB
  interfaces. The speed estimates and the clipping detector were tuned on one
  laptop.
* **The Quickshell file dialog crash.** A QtQuick `FileDialog` crashes
  Quickshell 0.3.1 on Omarchy 4, both inside the shell and in a separate `qs`
  process. Anyone who can diagnose it upstream unblocks a graphical picker;
  open an issue and the crash reports can be attached.
* **Per-track transcripts for "both" takes.** The raw tracks are already kept;
  transcribing them separately and interleaving the result is the missing piece.
* **Transcript quality.** Better seam choices for long takes, or a cheaper way
  to detect whisper's repetition loops after the fact.

## Ideas that fit

Anything on the [issue tracker](https://github.com/huey-holdings-llc/omarecorder/issues)
(the pinned roadmap issue is the overview), better estimates, a nicer Setup card, more
languages, accessibility, and anything that makes the code simpler without
changing what it does. Ideas that do not fit: new engines or models that need
packages Omarchy does not ship, cloud services, or features that need a
resident process.

## License

By contributing you agree that your contribution is licensed under the MIT
license, like the rest of the project.
