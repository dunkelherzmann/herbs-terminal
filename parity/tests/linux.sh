#!/bin/sh
# Runs the feature tests on Linux inside a headless KWin session (nothing appears on the desktop).
#   parity/tests/linux.sh [run.py arguments]   (on the Linux machine, after building the Flatpak build folder)
cd "$(dirname "$0")/../.." || exit 1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
session=$(mktemp)
printf '#!/bin/sh\ncd %s && python3 parity/tests/run.py --platform linux %s > /tmp/herbs-tests.log 2>&1\n' "$PWD" "$*" > "$session"
chmod +x "$session"
kwin_wayland --virtual --no-lockscreen --socket "herbs-tests-$$" --width 1600 --height 1000 --exit-with-session "$session" >/tmp/herbs-tests-kwin.log 2>&1
rm -f "$session"
cat /tmp/herbs-tests.log
