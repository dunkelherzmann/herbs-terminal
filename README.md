# Herb's Terminal

**Herb's Terminal** is a native macOS terminal for administrators. It runs on Apple silicon Macs (macOS 15+) and manages local files and remote Linux, macOS, and Windows machines over SSH.

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

- macOS 15 or later
- Apple silicon (arm64)

Nothing else needs to be installed. The app bundles its own SSH helpers and `tailcat`; it uses the system's `/usr/bin/ssh`, `/bin/sh`, `/usr/libexec/sftp-server`, and `sudo` — never Homebrew or PATH copies.

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

## Built with

Built with **Swift 6**, **SwiftUI + AppKit**, [SwiftTerm 1.20](https://github.com/migueldeicaza/SwiftTerm), and Swift Package Manager.

## Project layout

```
Sources/
  HerbsTerminal/       main app target (SwiftUI + AppKit)
  HerbsTerminalUI/     shared UI components (toolbar, panes)
Tests/
  HerbsTerminalTests/  unit and integration tests
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

## Security notes

- Passwords and Tailcat addresses never appear in command lines, shell history, or logs
- The login database uses AES-256 encryption; if it can't be opened the app falls back to a safe in-memory store
- Administrator mode uploads use unguessable temporary filenames and never write through existing files or preserve setuid/setgid bits
- The SSH socket folder is verified to be a real directory owned by the current user with mode `0700`

## License

Copyright © 2026 Herbert Cisneros. Creative direction and design by Herbert Cisneros; source code developed with AI coding assistance.

This project is dual-licensed:

| Use case | License |
|---|---|
| Personal, open-source, or non-commercial — **provided you publish your modifications under the same terms** | [AGPLv3](LICENSE) — free |
| Commercial use, or any use where you do not want to publish your source | [Commercial license](LICENSE-COMMERCIAL) — contact the author |

The short version: **use it freely and share your improvements, or pay to keep them private.**
