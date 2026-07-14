#!/bin/bash
set -e

INSTALL_DIR="$HOME/bin"
INSTALL_PATH="$INSTALL_DIR/KillSwitch"
CLI_PATH="$INSTALL_DIR/killswitchctl"
PLIST_SRC="io.killswitch.agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.killswitch.agent.plist"

echo "🔄 Updating KillSwitch..."

echo "📥 Pulling latest..."
git pull --rebase

echo "🔨 Building..."
swift build -c release --product KillSwitch

echo "⏹  Stopping running instance..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "📦 Installing binary..."
mkdir -p "$INSTALL_DIR"
cp .build/release/KillSwitch "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
ln -sfn "$INSTALL_PATH" "$CLI_PATH"

echo "📋 Updating LaunchAgent..."
mkdir -p "$(dirname "$PLIST_DST")"
sed "s|__INSTALL_PATH__|$INSTALL_PATH|g" "$PLIST_SRC" > "$PLIST_DST"

echo "▶️  Starting..."
launchctl load "$PLIST_DST"

echo "✅ KillSwitch updated!"
