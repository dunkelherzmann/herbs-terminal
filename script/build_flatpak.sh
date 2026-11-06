#!/bin/sh
# Builds the Linux version as a Flatpak bundle on macOS, in a Linux VM run by Apple's `container` tool
# (brew install container): dist/Herbs-Terminal-<version>-linux-<arch>.flatpak, for aarch64 or x86_64 (default: both).
# On Linux, build it directly instead: flatpak-builder --user --install --force-clean build linux/org.herbsterminal.app.yml
#
# The VM keeps the GNOME runtime, the Swift SDK extension and flatpak-builder's cache in the volume
# herbs-flatpak-<arch>, so only the first build downloads them.
# Usage: script/build_flatpak.sh [aarch64|x86_64]...
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sh "$ROOT/script/version.sh")"
ARCHES="${*:-aarch64 x86_64}"
command -v container >/dev/null || { echo "container not found; brew install container" >&2; exit 1; }
container system status >/dev/null 2>&1 || container system start --enable-kernel-install
mkdir -p "$ROOT/dist"

for arch in $ARCHES; do
    case "$arch" in
        aarch64) platform=arm64 ;;
        x86_64) platform=amd64 ;;
        *) echo "unknown architecture $arch" >&2; exit 1 ;;
    esac
    name="herbs-flatpak-$arch"
    container volume inspect "$name" >/dev/null 2>&1 || container volume create "$name" >/dev/null
    if ! container inspect "$name" >/dev/null 2>&1; then
        # flatpak-builder sandboxes each build step with bubblewrap, which needs these capabilities in the VM.
        container run -d --name "$name" --arch "$platform" --cpus 8 --memory 12G --cap-add ALL \
            -v "$name:/var/lib/flatpak" -v "$ROOT:/src" fedora:41 sleep infinity >/dev/null
    fi
    container start "$name" >/dev/null 2>&1 || true
    printf 'Building Herb'\''s Terminal %s for %s\n' "$VERSION" "$arch"
    container exec "$name" sh -c '
        set -eu
        # bubblewrap mounts a fresh /proc, which the VM refuses while parts of its own /proc are masked.
        for m in /proc/keys /proc/timer_list /proc/bus /proc/fs /proc/irq /proc/sys; do umount "$m" 2>/dev/null || true; done
        command -v flatpak-builder >/dev/null || dnf -y -q install flatpak flatpak-builder git >/dev/null
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        flatpak install -y --noninteractive flathub org.gnome.Sdk//49 org.gnome.Platform//49 org.freedesktop.Sdk.Extension.swift6//25.08 >/dev/null
        flatpak-builder --disable-rofiles-fuse --state-dir=/var/lib/flatpak/builder-state --repo=/var/lib/flatpak/herbs-repo \
            --force-clean /root/build /src/linux/org.herbsterminal.app.yml
        flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo /var/lib/flatpak/herbs-repo \
            "/src/dist/Herbs-Terminal-'"$VERSION"'-linux-'"$arch"'.flatpak" org.herbsterminal.app
    '
    printf 'Built dist/Herbs-Terminal-%s-linux-%s.flatpak\n' "$VERSION" "$arch"
done
