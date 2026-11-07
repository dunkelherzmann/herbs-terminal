# Herb's Terminal

**Herb's Terminal** is a terminal for administrators. It runs on and manages local files and remote Linux, macOS, and Windows machines over SSH.

Each tab pairs a shell with an SSH-aware file explorer. When the shell connects to another machine, the explorer follows it to the same host and account — shell, files, transfers, text editing, and permissions all in one tab.

## Features

- **SSH-aware file explorer** — in the style of Thunar, with a built-in text editor; follows the shell when you SSH to another host
- **MultiExec** — type into several terminals at once, like MobaXterm
- **Encrypted login vault** — save SSH credentials with AES-256 encryption
- **Administrator mode** — work on files as root over SFTP, with safe upload semantics
- **Tailcat pairing** — reach machines that can't see each other by IP, via the bundled `tailcat` helper
- **Split panes** — horizontal and vertical splits per tab
- **Session restore** — reopen tabs where you left them after a restart
- **iTerm2 color preset import** — `.itermcolors` themes drop straight in
- **SFTP transfer queue** — upload and download with progress, retry and cancel

## Requirements

- **macOS:** macOS 15 or later on Apple silicon (arm64).
- **Linux:** any distribution with Flatpak, on x86_64 or aarch64. The GNOME 49 runtime comes from Flathub.

Nothing else needs to be installed. The app bundles its own SSH helpers and `tailcat`. On a Mac it uses the system's `/usr/bin/ssh`, `/bin/sh`, `/usr/libexec/sftp-server`, and `sudo` — never Homebrew or PATH copies. On Linux, shells, `ssh` and `sudo` run on your computer (outside the Flatpak sandbox), so your login shell, `~/.ssh/config` and SSH agent work as usual.

## Installing

Herb's Terminal isn't notarized by Apple, so there are two ways to run it. Building it yourself is the simplest and the easiest to trust.

### Option 1: build from source (recommended)

You need only Apple's free Command Line Tools:

```bash
xcode-select --install
```

Then clone and build:

```bash
git clone https://github.com/dunkelherzmann/herbs-terminal.git
cd herbs-terminal
script/build_and_run.sh
```

The app is built and opened from `dist/Herb's Terminal.app`; drag it to your Applications folder to keep it. An app built on your own Mac isn't quarantined, so Gatekeeper opens it without any warning.

Other build commands:

```bash
script/build_and_run.sh --bundle   # build the .app without opening it
script/test.sh                     # run the test suite (includes real SFTP transfers)
```

### Option 2: use a prebuilt app

Download the `.zip` from [Releases](https://github.com/dunkelherzmann/herbs-terminal/releases), unzip it, and drag **Herb's Terminal.app** to your Applications folder.

Downloaded apps carry macOS's quarantine flag, and because this one isn't notarized, macOS refuses to open it at first ("Apple could not verify…"). Remove the flag once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Herb's Terminal.app"
```

- `-d com.apple.quarantine` removes only the quarantine flag, and `-r` does it for everything inside the app, including the bundled `tailcat` helper.
- `xattr -cr "/Applications/Herb's Terminal.app"` also works: `-c` clears all extended attributes, the quarantine flag among them.
- `-c` and `-d` can't be combined (`xattr -cdr` stops with "Cannot specify -d with -c"); use one or the other.

Without Terminal: try to open the app once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway** (this needs an administrator password). Since macOS 15, Control-click ▸ Open no longer bypasses the warning.

Only remove the quarantine flag from a copy you downloaded from this repository's Releases page.

## Linux (Flatpak)

The Linux version looks and works like the Mac one. As on Linux and Windows desktops, minimize, maximize and close sit on the right of the toolbar, and the Main Menu takes the left corner. Shortcuts follow Linux terminals: Ctrl+Shift+T new tab, Ctrl+Shift+C / V copy and paste, Alt+1–9 pick a tab, Ctrl+Page Up / Down switch tabs, Ctrl+, Settings (the Main Menu lists them all).

Install a prebuilt bundle from [Releases](https://github.com/dunkelherzmann/herbs-terminal/releases):

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

```bash
flatpak install --user Herbs-Terminal-<version>-linux-x86_64.flatpak
```

```bash
flatpak run org.herbsterminal.app
```

Build it yourself on Linux:

```bash
sh script/version.sh > linux/version.txt
flatpak-builder --user --install --force-clean build linux/org.herbsterminal.app.yml
```

The first line records the version from git; the build itself sees the sources without git history.

Or on a Mac, in a Linux VM (needs `brew install container`): `script/build_flatpak.sh` writes `dist/Herbs-Terminal-<version>-linux-<arch>.flatpak`.

The Flatpak asks for broad access, as terminals do: it runs your shell and `ssh` on the host (`flatpak-spawn`), and the explorer reaches all your folders.

## Built with

Built with **Swift 6** and Swift Package Manager: on macOS with **SwiftUI + AppKit** and [SwiftTerm 1.20](https://github.com/migueldeicaza/SwiftTerm), on Linux with **GTK 4**, **libadwaita**, [VTE](https://gitlab.gnome.org/GNOME/vte) and GtkSourceView. Both share the SSH, SFTP and login-vault code.

## Project layout

```
Sources/
  HerbsTerminal/       main app target (SwiftUI + AppKit)
  HerbsTerminalUI/     shared UI components (toolbar, panes)
Tests/
  HerbsTerminalTests/  unit and integration tests
linux/                 the Linux version: Swift package, Flatpak manifest, desktop file, icons
  Sources/HerbsTerminal/Shared/   links to the macOS sources both versions share
Assets/                app icon source files
Vendor/tailcat/        bundled tailcat binary + license
script/                build, signing, icon generation, and test scripts
dist/                  build output (gitignored)
```

## Dependencies

| Dependency | Version | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.20.0 | MIT |
| [tailcat](https://github.com/tailscale/tailcat) | 0.7.0 (bundled) | BSD-3-Clause |
| [VTE](https://gitlab.gnome.org/GNOME/vte) (Linux) | 0.82.4 (bundled in the Flatpak) | LGPL-3.0 |
| GTK 4, libadwaita, GtkSourceView (Linux) | GNOME 49 runtime | LGPL-2.1+ |

## Security notes

- Passwords and Tailcat addresses never appear in command lines, shell history, or logs
- The login database uses AES-256 encryption; if it can't be opened the app falls back to a safe in-memory store
- Administrator mode uploads use unguessable temporary filenames and never write through existing files or preserve setuid/setgid bits
- The SSH socket folder is verified to be a real directory owned by the current user with mode `0700`

## Versioning

Versions are `major.minor.patch`. [`VERSION`](VERSION) holds the major and minor number, and the patch number is the count of commits since `VERSION` last changed, so it rises with every push to `main`. Editing `VERSION` (to `1.1`, say) starts the next series at `1.1.0`. `script/version.sh` prints the current version, and the builds use it.

## Open source

Herb's Terminal is free and open source under the [MIT License](LICENSE): use it, change it and share it, for personal or commercial work. Just keep the copyright and license notice with any copy. Third-party components keep their own licenses; see [NOTICES](NOTICES).

## Support

Herb's Terminal is a testing app, shared publicly so others can benefit from it. It is provided as is: no support is promised or given.

## Contributing

Bug reports, ideas and pull requests are welcome: open an [issue](https://github.com/dunkelherzmann/herbs-terminal/issues) or a pull request here. Contributions are accepted under the same MIT License.

## Contact

Contact me through my GitHub profile: [dunkelherzmann](https://github.com/dunkelherzmann).

Copyright © 2026 Herbert Cisneros, developed with AI coding assistance.
