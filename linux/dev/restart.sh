#!/bin/sh
# On the Mac: rebuilds the development build in the VM and restarts it under Broadway (http://<vm>:8085).
VM=${VM:-herbs-flatpak-aarch64}
container exec "$VM" sh /src/linux/dev/build.sh 2>&1 | grep -E "error:|Build complete" | sort -u | head -40
container exec -d "$VM" sh -c 'sh /src/linux/dev/run.sh > /tmp/app.log 2>&1'
