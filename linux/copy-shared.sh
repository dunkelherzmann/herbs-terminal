#!/bin/sh
# Copies the sources every version shares (shared/ at the repository root) into Sources/HerbsTerminal/Shared,
# where the Linux package compiles them. The copies are gitignored and refreshed before every build.
# Usage: sh linux/copy-shared.sh   (from anywhere)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dest="$ROOT/linux/Sources/HerbsTerminal/Shared"
rm -rf "$dest"
mkdir -p "$dest"
cp "$ROOT"/shared/*.swift "$dest/"
