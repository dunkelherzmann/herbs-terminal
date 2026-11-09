#!/bin/sh
# Development (debug) build of the Linux version, on the Linux machine: linux/.build/flatpak/debug/HerbsTerminal.
# Usage: linux/dev/build.sh [swift build arguments]
set -eu
. "$(dirname "$0")/env.sh"
prepare_sdk
version="let appVersion = \"$(sh "$ROOT/scripts/version.sh")\""
file="$ROOT/linux/Sources/HerbsTerminal/Version.swift"
[ "$(cat "$file" 2>/dev/null)" = "$version" ] || printf '%s\n' "$version" > "$file"
sh "$ROOT/linux/copy-shared.sh"
in_sdk sh -c 'cd "$1/linux" && shift && swift build --scratch-path "$@"' sh "$ROOT" "$SCRATCH" "$@"
