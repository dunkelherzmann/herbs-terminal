#!/bin/sh
# Rebuilds the Flatpak in the VM (cached modules are reused), and installs it there for testing.
set -eu
cd /root
flatpak-builder --disable-rofiles-fuse --state-dir=/root/fbstate --repo=/root/repo --force-clean /root/fbfull /src/linux/org.herbsterminal.app.yml > /root/full.log 2>&1 || { tail -30 /root/full.log; exit 1; }
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo /root/repo /root/herbs.flatpak org.herbsterminal.app
flatpak install -y --noninteractive --reinstall --bundle /root/herbs.flatpak >/dev/null 2>&1
echo installed
