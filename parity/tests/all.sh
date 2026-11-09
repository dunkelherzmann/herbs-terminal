#!/usr/bin/env bash
# Builds and runs the feature tests on every platform, then writes the reports. One command instead of the sync,
# build and run steps per machine:
#
#   PARITY_LINUX_HOST=user@host PARITY_LINUX_KEY=~/.ssh/key PARITY_WINDOWS_HOST=ssh-alias \
#   PARITY_WINDOWS_TREE=~/Projects/<windows worktree> parity/tests/all.sh [mac] [linux] [windows] [--only W1,T3] [--no-build]
#       [--package]
#
# --package tests what ships on Windows: the single dist\HerbsTerminal.exe from build.ps1 -Package (not copied to
# the desktop), instead of the development build.
#
# With no platform named it runs all three. Linux runs in a headless KWin session, Windows in the logged-in
# desktop session (through a one-time scheduled task), the Mac in the background without taking focus.
set -uo pipefail
cd "$(dirname "$0")/../.."
platforms=(); only=""; build=true; package=false
while (($#)); do
    case "$1" in
        mac|linux|windows) platforms+=("$1") ;;
        --only) only="$2"; shift ;;
        --no-build) build=false ;;
        --package) package=true ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
((${#platforms[@]})) || platforms=(mac linux windows)
args=(); [[ -n "$only" ]] && args=(--only "$only")
mkdir -p parity/results

run_mac() {
    $build && { macos/parity/copy.sh >/dev/null || { echo "Mac: build failed" >&2; return 1; }; }
    python3 parity/tests/run.py --platform mac ${args[@]+"${args[@]}"} | grep -vE '^(WORKS|UNVERIFIED|N/A) '
}

run_linux() {
    # macOS's bash 3.2 treats an empty array as unset under set -u, so the key is expanded only when given.
    local host="${PARITY_LINUX_HOST:?set PARITY_LINUX_HOST}" key=(); [[ -n "${PARITY_LINUX_KEY:-}" ]] && key=(-i "$PARITY_LINUX_KEY")
    sh scripts/version.sh >/dev/null 2>&1 || true
    rsync -az --delete --exclude .build --exclude dist --exclude .git -e "ssh ${key[*]:-}" ./ "$host:src/herbs-parity/"
    if $build; then
        ssh ${key[@]+"${key[@]}"} -o BatchMode=yes "$host" 'cd ~/src/herbs-parity && flatpak run org.flatpak.Builder --user --state-dir=$HOME/src/herbs-state \
            --force-clean $HOME/src/herbs-parity-build linux/org.herbsterminal.app.yml >$HOME/src/parity-build.log 2>&1' \
            || { echo "Linux: build failed; see ~/src/parity-build.log there" >&2; return 1; }
    fi
    ssh ${key[@]+"${key[@]}"} -o BatchMode=yes "$host" "cd ~/src/herbs-parity && sh linux/parity/tests.sh ${args[*]:-}" | grep -vE '^(WORKS|UNVERIFIED|N/A) '
    scp -q ${key[@]+"${key[@]}"} "$host:src/herbs-parity/parity/results/linux.json" parity/results/linux.json
}

run_windows() {
    local host="${PARITY_WINDOWS_HOST:?set PARITY_WINDOWS_HOST}" tree="${PARITY_WINDOWS_TREE:-.}" home
    home=$(ssh -o BatchMode=yes "$host" 'echo %USERPROFILE%' | tr -d '\r' | tr '\\' '/')
    ssh -o BatchMode=yes "$host" 'powershell -NoProfile -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $env:USERPROFILE\src\herbs-parity\windows\Sources"'
    COPYFILE_DISABLE=1 tar -C "$tree" -cf - --exclude .git --exclude dist --exclude .build VERSION shared linux windows \
        | ssh -o BatchMode=yes "$host" "tar -xf - -C $home/src/herbs-parity"
    COPYFILE_DISABLE=1 tar -cf - --exclude results parity | ssh -o BatchMode=yes "$host" "tar -xf - -C $home/src/herbs-parity"
    # A test copy left over from an interrupted run would lock the program file; only test copies are stopped.
    ssh -o BatchMode=yes "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File $home/src/herbs-parity/windows/parity/tests-stop.ps1"
    if $build; then
        ssh -o BatchMode=yes "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File $home/src/herbs-parity/windows/dev/build.ps1$($package && echo ' -Package -NoDesktop')" \
            >parity/results/windows-build.log 2>&1 || { echo "Windows: build failed; see parity/results/windows-build.log" >&2; return 1; }
    fi
    local exe=""; $package && exe=" -Exe $home/src/herbs-parity/dist/HerbsTerminal.exe"
    ssh -o BatchMode=yes "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File $home/src/herbs-parity/windows/parity/tests.ps1 ${only:+-Only $only}$exe" >/dev/null
    scp -q "$host:$home/src/herbs-parity/parity/results/windows.json" parity/results/windows.json
    scp -q "$host:$home/src/herbs-parity/parity/results/windows.log" parity/results/windows.log
    sed -i '' $'1s/^\xEF\xBB\xBF//' parity/results/windows.log; grep -avE '^(WORKS|UNVERIFIED|N/A) ' parity/results/windows.log
}

# The three machines work at the same time; each prints only what didn't work.
for platform in "${platforms[@]}"; do
    ( echo "== $platform"; "run_$platform" ) > "parity/results/$platform.out" 2>&1 &
done
wait
for platform in "${platforms[@]}"; do cat "parity/results/$platform.out"; done
python3 parity/tests/report.py ${PARITY_WINDOWS_TREE:+--windows-pending "$PARITY_WINDOWS_TREE/windows/pending.md"}
