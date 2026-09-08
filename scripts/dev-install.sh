#!/usr/bin/env bash
# Mirror this checkout into the Omarchy plugin directory and reload the shell.
# The plugin tree may not contain symlinks (validator rule), so we rsync.
#   scripts/dev-install.sh            # sync + validate + rescan
#   scripts/dev-install.sh --enable   # also enable the bar widget (right section)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ID=$(jq -r .id "$HERE/manifest.json")
DEST="$HOME/.config/omarchy/plugins/$ID"

mkdir -p "$DEST"
# A real install is a plain clone, so the mirror must not carry anything git
# ignores. AGENTS.md especially: the marketplace does not allow agent-instruction
# files in a distributed plugin, which is why it is untracked in the first place.
rsync -a --delete \
  --exclude .git --exclude 'tests/tmp' --exclude 'docs' --exclude '.spike' \
  --exclude '.claude' --exclude 'AGENTS.md' --exclude 'coverage' \
  "$HERE/" "$DEST/"
chmod +x "$DEST/bin/omarecorder" "$DEST/scripts/"*.sh

if command -v omarchy-plugin-validate >/dev/null; then
  omarchy-plugin-validate "$DEST"
fi

# Put the CLI on PATH (symlink lives outside the plugin tree, so validation is unaffected).
mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/bin/omarecorder" "$HOME/.local/bin/omarecorder"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if [[ "${1:-}" == "--enable" ]]; then
  omarchy-plugin-enable "$ID" --section right || true
fi
echo "installed → $DEST"
