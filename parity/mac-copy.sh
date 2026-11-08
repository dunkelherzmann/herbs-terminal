#!/usr/bin/env bash
# Builds the parity copy of the Mac app: the same app under the bundle identifier org.herbsterminal.parity,
# so a parity scene has its own settings domain and never touches the user's profiles, logins or session.
# Prints the path of the copy's executable.
set -euo pipefail
cd "$(dirname "$0")/.."
script/build_and_run.sh --bundle >/dev/null
source_app="dist/Herb's Terminal.app"
copy="dist/parity/Herb's Terminal Parity.app"
rm -rf "$copy"
mkdir -p dist/parity
cp -R "$source_app" "$copy"
plist="$copy/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.herbsterminal.parity "$plist"
plutil -replace CFBundleName -string "Herb's Terminal Parity" "$plist"
codesign --force --deep --sign - "$copy" >/dev/null 2>&1
# Never hand out a copy that would run with the user's own settings.
if [[ "$(plutil -extract CFBundleIdentifier raw "$plist")" != org.herbsterminal.parity ]]; then
    echo "parity copy still has the app's own bundle identifier; not using it" >&2
    exit 1
fi
echo "$PWD/$copy/Contents/MacOS/HerbsTerminal"
