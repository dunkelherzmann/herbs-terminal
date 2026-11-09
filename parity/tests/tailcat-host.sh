#!/usr/bin/env bash
# Tailcat shares on the Linux test machine for the feature tests C3 and C4, only while a test run needs them:
#
#   parity/tests/tailcat-host.sh start   # two shares, their addresses into each test machine's private config
#   parity/tests/tailcat-host.sh stop    # ends them and deletes the addresses everywhere
#
# One share serves the machine's SSH port (C3 connects through it); the other serves only port 9, where nothing
# listens, so a peer is reached but nothing answers SSH (C4). Each run uses fresh ephemeral keys, so an address is
# useless once the run ends. The addresses are secrets: they're written only to ~/.config/herbs-terminal/test-tailcat
# and test-tailcat-nossh (mode 600) on the Mac, the Linux machine and the Windows PC, and never printed.
# Needs PARITY_LINUX_HOST; PARITY_WINDOWS_HOST is optional.
set -uo pipefail
linux="${PARITY_LINUX_HOST:?set PARITY_LINUX_HOST}" windows="${PARITY_WINDOWS_HOST:-}"
names=(test-tailcat test-tailcat-nossh)

forget() {
    for name in "${names[@]}"; do rm -f "$HOME/.config/herbs-terminal/$name"; done
    ssh -o BatchMode=yes "$linux" 'rm -f ~/.config/herbs-terminal/test-tailcat ~/.config/herbs-terminal/test-tailcat-nossh'
    [[ -n "$windows" ]] && ssh -o BatchMode=yes "$windows" \
        'del /q "%USERPROFILE%\.config\herbs-terminal\test-tailcat" "%USERPROFILE%\.config\herbs-terminal\test-tailcat-nossh" 2>nul' >/dev/null
    return 0
}

case "${1:-}" in
start)
    # The pids are saved and killed by number: a pkill pattern would match the ssh command running it.
    addresses=$(ssh -o BatchMode=yes "$linux" '
        T=$HOME/src/herbs-parity-build/files/bin/tailcat
        [ -x "$T" ] || exit 3
        mkdir -p ~/.cache/herbs-tailcat && cd ~/.cache/herbs-tailcat || exit 4
        for pid in $(cat ssh.pid nossh.pid 2>/dev/null); do kill "$pid" 2>/dev/null; done
        rm -f ssh.addr nossh.addr
        TAILCAT_ADDR_FILE=$PWD/ssh.addr nohup "$T" serve --key=new 22 >ssh.log 2>&1 </dev/null & echo $! > ssh.pid
        TAILCAT_ADDR_FILE=$PWD/nossh.addr nohup "$T" serve --key=new 9 >nossh.log 2>&1 </dev/null & echo $! > nossh.pid
        for i in $(seq 1 120); do [ -s ssh.addr ] && [ -s nossh.addr ] && break; sleep 0.5; done
        [ -s ssh.addr ] && [ -s nossh.addr ] || exit 5
        tr -d "\n" < ssh.addr; echo; tr -d "\n" < nossh.addr; echo') || { echo "tailcat shares didn't start on $linux" >&2; exit 1; }
    ssh_address=$(sed -n 1p <<<"$addresses"); nossh_address=$(sed -n 2p <<<"$addresses")
    values=("$ssh_address" "$nossh_address")
    mkdir -p "$HOME/.config/herbs-terminal"
    ssh -o BatchMode=yes "$linux" 'mkdir -p ~/.config/herbs-terminal'
    [[ -n "$windows" ]] && ssh -o BatchMode=yes "$windows" 'mkdir "%USERPROFILE%\.config\herbs-terminal" 2>nul' >/dev/null
    for i in 0 1; do
        file="$HOME/.config/herbs-terminal/${names[$i]}"
        (umask 077; printf '%s\n' "${values[$i]}" > "$file")
        scp -q -p "$file" "$linux:.config/herbs-terminal/${names[$i]}"
        [[ -n "$windows" ]] && scp -q "$file" "$windows:.config/herbs-terminal/${names[$i]}"
    done
    echo "tailcat shares running on $linux for this run"
    ;;
stop)
    ssh -o BatchMode=yes "$linux" 'cd ~/.cache/herbs-tailcat 2>/dev/null && for pid in $(cat ssh.pid nossh.pid 2>/dev/null); do kill "$pid" 2>/dev/null; done; rm -f ssh.pid nossh.pid ssh.addr nossh.addr'
    forget
    ;;
*) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
