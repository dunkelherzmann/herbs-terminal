#!/usr/bin/env bash
# Sets up an Ubuntu 24.04 LTS machine (GNOME) to build, test and develop Herb's Terminal and its sibling projects,
# paired with the Mac it is developed on. Run it as yourself (not root) on the new machine:
#
#   bash setup-ubuntu.sh --mac you@mac-address [--name Linux] [--xorg-default]
#
#   --mac           the Mac's ssh login (user@host). Remote Login must be on there; you're asked for the Mac's
#                   password once, to install this machine's SSH key on it.
#   --name          the name this machine's Claude Code Remote Control session shows (default: the host name).
#   --xorg-default  log in to "Ubuntu on Xorg" by default. The driven GUI tests need X11 for real clicks and window
#                   control; Wayland stays available at the login screen.
#
# What it does, each step safe to run again:
#   1. system packages: git, ssh server, Flatpak, Unison, Python with AT-SPI, a virtual X display, Node.js;
#   2. the GitHub CLI (its official apt repository) and Claude Code (Anthropic's native installer);
#   3. Flathub, the GNOME 49 SDK, the Swift 6 SDK extension and flatpak-builder, as the Flatpak manifest needs;
#   4. agent-desktop (accessibility-tree desktop control for the GUI tests), installed for this user;
#   5. SSH both ways with the Mac: this machine's key goes on the Mac, the Mac's public keys come here;
#   6. your git name and email, read from the Mac, with claude-linux as the committer name;
#   7. sign-ins, once each, in this machine's browser: GitHub CLI and Claude Code. Tokens are never copied from the
#      Mac: they stay in its Keychain, and each machine gets its own revocable sign-in;
#   8. ~/.agents and ~/.claude/CLAUDE.md copied from the Mac, and the projects cloned into ~/Projects;
#   9. Claude Code Remote Control as a user service that starts at boot and restarts itself.
# Afterwards, point the Mac's Unison profile at this machine (the script prints what to change).
set -euo pipefail

mac="" ; name="$(hostname -s)" ; xorg=false
while (($#)); do
    case "$1" in
        --mac) mac="${2:?--mac needs user@host}"; shift ;;
        --name) name="${2:?--name needs a value}"; shift ;;
        --xorg-default) xorg=true ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$mac" ]] || { echo "--mac user@host is required (see --help)" >&2; exit 2; }
