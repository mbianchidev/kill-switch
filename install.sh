#!/bin/bash
set -e

echo "🔨 Building KillSwitch..."
swift build -c release

BINARY=".build/release/KillSwitch"
INSTALL_PATH="/usr/local/bin/KillSwitch"
PLIST_SRC="com.mbianchidev.killswitch.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.mbianchidev.killswitch.plist"

echo "📦 Installing binary to $INSTALL_PATH..."
sudo cp "$BINARY" "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"

echo "🚀 Installing LaunchAgent for startup..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

echo "⏹  Unloading existing agent (if any)..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "▶️  Loading LaunchAgent..."
launchctl load "$PLIST_DST"

echo ""
echo "✅ KillSwitch installed and set to run at login!"
echo "   Binary: $INSTALL_PATH"
echo "   LaunchAgent: $PLIST_DST"
echo ""
echo "   To uninstall: ./uninstall.sh"
