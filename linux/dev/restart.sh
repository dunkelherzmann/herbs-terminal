#!/bin/sh
# Rebuilds the development build and restarts it on the Linux machine's desktop. From another computer:
#   ssh <linux-machine> 'cd herbs-terminal && linux/dev/restart.sh'
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
log="${TMPDIR:-/tmp}/herbs-terminal-dev-build.log"
if ! sh "$here/build.sh" >"$log" 2>&1; then
    grep -E "error:" "$log" | sort -u | head -40
    tail -5 "$log"
    exit 1
fi
grep -E "Build complete" "$log" || true
sh "$here/run.sh"
