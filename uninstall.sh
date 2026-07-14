#!/bin/bash
set -e

INSTALL_PATH="$HOME/bin/KillSwitch"
CLI_PATH="$HOME/bin/killswitchctl"
PLIST_DST="$HOME/Library/LaunchAgents/io.killswitch.agent.plist"

[ ! -d "$CLI_PATH" ] || [ -L "$CLI_PATH" ] || {
  echo "❌ Refusing to remove directory at $CLI_PATH. Move it and rerun uninstall." >&2
  exit 1
}

echo "⏹  Unloading LaunchAgent..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "🗑  Removing files..."
rm -f "$CLI_PATH"
rm -f "$INSTALL_PATH"
rm -f "$PLIST_DST"

echo "✅ KillSwitch uninstalled."
