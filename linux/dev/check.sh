#!/bin/sh
# Builds the development build and runs the Linux checks (its --self-test), on the Linux machine:
#   HERBS_TEST_SSH=user@host:port:password linux/dev/check.sh
# HERBS_TEST_SSH names a throwaway test account for the live SSH and SFTP check; without it that check is skipped.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
sh "$here/build.sh"
. "$here/env.sh"
in_sdk --env=HERBS_TEST_SSH="${HERBS_TEST_SSH:-}" --env=HERBS_TEST_HELPER="$SCRATCH/debug/HerbsTerminal" \
    "$SCRATCH/debug/HerbsTerminal" --self-test
