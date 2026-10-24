#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${KILLSWITCH_VERSION:-dev}"

die() { echo "Packaging failed: $1" >&2; exit 1; }

UNIVERSAL_BUILD=0
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = "--universal-build" ] \
    || die "Usage: bash scripts/package-macos.sh [--universal-build]"
  UNIVERSAL_BUILD=1
fi

[ "$(uname -s)" = "Darwin" ] || die "macOS is required."
if [ "$VERSION" = "dev" ]; then
  BUNDLE_VERSION="0.0.0"
elif [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  BUNDLE_VERSION="${VERSION#v}"
else
  die "KILLSWITCH_VERSION must be 'dev' or a version such as v1.2.3."
fi

mkdir -p "$ROOT/.build" "$DIST"
STAGE="$(mktemp -d "$ROOT/.build/macos-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/image/KillSwitch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

BUILD_ARGS=(--package-path "$ROOT" -c release --jobs "$(sysctl -n hw.logicalcpu)")
if [ "$UNIVERSAL_BUILD" -eq 1 ]; then
  echo "Building universal KillSwitch and update helper..."
  BUILD_ARGS+=(--build-system swiftbuild --arch arm64 --arch x86_64)
  for PRODUCT in KillSwitch KillSwitchUpdateHelper; do
    swift build "${BUILD_ARGS[@]}" --product "$PRODUCT"
  done
  BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
  cp "$BIN_DIR/KillSwitch" "$STAGE/KillSwitch"
  cp "$BIN_DIR/KillSwitchUpdateHelper" "$APP/Contents/Helpers/KillSwitchUpdateHelper"
else
  BINARIES=()
  HELPERS=()
  for ARCH in arm64 x86_64; do
    echo "Building KillSwitch for $ARCH..."
    swift build "${BUILD_ARGS[@]}" --product KillSwitch --arch "$ARCH"
    BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --arch "$ARCH" --show-bin-path)"
    cp "$BIN_DIR/KillSwitch" "$STAGE/KillSwitch-$ARCH"
    lipo "$STAGE/KillSwitch-$ARCH" -verify_arch "$ARCH"
    BINARIES+=("$STAGE/KillSwitch-$ARCH")
    swift build "${BUILD_ARGS[@]}" --product KillSwitchUpdateHelper --arch "$ARCH"
    cp "$BIN_DIR/KillSwitchUpdateHelper" "$STAGE/KillSwitchUpdateHelper-$ARCH"
    lipo "$STAGE/KillSwitchUpdateHelper-$ARCH" -verify_arch "$ARCH"
    HELPERS+=("$STAGE/KillSwitchUpdateHelper-$ARCH")
  done
  lipo -create "${BINARIES[@]}" -output "$STAGE/KillSwitch"
  lipo -create "${HELPERS[@]}" -output "$APP/Contents/Helpers/KillSwitchUpdateHelper"
fi

for ARCH in arm64 x86_64; do
  lipo "$STAGE/KillSwitch" -verify_arch "$ARCH"
  lipo "$APP/Contents/Helpers/KillSwitchUpdateHelper" -verify_arch "$ARCH"
done
codesign --force --sign - --identifier io.killswitch.cli "$STAGE/KillSwitch"
cp "$STAGE/KillSwitch" "$APP/Contents/MacOS/KillSwitch"
codesign --force --sign - --identifier io.killswitch.update-helper "$APP/Contents/Helpers/KillSwitchUpdateHelper"
cp "$ROOT/packaging/macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :KillSwitchVersion $VERSION" "$APP/Contents/Info.plist"

xcrun swift "$ROOT/scripts/make-app-icon.swift" "$STAGE/AppIcon.iconset"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$STAGE/image/Applications"
cp "$ROOT/packaging/macos/Install.txt" "$STAGE/image/Install.txt"
hdiutil create -quiet -volname KillSwitch -srcfolder "$STAGE/image" \
  -fs HFS+ -format UDZO "$STAGE/KillSwitch.dmg"
tar -czf "$STAGE/KillSwitch.tar.gz" -C "$STAGE" KillSwitch
for ASSET in KillSwitch KillSwitch.dmg; do
  shasum -a 256 "$STAGE/$ASSET" | awk '{print $1}' > "$STAGE/$ASSET.sha256"
done

for ASSET in KillSwitch KillSwitch.sha256 KillSwitch.tar.gz KillSwitch.dmg KillSwitch.dmg.sha256; do
  [ ! -d "$DIST/$ASSET" ] || die "Refusing to overwrite directory $DIST/$ASSET."
  mv -f "$STAGE/$ASSET" "$DIST/$ASSET"
done
echo "Packaged $DIST/KillSwitch.dmg ($VERSION, Apple Silicon and Intel)."
