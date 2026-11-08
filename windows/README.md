# Herb's Terminal for Windows

A native Win32 version of Herb's Terminal, in Swift. The terminal emulator is SwiftTerm's engine (the same one the Mac app uses), shells run in a Windows pseudo console (ConPTY), and the screen is painted with GDI. The login vault is the Mac app's own code, compiled unchanged: small `CryptoKit`, `CommonCrypto`, `SQLite3` and `Darwin` modules give it Apple's names on Windows CNG, the system's `winsqlite3` and the Universal CRT, so a vault made on a Mac or on Linux opens here.

**Status: early.** The terminal works; the file explorer, SSH and the rest are still to come (see the roadmap below).

## Building

You need:

- the [Swift toolchain for Windows](https://www.swift.org/install/windows/) (6.x), and
- Visual Studio 2022 or its free Build Tools with the **Desktop development with C++** workload (MSVC and a Windows SDK).

Then, from PowerShell in the repository:

```powershell
windows\dev\build.ps1 -Run        # build and start the app
windows\dev\build.ps1 -SelfTest   # build and run the headless checks
windows\dev\build.ps1 -Release    # optimized build
```

The script finds Visual Studio itself and sets up the MSVC environment, so it works from any PowerShell window. It copies the sources shared with the other versions (listed in `shared.txt`) into `Sources\HerbsTerminal\Shared` before each build; those copies are gitignored, so edit the originals.

The app is `windows\.build\out\Products\Debug-windows-x86_64\HerbsTerminal.exe` (or `Release-…`).

## What works

- Tabs, each running PowerShell 7 (`pwsh`) when it's installed, otherwise Windows PowerShell
- Full color (16, 256 and 24-bit), bold, italic, underline, strikethrough, dim, inverse; wide (CJK) characters
- Scrollback with the mouse wheel and Shift+Page Up / Down; full-screen programs scroll with the wheel
- Mouse selection (double-click selects a word), copy and paste as in Windows Terminal: Ctrl+C copies when text is selected, Ctrl+V pastes, right-click copies or pastes; bracketed paste
- Block, underline and bar cursors from the profile, blinking or steady
- Light and dark mode follow Windows, title bar included; per-monitor DPI
- Profiles, themes and window size from the same `settings.json` model as the Linux version
- Login vault (AES-256-GCM, PBKDF2-SHA256) on Windows CNG, verified against the NIST and RFC test vectors

## Shortcuts

| Keys | Action |
|---|---|
| Ctrl+Shift+T | New tab |
| Ctrl+Shift+W | Close tab |
| Ctrl+Shift+N | New window |
| Ctrl+Tab, Ctrl+Page Down | Next tab |
| Ctrl+Shift+Tab, Ctrl+Page Up | Previous tab |
| Alt+1–8, Alt+9 | Tab 1–8, last tab |
| Ctrl+= / Ctrl+- / Ctrl+0 | Zoom in, out, reset |
| Ctrl+Shift+C, Ctrl+Shift+V | Copy, paste |
| Shift+Page Up / Down, Ctrl+Shift+Home / End | Scroll back |

## Testing without touching the desktop

`--self-test` checks the crypto and the login vault and prints PASS/FAIL lines (exit code 0 when all pass).

Scripted runs drive the app from the command line instead of simulated keystrokes, so nothing is typed into other windows:

```powershell
HerbsTerminal.exe --type "Get-ChildItem\r" --type "\t" --type "ver\r" --capture shot.bmp
```

Each `--type` goes straight into the active terminal 1.5 s apart (`\r` is Enter, `\e` Escape, a lone `\t` opens a new tab); `--capture` saves the window as a BMP and quits. The window opens without taking focus.

## Roadmap

1. Settings window (fonts, themes, cursor, window size, shell choice) and the Main Menu
2. SSH: Connect via SSH, Manage Logins with the vault, saved hosts (Windows OpenSSH has no `ControlMaster`, so the explorer opens its own SFTP session)
3. File explorer: local files, then remote over SFTP, with the transfer queue and the text editor
4. Split panes, MultiExec, session restore, Export Session
5. Mouse reporting for full-screen programs, find in scrollback, IME composition window
6. App icon, an installer (MSIX or a zip), and code signing
