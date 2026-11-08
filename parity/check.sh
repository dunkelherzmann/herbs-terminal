#!/usr/bin/env bash
# The parity check: the Mac version is the reference; each port is compared with it scene by scene (controls by
# shared identifier, their labels, hover text, sizes and order, and a looks score), with Craft Anything evidence.
# Usage: parity/check.sh [--skip-linux-build]
# Results: dist/parity/report.html (findings with evidence ids) and dist/parity/out/<platform>/.
# Linux runs on the Linux machine over SSH (PARITY_LINUX_HOST=user@host, optional PARITY_LINUX_KEY=identity file),
# in a headless KWin session, from a copy of this tree in ~/src/herbs-parity there.
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
[[ "${1:-}" == "--skip-linux-build" ]] && skip_build=true

rm -rf "${out:?}" "${project:?}"
mkdir -p "$out/mac" "$out/linux" "$project"

echo "Mac: capturing $scenes"
for scene in $scenes; do parity/mac-scene.sh "$scene" "$out/mac" >/dev/null; done

echo "Linux: sending this tree and building"
sh script/version.sh >/dev/null 2>&1 || true
rsync -az --delete --exclude .build --exclude dist --exclude .git -e "ssh ${key_args[*]}" ./ "$linux_host:$remote_src/"
if ! $skip_build; then
    ssh_linux "cd ~/$remote_src && flatpak run org.flatpak.Builder --user --state-dir=\$HOME/src/herbs-state --force-clean \
        \$HOME/$remote_build linux/org.herbsterminal.app.yml >\$HOME/src/parity-build.log 2>&1" \
        || { echo "Linux build failed; see ~/src/parity-build.log there" >&2; exit 1; }
fi
for scene in $scenes; do
    ssh_linux "cd ~/$remote_src && sh parity/linux-scene.sh $scene /tmp/herbs-parity-out \$HOME/$remote_build" >/dev/null 2>&1 \
        || echo "Linux: scene $scene didn't capture" >&2
done
scp -q "${key_args[@]}" "$linux_host:/tmp/herbs-parity-out/*.png" "$linux_host:/tmp/herbs-parity-out/*-tree.json" "$out/linux/" || true

status=0
for scene in $scenes; do
    if [[ -f "$out/linux/$scene-tree.json" ]]; then
        python3 "$skills/parity-compare.py" parity/parity.json "$scene" "$out/mac/$scene-tree.json" \
            "$out/linux/$scene-tree.json" linux "$out/linux/$scene-diff.json" || status=1
    fi
done
python3 "$skills/parity-claim.py" parity/parity.json "$out" "$project" "$root/dist/parity/report.html" || status=1
exit $status
