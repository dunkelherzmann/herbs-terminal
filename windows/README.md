# Herb's Terminal for Windows

A native Win32 version of Herb's Terminal, in Swift. The terminal emulator is SwiftTerm's engine (the same one the Mac app uses), shells run in a Windows pseudo console (ConPTY), and the screen is painted with GDI. The login vault is the Mac app's own code, compiled unchanged: small `CryptoKit`, `CommonCrypto`, `SQLite3` and `Darwin` modules give it Apple's names on Windows CNG, the system's `winsqlite3` and the Universal CRT, so a vault made on a Mac or on Linux opens here.

**Status:** the window, terminal, SSH, file explorer, saved logins, split panes, MultiExec, Tailcat peers and accessibility work as on the Mac and Linux; what's left is listed in `pending.md`.

## Running it

The app is one portable `HerbsTerminal.exe`: no installer, no runtime, nothing added to the system. Unzip `Herbs-Terminal-<version>-windows-x86_64.zip` (or copy the exe) anywhere and open it. The exe carries the app and every DLL it needs (the Swift runtime, Foundation and the Microsoft C++ runtime); on first run it unpacks them to `%LOCALAPPDATA%\HerbsTerminal\Versions\<version>-<hash>` and runs the app from there, removing the copies of older builds. To remove it, delete the exe and that folder. It runs on Windows 10 1809 or later and Windows 11, and uses Windows' own OpenSSH client for SSH.

Build the exe and the zip into `dist\` with:

```powershell
windows\dev\build.ps1 -Package
```

The script checks every DLL the app imports, following each file's own imports, and stops if anything other than a part of Windows would be missing; then it packs that folder into the launcher (`launcher/`) and copies the result to the desktop as `Herb's Terminal.exe`, replacing the older copy. Windows doesn't trust a downloaded `.exe` that isn't code-signed yet, so the first launch of a downloaded copy may show SmartScreen's "Windows protected your PC": choose **More info ▸ Run anyway**.

## Building

You need:

