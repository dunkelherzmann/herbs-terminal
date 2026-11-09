#!/usr/bin/env bash
# The parity check: the Mac version is the reference; each port is compared with it scene by scene (controls by
# shared identifier, their labels, hover text, sizes and order, and a looks score), with Craft Anything evidence.
# Usage: parity/check.sh [--skip-linux-build] [--skip-windows-build]
# Results: dist/parity/report.html (findings with evidence ids) and dist/parity/out/<platform>/.
# Linux runs on the Linux machine over SSH (PARITY_LINUX_HOST=user@host, optional PARITY_LINUX_KEY=identity file),
# in a headless KWin session, from a copy of this tree in ~/src/herbs-parity there.
# Windows runs when PARITY_WINDOWS_HOST names an SSH host (an alias from ~/.ssh/config is easiest): a copy of this
# tree goes to %USERPROFILE%\src\herbs-parity there, is built with windows\dev\build.ps1, and each scene opens briefly
# on that PC's desktop (UI Automation needs the logged-in session; nothing else on the desktop is touched).
# Until the Windows version reaches main, PARITY_WINDOWS_TREE names a checkout of its branch (one with windows/);
# by default it's this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
skills="$HOME/.agents/library/app-parity/scripts"
out="$root/dist/parity/out"
project="$root/dist/parity/parity.cany"
linux_host="${PARITY_LINUX_HOST:?set PARITY_LINUX_HOST to user@host of the Linux machine}"
key_args=()
[[ -n "${PARITY_LINUX_KEY:-}" ]] && key_args=(-i "$PARITY_LINUX_KEY")
remote_src="src/herbs-parity"
remote_build="src/herbs-parity-build"
ssh_linux() { ssh "${key_args[@]}" -o BatchMode=yes "$linux_host" "$@"; }
scenes=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["scenes"]))' parity/parity.json)
skip_build=false
skip_windows_build=false
for argument in "$@"; do
    case "$argument" in
        --skip-linux-build) skip_build=true ;;
        --skip-windows-build) skip_windows_build=true ;;
    esac
done
windows_host="${PARITY_WINDOWS_HOST:-}"
windows_tree="${PARITY_WINDOWS_TREE:-$root}"

rm -rf "${out:?}" "${project:?}"
mkdir -p "$out/mac" "$out/linux" "$project"
[[ -n "$windows_host" ]] && mkdir -p "$out/windows"

echo "Mac: capturing $scenes"
for scene in $scenes; do macos/parity/scene.sh "$scene" "$out/mac" >/dev/null; done

echo "Linux: sending this tree and building"
sh scripts/version.sh >/dev/null 2>&1 || true
rsync -az --delete --exclude .build --exclude dist --exclude .git -e "ssh ${key_args[*]}" ./ "$linux_host:$remote_src/"
if ! $skip_build; then
    ssh_linux "cd ~/$remote_src && flatpak run org.flatpak.Builder --user --state-dir=\$HOME/src/herbs-state --force-clean \
        \$HOME/$remote_build linux/org.herbsterminal.app.yml >\$HOME/src/parity-build.log 2>&1" \
        || { echo "Linux build failed; see ~/src/parity-build.log there" >&2; exit 1; }
fi
for scene in $scenes; do
    ssh_linux "cd ~/$remote_src && sh linux/parity/scene.sh $scene /tmp/herbs-parity-out \$HOME/$remote_build" >/dev/null 2>&1 \
        || echo "Linux: scene $scene didn't capture" >&2
done
scp -q "${key_args[@]}" "$linux_host:/tmp/herbs-parity-out/*.png" "$linux_host:/tmp/herbs-parity-out/*-tree.json" "$out/linux/" || true

if [[ -n "$windows_host" ]]; then
    if [[ ! -d "$windows_tree/windows" ]]; then
        echo "Windows: $windows_tree has no windows/ folder (set PARITY_WINDOWS_TREE); skipped" >&2
    else
        echo "Windows: sending this tree and building"
        ssh -o BatchMode=yes "$windows_host" 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force $env:USERPROFILE\src\herbs-parity\parity-tools, $env:USERPROFILE\src\herbs-parity-out | Out-Null; Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $env:USERPROFILE\src\herbs-parity\windows\Sources"'
        remote_home=$(ssh -o BatchMode=yes "$windows_host" 'echo %USERPROFILE%' | tr -d '\r' | tr '\\' '/')
        COPYFILE_DISABLE=1 tar -C "$windows_tree" -cf - --exclude .git --exclude dist --exclude .build VERSION shared linux windows \
            | ssh -o BatchMode=yes "$windows_host" "tar -xf - -C $remote_home/src/herbs-parity"
        COPYFILE_DISABLE=1 tar -cf - parity | ssh -o BatchMode=yes "$windows_host" "tar -xf - -C $remote_home/src/herbs-parity"
        scp -q "$skills/uia-dump.ps1" "$windows_host:$remote_home/src/herbs-parity/parity-tools/uia-dump.ps1"
        if ! $skip_windows_build; then
            ssh -o BatchMode=yes "$windows_host" "powershell -NoProfile -ExecutionPolicy Bypass -File $remote_home/src/herbs-parity/windows/dev/build.ps1" \
                >"$out/windows/build.log" 2>&1 || { echo "Windows build failed; see $out/windows/build.log" >&2; exit 1; }
        fi
        exe="$remote_home/src/herbs-parity/windows/.build/out/Products/Debug-windows-x86_64/HerbsTerminal.exe"
        for scene in $scenes; do
            ssh -o BatchMode=yes "$windows_host" "powershell -NoProfile -ExecutionPolicy Bypass -File $remote_home/src/herbs-parity/windows/parity/scene.ps1 \
                -Scene $scene -Out $remote_home/src/herbs-parity-out -Exe $exe -Dump $remote_home/src/herbs-parity/parity-tools/uia-dump.ps1" \
                >"$out/windows/$scene-scene.log" 2>&1 || echo "Windows: scene $scene didn't capture; see $out/windows/$scene-scene.log" >&2
            scp -q "$windows_host:$remote_home/src/herbs-parity-out/$scene.png" "$windows_host:$remote_home/src/herbs-parity-out/$scene-tree.json" \
                "$out/windows/" || true
            # PowerShell writes UTF-8 with a byte-order mark; the comparer reads plain JSON.
            [[ -f "$out/windows/$scene-tree.json" ]] && python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p,encoding="utf-8-sig")); json.dump(d,open(p,"w"),indent=1)' "$out/windows/$scene-tree.json"
        done
    fi
fi

status=0
for scene in $scenes; do
    for platform in linux windows; do
        if [[ -f "$out/$platform/$scene-tree.json" ]]; then
            python3 "$skills/parity-compare.py" parity/parity.json "$scene" "$out/mac/$scene-tree.json" \
                "$out/$platform/$scene-tree.json" "$platform" "$out/$platform/$scene-diff.json" || status=1
        fi
    done
done
python3 "$skills/parity-claim.py" parity/parity.json "$out" "$project" "$root/dist/parity/report.html" || status=1
exit $status
