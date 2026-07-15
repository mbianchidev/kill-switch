#!/bin/bash
set -e

INSTALL_DIR="$HOME/bin"
INSTALL_PATH="$INSTALL_DIR/KillSwitch"
CLI_PATH="$INSTALL_DIR/killswitchctl"
PLIST_SRC="io.killswitch.agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.killswitch.agent.plist"

die() { echo "❌ $1" >&2; exit 1; }

validate_install_path() {
  [ ! -d "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ] \
    || die "Refusing to replace directory at $INSTALL_PATH. Move it and rerun the update."
}

install_binary() {
  local source="$1"
  local staged

  validate_install_path
  mkdir -p "$INSTALL_DIR"
  staged="$(mktemp "$INSTALL_DIR/.KillSwitch.XXXXXX")" \
    || die "Could not create a staged install file in $INSTALL_DIR."
  cp "$source" "$staged" \
    || { rm -f "$staged"; die "Could not stage the KillSwitch binary."; }
  chmod +x "$staged" \
    || { rm -f "$staged"; die "Could not make the staged KillSwitch binary executable."; }
  validate_install_path
  mv -fh "$staged" "$INSTALL_PATH" \
    || { rm -f "$staged"; die "Could not replace $INSTALL_PATH."; }
}

validate_install_path
[ ! -e "$CLI_PATH" ] || [ -L "$CLI_PATH" ] || {
  echo "❌ Refusing to replace non-symlink at $CLI_PATH. Move it and rerun the update." >&2
  exit 1
}

echo "🔄 Updating KillSwitch..."

echo "📥 Pulling latest..."
git pull --rebase

echo "🔨 Building..."
swift build -c release --product KillSwitch

echo "⏹  Stopping running instance..."
launchctl unload "$PLIST_DST" 2>/dev/null || true

echo "📦 Installing binary..."
install_binary ".build/release/KillSwitch"
ln -sfn "$INSTALL_PATH" "$CLI_PATH"

echo "📋 Updating LaunchAgent..."
mkdir -p "$(dirname "$PLIST_DST")"
sed "s|__INSTALL_PATH__|$INSTALL_PATH|g" "$PLIST_SRC" > "$PLIST_DST"

echo "▶️  Starting..."
launchctl load "$PLIST_DST"

echo "✅ KillSwitch updated!"
