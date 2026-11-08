#!/bin/sh
# Opens one parity scene of the Linux build in a private, headless KWin session (nothing appears on the desktop),
# saves its UI tree (AT-SPI) and the window's own picture, then closes it. The installed Flatpak is not used.
# Run on the Linux machine: parity/linux-scene.sh <scene> <output folder> <flatpak-builder build folder>
set -eu
scene="$1"; out="$2"; build="$3"
here="$(cd "$(dirname "$0")/.." && pwd)"
dump="$HOME/.agents/library/app-parity/scripts/atspi-dump.py"
mkdir -p "$out"
# Over SSH there is no session bus in the environment; the user's own one carries D-Bus and accessibility.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
rm -f "$out/$scene.png" "$out/$scene.png.ids.json" "$out/$scene-tree.json"
# Every scene starts from nothing: no settings, no saved session, an empty home.
rm -rf /tmp/herbs-parity-app /tmp/herbs-parity
socket="herbs-parity-$$"
settle="${PARITY_SETTLE_SECS:-4}"
# The host's flatpak runs the finished build folder in one sandbox with the app's own permissions (its metadata);
# flatpak-builder --run would nest it inside the Builder's sandbox, where the session bus can't be reached.
app="flatpak build --with-appdir --socket=wayland --share=ipc --device=all --filesystem=host --filesystem=/tmp \
--talk-name=org.freedesktop.Flatpak --talk-name=org.a11y.Bus --filesystem=xdg-run/at-spi --env=HERBS_PARITY=1 --env=PARITY_SETTLE_SECS=$settle $build \
herbs-terminal --parity-scene $scene --parity-capture $out/$scene.png"
kwin_wayland --virtual --no-lockscreen --socket "$socket" --width 1600 --height 1000 --exit-with-session "$app" \
    >"$out/$scene-kwin.log" 2>&1 &
kwin=$!
# The window's picture is written once the scene has settled; read the tree right after.
for _ in $(seq 1 120); do
    [ -s "$out/$scene.png" ] && break
    kill -0 "$kwin" 2>/dev/null || break
    sleep 0.5
done
python3 "$dump" org.herbsterminal.app.Parity "$out/$scene-tree.json" --wait 10 --ids "$out/$scene.png.ids.json" || true
kill "$kwin" 2>/dev/null || true
wait "$kwin" 2>/dev/null || true
[ -s "$out/$scene.png" ] && [ -s "$out/$scene-tree.json" ] || { echo "the scene didn't produce a picture and a tree; see $out/$scene-kwin.log" >&2; exit 1; }
echo "$out/$scene-tree.json"
