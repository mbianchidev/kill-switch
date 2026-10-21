#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
die() { echo "Package check failed: $1" >&2; exit 1; }

mkdir -p "$ROOT/.build"
STAGE="$(mktemp -d "$ROOT/.build/macos-package-checks.XXXXXX")"
MOUNT="$STAGE/mount"
MOUNTED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$MOUNTED" -eq 1 ]; then
    if ! hdiutil detach -quiet "$MOUNT"; then
      echo "Could not unmount $MOUNT. Temporary files were left in $STAGE." >&2
      exit 1
    fi
  fi
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT

for ASSET in KillSwitch KillSwitch.dmg; do
  [ -f "$DIST/$ASSET" ] || die "Missing $DIST/$ASSET. Run scripts/package-macos.sh first."
  EXPECTED="$(cat "$DIST/$ASSET.sha256")"
  printf '%s  %s\n' "$EXPECTED" "$DIST/$ASSET" | shasum -a 256 -c -
done
hdiutil verify -quiet "$DIST/KillSwitch.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DIST/KillSwitch.dmg"
MOUNTED=1

APP="$MOUNT/KillSwitch.app"
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "io.killswitch.app" ] \
  || die "Incorrect app bundle identifier."
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = "KillSwitch" ] \
  || die "Incorrect app executable."
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "13.0" ] \
  || die "Incorrect minimum macOS version."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :KillSwitchVersion' "$PLIST")"
if [ "$VERSION" = "dev" ]; then
  BUNDLE_VERSION="0.0.0"
else
  BUNDLE_VERSION="${VERSION#v}"
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$BUNDLE_VERSION" ] \
  || die "App and bundle versions disagree."
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BUNDLE_VERSION" ] \
  || die "App and build versions disagree."
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  || die "Missing drag-to-Applications shortcut."
grep -Fq 'xattr -dr com.apple.quarantine /Applications/KillSwitch.app' "$MOUNT/Install.txt" \
  || die "Missing quarantine removal instructions."
iconutil --convert iconset --output "$STAGE/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$DIST/KillSwitch"

INSTALLED_APP="$STAGE/Mock Applications/KillSwitch.app"
ditto "$APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

mkdir -p "$STAGE/legacy"
tar -xzf "$DIST/KillSwitch.tar.gz" -C "$STAGE/legacy"
cmp "$DIST/KillSwitch" "$STAGE/legacy/KillSwitch"

# Invalid arguments exercise headless dispatch without reading preferences or running cleanup.
for BINARY in "$APP/Contents/MacOS/KillSwitch" "$INSTALLED_APP/Contents/MacOS/KillSwitch" "$DIST/KillSwitch"; do
  for ARCH in arm64 x86_64; do
    lipo "$BINARY" -verify_arch "$ARCH"
  done
  ln -sfn "$BINARY" "$STAGE/killswitchctl"
  STATUS=0
  "$STAGE/killswitchctl" invalid --json > "$STAGE/stdout" 2> "$STAGE/stderr" || STATUS=$?
  [ "$STATUS" -eq 2 ] || die "CLI dispatch exited $STATUS instead of 2 for $BINARY."
  [ ! -s "$STAGE/stdout" ] || die "Invalid CLI arguments unexpectedly produced stdout."
  [ "$(plutil -extract error.code raw -o - "$STAGE/stderr")" = "invalid_arguments" ] \
    || die "CLI did not return the expected JSON error."
done
echo "macOS package checks passed."
