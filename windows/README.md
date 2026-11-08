# Herb's Terminal for Windows

A native Win32 version of Herb's Terminal, in Swift. The terminal emulator is SwiftTerm's engine (the same one the Mac app uses), shells run in a Windows pseudo console (ConPTY), and the screen is painted with GDI. The login vault is the Mac app's own code, compiled unchanged: small `CryptoKit`, `CommonCrypto`, `SQLite3` and `Darwin` modules give it Apple's names on Windows CNG, the system's `winsqlite3` and the Universal CRT, so a vault made on a Mac or on Linux opens here.

**Status: early.** The window looks like the Mac and Linux versions, and the terminal, Settings and SSH with saved logins work; the file explorer and the rest are still to come (see the roadmap below).

## Running it

The app is self-contained: the `HerbsTerminal-windows` folder holds `HerbsTerminal.exe` and every DLL it needs (the Swift runtime, Foundation and the Microsoft C++ runtime), so nothing has to be installed. Unzip `Herbs-Terminal-<version>-windows-x86_64.zip` (or copy the folder) anywhere and open `HerbsTerminal.exe`. It runs on Windows 10 1809 or later and Windows 11, and uses Windows' own OpenSSH client for SSH.

Build the folder and the zip into `dist\` with:

```powershell
windows\dev\build.ps1 -Package
```

The script checks every DLL the app imports, following each file's own imports, and stops if anything other than a part of Windows would be missing. Windows doesn't trust a downloaded `.exe` that isn't code-signed yet, so the first launch of a downloaded copy may show SmartScreen's "Windows protected your PC": choose **More info ▸ Run anyway**.

## Building

You need:

- the [Swift toolchain for Windows](https://www.swift.org/install/windows/) (6.x), and
- Visual Studio 2022 or its free Build Tools with the **Desktop development with C++** workload (MSVC and a Windows SDK).

Then, from PowerShell in the repository:

```powershell
windows\dev\build.ps1 -Run        # build and start the app
windows\dev\build.ps1 -SelfTest   # build and run the headless checks
windows\dev\build.ps1 -Release    # optimized build
windows\dev\build.ps1 -Package    # self-contained folder and zip in dist\
```

The script finds Visual Studio itself and sets up the MSVC environment, so it works from any PowerShell window. It copies the sources shared with the other versions (listed in `shared.txt`) into `Sources\HerbsTerminal\Shared` before each build; those copies are gitignored, so edit the originals.

A development build is `windows\.build\out\Products\Debug-windows-x86_64\HerbsTerminal.exe` (or `Release-…`). It loads the Swift runtime from the toolchain, so it runs only on a PC with Swift installed; use `-Package` for a copy that runs anywhere.

## What works

- **The window, laid out as on Linux:** the toolbar takes the title bar's place, with the Main Menu, New Tab and Connect via SSH on the left, the tab's title in the middle, Export Session, Take Screenshot, the explorer switch, MultiExec, Tailcat Peers and Search on the right, and minimize, maximize and close at the right end (with Windows 11's snap layouts on maximize). Toolbar buttons never take the keyboard from the terminal, and each shows a hover hint after about half a second. The explorer, MultiExec, Tailcat and Search buttons are there but greyed out until those features arrive
- **Main Menu**, item for item as on Linux: New Tab, New Window, Connect via SSH, Open Tabs, Zoom, Appearance (System / Light / Dark, color presets, iTerm2 import, Restore Defaults), the Shell submenu (Export Session, Take Screenshot, tabs, Disconnect, Clear to Start, Clear Scrollback, Reset, Hard Reset; splits, profiles, MultiExec and Run Command on Hosts greyed out for now), Toggle Full Screen, Settings, Manage Logins, About and Quit. Menus and hints follow dark mode
- **Tab strip**: tabs are numbered "Terminal 1", "Terminal 2"… (the lowest free number), double-click or Ctrl+Shift+I to rename, drag to reorder, middle-click to close, right-click for Rename, Move Left/Right and Close. The title shows what the shell reports; double-click it for the default window size and zoom, right-click to make the current size the default
- **Export Session** (Ctrl+Shift+S): everything in the terminal, scrollback included, to a text file named after the tab and the time
- **Take Screenshot** (Ctrl+Alt+S): a picture of the whole window, toolbar and tabs included, to the clipboard, ready to paste; the button shows a check mark for a moment to confirm it
- Each tab runs PowerShell 7 (`pwsh`) when it's installed, otherwise Windows PowerShell
- Full color (16, 256 and 24-bit), bold, italic, underline, strikethrough, dim, inverse; wide (CJK) characters
- Scrollback with the mouse wheel and Shift+Page Up / Down; full-screen programs scroll with the wheel
- Mouse selection (double-click selects a word), copy and paste as in Windows Terminal: Ctrl+C copies when text is selected, Ctrl+V pastes, right-click copies or pastes; bracketed paste
- Dropping files or folders from File Explorer on a terminal types their paths, as on the Mac and Linux, quoted for the tab's shell: single quotes for PowerShell, double quotes for Command Prompt, `/mnt/c/…` for WSL, and POSIX quoting for Git Bash and SSH tabs
- Block, underline and bar cursors from the profile, blinking or steady
- Light and dark mode follow Windows, title bar included; per-monitor DPI
- Settings (Ctrl+, or the window menu): font and size, cursor shape and blinking, color theme with `.itermcolors` import, light/dark/system appearance, the shell for new tabs (PowerShell 7, Windows PowerShell, Command Prompt, WSL, Git Bash or any command line), scrollback length, new window size, and confirm-before-closing. Changes apply to open terminals at once and are saved in `%LOCALAPPDATA%\HerbsTerminal\settings.json`, the same model as the Linux version
- **SSH:** Connect via SSH (Ctrl+Shift+K, the SSH button beside New Tab, or the window menu) opens the login in a new tab running Windows' own OpenSSH client (`System32\OpenSSH\ssh.exe`). Pick a saved login or type one, and optionally save it. A password reaches ssh only once, through a one-time token traded over a private named pipe (SSH_ASKPASS), never on a command line or in the terminal; host-key questions, one-time codes and retries are asked in the terminal as usual, and keys from `ssh-agent` or `~/.ssh` work without a password. When the host is switched off, restarts or drops off the network, the session ends within about 15 seconds. When a session ends with an error the tab stays open with the reason; Enter reconnects
- **Manage Logins:** the saved logins in a list with New, Edit, Delete, Import and Export (CSV, the same format as the Mac and Linux), and the Administrator Password: create, change or remove it, and unlock once per session
- Login vault (AES-256-GCM, PBKDF2-SHA256) on Windows CNG, verified against the NIST and RFC test vectors; the database is `%LOCALAPPDATA%\HerbsTerminal\logins.sqlite3`

## Shortcuts

| Keys | Action |
|---|---|
| Ctrl+Shift+T | New tab |
| Ctrl+Shift+W | Close tab |
| Ctrl+Shift+N | New window |
| Ctrl+Shift+S | Export Session |
| Ctrl+Alt+S | Take Screenshot |
| Ctrl+Shift+I | Rename tab |
| Ctrl+Shift+Page Up / Down | Move tab left / right |
| Ctrl+Shift+L, Ctrl+Alt+K | Clear to Start, Clear Scrollback |
| Ctrl+Alt+R, Ctrl+Alt+Shift+R | Reset, Hard Reset |
| F11 | Full screen |
| Ctrl+Shift+Q | Quit |
| Ctrl+Tab, Ctrl+Page Down | Next tab |
| Ctrl+Shift+Tab, Ctrl+Page Up | Previous tab |
| Alt+1–8, Alt+9 | Tab 1–8, last tab |
| Ctrl+= / Ctrl+- / Ctrl+0 | Zoom in, out, reset |
| Ctrl+, | Settings |
| Ctrl+Shift+K | Connect via SSH |
| Ctrl+Shift+C, Ctrl+Shift+V | Copy, paste |
| Shift+Page Up / Down, Ctrl+Shift+Home / End | Scroll back |

## Testing without touching the desktop

`--self-test` checks the crypto, the login vault, ssh command lines and the password broker, and prints PASS/FAIL lines (exit code 0 when all pass).

Scripted runs drive the app from the command line instead of simulated keystrokes, so nothing is typed into other windows:

```powershell
HerbsTerminal.exe --type "Get-ChildItem\r" --type "\t" --type "ver\r" --capture shot.bmp
```

Steps run 1.5 s apart. `--type` sends text straight into the active terminal (`\r` is Enter, `\e` Escape); a lone `\t` opens a new tab, `\s` Settings, `\k` Connect via SSH, `\l` Manage Logins, `\m` the Main Menu, `\c<id>` a menu command, and `\f` followed by `value|value|…#button` fills the open dialog and presses that button (`+check` as the last value ticks its checkbox). `--ssh user@host:port` (after `--ssh-password`) opens an SSH tab directly. `--drop "path|path"` drops files on the active terminal the way File Explorer does. `--capture` saves the window, and any open Settings, Manage Logins, dialog or menu beside it, as BMPs and quits. The window opens without taking focus.

## Roadmap

1. Named profiles (Settings edits the default profile today), dark-mode Settings and dialogs, Find in Terminal
2. SSH follow-ups: noticing an `ssh` typed in a local tab, the connection details window, saved hosts and MultiExec targets
3. File explorer: local files, then remote over SFTP, with the transfer queue and the text editor
4. Split panes, MultiExec, session restore, Export Session
5. Mouse reporting for full-screen programs, find in scrollback, IME composition window
6. App icon, an installer (MSIX), and code signing
