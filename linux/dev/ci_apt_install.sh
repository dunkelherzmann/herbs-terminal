#!/bin/sh
# Installs packages on a CI runner: `linux/dev/ci_apt_install.sh flatpak`.
#
# Ubuntu's own package servers sometimes can't be reached from a runner (their names stopped resolving for hours
# on 2026-11-11, failing every Linux job before it built anything). When they can't, apt is pointed at an
# independent mirror for this run. Packages are still checked against Ubuntu's signing keys, whichever server
# sends them.
set -eu

APT_ROOT="${APT_ROOT:-/etc/apt}"          # tests point this at a copy
SUDO="${SUDO-sudo}"
OPTIONS="-o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20"

ubuntu_hosts() {
    cat "$APT_ROOT"/apt-mirrors.txt "$APT_ROOT"/sources.list "$APT_ROOT"/sources.list.d/*.sources \
        "$APT_ROOT"/sources.list.d/*.list 2>/dev/null |
        grep -oE 'https?://[A-Za-z0-9.-]*ubuntu\.com' | sed -E 's#https?://##' | sort -u
}

reachable() {
    for host in $(ubuntu_hosts); do
        getent hosts "$host" >/dev/null 2>&1 || { echo "can't resolve $host"; return 1; }
    done
}

use_mirror() {
    case "$(dpkg --print-architecture)" in
        amd64|i386) mirror="https://mirrors.edge.kernel.org/ubuntu/" ;;
        *)          mirror="https://ftp.tu-chemnitz.de/pub/linux/ubuntu-ports/" ;;
    esac
    echo "::warning::Ubuntu's package servers can't be reached; using $mirror for this run"
    if [ -f "$APT_ROOT/apt-mirrors.txt" ]; then
        echo "$mirror" | $SUDO tee "$APT_ROOT/apt-mirrors.txt" >/dev/null
    fi
    for file in "$APT_ROOT"/sources.list "$APT_ROOT"/sources.list.d/*.sources "$APT_ROOT"/sources.list.d/*.list; do
        [ -f "$file" ] || continue
        $SUDO sed -i -E "s#https?://[A-Za-z0-9.-]*ubuntu\.com/ubuntu(-ports)?/?#$mirror#g" "$file"
    done
}

install() {
    # shellcheck disable=SC2086
    $SUDO apt-get update -q $OPTIONS && $SUDO apt-get install -yq $OPTIONS "$@"
}

if [ "${1:-}" = "--use-mirror" ]; then   # for tests: only rewrite the sources
    use_mirror
    exit 0
fi

if reachable && install "$@"; then
    exit 0
fi
use_mirror
install "$@"
