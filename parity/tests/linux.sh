#!/bin/sh
# Runs the feature tests on Linux in their own KWin session, so the app's clipboard and windows are its own.
#   parity/tests/linux.sh [run.py arguments]   (on the Linux machine, after building the Flatpak build folder)
# While a GNOME session is logged in, the session is shown in a window on the test workspace (Workspace 2,
# HERBS_TEST_WORKSPACE counts from 1), in the foreground there and never on the workspace in use; switch to it to
# watch. Without one it runs headless.
cd "$(dirname "$0")/../.." || exit 1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
session=$(mktemp)
printf '#!/bin/sh\ncd %s && python3 parity/tests/run.py --platform linux %s > /tmp/herbs-tests.log 2>&1\n' "$PWD" "$*" > "$session"
chmod +x "$session"
display=""
host_display=":0" host_auth="$XDG_RUNTIME_DIR/gdm/Xauthority"
if command -v Xephyr >/dev/null && command -v wmctrl >/dev/null && [ -r "$host_auth" ] &&
   DISPLAY=$host_display XAUTHORITY=$host_auth xprop -root _NET_CLIENT_LIST >/dev/null 2>&1; then
    # A nested X server window: GNOME manages it like any window (KWin's own X11 window it leaves unmanaged).
    before=$(DISPLAY=$host_display XAUTHORITY=$host_auth xprop -root _NET_CLIENT_LIST)
    DISPLAY=$host_display XAUTHORITY=$host_auth Xephyr :57 -screen 1600x1000 -title "Herb's Terminal tests" -no-host-grab \
        -nolisten tcp >/tmp/herbs-tests-xephyr.log 2>&1 &
    xephyr=$!
    # Moved to the test workspace the moment GNOME takes it, before it is drawn on the workspace in use.
    for _ in $(seq 1 250); do
        window=$(DISPLAY=$host_display XAUTHORITY=$host_auth xprop -root _NET_CLIENT_LIST | tr -d , | tr ' ' '\n' | grep '^0x' |
                 while read -r id; do echo "$before" | grep -q "$id" || echo "$id"; done | head -1)
        [ -n "$window" ] && break
        sleep 0.02
    done
    if [ -n "$window" ]; then
        DISPLAY=$host_display XAUTHORITY=$host_auth wmctrl -i -r "$window" -t $(( ${HERBS_TEST_WORKSPACE:-2} - 1 ))
        display=":57"
    else
        kill "$xephyr" 2>/dev/null
    fi
fi
if [ -n "$display" ]; then
    DISPLAY=$display kwin_wayland --x11-display "$display" --no-lockscreen --socket "herbs-tests-$$" --width 1600 --height 1000 \
        --exit-with-session "$session" >/tmp/herbs-tests-kwin.log 2>&1
    kill "$xephyr" 2>/dev/null
else
    kwin_wayland --virtual --no-lockscreen --socket "herbs-tests-$$" --width 1600 --height 1000 --exit-with-session "$session" >/tmp/herbs-tests-kwin.log 2>&1
fi
rm -f "$session"
cat /tmp/herbs-tests.log