- the [Swift toolchain for Windows](https://www.swift.org/install/windows/) (6.x), and
- Visual Studio 2022 or its free Build Tools with the **Desktop development with C++** workload (MSVC and a Windows SDK).

Then, from PowerShell in the repository:

```powershell
windows\dev\build.ps1 -Run        # build and start the app
windows\dev\build.ps1 -SelfTest   # build and run the headless checks
windows\dev\build.ps1 -Release    # optimized build
windows\dev\build.ps1 -Package    # dist\HerbsTerminal.exe and the zip, copied to the desktop
```

The script finds Visual Studio itself and sets up the MSVC environment, so it works from any PowerShell window. It copies the sources shared with the other versions (listed in `shared.txt`) into `Sources\HerbsTerminal\Shared` before each build; those copies are gitignored, so edit the originals.

A development build is `windows\.build\out\Products\Debug-windows-x86_64\HerbsTerminal.exe` (or `Release-…`). It loads the Swift runtime from the toolchain, so it runs only on a PC with Swift installed; use `-Package` for a copy that runs anywhere.

## What works

- **The window, laid out as on Linux:** the toolbar takes the title bar's place, with the Main Menu, New Tab and Connect via SSH on the left, the tab's title in the middle, Export Session, Take Screenshot, the explorer switch, MultiExec, Tailcat Peers and Search on the right, and minimize, maximize and close at the right end (with Windows 11's snap layouts on maximize). Toolbar buttons never take the keyboard from the terminal, and each shows a hover hint after about half a second.
- **Main Menu**, item for item as on Linux: New Tab, New Window, Connect via SSH, Open Tabs, Zoom, Appearance (System / Light / Dark, color presets, iTerm2 import, Restore Defaults), the Shell submenu (Export Session, Take Screenshot, tabs, Disconnect, Clear to Start, Clear Scrollback, Reset, Hard Reset, splits, profiles, MultiExec and Run Command on Hosts), Toggle Full Screen, Settings, Manage Logins, About and Quit. Menus and hints follow dark mode
- **Tab strip**: tabs are numbered "Terminal 1", "Terminal 2"… (the lowest free number), double-click or Ctrl+Shift+I to rename, drag to reorder, middle-click to close, right-click for Rename, Move Left/Right and Close. The title shows what the shell reports; double-click it for the default window size and zoom, right-click to make the current size the default
- **Export Session** (Ctrl+Shift+S): everything in the terminal, scrollback included, to a text file named after the tab and the time
- **Take Screenshot** (Ctrl+Alt+S): a picture of the whole window, toolbar and tabs included, to the clipboard, ready to paste; the button shows a check mark for a moment to confirm it
- Each tab runs PowerShell 7 (`pwsh`) when it's installed, otherwise Windows PowerShell
- Full color (16, 256 and 24-bit), bold, italic, underline, strikethrough, dim, inverse; wide (CJK) characters
- Scrollback with the mouse wheel and Shift+Page Up / Down; full-screen programs scroll with the wheel
- **Mouse reporting:** programs that track the mouse (vim, htop, tmux, mc, over SSH or in WSL) get clicks, drags, movement and the wheel; Shift+click and Shift+drag still select, as on the Mac
- **Input methods:** the composition and candidate windows of Chinese, Japanese and Korean input methods sit at the terminal's cursor, in its font
- Mouse selection (double-click selects a word), copy and paste as in Windows Terminal: Ctrl+C copies when text is selected, Ctrl+V pastes, right-click opens the terminal's menu (as on the Mac); bracketed paste
- **File explorer** for this PC's files (the toolbar's folder button or Ctrl+Shift+X): places, location bar, sortable list with Windows' icons, open, Copy / Cut / Paste shared with File Explorer, Recycle Bin, rename, New Folder / New File, hidden files, Find (Ctrl+F filters the folder by name), Properties, and Open in New Terminal Tab. In an SSH tab it shows the host's files over its own SFTP channel (signed in with the tab's saved password or SSH keys): browse, copy and move on the host, delete, rename, New Folder / New File, and upload or download files and folders (menus, drops, or Copy here and Paste there) with a transfer strip showing progress, Cancel and Retry. Text files open in a **text editor** tab, on this PC or on the host: Find (Ctrl+F), Wrap Lines, Save (Ctrl+S) keeping the file's encoding and line endings, and a prompt before unsaved changes are lost. **Get Info** (Alt+Enter) on host items changes permissions, owner and group, optionally for everything inside a folder, and the lock turns on **Administrator mode** there: the explorer works as root through sudo, under a red bar with Leave
- Dropping files or folders from File Explorer on a terminal types their paths, as on the Mac and Linux, quoted for the tab's shell: single quotes for PowerShell, double quotes for Command Prompt, `/mnt/c/…` for WSL, and POSIX quoting for Git Bash and SSH tabs
- Block, underline and bar cursors from the profile, blinking or steady
- Light and dark mode follow Windows, title bar included; per-monitor DPI
- Settings (Ctrl+, or the window menu): font and size, cursor shape and blinking, color theme with `.itermcolors` import, light/dark/system appearance, the shell for new tabs (PowerShell 7, Windows PowerShell, Command Prompt, WSL, Git Bash or any command line), scrollback length, new window size, and confirm-before-closing. Changes apply to open terminals at once and are saved in `%LOCALAPPDATA%\HerbsTerminal\settings.json`, the same model as the Linux version
- **SSH:** Connect via SSH (Ctrl+Shift+K, the SSH button beside New Tab, or the window menu) runs Windows' own OpenSSH client (`System32\OpenSSH\ssh.exe`) inside the tab's shell, as on the Mac: the app types only the path of a private launcher that deletes itself. An `ssh` you type yourself is followed the same way. Pick a saved login or type one, and optionally save it. A password reaches ssh only once, through a one-time token traded over a private named pipe (SSH_ASKPASS), never on a command line, on screen or in history; host-key questions, one-time codes and retries are asked in the terminal as usual, and keys from `ssh-agent` or `~/.ssh` work without a password. When the session ends (`exit`, Disconnect, or a host that goes away, within about 15 seconds) the tab is back at its own shell.
- **Manage Logins:** the saved logins in a list with New, Edit, Delete, Import and Export (CSV, the same format as the Mac and Linux), and the Administrator Password: create, change or remove it, and unlock once per session
- **Snippets:** the lock beside Connect via SSH lists snippets (commands, a sudo password, any text) with each description beside its name; choosing one types only its text into the terminal, without Return. Manage Snippets keeps them by Name, Snippets and Description, in their own vault under the same Administrator Password as the logins.
- **Accessibility:** screen readers (Narrator, NVDA, JAWS) and Windows' accessibility tools see every drawn control through UI Automation: the toolbar, tab strip and window buttons, and the explorer's bar, places and transfer buttons, each with its name, hover text, shortcut and state (the selected tab and place; MultiExec, Bookmark and Administrator mode as on/off toggle buttons), and each can be pressed from there. The terminal is a document with UI Automation's Text pattern, read by character, word and line with the cursor as the caret, and new output is announced as it arrives (without repeating what you typed). The visual bell flashes at most twice a second and fades more slowly when Windows' animations are off
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
| Ctrl+Shift+X | Show File Explorer / Terminal |
| Ctrl+Shift+C, Ctrl+Shift+V | Copy, paste |
| Shift+Page Up / Down, Ctrl+Shift+Home / End | Scroll back |
| Ctrl+S, Ctrl+F | Save, Find (text editor) |

## Testing without touching the desktop

`--self-test` checks the crypto, the login vault, ssh command lines and the password broker, and prints PASS/FAIL lines (exit code 0 when all pass).

Scripted runs drive the app from the command line instead of simulated keystrokes, so nothing is typed into other windows:

```powershell
HerbsTerminal.exe --type "Get-ChildItem\r" --type "\t" --type "ver\r" --capture shot.bmp
```

Steps run 1.5 s apart. `--type` sends text straight into the active terminal (`\r` is Enter, `\e` Escape); a lone `\t` opens a new tab, `\s` Settings, `\k` Connect via SSH, `\l` Manage Logins, `\m` the Main Menu, `\c<id>` a menu command, and `\f` followed by `value|value|…#button` fills the open dialog and presses that button (`+check` as the last value ticks its checkbox). `--ssh user@host:port` (after `--ssh-password`) opens an SSH tab directly. `--drop "path|path"` drops files on the active terminal the way File Explorer does. A lone `\x` switches the tab to its explorer; `--explore PATH`, `--select "a|b"` and `--explorer-do NAME` (copy, cut, paste, newFolder, newFile, delete, deletePermanently, showHidden, reload, selectAll, up, back, `upload=path|path` into the current host folder, `download=C:\folder` for the selection, `edit` opens the selection in the text editor, `info` opens Get Info for a host's selection) drive it. `admin` (or `admin=PASSWORD` to skip the dialog) enters Administrator mode on a host and `leaveAdmin` leaves it. With Get Info open, `--info-do NAME` runs owner=NAME, group=NAME, octal=DIGITS, recursive, apply, revert or close. With an editor tab active, `--type` types into it and `--editor-do NAME` runs save, wrap, find=TEXT, next, previous, done or end. `--capture` saves the window, and any open Settings, Manage Logins, dialog or menu beside it, as BMPs and quits. The window opens without taking focus.

## Roadmap

What's left is in `pending.md`. The app ships unsigned and without an installer, so Windows SmartScreen may ask once before the first run (More info ▸ Run anyway).
