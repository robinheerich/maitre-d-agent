#!/bin/sh
# Builds the app, installs it to ~/Applications, installs the Claude Code hooks
# (backing up ~/.claude/settings.json first) and launches it.
set -eu
cd "$(dirname "$0")/.."

./scripts/build.sh

DEST="$HOME/Applications/MaitreDAgent.app"
pkill -x MaitreDAgent 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/MaitreDAgent.app "$DEST"

if ! grep -q "maitre-d-agent/hook.sh" "$HOME/.claude/settings.json" 2>/dev/null; then
    "$DEST/Contents/MacOS/MaitreDAgent" --install-hooks
fi
open "$DEST"
echo "Installed $DEST"
