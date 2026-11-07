#!/bin/sh
# Development build inside the Flatpak SDK (with VTE from the flatpak-builder build directory). Run in the Linux VM:
#   sh /src/linux/dev/build.sh [swift build arguments]
set -eu
BUILD=${BUILD:-/root/fbbuild}
exec flatpak build --filesystem=/src --filesystem=/root --share=network --env=PATH=/app/bin:/usr/bin:/usr/lib/sdk/swift6/bin \
  --env=HOME=/root/home --env=XDG_CACHE_HOME=/root/home/.cache "$BUILD" \
  sh -c "mkdir -p /root/home && cd /src/linux && swift build --scratch-path /root/swiftbuild $*"
