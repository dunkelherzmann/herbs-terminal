#!/bin/sh
# Builds the development build and runs the Linux checks (its --self-test), on the Linux machine:
#   HERBS_TEST_SSH=user@host:port:password linux/dev/check.sh
# HERBS_TEST_SSH names a throwaway test account for the live SSH and SFTP check; without it that check is skipped.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
sh "$here/build.sh"
. "$here/env.sh"
# The checks start their test processes inside the sandbox, so they treat the sandbox as the host (HERBS_LOCAL_HOST).
set -- HERBS_LOCAL_HOST=1 HERBS_TEST_HELPER="$SCRATCH/debug/HerbsTerminal"
[ -n "${HERBS_TEST_SSH:-}" ] && set -- "$@" HERBS_TEST_SSH="$HERBS_TEST_SSH"
in_sdk env "$@" "$SCRATCH/debug/HerbsTerminal" --self-test
