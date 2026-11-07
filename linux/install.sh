#!/bin/sh
# Builds Herb's Terminal for Linux and installs it under a prefix (/app inside the Flatpak build).
# Usage: sh linux/install.sh PREFIX   (run from the repository root)
set -eu
PREFIX="${1:-/app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sh "$ROOT/script/version.sh")"
# flatpak-builder copies the sources without .git, so the version comes from the stamp written before the build
# (sh script/version.sh > linux/version.txt; script/build_flatpak.sh does it).
if [ ! -e "$ROOT/.git" ] && [ -s "$ROOT/linux/version.txt" ]; then VERSION="$(tr -d ' \n\r' < "$ROOT/linux/version.txt")"; fi
cd "$ROOT/linux"
printf 'let appVersion = "%s"\n' "$VERSION" > Sources/HerbsTerminal/Version.swift
swift build -c release --static-swift-stdlib --product HerbsTerminal
BIN="$(swift build -c release --show-bin-path)"
install -Dm755 "$BIN/HerbsTerminal" "$PREFIX/bin/herbs-terminal"
install -Dm644 data/org.herbsterminal.app.desktop "$PREFIX/share/applications/org.herbsterminal.app.desktop"
mkdir -p "$PREFIX/share/metainfo"
sed "s|<release version=\"[^\"]*\" date=\"[^\"]*\"/>|<release version=\"$VERSION\" date=\"$(date -u +%Y-%m-%d)\"/>|" \
    data/org.herbsterminal.app.metainfo.xml > "$PREFIX/share/metainfo/org.herbsterminal.app.metainfo.xml"
install -Dm644 data/org.herbsterminal.app.svg "$PREFIX/share/icons/hicolor/scalable/apps/org.herbsterminal.app.svg"
for icon in data/icons/hicolor/scalable/actions/*.svg; do
    install -Dm644 "$icon" "$PREFIX/share/icons/hicolor/scalable/actions/$(basename "$icon")"
done
install -Dm644 "$ROOT/LICENSE" "$PREFIX/share/licenses/org.herbsterminal.app/LICENSE"
install -Dm644 "$ROOT/NOTICES" "$PREFIX/share/licenses/org.herbsterminal.app/NOTICES"
