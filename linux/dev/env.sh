# Shared by the development scripts in linux/dev (sourced, not run). They run on the Linux machine itself.
# The development build compiles with the Swift 6 SDK extension inside a Flatpak SDK folder (linux/build/sdk) that
# flatpak-builder fills with every module of the manifest except the app (VTE, tailcat); the first run makes it.
[ "$(uname -s)" = Linux ] || { echo "Run the development scripts on a Linux machine." >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="$ROOT/linux/build/sdk"
SCRATCH="$ROOT/linux/.build/flatpak"
# Development runs keep their settings, saved session and caches here, apart from the installed app's.
DEVHOME="$ROOT/linux/.build/dev-home"
# Over SSH there is no session bus in the environment; the user's own one lets the app reach the host (flatpak-spawn).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

prepare_sdk() {
    [ -d "$SDK/files" ] && return
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak info --user org.flatpak.Builder >/dev/null 2>&1 || flatpak install --user -y --noninteractive flathub org.flatpak.Builder
    flatpak run org.flatpak.Builder --user --install-deps-from=flathub --state-dir="$ROOT/linux/.flatpak-builder" \
        --stop-at=herbs-terminal --force-clean "$SDK" "$ROOT/linux/org.herbsterminal.app.yml"
}

# Runs a command in the SDK folder with the app's own permissions (as in linux/org.herbsterminal.app.yml).
in_sdk() {
    mkdir -p "$DEVHOME"
    flatpak build --share=network --share=ipc --socket=wayland --socket=fallback-x11 --device=all \
        --talk-name=org.freedesktop.Flatpak --filesystem=host --filesystem=/tmp \
        --env=PATH=/app/bin:/usr/bin:/usr/lib/sdk/swift6/bin --env=XDG_CONFIG_HOME="$DEVHOME/config" \
        --env=XDG_DATA_HOME="$DEVHOME/data" --env=XDG_CACHE_HOME="$DEVHOME/cache" --env=XDG_STATE_HOME="$DEVHOME/state" \
        --env=HERBS_ICON_PATH="$ROOT/linux/data/icons" "$SDK" "$@"
}
