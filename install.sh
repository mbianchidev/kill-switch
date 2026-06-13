#!/bin/bash
# KillSwitch installer.
#
# One-line install (downloads the latest prebuilt release):
#   curl -fsSL https://raw.githubusercontent.com/mbianchidev/kill-switch/main/install.sh | bash
#
# From a source checkout it builds with Swift instead. Override the mode with
#   KILLSWITCH_INSTALL_MODE=release  # force prebuilt download
#   KILLSWITCH_INSTALL_MODE=source   # force local Swift build
set -euo pipefail

REPO="mbianchidev/kill-switch"
INSTALL_DIR="$HOME/bin"
INSTALL_PATH="$INSTALL_DIR/KillSwitch"
PLIST_LABEL="io.killswitch.agent"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

log() { echo "$1"; }
die() { echo "❌ $1" >&2; exit 1; }

# Pick install mode: explicit override, else build when run inside a checkout
# with Swift, else download the latest prebuilt release (the curl | bash path).
choose_mode() {
  if [ -n "${KILLSWITCH_INSTALL_MODE:-}" ]; then
    echo "$KILLSWITCH_INSTALL_MODE"
  elif [ -f "Package.swift" ] && command -v swift >/dev/null 2>&1; then
    echo "source"
  else
    echo "release"
  fi
}

build_from_source() {
  command -v swift >/dev/null 2>&1 || die "Swift not found. Install Xcode Command Line Tools or use the release installer."
  log "🔨 Building KillSwitch from source..."
  swift build -c release
  mkdir -p "$INSTALL_DIR"
  cp ".build/release/KillSwitch" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
}

download_release() {
  command -v curl >/dev/null 2>&1 || die "curl is required to download the release."
  command -v shasum >/dev/null 2>&1 || die "shasum is required to verify the download."

  local base="https://github.com/$REPO/releases/latest/download"
  local tmp sha
  tmp="$(mktemp -t KillSwitch)" || die "Could not create a temp file."
  sha="$(mktemp -t KillSwitch.sha256)" || die "Could not create a temp file."
  trap 'rm -f "$tmp" "$sha"' RETURN

  log "📥 Downloading latest KillSwitch release..."
  curl -fsSL -o "$tmp" "$base/KillSwitch" || die "Failed to download the KillSwitch binary."
  curl -fsSL -o "$sha" "$base/KillSwitch.sha256" || die "Failed to download the checksum."

  log "🔐 Verifying checksum..."
  local expected
  expected="$(tr -d '[:space:]' < "$sha")"
  [ -n "$expected" ] || die "Empty checksum file."
  printf '%s  %s\n' "$expected" "$tmp" | shasum -a 256 -c - >/dev/null 2>&1 \
    || die "Checksum verification failed — refusing to install."

  mkdir -p "$INSTALL_DIR"
  cp "$tmp" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
}

install_plist() {
  log "🚀 Installing LaunchAgent for startup..."
  mkdir -p "$(dirname "$PLIST_DST")"
  cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
}

reload_agent() {
  log "⏹  Unloading existing agent (if any)..."
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  log "▶️  Loading LaunchAgent..."
  launchctl load "$PLIST_DST"
}

MODE="$(choose_mode)"
case "$MODE" in
  source)  build_from_source ;;
  release) download_release ;;
  *)       die "Unknown KILLSWITCH_INSTALL_MODE '$MODE' (expected 'source' or 'release')." ;;
esac

log "📦 Installed binary to $INSTALL_PATH ($MODE)"
install_plist
reload_agent

echo ""
echo "✅ KillSwitch installed and set to run at login!"
echo "   Binary: $INSTALL_PATH"
echo "   LaunchAgent: $PLIST_DST"
echo ""
echo "   To uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
