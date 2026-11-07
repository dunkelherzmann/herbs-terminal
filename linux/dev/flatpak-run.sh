#!/bin/sh
# Runs the installed Flatpak in the VM, with a session bus and flatpak-session-helper so `flatpak-spawn --host`
# reaches the VM as the host, drawn through Broadway at http://<vm>:8085.
pkill -f gtk4-broadwayd 2>/dev/null; pkill -f herbs-terminal 2>/dev/null; pkill -f flatpak-session-helper 2>/dev/null
rm -f /tmp/xdg/broadway*.socket; mkdir -p /tmp/xdg; sleep 1
export XDG_RUNTIME_DIR=/tmp/xdg SHELL=/bin/bash
flatpak build --share=network --filesystem=/tmp --env=XDG_RUNTIME_DIR=/tmp/xdg /root/fbbuild gtk4-broadwayd --port 8085 --address 0.0.0.0 :5 >/tmp/broadway.log 2>&1 &
sleep 1
exec dbus-run-session sh -c '/usr/libexec/flatpak-session-helper >/tmp/helper.log 2>&1 & sleep 1; \
  flatpak run --env=GDK_BACKEND=broadway --env=BROADWAY_DISPLAY=:5 --env=XDG_RUNTIME_DIR=/tmp/xdg org.herbsterminal.app'
