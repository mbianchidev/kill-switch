#!/bin/bash
set -e

INSTALL_PATH="/usr/local/bin/KillSwitch"
PLIST_DST="$HOME/Library/LaunchAgents/com.mbianchidev.killswitch.plist"

echo "🔄 Updating KillSwitch..."

echo "📥 Pulling latest..."
git pull --rebase

echo "🔨 Building..."
swift build -c release

echo "⏹  Stopping running instance..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "📦 Installing binary..."
sudo cp .build/release/KillSwitch "$INSTALL_PATH"
sudo chmod +x "$INSTALL_PATH"

echo "📋 Updating LaunchAgent..."
cp com.mbianchidev.killswitch.plist "$PLIST_DST"

echo "▶️  Starting..."
launchctl load "$PLIST_DST"

echo "✅ KillSwitch updated!"