[[ $EUID -ne 0 ]] || { echo "run this as yourself, not root: it asks for sudo when it needs it" >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || echo "warning: written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}" >&2

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
export PATH="$HOME/.local/bin:$PATH"
projects=(herbs-terminal ptz-control herbs-skills path-shaper-chronicles)
owner=dunkelherzmann

step "1. System packages"
sudo apt-get update
# Ubuntu 24.04's desktop already offers "Ubuntu on Xorg" at the login screen; Node.js 18 (agent-desktop needs >= 18).
sudo apt-get install -y git curl wget rsync jq openssh-server flatpak unison \
    python3 python3-gi gir1.2-atspi-2.0 at-spi2-core wl-clipboard xvfb xauth dbus-x11 nodejs npm
sudo systemctl enable --now ssh
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then sudo ufw allow OpenSSH; fi

step "2. GitHub CLI and Claude Code"
if ! command -v gh >/dev/null; then
    # From github.com/cli/cli/blob/trunk/docs/install_linux.md
    sudo mkdir -p -m 755 /etc/apt/keyrings
    out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg <"$out" >/dev/null && rm -f "$out"
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update && sudo apt-get install -y gh
fi
# From code.claude.com/docs/en/setup: the native installer puts the launcher at ~/.local/bin/claude.
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

step "3. Flathub, the GNOME 49 SDK, Swift 6 and flatpak-builder"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y --noninteractive flathub \
    org.gnome.Platform//49 org.gnome.Sdk//49 org.freedesktop.Sdk.Extension.swift6//25.08 org.flatpak.Builder

step "4. agent-desktop (for the driven GUI tests)"
npm config set prefix "$HOME/.local"
command -v agent-desktop >/dev/null || npm install -g agent-desktop
agent-desktop --version || true

step "5. SSH with the Mac ($mac)"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -C "$USER@$(hostname -s)" -f ~/.ssh/id_ed25519
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$mac" true 2>/dev/null; then
    echo "Installing this machine's key on the Mac: enter the Mac's password once."
    ssh-copy-id -i ~/.ssh/id_ed25519.pub "$mac"
fi
ssh -o BatchMode=yes "$mac" true || { echo "can't log in to $mac with the key; check Remote Login on the Mac" >&2; exit 1; }
# The Mac's public keys may log in here (the Mac reaches this machine for builds, tests and the skills sync).
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
ssh -o BatchMode=yes "$mac" 'cat ~/.ssh/*.pub 2>/dev/null' | while read -r key; do
    [[ -n "$key" ]] && ! grep -qxF "$key" ~/.ssh/authorized_keys && echo "$key" >>~/.ssh/authorized_keys
done
echo "Mac keys allowed here: $(wc -l <~/.ssh/authorized_keys)"

step "6. Git name and email from the Mac"
git config --global user.name "$(ssh -o BatchMode=yes "$mac" 'git config --global user.name')"
git config --global user.email "$(ssh -o BatchMode=yes "$mac" 'git config --global user.email')"
git config --global init.defaultBranch main
# Commits show which computer made them: "Herbert Cisneros authored and claude-linux committed".
git config --global committer.name claude-linux
echo "git: $(git config --global user.name) <$(git config --global user.email)>"

step "7. Sign-ins (once each, in this machine's browser)"
if ! gh auth status >/dev/null 2>&1; then
    gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git
mkdir -p ~/Projects
if [[ ! -f ~/.claude/.credentials.json ]]; then
    cat <<'EOF'
Claude Code opens next, in ~/Projects. Sign in with the browser prompt, trust the folder when it asks
(Remote Control works there), then type /exit to continue this script.
EOF
    read -r -p "Press Enter to start Claude Code… " _
    (cd ~/Projects && claude) || true
fi

step "8. Skills, CLAUDE.md and projects"
mkdir -p ~/.agents ~/.claude
rsync -a --exclude skills/ --exclude library/skill-library/INDEX.md --exclude skills.json --exclude .DS_Store \
    "$mac:.agents/" ~/.agents/
rsync -a "$mac:.claude/CLAUDE.md" ~/.claude/CLAUDE.md
[[ -f ~/.agents/sync-skills.sh ]] && sh ~/.agents/sync-skills.sh || true
for project in "${projects[@]}"; do
    [[ -d ~/Projects/$project/.git ]] || gh repo clone "$owner/$project" ~/Projects/"$project"
done

step "9. Claude Code Remote Control (\"$name\") as a user service"
mkdir -p ~/.config/systemd/user
cat >~/.config/systemd/user/claude-remote-control.service <<EOF
[Unit]
Description=Claude Code Remote Control ("$name") for the Mac session
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=%h/Projects
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin
Environment=TERM=xterm-256color
ExecStart=%h/.local/bin/claude remote-control --name $name --permission-mode bypassPermissions
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now claude-remote-control.service
systemctl --user --no-pager status claude-remote-control.service | sed -n '1,4p' || true

if $xorg; then
    step "Default session: Ubuntu on Xorg"
    sudo mkdir -p /var/lib/AccountsService/users
    file="/var/lib/AccountsService/users/$USER"
    if sudo grep -q '^Session=' "$file" 2>/dev/null; then sudo sed -i 's/^Session=.*/Session=ubuntu-xorg/' "$file"
    else printf '[User]\nSession=ubuntu-xorg\n' | sudo tee -a "$file" >/dev/null; fi
    echo "Next login uses Ubuntu on Xorg (the gear on the login screen switches back to Wayland)."
fi

step "Done"
cat <<EOF
This machine: $USER@$(hostname -I | awk '{print $1}')   Remote Control: "$name"
Left for the Mac side (ask Claude on the Mac, or do it by hand):
  - in ~/.unison/<profile>.prf, set the second root to ssh://$USER@<this address>//home/$USER
    and servercmd = /usr/bin/unison, so ~/.agents and CLAUDE.md keep syncing both ways;
  - point the parity and feature tests at this machine (PARITY_LINUX_HOST=$USER@<this address>).
Then build once here to fill the Flatpak cache:  cd ~/Projects/herbs-terminal && flatpak run org.flatpak.Builder \\
  --user --force-clean ~/src/herbs-build linux/org.herbsterminal.app.yml
EOF
