#!/bin/sh
# Removes the Claude Code hooks, the app and its data (~/.maitre-d-agent).
set -eu

APP="$HOME/Applications/MaitreDAgent.app"
pkill -x MaitreDAgent 2>/dev/null || true
if [ -x "$APP/Contents/MacOS/MaitreDAgent" ]; then
    "$APP/Contents/MacOS/MaitreDAgent" --uninstall-hooks
fi
rm -rf "$APP" "$HOME/.maitre-d-agent"
echo "Removed Maître d'Agént. A backup of ~/.claude/settings.json was kept next to it."
