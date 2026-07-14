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
CLI_PATH="$INSTALL_DIR/killswitchctl"
PLIST_LABEL="io.killswitch.agent"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

log() { echo "$1"; }
die() { echo "❌ $1" >&2; exit 1; }

[ ! -d "$CLI_PATH" ] || [ -L "$CLI_PATH" ] \
  || die "Refusing to replace directory at $CLI_PATH. Move it and rerun the installer."

# Pick install mode: explicit override, else build when run inside a checkout
# with Swift, else download the latest prebuilt release (the curl | bash path).
choose_mode() {
  if [ -n "${KILLSWITCH_INSTALL_MODE:-}" ]; then
    echo "$KILLSWITCH_INSTALL_MODE"
  elif [ -f "Package.swift" ] && [ -d "Sources/KillSwitch" ] && command -v swift >/dev/null 2>&1; then
    echo "source"
  else
    echo "release"
  fi
}

build_from_source() {
  command -v swift >/dev/null 2>&1 || die "Swift not found. Install Xcode Command Line Tools or use the release installer."
  log "🔨 Building KillSwitch from source..."
  swift build -c release --product KillSwitch
  mkdir -p "$INSTALL_DIR"
  cp ".build/release/KillSwitch" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
}

download_release() {
  command -v curl >/dev/null 2>&1 || die "curl is required to download the release."
  command -v shasum >/dev/null 2>&1 || die "shasum is required to verify the download."

  local base="https://github.com/$REPO/releases/latest/download"
  local tmp="" sha=""
  cleanup_download_release() {
    [ -z "${tmp:-}" ] || rm -f "$tmp"
    [ -z "${sha:-}" ] || rm -f "$sha"
  }
  trap cleanup_download_release RETURN
  trap cleanup_download_release EXIT

  tmp="$(mktemp -t KillSwitch)" || die "Could not create a temp file."
  sha="$(mktemp -t KillSwitch.sha256)" || die "Could not create a temp file."

  log "📥 Downloading latest KillSwitch release..."
  curl -fsSL -o "$tmp" "$base/KillSwitch" || die "Failed to download the KillSwitch binary."
  curl -fsSL -o "$sha" "$base/KillSwitch.sha256" || die "Failed to download the checksum."

  log "🔐 Verifying checksum..."
  local expected
  expected="$(awk '{print $1}' "$sha" | tr -d '[:space:]')"
  [ -n "$expected" ] || die "Empty checksum file."
  printf '%s  %s\n' "$expected" "$tmp" | shasum -a 256 -c - >/dev/null 2>&1 \
    || die "Checksum verification failed — refusing to install."

  mkdir -p "$INSTALL_DIR"
  cp "$tmp" "$INSTALL_PATH"
  chmod +x "$INSTALL_PATH"
  trap - RETURN
  cleanup_download_release
  trap - EXIT
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
ln -sfn "$INSTALL_PATH" "$CLI_PATH"
log "🔗 Installed CLI alias at $CLI_PATH"
install_plist
reload_agent

echo ""
echo "✅ KillSwitch installed and set to run at login!"
echo "   Binary: $INSTALL_PATH"
echo "   CLI: $CLI_PATH"
echo "   LaunchAgent: $PLIST_DST"
echo ""
echo "   To uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
