#!/bin/sh
# Runs the development build in the Linux VM, drawn through GTK's Broadway backend at http://<vm>:8085.
BUILD=${BUILD:-/root/fbbuild}
pkill -f gtk4-broadwayd 2>/dev/null; pkill -f swiftbuild/debug/HerbsTerminal 2>/dev/null; pkill -f 'bwrap --args 17' 2>/dev/null; rm -f /tmp/xdg/broadway*.socket; sleep 1
exec flatpak build --filesystem=/src --filesystem=/root --filesystem=/tmp --share=network --env=PATH=/app/bin:/usr/bin \
  --env=HOME=/root/home --env=XDG_RUNTIME_DIR=/tmp/xdg --env=SHELL=/bin/bash --env=HERBS_LOCAL_HOST=1 --env=HERBS_ICON_PATH=/src/linux/data/icons "$BUILD" \
  sh -c "mkdir -p /tmp/xdg /root/home && (gtk4-broadwayd --port 8085 --address 0.0.0.0 :5 >/tmp/broadway.log 2>&1 &) && sleep 1 && GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 dbus-run-session /root/swiftbuild/debug/HerbsTerminal $*"
