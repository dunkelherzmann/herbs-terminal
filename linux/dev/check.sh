#!/bin/sh
# Runs the Linux checks (a debug build's --self-test) inside the Flatpak SDK in the VM:
#   HERBS_TEST_SSH=user@host:port:password sh /src/linux/dev/check.sh
# HERBS_TEST_SSH names a throwaway test account for the live SSH and SFTP check; without it that check is skipped.
set -eu
BUILD=${BUILD:-/root/fbbuild}
exec flatpak build --filesystem=/src --filesystem=/root --filesystem=/tmp --share=network --env=PATH=/app/bin:/usr/bin:/usr/lib/sdk/swift6/bin \
  --env=HOME=/root/home --env=XDG_CACHE_HOME=/root/home/.cache --env=HERBS_LOCAL_HOST=1 \
  --env=HERBS_TEST_SSH="${HERBS_TEST_SSH:-}" --env=HERBS_TEST_HELPER=/root/swiftbuild/debug/HerbsTerminal "$BUILD" \
  sh -c "mkdir -p /root/home && cd /src/linux && swift build --scratch-path /root/swiftbuild && /root/swiftbuild/debug/HerbsTerminal --self-test"
