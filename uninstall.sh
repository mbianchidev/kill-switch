#!/bin/bash
set -e

INSTALL_PATH="$HOME/bin/KillSwitch"
PLIST_DST="$HOME/Library/LaunchAgents/io.killswitch.agent.plist"

echo "⏹  Unloading LaunchAgent..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "🗑  Removing files..."
rm -f "$INSTALL_PATH"
rm -f "$PLIST_DST"

echo "✅ KillSwitch uninstalled."
