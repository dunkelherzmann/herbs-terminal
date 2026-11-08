#!/bin/sh
# Builds the Linux version as a Flatpak bundle on a Linux machine, for that machine's architecture:
# dist/Herbs-Terminal-<version>-linux-<arch>.flatpak. With --install it also installs the bundle for this user.
#
# Needs flatpak with the Flathub remote; the first run installs flatpak-builder (org.flatpak.Builder), the GNOME 49
# SDK and the Swift 6 SDK extension from Flathub for this user. flatpak-builder's cache (linux/.flatpak-builder) keeps
# VTE and the downloads, so later builds only rebuild the app.
#
# From another computer, over SSH:
#   ssh <linux-machine> 'cd herbs-terminal && git pull --ff-only && script/build_flatpak.sh --install'
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
# Downloads go into flatpak-builder's cache (downloads/<sha256>/<file>) first, so a source whose server is
# briefly down doesn't stop the build: curl retries, and a GitHub release asset is fetched through GitHub's API
# with gh, which keeps working when github.com's download links return errors. Every file is checked against
# the manifest's checksum; flatpak-builder then finds it in the cache.
prefetch() {
    url="$1" sum="$2"
    dir="$STATE/downloads/$sum" file="$STATE/downloads/$sum/$(basename "$url")"
    [ -s "$file" ] && return 0
    mkdir -p "$dir"
    if ! curl -fsSL --retry 4 --retry-all-errors --retry-delay 3 -o "$file.part" "$url"; then
        rm -f "$file.part"
        case "$url" in
            https://github.com/*/releases/download/*)
                repo="$(printf '%s' "$url" | cut -d/ -f4-5)" tag="$(printf '%s' "$url" | cut -d/ -f8)"
                command -v gh >/dev/null && gh release download "$tag" -R "$repo" -p "$(basename "$url")" -O "$file.part" --clobber || true ;;
        esac
    fi
    if [ -s "$file.part" ] && [ "$(sha256sum "$file.part" | cut -d' ' -f1)" = "$sum" ]; then
        mv "$file.part" "$file"
    else
        rm -f "$file.part"
        printf 'Couldn'\''t fetch %s now; flatpak-builder will try it itself.\n' "$url" >&2
    fi
}
awk '/^ *url: /{url=$2} /^ *sha256: /{if (url != "") print url, $2; url=""}' "$ROOT/linux/$APP.yml" |
    while read -r url sum; do prefetch "$url" "$sum"; done

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
