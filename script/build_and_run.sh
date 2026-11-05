#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HerbsTerminal"
DISPLAY_NAME="Herb's Terminal"
BUNDLE_ID="org.herbsterminal.app"
MIN_SYSTEM_VERSION="15.0"
# The version rises with every commit on main; see script/version.sh.
VERSION="$(sh "$(dirname "${BASH_SOURCE[0]}")/version.sh")"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# --bundle only assembles and signs the app, leaving a running copy alone.
if [[ "$MODE" != "--bundle" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
swift build --build-system native --product "$APP_NAME"
BUILD_BINARY="$(swift build --build-system native --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
mkdir -p "$APP_CONTENTS/Resources"
cp "$ROOT_DIR/Assets/HerbsTerminal.icns" "$APP_CONTENTS/Resources/HerbsTerminal.icns"
cp -R "$(dirname "$BUILD_BINARY")/SwiftTerm_SwiftTerm.bundle" "$APP_CONTENTS/Resources/"
# Helpers the app runs itself, so it never depends on copies installed elsewhere on the system.
mkdir -p "$APP_CONTENTS/Helpers"
cp "$ROOT_DIR/Vendor/tailcat/tailcat" "$APP_CONTENTS/Helpers/tailcat"
cp "$ROOT_DIR/Vendor/tailcat/LICENSE" "$APP_CONTENTS/Resources/tailcat-LICENSE.txt"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIconFile</key>
  <string>HerbsTerminal.icns</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Herb's Terminal connects to SSH, SFTP and remote desktop services on computers in your local network.</string>
</dict>
</plist>
PLIST

# Sign the assembled bundle under its bundle identifier. Without this the linker's ad-hoc signature
# names the binary "HerbsTerminal-<hash>", macOS Local Network privacy can't match it to the bundle ID,
# and ssh to LAN addresses fails with "No route to host".
#
# With SIGN_IDENTITY set to a Developer ID Application certificate (for example
# SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"), the helper and the app are signed with it,
# with the hardened runtime and a secure timestamp, ready for script/notarize.sh. Otherwise the signature
# is ad hoc, which runs on this Mac only.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi
codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID.tailcat" "$APP_CONTENTS/Helpers/tailcat"
codesign "${SIGN_OPTIONS[@]}" --identifier "$BUNDLE_ID" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --bundle)
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
