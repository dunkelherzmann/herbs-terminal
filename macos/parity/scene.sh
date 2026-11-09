#!/usr/bin/env bash
# Opens one parity scene in the Mac parity copy (in the background, without taking focus), saves its UI tree
# and a picture of its window, then quits it. Usage: macos/parity/scene.sh <scene> <output folder>
set -euo pipefail
cd "$(dirname "$0")/../.."
scene="$1"; out="$2"
mkdir -p "$out"
executable="$(macos/parity/copy.sh 2>/dev/null)"
app="${executable%/Contents/MacOS/*}"
osascript -e 'tell application id "org.herbsterminal.parity" to quit' >/dev/null 2>&1 || true
# Every scene starts from the default settings: clear what earlier scenes left in the parity copy's own settings
# domain (never the app's real one, org.herbsterminal.app).
domain="org.herbsterminal.parity"
defaults delete "$domain" >/dev/null 2>&1 || true
open -n -g -a "$app" --args --parity-scene "$scene"
pid=""
for _ in $(seq 1 40); do
    pid="$(pgrep -f "^$executable" | head -1 || true)"
    [[ -n "$pid" ]] && break
    sleep 0.25
done
[[ -n "$pid" ]] || { echo "the parity copy didn't start" >&2; exit 1; }
sleep "${PARITY_SETTLE_SECS:-4}"
swift "$HOME/.agents/library/app-parity/scripts/mac-ax-dump.swift" "$pid" "$out/$scene-tree.json" "$out/$scene.png"
for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    osascript -e 'tell application id "org.herbsterminal.parity" to quit' >/dev/null 2>&1 || true
    sleep 0.5
done
kill -0 "$pid" 2>/dev/null && { echo "the parity copy didn't quit (pid $pid)" >&2; exit 1; }
echo "$out/$scene-tree.json"
