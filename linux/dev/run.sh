#!/bin/sh
# Starts the development build on the Linux machine's desktop, as the user service herbs-terminal-dev (replacing a
# running one), so it works the same from a terminal there and over SSH. Its output: journalctl --user -u herbs-terminal-dev
# Usage: linux/dev/run.sh [app arguments]
set -eu
self="$(cd "$(dirname "$0")" && pwd)/run.sh"
if [ -z "${HERBS_DEV_UNIT:-}" ]; then
    . "$(dirname "$self")/env.sh"
    [ -x "$SCRATCH/debug/HerbsTerminal" ] || { echo "No development build yet; run linux/dev/build.sh" >&2; exit 1; }
    systemctl --user stop herbs-terminal-dev.service 2>/dev/null || true
    exec systemd-run --user --collect --quiet --unit=herbs-terminal-dev --setenv=HERBS_DEV_UNIT=1 sh "$self" "$@"
fi
. "$(dirname "$self")/env.sh"
in_sdk "$SCRATCH/debug/HerbsTerminal" "$@"
