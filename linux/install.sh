#!/bin/sh
# Builds Herb's Terminal for Linux and installs it under a prefix (/app inside the Flatpak build).
# Usage: sh linux/install.sh PREFIX   (run from the repository root)
set -eu
PREFIX="${1:-/app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sh "$ROOT/script/version.sh" 2>/dev/null || echo "$(tr -d ' \n' < "$ROOT/VERSION").0")"
cd "$ROOT/linux"
printf 'let appVersion = "%s"\n' "$VERSION" > Sources/HerbsTerminal/Version.swift
swift build -c release --static-swift-stdlib --product HerbsTerminal
BIN="$(swift build -c release --show-bin-path)"
install -Dm755 "$BIN/HerbsTerminal" "$PREFIX/bin/herbs-terminal"
install -Dm644 data/org.herbsterminal.app.desktop "$PREFIX/share/applications/org.herbsterminal.app.desktop"
install -Dm644 data/org.herbsterminal.app.metainfo.xml "$PREFIX/share/metainfo/org.herbsterminal.app.metainfo.xml"
install -Dm644 data/org.herbsterminal.app.svg "$PREFIX/share/icons/hicolor/scalable/apps/org.herbsterminal.app.svg"
for icon in data/icons/hicolor/scalable/actions/*.svg; do
    install -Dm644 "$icon" "$PREFIX/share/icons/hicolor/scalable/actions/$(basename "$icon")"
done
install -Dm644 "$ROOT/LICENSE" "$PREFIX/share/licenses/org.herbsterminal.app/LICENSE"
install -Dm644 "$ROOT/NOTICES" "$PREFIX/share/licenses/org.herbsterminal.app/NOTICES"
