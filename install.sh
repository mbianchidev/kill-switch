#!/bin/bash
set -e

echo "🔨 Building KillSwitch..."
swift build -c release

BINARY=".build/release/KillSwitch"
INSTALL_DIR="$HOME/bin"
INSTALL_PATH="$INSTALL_DIR/KillSwitch"
PLIST_SRC="io.killswitch.agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.killswitch.agent.plist"

echo "📦 Installing binary to $INSTALL_PATH..."
mkdir -p "$INSTALL_DIR"
cp "$BINARY" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo "🚀 Installing LaunchAgent for startup..."
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__INSTALL_PATH__|$INSTALL_PATH|g" "$PLIST_SRC" > "$PLIST_DST"

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
