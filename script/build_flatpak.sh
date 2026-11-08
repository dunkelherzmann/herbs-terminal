#!/bin/sh
# Builds the Linux version as a Flatpak bundle on a Linux machine, for that machine's architecture:
# dist/Herbs-Terminal-<version>-linux-<arch>.flatpak. With --install it also installs the bundle for this user.
#
# Needs flatpak with the Flathub remote; the first run installs flatpak-builder (org.flatpak.Builder), the GNOME 49
# SDK and the Swift 6 SDK extension from Flathub for this user. flatpak-builder's cache (linux/.flatpak-builder) keeps
# VTE and the downloads, so later builds only rebuild the app.
#
# From another computer, over SSH:
#   ssh <linux-machine> 'cd ~/Projects/herbs-terminal && git pull --ff-only && script/build_flatpak.sh --install'
# Usage: script/build_flatpak.sh [--install]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
install=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        *) echo "usage: script/build_flatpak.sh [--install]" >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "Build the Linux version on a Linux machine." >&2; exit 1; }
command -v flatpak >/dev/null || { echo "flatpak not found; install it with your package manager" >&2; exit 1; }

APP=org.herbsterminal.app
VERSION="$(sh "$ROOT/script/version.sh")"
ARCH="$(flatpak --default-arch)"
STATE="$ROOT/linux/.flatpak-builder"
BUNDLE="$ROOT/dist/Herbs-Terminal-$VERSION-linux-$ARCH.flatpak"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak info --user org.flatpak.Builder >/dev/null 2>&1 || flatpak install --user -y --noninteractive flathub org.flatpak.Builder

# flatpak-builder copies the sources without .git, so the build takes the version from this stamp.
printf '%s\n' "$VERSION" > "$ROOT/linux/version.txt"
mkdir -p "$ROOT/dist"
printf 'Building Herb'\''s Terminal %s for %s\n' "$VERSION" "$ARCH"
# The state and build folders sit in paths the manifest's source copy skips.
flatpak run org.flatpak.Builder --user --install-deps-from=flathub --state-dir="$STATE" --repo="$STATE/repo" \
    --force-clean "$ROOT/linux/build/app" "$ROOT/linux/$APP.yml"
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo "$STATE/repo" "$BUNDLE" "$APP"
printf 'Built dist/%s\n' "$(basename "$BUNDLE")"

if $install; then
    # Never replace the app under a running copy.
    if flatpak ps --columns=application 2>/dev/null | grep -qx "$APP"; then
        echo "Herb's Terminal is running; quit it, then: flatpak install --user --reinstall -y $BUNDLE" >&2
        exit 1
    fi
    flatpak install --user --reinstall -y --noninteractive --bundle "$BUNDLE"
    printf 'Installed %s %s for this user\n' "$APP" "$VERSION"
fi
