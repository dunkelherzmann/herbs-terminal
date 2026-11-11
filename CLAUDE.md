# Working in Herb's Terminal

A native terminal for macOS, Linux and Windows. `SPECIFICATION.md` describes how it works now;
`enhancements.md` and `bugs.md` record what was asked for; each platform keeps its own `pending.md`.

## Layout and commands

| Version | Where | Stack | Build and test (on that system) |
|---|---|---|---|
| macOS (the reference) | `macos/` | Swift 6, SwiftUI + AppKit, SwiftTerm, SPM; macOS 15+, Apple silicon | `macos/dev/build_and_run.sh [--bundle]`, `macos/dev/test.sh` |
| Linux | `linux/` | Swift + GTK 4/libadwaita/VTE, Flatpak `org.herbsterminal.app` | `linux/dev/build_flatpak.sh --install`; development builds `linux/dev/build.sh`, `run.sh`, `restart.sh`; checks `linux/dev/check.sh` |
| Windows | `windows/` | Win32 + SwiftTerm + ConPTY | `windows\dev\build.ps1` |

`shared/` holds the SSH, SFTP and vault sources; the Linux and Windows builds copy them in before each build.
The shared GUI tests are in `parity/tests` (`all.sh`): they drive each app through its test bridge
(`parity/tests/BRIDGE.md`), never synthetic keys or the clipboard.

## Decisions already made

- App icon: `> HT_`, centered, cursor in the text color.
- Export checkboxes sit in their own first column.
- The text editor opens as a tab. Manage Logins is a button that opens a window.
- Zoom ▸ "Default". One Appearance menu, with Color scheme above Color preset.
- Tab numbers reuse the lowest free number.
- `exit` in an SSH tab returns to the local shell.
- A remote copy pasted in the file manager makes real files.

## Traps

- **Never wait on a process on the main thread in `shared/`:** `Process.waitUntilExit` spins Foundation's run
  loop, not GTK's or Win32's, and can hang the window for good.
- **Mac test hooks:** the in-process accessibility tree leaves out SwiftUI-native controls, and outside
  accessibility clients can't see windows on another Space, so SwiftUI controls are driven through a registry
  modifier that holds their bindings (see `BRIDGE.md`).
- **Linux:** `flatpak build` passes neither the caller's environment nor `/dev/tty` into the sandbox
  (`flatpak run` passes both), and a scene shell's `HOME` hides the user's runtimes: helpers run from a build
  need `--env=` and `FLATPAK_USER_DIR`.
