# Herb's Terminal

Herb's Terminal is a terminal for administrators. It is native on Macs with Apple silicon, on Linux, as a Flatpak, and on Windows, and manages local files and remote Linux, macOS and Windows machines over SSH. Sections 1–10 describe the Mac app; section 11 lists what is different on Linux, and section 12 what is different on Windows.

Each tab pairs a shell with a file explorer. When the shell connects to another machine, the explorer follows it to the same host and account. Connect once, and the shell, files, transfers, text editing and permissions are all in that one tab.

It covers the everyday features of the stock macOS Terminal and Ptyxis. It adds:

- an SSH-aware file explorer in the style of Thunar, with a built-in text editor;
- MultiExec, which types into several terminals at once;
- an encrypted login vault;
- Administrator mode, for working on files as root;
- Tailcat pairing, for reaching machines that can't reach each other by IP.

## 1. Platform

- **System:** macOS 15 or later on Apple silicon.
- **Built with:** SwiftUI and AppKit, the SwiftTerm terminal emulator and Swift Package Manager.
- **Self-contained:** nothing has to be installed separately. The app uses its own bundled helpers and parts of macOS (`/usr/bin/ssh`, `/bin/sh`, `/usr/libexec/sftp-server`, `sudo`). It never picks up other copies of these tools from PATH or Homebrew.
  - The bundled `tailcat` (BSD-3) lives in `Contents/Helpers`.
  - The SSH password helper and the Tailcat proxy are modes of the app's own executable.
- **Building:** `macos/dev/build_and_run.sh` builds and signs `dist/Herb's Terminal.app` with bundle ID `org.herbsterminal.app`.
  - `--bundle` assembles the app without touching a running copy.
  - `--verify` builds the app and checks it.
- **Signing for other Macs:**
  - Without a certificate the app is signed ad hoc and runs only on the Mac that built it.
  - With `SIGN_IDENTITY` set to a Developer ID Application certificate, the app and its helper are signed with the hardened runtime and a secure timestamp.
  - `macos/dev/notarize.sh` then has Apple notarize the app and staples the ticket, so it opens anywhere without Gatekeeper warnings.
- **Icon:** a dark glass tile in the style of the macOS Terminal icon, with a centered prompt that reads `> HT_`. `macos/dev/make_icon.swift` draws it and writes `macos/Assets/HerbsTerminal.icns`.
- **Local Network permission:** the app declares a Local Network usage description, so macOS can ask for that permission and SSH to machines on the LAN works.
- **Tests:** `macos/dev/test.sh` runs the test suite, including real SFTP transfers through the system SFTP server.

## 2. Window, tabs and toolbar

### Toolbar

- **Left:** after the traffic lights come **New Tab** and **Connect via SSH**.
  - While the tab is connected, the SSH button is highlighted. It then opens the connection details instead: account, host, port, route, remote home and how long it has been connected. From there you can **Disconnect**, or start a **New Connection** in a new tab.
- **Center:** the tab's title and location, for example `user@host ~`.
  - It follows the titles the shell reports, the current folder and the program in the foreground, and shows home as `~`.
  - Passwords and tokens in a command line (`user:pass@host`, `--password=`, `*_TOKEN=`) are hidden before the title is shown.
  - Double-click the title to return the window to its default size and the text to its default zoom. Right-click it to make the current size and text size the defaults.
- **Right:**
  - **Export Session** (⌘S): saves everything in the active terminal, scrollback included, to a text file named after the tab and the time, for example `Terminal 2 2026-11-06 09-05.txt`.
  - **Take Screenshot** (⇧⌘S): copies a picture of the whole window, as it looks now, to the clipboard, ready to paste anywhere.
  - **Show File Explorer / Show Terminal**: switch the tab between its shell and its explorer.
  - **MultiExec**.
  - **Tailcat Peers**.
  - **Search**: searches files while the explorer is showing and the scrollback otherwise (⌘F).
  - The **Main Menu**.
- **Main Menu:**
  - New Tab, New Window, Connect via SSH…, and Open Tabs (a list of tabs to jump to).
  - Find in Terminal….
  - **Zoom:** Bigger, Smaller, Default.
  - **Appearance:**
    - Color scheme: System, Light, Dark.
    - Color preset: the theme list.
    - Import iTerm2 Color Preset….
    - Restore Defaults.
  - Toggle Full Screen.
  - **Edit:** Undo, Redo, Cut, Copy, Paste, Select All, Clear to Start (⌘K), Clear Scrollback (⌥⌘K).
  - **Shell:** every Shell command (section 2's tabs, panes, MultiExec, profiles, connections, Reset, Secure Keyboard
    Entry), with the shortcuts listed there.
  - **Window:** Minimize (⌘M), Zoom, Show Tab 1–8 and Show Last Tab (⌘1–⌘9).
  - Settings…, and About, which shows the author (dunkelherzmann) and a link to the project on GitHub.
  - Hide Herb's Terminal (⌘H) and Quit Herb's Terminal (⌘Q).
- **Every menu is in the window.** The macOS menu bar shows only the app menu (About, Settings…, Services, Hide, Quit),
  which macOS always shows; every other menu is in the Main Menu, so on a wide screen no command needs a trip to the
  top of the screen. Every shortcut works as before, Cut, Copy and Paste in text fields included.
- **Hover hints:** every control shows a short bubble saying what it is and what it does. It appears after about half a second, in the titlebar too, and while the app is in the background. Screen readers get the same description.

### Tabs

- Each tab has its own shell, scrollback, explorer location and connection. Switching tabs keeps every session running.
- **Names:** tabs are numbered "Terminal 1", "Terminal 2" and so on. A new tab takes the lowest free number. Rename a tab by double-clicking it, from its right-click menu, or with Shell ▸ Rename Tab (⇧⌘I).
- **Order:** drag tabs to reorder them, or use Move Tab Left and Move Tab Right.
- **Switching:** ⌘1–⌘8 pick a tab by position, and ⌘9 picks the last tab. ⇧⌘[ and ⇧⌘] go to the previous and next tab. Keyboard focus moves to the selected tab.
- **Closing:**
  - ⌘W closes the current tab. When only one tab is left, ⌘W closes the window.
  - Typing `exit` closes the pane, then the tab, then the window when it was the window's last terminal. In the app's last window it quits Herb's Terminal. In an SSH session, `exit` ends the session and returns to the local shell.
  - Closing a tab, a window or the app asks first if a shell is running another program or an SSH session (Settings ▸ Terminal).
- **Where new tabs start:** in the current tab's folder or in your home folder, as set in Settings. A profile can also set its own start folder.
- **Session restore:** when the app quits, each window's tabs are saved with their folder, panes, explorer folder and name, and they reopen at the next launch.
  - This is on by default.
  - Remote sessions reopen as local shells; logins are never replayed.
  - Scrollback isn't saved.

### Split panes

- Shell ▸ **Split Vertically** (⌘D) places panes side by side; **Split Horizontally** (⇧⌘D) stacks them. Panes can be split again, and they share the space equally.
- Each pane is its own shell, using the current pane's profile and folder.
- **Close Pane** is ⌥⌘W, and typing `exit` also closes a pane. **Select Next / Previous Pane** are ⌥⌘→ and ⌥⌘←.
- The focused pane is outlined. Zoom, Clear, Reset and Find act on it.
- A tab's SSH connection and explorer belong to its first pane. If that pane closes, the next pane takes over.

### Terminal behavior

- **Right-click menu:**
  - Copy, Paste, Paste Escaped Text, Select All, Find.
  - Clear to Start, Clear Scrollback, Reset.
  - Split Vertically, Split Horizontally, Close Pane, New Tab, Show File Explorer.
  - Connect via SSH, or Disconnect while connected.
  - Bigger, Smaller, Settings.
- **Dropping files:** dropping files or folders on the terminal types their paths, quoted for the shell.
- **Bell:** sounds, flashes, does both, or does nothing. The flash happens at most twice a second and fades gently when Reduce Motion is on.
- **Mouse in full-screen programs:** a program that asks for mouse events (vim, htop, tmux, mc) gets clicks, drags, movement and the wheel at the cell under the pointer. Shift+click and Shift+drag still select text, unless the program asks for Shift too, and the right-click menu stays. Without mouse reporting, the wheel scrolls back, or sends arrow keys in full-screen programs (unless they turn alternate scrolling off).
- **Input methods:** Chinese, Japanese and Korean input methods compose at the cursor, in the terminal's font, with the candidate list below the cursor's line; the result is typed like keys.
- **Size badge:** while the window is being resized, a badge shows the terminal's size in columns × rows (Settings ▸ Window).

### Menus and shortcuts

These follow macOS Terminal:

- **Shell:**
  - New Tab ⌘T, Export Session… ⌘S, Take Screenshot ⇧⌘S, New Tab with Profile, Use Profile.
  - Split Vertically ⌘D, Split Horizontally ⇧⌘D, Close Pane ⌥⌘W, Select Next / Previous Pane ⌥⌘→ / ⌥⌘←.
  - MultiExec ⇧⌘M, Run Command on Hosts….
  - New Remote Connection ⇧⌘K, Disconnect.
  - Show Previous / Next Tab ⇧⌘[ / ⇧⌘], Rename Tab ⇧⌘I, Move Tab Left / Right.
  - Reset ⌥⌘R, Hard Reset ⌃⌥⌘R.
  - Secure Keyboard Entry.
- **Edit:** Clear to Start ⌘K, Clear Scrollback ⌥⌘K.
- **View:** Bigger ⌘+, Smaller ⌘−, Default ⌘0. The zoom is saved in the tab's profile, so text keeps its size across sessions. ⌘0 clears it.
- **Window:** Show Tab 1–8 ⌘1–⌘8, Show Last Tab ⌘9.
- macOS's own window tabbing is turned off; the app has its own tab strip.

## 3. Profiles, appearance and Settings

### Profiles

- Each tab uses a named profile, and new tabs keep the current tab's profile.
- **A profile holds:**
  - text: font, size, zoom and cursor shape and blink;
  - colors: the color preset, background opacity and blur;
  - keyboard: whether Option acts as the Meta key;
  - scrollback length and the bell;
  - a command to run when a tab opens, and a start folder.
- **Default look:** the macOS Terminal **Basic** profile, in SF Mono Terminal 13 pt with Terminal's light and dark colors and ANSI palette.

### Color presets

- macOS Terminal Basic, Solarized Dark, Solarized Light, Tango Dark, Tango Light, Gruvbox Dark and Nord.
- **iTerm2 import:** an `.itermcolors` file sets the foreground, background, cursor, cursor text, selection and selected text, and the 16 ANSI colors.
  - A damaged file is rejected without changing the current colors.
  - Imported presets can be removed.
- **Restore Defaults** (Main Menu ▸ Appearance) asks first. It then returns the profile's font, size, zoom, cursor, colors and transparency, and the app's color scheme, to the Basic look.

### Settings (⌘,)

- **Profiles:** add, duplicate, rename, delete and choose the default profile. Also set the startup command and start folder.
- **Text:** any installed monospaced font, size 6–72 pt, cursor shape and blink, background opacity (20–100%) and blur, with a live preview.
- **Terminal:**
  - Option as Meta (off by default, as in Terminal);
  - scrollback of 100–1,000,000 lines;
  - the bell;
  - where new tabs open;
  - restoring windows and tabs at launch;
  - asking before closing.
- **Window:**
  - the size of new windows in **columns × rows**, the same numbers the resize badge shows (default 100 × 30, in every version);
  - showing the size badge while resizing;
  - Apply to Open Windows, Use Front Window's Size, and Reset.
  - Windows are sized against the terminal's real grid, so they open at exactly the size set, within the screen and the window's minimum size.
- **Colors:** the color scheme (System, Light, Dark) and the color presets, with import and removal.

## 4. SSH: connect once, follow the host

| You do | Herb's Terminal does |
|---|---|
| Open a tab | Starts your login shell; the explorer shows this Mac's files. |
| **Connect via SSH** (⇧⌘K) | Takes a host, port (22 by default), username, and a password or a saved login. You can save the login or use it once. It opens the remote shell, and once the login succeeds the explorer moves to the same host and account. |
| Type `ssh user@host` or `ssh alias` in zsh or bash | Resolves the destination through your SSH configuration and follows it exactly like a Connect via SSH login. |
| Exit the remote shell, or **Disconnect** | Returns the tab, its title and its explorer to this Mac. |
| A login fails or the link drops | A banner shows the real state, and the title shows this Mac's `user@host` again. File actions never go anywhere other than the host you're connected to. |

**How a connection is made**

- The app types only the path of a private launcher, which deletes itself after use. The launcher clears that line from the screen and starts the system `ssh` as the master of an OpenSSH shared connection.
- **Shared-connection settings:**
  - `ControlMaster=auto`, `ControlPersist=10`.
  - `ServerAliveInterval=5`, `ServerAliveCountMax=2`: when the host is switched off, restarts or drops off the network, the session ends within about 15 seconds and the tab returns to this Mac.
  - The socket lives in `/tmp/herbs-<uid>`, which must be a real folder owned by you with mode 0700. Unix socket paths must stay under 104 bytes, which is why the folder name is short.
- No command line, password or token appears on screen or in shell history.
- **Saved passwords:** a saved password reaches ssh through `SSH_ASKPASS`, which is the app itself in helper mode. It trades a one-time token over a private socket.
  - The token only answers a password prompt for the saved login's own `user@host` (as given, or as `~/.ssh/config` resolves it). A ProxyJump host that asks first is asked on the terminal instead.
  - The socket answers only processes of your own account, and a client that connects and stays silent is dropped after two seconds.
- Host-key questions, one-time codes and retries are asked in the terminal as usual.
- The tab checks the shared connection. It attaches the explorer at the remote home folder once the login succeeds, and detaches when ssh exits or the link drops.

**Startup files:** zsh loads your own startup files through `ZDOTDIR`. bash starts interactive with its own `--rcfile`, which loads what a login bash would (`/etc/profile`, then `~/.bash_profile`, `~/.bash_login` or `~/.profile`), each file once.

**Typed ssh**

- Each tab's zsh or bash first loads your own startup files, then adds a small `ssh` function (zsh through `ZDOTDIR`, bash through `--rcfile`).
- The function resolves the destination with `ssh -G`, tells the app where it's going, and runs the real ssh as the master of a shared connection.
- `ssh -G`, `-O`, `-V` and `-Q` pass straight through. Other shells run unchanged.

**Your SSH setup is respected.** Aliases, ports, identity files, the SSH agent, multi-factor prompts, host-key checks and jump hosts all come from your own `~/.ssh/config` and the system ssh client. The explorer and transfers reuse the shell's connection, so you log in only once.

## 5. File explorer

The explorer follows Thunar's design and works the same on this Mac and on SSH hosts.

### Navigating

- **Places side pane:**
  - This Mac: Home, Desktop, Documents, Downloads, Movies, Music, Pictures, Computer, Trash and mounted devices.
  - A host: Home and File System.
- **Bookmarks:** ⌥⌘D. Bookmarks are kept separately for each host.
- **Moving around:** back and forward (⌘[ and ⌘]), up (⌘↑), home (⇧⌘H), clickable path segments, an editable location (⌘L) that accepts `~` and relative paths, show hidden files (⇧⌘.), reload (⌘R), and Delete to go back.
- **Opening:** double-click or Return opens an item. Symbolic links to folders open as folders.

### File Actions

The File Actions button in the location bar holds:

- Upload File/Folder and Download File/Folder;
- Undo ⌘Z and Redo ⇧⌘Z;
- Cut ⌘X, Copy ⌘C, Paste ⌘V and Delete ⌘⌫;
- Select All ⌘A and Find ⌘F.

These shortcuts act on the file list when it has focus. In the terminal, ⌘C and ⌘V still copy and paste text.

### Changing files

- **On this Mac:**
  - Copy, move and move to Trash, with Finder-style "name copy" names that never overwrite anything.
  - Undo and Redo, named after the action.
  - The Finder clipboard works in both directions.
- **On a host:**
  - Moving is undoable, copying happens on the host, and deleting asks first and removes whole folders.
  - Pasting files from this Mac uploads them.
  - Copied items paste into Finder, or the local explorer, as real files and folders. They're downloaded at the moment they're pasted.
  - A folder can't be moved or copied into itself.
- **Creating and renaming:** right-click an empty area for New Folder and New File, and right-click an item to rename it. New items get a free "untitled" name. On this Mac both actions are undoable; on a host, renaming is.

### Transfers

- Uploads and downloads work for single files and whole folder trees.
- A progress strip under the file list has Cancel and Retry. Retry runs a failed or cancelled transfer again from the start.
- **Speed:** up to 16 requests are kept in flight, as OpenSSH's `sftp` does, so transfers stay fast on slow or distant links.
- **Hung links:** a server that stops answering for 30 seconds ends the request with an error instead of stalling; the explorer opens a fresh channel, so Reload works again.
- **This Mac:** copy, move and Move to Trash run in the background with a "Copying…" note, so large folders never freeze the window.
- **Uploads are staged:** each file is written under an unguessable temporary name, opened exclusively, then renamed into place. A dropped connection never leaves a half-written file, and nothing already at that name is written through.
- Name clashes get new names, never overwrites.
- Links to folders inside a tree are skipped, so a link that loops back can't make a transfer run forever.

### Text editor

- Text files open in a built-in editor, as a tab in the terminal window: double-click them, or right-click and choose **Open in Text Editor**.
  - "Text" covers plain text, Markdown, source code, scripts, configuration files, JSON, YAML, XML, CSV and logs.
  - It also covers files with no extension, or an unfamiliar one, whose content looks like text.
- **New File…** opens the new file straight in the editor, on this Mac and on hosts.
- **Editing:**
  - a monospaced font, undo, and Find (⌘F);
  - Wrap Lines;
  - a status line with line and column, line count, encoding and line endings.
- **Saving:**
  - ⌘S or the Save button saves. The tab shows a • while there are unsaved changes.
  - Closing the tab, the window or the app asks before discarding them.
  - If the file changed elsewhere since it was opened, you're asked before it's replaced.
  - Files keep their encoding (UTF-8, UTF-16 or Latin-1), line endings and permissions.
  - Remote saves are written in full and then renamed into place.
  - Links are edited at their target.
- **Limits:** files larger than 20 MB, and files that look binary, aren't opened. A message explains why.
- **Other apps:** on this Mac, **Open with Default App** opens a file in its usual Mac app.

### Get Info: permissions and attributes

Right-click one or more items and choose **Get Info…**.

- **Shown:** name, location, kind, size, the date modified, and the current permissions as `ls -l` text with the octal value.
- **Permissions (chmod):**
  - Read, write and execute for the owner, the group and others (for folders, execute reads "Open").
  - Set user ID, set group ID and sticky.
  - An octal field (644, 755, …) that stays in step with the checkboxes.
- **Owner and group (chown):** by name or number. On a host, names are looked up on the host itself.
- **This Mac only:** **Hidden** and **Locked**.
- **Apply to enclosed items:** changes everything inside a folder too. Folders inside keep their search permission wherever they're readable, so they stay openable. Links inside are left alone.
- Apply changes only what you edited, on every selected item. Revert reloads the current values.

### Administrator mode

- The lock button in either explorer starts Administrator mode for that tab. After you enter the sudo password, the explorer works as root: on this Mac, or on the connected host over the tab's own SSH connection.
- **How it works:**
  - It starts the system SFTP server under `sudo`.
  - Every explorer action runs as root: browsing, creating, renaming, cut, copy and paste, deleting, transfers, editing and Get Info.
  - This is what makes it possible to give a file to another owner.
- **The password:**
  - It goes to `sudo -S` once, on standard input.
  - It's checked first, so a wrong password can't hang the session.
  - It's never stored.
  - Accounts with password-free sudo aren't asked.
- **Deleting as root:** a folder is only emptied when root owns it and the folder holding it and no other account can write to them. Otherwise another account could swap part of the tree for a link mid-delete. The delete stops with an explanation; turn off Administrator mode to delete it with your own access.
- A red bar marks Administrator mode until you leave it. On a host, it ends with the SSH session it runs over.

## 6. Saved logins

**Storage**

- Logins are kept in an app-owned database at `~/Library/Application Support/HerbsTerminal/logins.sqlite3`, mode 0600.
- Each login has a host, port, username and password, and a host can have several logins.
- Host names ignore case. The macOS Keychain isn't used.

**Administrator Password**

- With an Administrator Password, every password is encrypted with AES-GCM. The key is derived from the Administrator Password with PBKDF2-SHA256: 600,000 rounds and a random 16-byte salt.
- Only the salt, the round count and an encrypted check value are stored; the Administrator Password itself never is.
- Saved logins are locked when the app starts and unlock once per session.
- Changing the Administrator Password re-encrypts every login in one step.
- Tailcat peer addresses are protected the same way, and are re-encoded whenever the Administrator Password is created, changed or removed.

**Plain text**

- Without an Administrator Password, logins are stored as plain text.
- This needs an explicit choice and a second confirmation.

**First use**

- The first time you save a login or open Manage Logins, an explanation appears. It says an Administrator Password is needed to encrypt saved logins, and that plain text is a security risk.
- It offers Create Administrator Password, Store as Plain Text, or Not Now.
- Nothing is saved until you choose.

**Manage Logins** (a button in Connect via SSH) opens a window listing every saved login, with host, port, username, a hidden password, and whether the login is encrypted or plain text.

- **Opening it:** with an Administrator Password set, the window asks for it first. **Skip** still opens the window, showing only plain-text logins, with a bar to unlock the rest.
- **Top bar:**
  - **New** and **Edit**: a form for host, port, username and password. **Show password** shows the stored password as text, for plain-text logins or once the Administrator Password has been entered.
  - **Import**.
  - **Export**: exports only the ticked logins.
  - **Create Administrator Password** (or **Modify Administrator Password** once one is set). Leaving both new password fields blank removes the Administrator Password, after a confirmation; saved logins are then stored as plain text, unprotected.
- **In the list:**
  - The first column has a checkbox for each login that ticks it for Export; the checkbox in its heading ticks or unticks them all.
  - Double-click a login to edit it.
  - Right-click, or press Delete, to remove one after a confirmation whose default is Cancel.

**Import and export**

- The format is CSV with the header `host,port,username,password`, in UTF-8. Commas, quotes and line breaks are quoted.
- Importing is all-or-nothing: a rejected import leaves the saved logins as they were.
- **Export** writes readable passwords, so it needs the Administrator Password (or a confirmation for plain-text logins). It always includes every login.
  - The file is suggested as `logins_export.csv`.
  - Only your account can read it.

**Privacy and recovery**

- Passwords never appear in process arguments, terminal output, shell history or logs. SSH private keys never go into the CSV.
- A forgotten Administrator Password can't be recovered; the logins have to be deleted and entered again.
- To move to another Mac, export the logins and import them there.

## 7. MultiExec and Run Command on Hosts

**MultiExec** (the toolbar button, or Shell ▸ MultiExec ⇧⌘M) works like MobaXterm's.

- **The grid:** every terminal in the window appears as a live terminal in a grid. Each has a caption bar with its number, title or remote `user@host`, and an include checkbox.
- **Typing:** what you type or paste into an included terminal goes to every included terminal. An unchecked terminal takes only its own typing.
- **Keys:**
  - ⌘1–⌘9 pick a terminal by its number.
  - ⌘W closes only the active terminal.
  - Esc leaves MultiExec.
- **The bar** shows how many terminals receive typing, and has New Tab, Connect via SSH, Include All, **Close All** and Exit MultiExec.
  - Close All asks first, ends every terminal in the grid, and leaves MultiExec with one new terminal.
- **What isn't broadcast:** only your own input is sent to the others. The emulator's replies to programs, and text the app types itself, stay in their own terminal.
- MultiExec types into live sessions, so it reaches whatever each one is running, including a password prompt or an editor. Leave a terminal out with its checkbox to protect it.

**Run Command on Hosts** (Shell menu) runs one command on several machines without typing into any session.

- **Targets:** selected saved logins and the tab's live connection, all at the same time. Each runs over its own ssh channel, with strict host-key checking and no retries.
- **Results:** each host's outcome, exit code, duration and output. Output is kept up to 64 KB per host while the command runs; the rest is dropped and marked as truncated.

## 8. Tailcat peers

Tailcat connects machines that can't reach each other by IP. Herb's Terminal runs its bundled `tailcat`; the other machine runs `tailcat serve`.

- **Add a peer:**
  - Enter a name, a username and the peer's secret address.
  - Mark it **One-time** (the address ends with its server; the default) or **Persistent** (the peer keeps a saved server key).
  - Addresses are protected like saved logins.
- **Ping** reports whether the route is Direct or Relayed, with the latency.
- **Connect** opens the shell and explorer through Tailcat.
  - ssh's ProxyCommand is the app's helper, which swaps a one-time token for the address and then runs as the bundled tailcat.
  - The bundled tailcat runs as a local SOCKS proxy and receives the address over the loopback socket, so the address never appears in ssh's or tailcat's arguments, in the process list, or in history.
  - When the peer is reached but nothing answers SSH there, the terminal says so and how to turn SSH on (Remote Login on a Mac, the SSH service on Linux), before ssh's own "Connection closed" line.
- **Remove** forgets a peer on this Mac.
- The panel starts empty each time it opens; nothing typed but not added is kept.
- **Share this Mac:** runs `tailcat serve` for SSH, one-time (the default) or persistent, and shows the address with Copy and Stop.
  - It needs Remote Login turned on. **Start Sharing** checks first: when nothing on this Mac answers SSH, it doesn't share and says to turn on Remote Login in System Settings › General › Sharing.
  - Sharing stops when the app quits.
- SSH host verification and authentication stay on inside the tunnel.
- **Unlock… / Lock…** (bottom left, opposite Done) shows whether saved logins and Tailcat addresses are locked.
  - Its hover bubble explains that it unlocks or locks the safe storage of Tailcat addresses and saved logins with the Administrator Password, or, without one, that they are stored as plain text. VoiceOver reads "Unlock Saved Logins" or "Lock Saved Logins".
  - Clicking it opens a window. When locked, it asks for the Administrator Password, with **Unlock**, **Cancel** and **Change Administrator Password…**. When unlocked, **Lock** locks again without a password. With no Administrator Password set, it explains the protection and offers to create one.
  - So a locked store can be unlocked in the Tailcat Peers window itself, without going through Connect via SSH.

## 9. Accessibility

- Every control has a name for VoiceOver and a hover hint. Hints read the description once, without repeating the control's name.
- **States VoiceOver announces:**
  - which tab is selected; the selected tab's title is also bold;
  - whether toggle buttons (MultiExec, Bookmark, Administrator mode) are on or off;
  - each MultiExec checkbox, named after its terminal.
- **The terminal's text** reaches screen readers: through SwiftTerm's accessibility on the Mac, VTE's on Linux, and on Windows through UI Automation's Text pattern (read by character, word and line, with the cursor as the caret), where new output is also announced as it arrives, without the echo of what was typed (full-screen programs are read by reviewing the screen). On Windows the drawn controls (toolbar, tab strip, window buttons, the explorer's bar, places and transfer buttons) are described to UI Automation by the app itself, with their states, and can be pressed from there.
- **Password fields** in dialogs have visible labels.
- **Motion:** window resizing follows Reduce Motion, and the visual bell never flashes more than twice a second.
- **Identifiers:** toolbar controls carry the same accessibility identifier on Mac, Linux and Windows (`toolbar.newTab`, `toolbar.connect`, `toolbar.title`, `toolbar.exportSession`, `toolbar.takeScreenshot`, `toolbar.switchView`, `toolbar.multiExec`, `toolbar.tailcatPeers`, `toolbar.search`, `toolbar.mainMenu`), so the parity check can match them.

### Parity checks

`parity/check.sh` compares the Linux and Windows versions with the Mac version, scene by scene, as described in `parity/parity.json`. Each scene is a fixed state that the app opens itself:

- **Mac:** a parity copy of the app (`macos/parity/copy.sh`, bundle identifier `org.herbsterminal.parity`) launched with `--parity-scene <name>`. Only that copy honours the flag. It has its own settings domain, keeps its files in a temporary folder, never restores or saves a session, and opens without taking focus.
- **Linux:** the Flatpak build started with `--parity-scene <name>` and `HERBS_PARITY=1` (both are needed). It runs as a separate, non-unique application (`org.herbsterminal.app.Parity`) in a headless KWin session, with every XDG folder in a temporary folder. `--parity-capture FILE` saves the window's picture once the scene has settled (the same picture as Take Screenshot), with each identified control's place in the window beside it.
- **Windows:** the app started with `--parity-scene <name>` and `HERBS_PARITY=1` (both are needed). It keeps its files in a temporary folder (so it starts from the default settings) and opens without taking focus. `windows/parity/scene.ps1` runs it in the PC's logged-in desktop session, where UI Automation can read it, saves the window's picture and closes it. The toolbar, tab strip and window buttons are drawn, so the app describes each one to UI Automation itself (also for screen readers).
- **The `main` scene:** one window, one local tab in an empty home with the prompt `$ `, titled `parity@scene ~`. The shell is `/bin/sh` on the Mac and Linux and Command Prompt on Windows.

The check reads each version's controls through the accessibility API (macOS accessibility, AT-SPI, UI Automation), compares them by identifier (kind, label, hover text, value, enabled state, size, order, alignment, window size), scores the two pictures, and records the results as Craft Anything evidence in `dist/parity/report.html`.

### Feature tests

`parity/features.md` lists every feature of the Mac version with an id. The feature tests in `parity/tests` check each one on the Mac, Linux and Windows, and record whether it works, is broken, is missing, or still needs a person (with the reason).

- **One suite for all three:** `parity/tests/suite.py` holds the tests; `run.py` runs them on one platform, starting a fresh parity copy of the app for every test. `all.sh` builds and runs all three platforms at once (Linux in a headless KWin session, Windows in the PC's desktop session, the Mac in the background without taking focus). `report.py` then writes `parity/feature-check.md` and the generated part of each version's `pending.md` (`pending.md` for the Mac, `linux/pending.md`, `windows/pending.md`).
- **The test bridge:** a parity copy started with `--test-bridge` reads requests from `request.json` in its private folder and answers in `response.json`. It reports the app's state (windows, tabs, panes and their text, the explorer, MultiExec, open dialogs and windows) and runs the same commands the menus and buttons run, types into the focused terminal the way the keyboard does, picks explorer items, types into the explorer's Find field and its in-place Rename (Windows), uploads and downloads with the files and folder given in place of the open dialog, types into the text editor, undoes, finds, saves and switches Wrap Lines there, and reads its status line, fills in and answers dialogs, lists and chooses items of the focused terminal's right-click menu (the same menu a right-click builds), and drops files on the terminal through the same code a drop from the file manager runs. The user's own app never listens, and tests never use the user's settings, files or clipboard.
- **A private clipboard:** a parity copy never uses the user's clipboard. On the Mac its general pasteboard (also the one SwiftTerm's and AppKit's Copy and Paste use) is a private named pasteboard; on Windows it keeps clipboard text, files and screenshots in memory; on Linux the tests run in their own headless session, which has its own clipboard. The bridge reads and fills the Mac and Windows ones (`clipboard`, `clipboard-set` with text or files); on Linux the runner uses `wl-paste` and `wl-copy` in that session. So Copy, Paste, Paste Escaped Text, Take Screenshot and the explorer's file clipboard are tested for real.
- **SSH test host:** the SSH tests log in to a test account named in `HERBS_TEST_SSH` or in `~/.config/herbs-terminal/test-ssh` (`user@host:port:password`, a private file outside the repository on each machine). The account lives on the Linux machine, takes passwords only from the home network, and may use sudo with its password, for the Administrator-mode tests. The bridge reports each tab's connection (local, connecting, connected or failed, with the account), and `connect-button` does what the toolbar's SSH button does.
- **A test desktop on each computer:** the tests run in the foreground on a desktop of their own, never on the one in use; switch to it to watch. On the Mac it is the last desktop (Space) of the main display: a test copy started with `--test-desktop` moves each window it shows there (through SkyLight, since macOS has no public API for desktops). On Windows it is the virtual desktop named "Herb's Terminal tests", made once on the test PC: windows move there before they're shown (`IVirtualDesktopManager`), and the runner says if any couldn't. On Linux the tests' KWin session is shown in a window (Xephyr) on GNOME's Workspace 2 (`HERBS_TEST_WORKSPACE`), or runs headless when no one is logged in.
- **Pointer checks on the Mac:** a test copy started without `--test-desktop` is on every desktop instead (not over a full-screen app), and the bridge reports whether it is visible and on the desktop in use (`visible`, `onActiveSpace`). REA presses its toolbar buttons through accessibility, and the bridge confirms what each press changed.
- **Limits:** features that need a second machine, pointer gestures or the system's file dialogs are listed as not checked, with the reason, until the bridge or a test machine covers them.

## 10. Security summary

- **Secrets stay hidden:** passwords and Tailcat addresses never appear in command lines, on screen, in history or in logs.
- **Private folders:** the SSH socket folder is checked to be a real folder owned by you, with mode 0700. A symlink placed there by someone else is refused.
- **Administrator mode uploads:**
  - Uploads use unguessable temporary names opened exclusively.
  - Copies never write through existing files.
  - Uploaded files don't carry setuid or setgid bits.
- **No silent data loss:**
  - Settings, profiles or Tailcat peers that can't be read are set aside rather than overwritten.
  - If the login database can't be opened, the app keeps working with an in-memory store and turns Manage Logins off.
- **Exports:** files with passwords are created readable by your account only.
- **Disconnects:** a dropped connection is reported as an error; it never stops the app.

## 11. Linux

The Linux version is the same app on GTK 4, libadwaita and VTE, packaged as the Flatpak `org.herbsterminal.app`. Everything in sections 2–10 applies, with these differences.

### Build and packaging

- **Source:** `linux/`, a Swift package. The SSH, SFTP, login-vault and shell-integration code is shared by every version: it lives in `shared/` at the repository root, and `linux/copy-shared.sh` copies it into `linux/Sources/HerbsTerminal/Shared` before each build. Small modules named `Darwin`, `CryptoKit` and `CommonCrypto` give that code the same names on Linux (Glibc, and AES-GCM and PBKDF2 on OpenSSL), so a vault from a Mac opens unchanged.
- **Flatpak:** `linux/org.herbsterminal.app.yml` builds on the GNOME 49 runtime with Flathub's Swift 6 SDK extension. It builds VTE 0.82 and bundles Tailscale's official `tailcat` Linux release. The Swift runtime is linked in statically.
- **Building:** on a Linux machine, `linux/dev/build_flatpak.sh [--install]` writes `linux/version.txt` (`scripts/version.sh`), builds the manifest with flatpak-builder from Flathub (`org.flatpak.Builder`, which installs the SDK and extension it needs) and writes `dist/Herbs-Terminal-<version>-linux-<arch>.flatpak` for that machine's architecture; `--install` installs the bundle for the user, unless the app is running. Each architecture's bundle is built on a machine of that architecture. Another computer starts a build over SSH: `ssh <linux-machine> 'cd herbs-terminal && git pull --ff-only && linux/dev/build_flatpak.sh --install'`.
- **Downloads:** before building, `linux/dev/build_flatpak.sh` puts the manifest's downloads (VTE, tailcat) into flatpak-builder's cache, checked against the manifest's checksums: curl retries, and a GitHub release asset is fetched with `gh release download` when github.com's download links fail. A source that still can't be fetched is left to flatpak-builder.
- **Development builds** (`linux/dev`, on the Linux machine): `build.sh` makes a debug build with the Swift SDK extension inside a Flatpak SDK folder holding the manifest's other modules (`linux/build/sdk`, made on first use); `run.sh` starts it on the desktop as the user service `herbs-terminal-dev`, with the app's permissions and its own settings folder (`linux/.build/dev-home`); `restart.sh` does both; `check.sh` builds and runs the checks.
- **A development machine:** `linux/dev/setup-ubuntu.sh --mac user@host` sets up Ubuntu 24.04 LTS for building and testing: the Flatpak SDK and builder, the feature-test tools, SSH both ways with the Mac, the projects, and Claude Code Remote Control as a user service. Sign-ins happen in that machine's browser; no tokens are copied.
- **Checks:** a debug build run with `--self-test` checks the compatibility modules against standard vectors, the vault, the password helper, the host bridge, short commands (exit codes, input and output, the time limit), the Trash and file operations, iTerm2 presets, and, with a test account in `HERBS_TEST_SSH`, a real password login, shared connection and SFTP round trip.

### The host

- Shells, the interactive `ssh`, `sudo` and the system SFTP server run on the computer itself, outside the sandbox, through `flatpak-spawn --host`. A tab is a real login with your shell, `~/.ssh/config`, SSH agent and tools.
- Terminals are created in the host's `/dev/pts` (the Flatpak has host device access), so programs on the host can name their terminal (`tty`, `GPG_TTY`).
- The shell has the terminal as its controlling terminal on the host, so job control works and the app can see the program in the foreground. Flatpak usually hands it over; otherwise `setsid --ctty` takes it.
- One long-lived `sh` on the host answers the app's questions about a tab's shell: its folder, the foreground program and whether an `ssh` runs under it.
- `/tmp/herbs-<uid>` is shared with the host: the shared-connection sockets, the one-shot launchers and the password helper live there.
- **Saved passwords:** ssh on the host can't run the sandboxed executable, so its `SSH_ASKPASS` is a small script that asks the app through `flatpak run` for the saved password, and asks every other question on the terminal. The one-time token, socket and per-account checks are those of section 4.
- **Tailcat:** the ProxyCommand runs the app's helper through `flatpak run` in the same way. **Start Sharing** checks for the computer's SSH service instead of Remote Login, and suggests `sudo systemctl enable --now sshd` when nothing answers.
- **The explorer** shows the host's files: home folders, removable drives, `/opt`, `/srv` and `/tmp` at their own paths, the system folders through the Flatpak's read-only view of them. Administrator mode runs the host's own `sftp-server` under `sudo`, so as root it sees and changes everything.

### Window and toolbar

- Minimize, maximize and close sit at the right end of the toolbar, as on Linux and Windows desktops. The Main Menu takes the left corner, followed by New Tab and Connect via SSH; the rest of the toolbar is as on the Mac.
- The Main Menu holds the Mac's menus in the Mac's order, with Ctrl or Ctrl+Shift for ⌘ as the shortcuts list says: **Edit** (Undo, Redo and Cut for a focused text field such as the find bar; Copy, Paste and Select All, which act on the terminal otherwise; Clear to Start and Clear Scrollback), **Shell** (the Mac's Shell menu without Secure Keyboard Entry, which is macOS-only), **Window** (Minimize, Zoom, which maximizes, and Show Tab 1–8 and Show Last Tab, Alt+1–9), then Settings, About and Quit Herb's Terminal. Hide is macOS-only.
- Toolbar buttons never take the keyboard focus from the terminal. The window's shortcuts are handled before the terminal sees the key.
- Toolbar buttons are 30 × 28 px as on the Mac, and the Main Menu is a plain glyph with a background only while hovered or pressed.
- Hover hints are GTK tooltips with the same text; screen readers get the same descriptions, the title's included. Items in the Main Menu and other menus are named after their text for screen readers (GTK leaves menu items unnamed).

### Shortcuts

Linux terminals' conventions replace ⌘:

| Command | Mac | Linux |
|---|---|---|
| New Tab / New Window | ⌘T / ⌘N | Ctrl+Shift+T / Ctrl+Shift+N |
| Close Tab (the window with the last tab) | ⌘W | Ctrl+Shift+W |
| Export Session | ⌘S | Ctrl+Shift+S |
| Take Screenshot | ⇧⌘S | Ctrl+Alt+S |
| Copy / Paste / Paste Escaped Text | ⌘C / ⌘V / ⌃⌘V | Ctrl+Shift+C / Ctrl+Shift+V / Ctrl+Alt+V |
| Find | ⌘F | Ctrl+Shift+F |
| Split Vertically / Horizontally | ⌘D / ⇧⌘D | Ctrl+Shift+E / Ctrl+Shift+O |
| Close Pane, Next / Previous Pane | ⌥⌘W, ⌥⌘→ / ⌥⌘← | Ctrl+Alt+W, Ctrl+Alt+→ / Ctrl+Alt+← |
| MultiExec | ⇧⌘M | Ctrl+Shift+M |
| Connect via SSH | ⇧⌘K | Ctrl+Shift+K |
| Show Tab 1–8, Last Tab | ⌘1–⌘8, ⌘9 | Alt+1–Alt+8, Alt+9 |
| Previous / Next Tab | ⇧⌘[ / ⇧⌘] | Ctrl+Page Up / Ctrl+Page Down |
| Move Tab Left / Right | (menu) | Ctrl+Shift+Page Up / Ctrl+Shift+Page Down |
| Rename Tab | ⇧⌘I | Ctrl+Shift+I |
| Show File Explorer / Terminal | (toolbar) | Ctrl+Shift+X |
| Clear to Start / Clear Scrollback | ⌘K / ⌥⌘K | Ctrl+Shift+L / Ctrl+Alt+K |
| Reset / Hard Reset | ⌥⌘R / ⌃⌥⌘R | Ctrl+Alt+R / Ctrl+Alt+Shift+R |
| Bigger / Smaller / Default | ⌘+ / ⌘− / ⌘0 | Ctrl++ / Ctrl+− / Ctrl+0 |
| Settings | ⌘, | Ctrl+, |
| Full Screen | ⌃⌘F | F11 |
| Quit | ⌘Q | Ctrl+Shift+Q |

The explorer follows Thunar: Ctrl+C / X / V / A / Z, Ctrl+Shift+Z to redo, Delete moves to the Trash (deletes on a host, after asking), BackSpace and Alt+← go back, Alt+→ forward, Alt+↑ up, Alt+Home home, Ctrl+L location, Ctrl+R or F5 reload, Ctrl+H hidden files, Ctrl+D bookmark, Ctrl+F find, F2 rename and Alt+Return Get Info. The text editor saves with Ctrl+S and finds with Ctrl+F.

### Appearance

- The stock face is Adwaita Mono 13 pt; the Basic look keeps macOS Terminal's colors and ANSI palette.
- Font sizes use the Mac's points in every version: one point is one screen pixel before display scaling (Pango gets `13px`; Windows uses `points × dpi / 96`), so the same size gives the same window on every platform.
- Settings lists the installed monospaced fonts. Background opacity works as on the Mac; GTK has no blur behind windows, so there is no Blur setting.
- The color scheme (System, Light, Dark) follows the desktop through libadwaita.

### Files

- **Places:** Home and the XDG folders that exist (Desktop, Documents, Downloads, Music, Pictures, Videos, as `~/.config/user-dirs.dirs` names them), Computer, Trash, then mounted drives under `/run/media`, `/media` and `/mnt`.
- **Trash:** the freedesktop.org Trash (`~/.local/share/Trash`, or `.Trash-<uid>` on other drives), with a `.trashinfo` record, so file managers can restore items; Undo moves them straight back.
- **Clipboard:** copied files go on the clipboard as a file list and in GNOME's copied-files format, so file managers paste them, and cut items move. Copied host items paste into file managers as real files, downloaded when they're pasted.
- **Show in Files** and **Open with Default App** go through the desktop's file manager and default apps.
- **Get Info** shows and changes permissions, owner and group; macOS's Hidden and Locked flags don't exist on Linux.

### Not on Linux

- Secure Keyboard Entry: the Wayland desktop already keeps other apps from reading what you type.
- Option as Meta: Alt always acts as Meta, as in Linux terminals.

## 12. Windows

The Windows version is the same app as a native Win32 program, with SwiftTerm's terminal engine, Windows' pseudo console (ConPTY) and GDI drawing. It runs on Windows 10 (1809 or later) and Windows 11. Sections 2–10 apply where this section doesn't say otherwise; "Not yet on Windows" lists what it doesn't have.

### Build and packaging

- **Source:** `windows/`, a Swift package built with the Swift toolchain for Windows and Visual Studio's C++ build tools: `windows\dev\build.ps1` (`-Run`, `-SelfTest`, `-Package`). The login-vault code comes from `shared/` (and some from `linux/`), copied in at build time from the list in `windows/shared.txt`. Small modules named `Darwin`, `CryptoKit`, `CommonCrypto` and `SQLite3` give it the same names on Windows (the Universal C runtime, AES-GCM and PBKDF2 on Windows CNG, and the system's `winsqlite3`), so a vault from a Mac opens unchanged.
- **Package:** `-Package` builds one portable `dist\HerbsTerminal.exe` and `dist\Herbs-Terminal-<version>-windows-x86_64.zip` (the exe, the license and the notices). Nothing needs installing, no runtime, and nothing is registered: open the .exe from anywhere. The exe isn't code-signed and there is no installer, so Windows SmartScreen may ask once before a downloaded copy first runs. The app needs the Swift runtime, Foundation and the Microsoft C++ runtime DLLs beside it, so the build first gathers exactly the DLLs it uses in `dist\HerbsTerminal-windows` (it stops if the app would need anything that is neither part of Windows nor in that folder), and a small launcher in C (static C runtime, Windows DLLs only, `windows/launcher`) carries that folder inside itself, compressed with Windows' LZMS. On first run it unpacks it to `%LOCALAPPDATA%\HerbsTerminal\Versions\<version>-<hash>` (into a temporary folder renamed into place, so a copy is complete or absent), removes the copies of older builds, and runs the app there with the same arguments, waiting for it and returning its exit code; later runs start the unpacked copy directly. If it can't unpack or start the app, it says why in a message box. The app and the launcher carry Herb's Terminal's icon in the stock Windows terminal look (a dark window with a title bar and the `> HT_` prompt, `windows/Resources/HerbsTerminal.ico`, drawn by `windows/dev/make_icon_windows.swift`), so the desktop, the taskbar and the window show it. Every package build is also copied to the desktop as `Herb's Terminal.exe`, replacing the older copy (skipped with a warning while that copy is open).
- **Checks:** `HerbsTerminal.exe --self-test` checks the compatibility modules against standard vectors, the vault, ssh command lines, the password helper's pipe, and how dropped paths are quoted. A scripted mode (`--type`, `--drop`, `--ssh`, `--capture` and others, listed in `windows/README.md`) drives the window without touching the desktop and saves pictures of it.

### Shells and SSH

- **Tabs** run PowerShell 7 when it's installed, otherwise Windows PowerShell. Settings ▸ Shell can choose Command Prompt, WSL, Git Bash or any command line instead.
- **New tabs** start in the profile's start folder when it has one, else in the current tab's folder (Settings ▸ Shell ▸ New tabs open in: "Same folder as the current tab", the default, or "Home folder"), as on the Mac; a folder that isn't on this PC (a WSL shell's) falls back to home. A profile's startup command is typed into a new local tab's shell.
- **Closing** a tab or window asks first only when a program is running in it, or an SSH session is open, and names what would end ("Do you want to terminate running processes in this tab?"), as on the Mac; Settings ▸ Ask before closing a tab with running processes turns the question off.
- **SSH runs inside the tab's own shell**, as in section 4. **Connect via SSH** starts the login in the focused terminal when it's a local shell with nothing running (otherwise in a new tab): the app types only the path of a private launcher (a batch file in the app's own folder, run as `"path"` in Command Prompt, `& 'path'` in PowerShell, `cmd.exe /c 'path'` in Git Bash and WSL). The launcher clears its line from the screen (as many rows as the line took), gives Windows' own OpenSSH client (`System32\OpenSSH\ssh.exe`) the password helper's variables when there's a saved password, runs it with the keepalive of section 4 (a host that goes away ends the session within about 15 seconds), and deletes itself; the app also deletes it as soon as ssh is running, and launchers left by a session cut short are removed at the next launch. No command line, password or token appears on screen or in the shell's history.
- **Typed ssh:** an `ssh` typed in any local shell (Command Prompt, PowerShell, Git Bash) is followed the same way: the app sees Windows' ssh start under the tab's shell, resolves its destination with `ssh -G` (aliases, ports and users from `~/.ssh/config`), and connects the tab to it; `ssh -G`, `-O`, `-V` and `-Q` are left alone. The explorer signs in with a saved login for that account when there is one, or with keys and `ssh-agent`.
- **Ending a session:** `exit` in the remote shell, Disconnect, a failed login or a dropped link return the tab, its title and its explorer to this PC, at the shell it started from.
- **Saved passwords:** ssh runs the app's own executable as `SSH_ASKPASS`, which trades the one-time token of section 4 for the password over a named pipe that only this Windows account and SYSTEM may open, and that refuses remote clients. Both the `user@host's password:` and `(user@host) Password:` prompts are answered; every other question (a new host key, a one-time code, a retry) is asked in the terminal.
- **The connected tab** shows its `user@host` as its title, and the SSH button is highlighted; it opens the connection details with New Connection, Close and Disconnect.
- **The title** of a local tab is `user@host`, with the program running in the foreground and its arguments beside it (for example `user@host — ping -n 5 example.com`), passwords and tokens hidden as in section 2; the program is the shell's newest child process. The shell's current folder shows beside the title, with the home folder as `~`. Command Prompt and PowerShell report their folder at every prompt, as Windows Terminal reads it (`ESC ] 9 ; 9 ; "<path>" ESC \`): the app adds that to Command Prompt's `PROMPT` and wraps PowerShell's prompt function after the user's profile has run. Shells that send `ESC ] 7 ; file://…` (WSL, Git Bash) are followed too.

### Window and toolbar

- The toolbar replaces the title bar and is laid out as on Linux: the Main Menu, New Tab and Connect via SSH on the left; the title in the middle; Export Session, Take Screenshot, Show File Explorer, MultiExec, Tailcat Peers and Search on the right, then minimize, maximize and close. Maximize shows Windows 11's snap layouts. Drag an empty part of the toolbar to move the window, and double-click it to maximize.
- The tab strip sits under the toolbar: click to switch, double-click to rename, drag to reorder, middle-click to close, right-click for Rename, Move Left, Move Right and Close.
- The Main Menu is a plain glyph, as on the Mac, with a background only while hovered or pressed. It matches Linux's: the Mac's menus in the Mac's order, Edit, Shell and Window included, plus Manage Logins. Redo is greyed, since Windows' text fields keep a single undo step. Menus, hover hints, Settings, Manage Logins, Get Info and the app's dialogs follow its light or dark appearance (dark frames, fields, lists and buttons in Windows' own dark styles), and colors use the Windows accent color.
- Toolbar buttons never take the keyboard focus from the terminal. Hover hints appear after about half a second with the Mac's wording.

### Shortcuts

The Linux shortcuts of section 11 apply, with Take Screenshot on Ctrl+Alt+S. In the terminal, Ctrl+C copies when text is selected (otherwise it interrupts the program), Ctrl+V pastes. Right-click opens the terminal's menu, as on the Mac and Linux (section 2): Copy, Paste, Paste Escaped Text (Ctrl+Alt+V), Select All (Ctrl+Shift+A), Find…, the Clear and Reset commands, the splits, New Tab, Show File Explorer, Connect via SSH or Disconnect, Bigger, Smaller and Settings. Paste Escaped Text quotes the text for the tab's shell so it's taken literally: single quotes for PowerShell and POSIX shells, and for Command Prompt a caret before each special character (`%` included) with line breaks turned into spaces.

**Find in Terminal** (Ctrl+Shift+F, the toolbar's Search, the Main Menu or the right-click menu) shows a find bar at the top right of the terminal: the search text, Previous (Return), Next (Shift+Return) and Done (Esc), each with a hover hint and a name for screen readers. It finds as you type, ignores case, searches the scrollback, wraps around, and selects and scrolls to the match; it starts from the match nearest the prompt.

### Terminal

- **Dropping files:** files and folders dropped from File Explorer are typed as paths followed by a space, quoted for the tab's shell: single quotes (with `''` inside) for PowerShell, double quotes for Command Prompt, POSIX quoting of the `/mnt/c/…` form for WSL, and POSIX quoting for Git Bash and SSH tabs. Paths without spaces or special characters aren't quoted.
- **Take Screenshot** copies a picture of the whole window to the clipboard; the button shows a check mark for a moment to confirm it.
- **Export Session** saves the terminal's text, scrollback included, as a text file with Windows line endings.

- **Split panes** work as in section 2: Split Vertically (Ctrl+Shift+E) and Split Horizontally (Ctrl+Shift+O) in the Main Menu's Shell submenu, equal shares with a one-pixel hairline between panes, Close Pane (Ctrl+Alt+W) and `exit`, Select Next / Previous Pane (Ctrl+Alt+→ / ←), and the focused pane outlined in Windows' accent color. A new pane starts in the current pane's folder when that's on this PC. Clear, Reset, Export Session and the window title follow the focused pane. The tab's SSH connection and explorer belong to its first pane; when that pane closes its session ends with it (Windows' ssh can't share a connection), and the next pane takes over the tab's number and name.

- **MultiExec** works as in section 7: the toolbar button (highlighted while on), Ctrl+Shift+M or the Shell submenu shows every terminal of the window, split panes included, in a grid under an orange bar ("MultiExec: typing goes to N of M terminals" with New Tab, Connect via SSH…, Include All, Close All and Exit MultiExec). Each terminal has a caption with an include checkbox, its number and its tab's name or host ("3. Terminal 2 (pane 2)"); the bar's buttons and checkboxes are standard Windows controls with hover hints. Typing, pasting and dropping into an included terminal goes to every included terminal; text the app types and the emulator's replies stay in their own terminal. Alt+1–Alt+9 pick a terminal by number, Ctrl+Shift+W closes only the active terminal, and Esc on the bar leaves MultiExec (in a terminal, Esc goes to the program, as on the Mac). Close All asks first and leaves MultiExec with one new terminal; editor tabs stay.

- **Run Command on Hosts** (Shell submenu) works as in section 7, in a window laid out as on the Mac and Linux ("Multi-Host Commands"): the hosts with checkboxes (the tab's live connection first, then every saved login, with Unlock… while saved logins are locked), the command, what will run where, each host's result (✓ exit 0, ✗ exit code, ⚠ not reached with ssh's reason, ■ stopped; duration and output, up to 64 KB per host, longer output marked as truncated), and Stop, Close (Esc) and Run (Ctrl+Enter; Enter makes a new line in the command). Each host runs over its own `ssh -T` started through the explorer's relay, so a saved password reaches ssh only through the password helper; unknown host keys are refused, one password try, no retries, 10 seconds to connect.

- **Profiles** work as in section 3: each tab uses a named profile and new tabs and split panes keep the current one; the Main Menu's Shell submenu has New Tab with Profile and Use Profile (which changes the focused terminal's profile at once). Zoom, the color preset and Restore Defaults change the focused terminal's profile. Settings starts with a Profile section: the profile it edits ("(default)" marks the default), New, Duplicate, Rename…, Delete… (asks first; tabs using it switch to the default) and Use as Default, and the profile's Run command and Start in folder; the Text, Colors and scrollback settings below apply to that profile.

- **Session restore** works as in section 2 (Settings ▸ Shell ▸ "Restore windows and tabs when Herb's Terminal opens", on by default): Quit, closing the last window, and signing out of Windows save each window's terminal tabs with their folder, name, profile, split panes and, for this PC's files, the explorer and its folder; the next launch reopens them. SSH tabs reopen as local shells in the home folder (logins are never replayed), editor tabs aren't reopened, and a folder that no longer exists starts in the home folder. Turning the setting off forgets the saved session.
- **Size badge:** while the terminal's grid changes size (resizing the window or splitting), each pane shows its columns × rows in the middle, in its own font at 18 px on a rounded card, and hides it 1.2 seconds after the last change (Settings ▸ Window ▸ "Show columns × rows while resizing").

- **Tailcat peers** work as in section 8, with Tailscale's own Windows build of tailcat (`tailcat.exe`, BSD-3-Clause, pinned to its published checksum) beside the app. The Tailcat Peers window (the toolbar's peers button) adds a peer (name, username, secret address, One-time or Persistent; addresses protected like saved logins), lists the peers with their pairing and route, and has Ping (Direct or Relayed with the latency), Connect and Remove (asks first) for the selected one; **Share this PC** runs `tailcat serve` for this PC's SSH server, one-time or persistent, with the address, Copy and Stop Sharing, and says to turn on the OpenSSH SSH Server service when nothing answers SSH here. Unlock… / Lock… sits opposite Done. The terminal reaches a peer through ssh's ProxyCommand: the app's helper trades a one-time token for the address and hands it to tailcat's local SOCKS proxy over the loopback socket. Windows' ssh stalls running a ProxyCommand without a terminal, so the explorer and Run Command on Hosts reach the peer through a one-connection loopback port the app forwards through a shared `tailcat socks` instead, keeping the peer's name for its host key. Every tailcat the app starts ends with it. When the explorer has no password for a login (a Tailcat peer, a typed ssh) and keys don't sign in, it asks for the password once.

### Files

- **The explorer** shows this PC's files in a local tab and the host's files in an SSH tab: the toolbar's folder button or Ctrl+Shift+X switches between the tab's shell and its explorer, which keeps its folder while hidden.
- **Hosts:** Windows' OpenSSH can't share the terminal's connection, so the explorer signs in to the tab's host over its own SFTP channel, with the tab's saved password through the password helper (section 4) or with SSH keys and `ssh-agent`. ssh is started by a small relay (the app itself) that receives the one-time token on its input, so the token never appears in a command line or in the app's environment. The channel only accepts a host key the terminal already accepted, and it signs in again once if the connection drops. Places are Home and File System; folders and links to folders open, text files open in the text editor, and for other files the status line explains that Download copies them to this PC. Copy and Paste duplicate items on the host with free " copy" names, Cut and Paste move them, Delete removes items (folders with everything in them) after asking, with Cancel as the default, and New Folder, New File and Rename work as on this PC. Listings and changes run in the background with "Loading…" or "Working…" in the status line.
- **Transfers:** File Actions (and the list's menu) in a host's explorer offer Upload Files… (Windows' Open dialog, several files at once), Upload Folder… (the folder picker) and Download… for the selection (the folder picker chooses where on this PC). Files and folders dropped from File Explorer onto a host's explorer are uploaded; dropped onto this PC's explorer they're copied. The clipboard works across: files copied on this PC (in File Explorer or the app's explorer) and pasted into a host's folder are uploaded, and host items copied in a host's explorer and pasted into this PC's explorer are downloaded; copying host items also puts their paths on the clipboard as text, so copying anything else afterwards replaces them. Folders go with everything in them, and nothing is overwritten: an item whose name is taken arrives as "name copy". Uploads are written under an unguessable temporary name and renamed into place when complete, downloads likewise on this PC, so a cancelled or failed transfer leaves nothing half-written. Transfers run on a second channel to the host, so browsing stays responsive.
- **The transfer strip** appears under the file list while there are transfers: a "Transfers" heading with Clear Finished, and the latest four transfers, each with an arrow (up for uploads, down for downloads), its name, then a progress bar with the bytes so far, "Done", "Cancelled" or the error in red. Cancel (✕) stops a running transfer and discards the partial copy; Retry runs a failed or cancelled one again. Hover hints: Clear Finished — "Remove completed, failed and cancelled transfers from this list."; Cancel — "Stop this transfer and discard the partial copy."; Retry — "Run this transfer again from the start." The location bar's buttons and the places have hover hints too (for example Back — "Back (Alt+←) Go to the folder you were in before.").
- **Places:** Home and the Windows user folders that exist (Desktop, Documents, Downloads, Music, Pictures, Videos), then every drive with its label.
- **Location bar:** back, forward, up and home, an editable location (Ctrl+L) that accepts `~`, relative paths, `.` and `..`, and File Actions (Cut, Copy, Paste, Move to Recycle Bin, Select All, New Folder, New File, Show Hidden Files, Reload). The mouse's back and forward buttons work too.
- **The list:** name, date modified, type and size, with Windows' own icons and type names; folders first, then names in File Explorer's order (`file2` before `file10`). Click a heading to sort by it. Hidden items (Windows' hidden attribute, or a name starting with `.`) show only with Show Hidden Files, faded; the status line counts them.
- **Opening:** double-click or Return opens a folder, a text file in the text editor, or any other file in its usual app (Windows asks which app when there's none). Right-click files for **Open in Text Editor** and **Open With…**, or a folder for **Open in New Terminal Tab**, which starts a shell there.
- **Text editor:** text files open as a tab beside the current one, named after the file (with • while there are unsaved changes); the toolbar shows the file's name and its path or `user@host:path`. Opening a file that's already open selects its tab. "Text" is decided as on Linux: known text extensions (including Windows' own, such as `.ps1`, `.bat`, `.reg` and `.inf`), and files with no extension or an unfamiliar one whose first bytes look like text; on a host, files that aren't known binary types are tried and refused if they turn out binary. New File opens the new file in the editor once its name is chosen (on a host, straight away).
  - **Editing:** the terminal's font (at least 12 points), undo and redo (Ctrl+Z, Ctrl+Y), and Find (Ctrl+F): a bar at the top with the search text, Previous (Shift+Return), Next (Return) and Done (Esc); it finds as you type, ignores case and wraps around. Wrap Lines in the bottom bar is remembered. The status line shows line and column, the line count, the encoding and the line endings.
  - **Saving:** Ctrl+S or Save (dimmed while there's nothing to save). Files keep their encoding (UTF-8, UTF-16 in its own byte order, or Latin-1) and line endings (CRLF, LF or CR). On this PC the file is written beside the original and swapped in with Windows' ReplaceFile, so it keeps its attributes and permissions; on a host it's written in full under a temporary name and renamed into place, keeping its permissions. Links are edited at their target. If the file changed elsewhere since it was opened, saving asks first (Cancel is the default).
  - **Closing:** a tab, the window or the app with unsaved changes asks "Do you want to save the changes?" with Don't Save, Cancel and Save (the default).
  - **Limits:** files larger than 20 MB, and files that look binary, aren't opened; a message explains why.
  - Hover hints: Wrap Lines — "Wrap long lines at the edge instead of scrolling sideways."; Save — "Save (Ctrl+S) Write your changes to the file."; and Find's Previous, Next and Done with their keys.
- **Changing files** goes through the Windows shell, with its progress window for long jobs: copy, move and rename; Delete moves to the Recycle Bin, and Shift+Delete deletes permanently after asking (Cancel is the default). Pasting where a name is taken gets the Mac's "name copy" name ("name copy 2", … before the extension) instead of overwriting, and a folder can't be pasted into itself.
- **Clipboard:** Copy and Cut put files on the clipboard as File Explorer does, so they paste in File Explorer, and files copied there paste here.
- **Creating and renaming:** New Folder and New File ask for the name, as on the Mac, starting with a free "untitled folder" or "untitled" here ("untitled folder" or "untitled.txt" on a host, where a taken name gets the next free one); a new file opens straight in the text editor. F2 renames in place. Names Windows can't use are refused with an explanation.
- **Shortcuts:** as on Linux (Thunar's): Ctrl+C / X / V / A, Delete, Shift+Delete, BackSpace and Alt+← back, Alt+→ forward, Alt+↑ up, Alt+Home home, Ctrl+L location, F5 or Ctrl+R reload, Ctrl+H hidden files, F2 rename, Ctrl+Shift+N new folder, Alt+Return Properties.
- **Undo and Redo:** File Actions holds Undo and Redo (Ctrl+Z, Ctrl+Shift+Z), named after the action (Undo Copy, Undo Move, Undo Rename, Undo New Folder, Undo Move to Recycle Bin). On this PC copies, moves, renames, new items and Move to Recycle Bin can be undone: copies and new items go to the Recycle Bin, moved and renamed items go back under their old names, and recycled items come back from the Recycle Bin to where they were (through the record Windows keeps beside each recycled item, as File Explorer's Restore does). Nothing is overwritten: an item whose old place is taken stays put and a message says why. On a host, moves and renames can be undone. Delete Permanently, and deleting on a host, can't.
- **Bookmarks:** the star at the end of the location bar (Ctrl+D) bookmarks the current folder or takes it out (hover: "Bookmark This Folder (Ctrl+D) — Add it to the side pane's Bookmarks." / "Remove Bookmark (Ctrl+D) — Take this folder out of the side pane's Bookmarks."); right-click a folder for Add Bookmark or Remove Bookmark, and a bookmark in the side pane for Remove Bookmark. Bookmarks show under Places and Devices, kept separately for this PC and for each host, in the same settings Linux uses.
- **Find** (Ctrl+F in the list, File Actions ▸ Find, the toolbar's Search or Ctrl+Shift+F while the explorer shows): a "Filter by name" field under the location bar shows only the items whose name contains the text, ignoring case, as on the Mac and Linux. Return or ↓ moves to the list, Esc or the close button (hover: "Close Find — Show every item in this folder again (Esc).") closes it, and going to another folder closes it too.
- **Rename** (F2 or the right-click menu) edits the name in place in the list, as in File Explorer; Return renames, Esc cancels.
- **File Actions on this PC** lists Upload File/Folder… and Download File/Folder… greyed out, as on the Mac and Linux: they work in a host's explorer.
- **Properties** opens Windows' own Properties window; **Show in File Explorer** opens File Explorer with the item selected; **Copy Path** copies the full path.
- **Get Info on hosts:** in a host's explorer, right-click items and choose **Get Info…** (Alt+Return). A window shows the name, location, kind, size, date modified and permissions (`ls -l` text and octal) for one item, or how many items for several. Below: Owner and Group fields (by name or number), Read, Write and Execute checkboxes for the owner, the group and others (Execute reads "Open" for a folder), Set user ID, Set group ID and Sticky, an Octal field kept in step with the checkboxes, and Apply to enclosed items when folders are selected. Apply (Return) changes only what was edited, on every selected item; Revert reloads the values; Close (Esc). Owner and group names are looked up on the host itself (`id`, `getent` or `dscl`); Windows' OpenSSH can't reuse the tab's connection, so the lookup signs in once more the way the explorer does. Apply to enclosed items works as in section 5: folders inside keep their search permission wherever they're readable, and links inside are left alone. Every control has a hover hint (for example Octal — "The same permissions as chmod takes them, e.g. 644 or 755."). On this PC, Alt+Return opens Windows' Properties instead, since Windows files have no Unix permissions.
- **Administrator mode on hosts:** the lock beside File Actions in a host's explorer (hover: "Administrator Mode — Work as root with sudo on this host: open and change any file. Asks for the sudo password."). It works as in section 5, with one difference: Windows' OpenSSH can't share the tab's connection, so the root channel signs in once more the way the explorer does, then starts the host's own `sftp-server` under `sudo`. The sudo password is asked for in a dialog, checked on its own first (a wrong one is refused with an explanation), and then reaches `sudo -S` once on standard input after the password helper's token line; it's never stored or put in a command line. Accounts with password-free sudo aren't asked. While it's on, every explorer action runs as root (browsing, creating, renaming, copy and move, deleting with section 5's root-only rule, transfers, the text editor, whose tab shows "(root)" in its location, and Get Info), a red bar across the explorer says "Administrator mode: changes are made as root on <host>." with a Leave button, and the lock turns red and reads Leave Administrator Mode. Leaving goes back to the tab's own login in the same folder; it also ends when the tab's SSH session ends. On this PC there is no Administrator mode: run the app as administrator from Windows instead.

### Appearance

- The stock face is Cascadia Mono 11 pt (Consolas where it isn't installed); Settings lists the installed monospaced fonts.
- The color scheme (System, Light, Dark) follows Windows' app mode, title bar included.

## References

| Reference | Used for |
|---|---|
| [macOS Terminal User Guide](https://support.apple.com/guide/terminal/welcome/mac) | Menus, shortcuts and the Basic profile |
| [Ptyxis](https://devsuite.app/ptyxis/) and [iTerm2 documentation](https://iterm2.com/documentation.html) | Terminal features, split panes and profiles |
| [MobaXterm](https://mobaxterm.mobatek.net/features.html) | MultiExec and the SSH-linked explorer |
| [Xfce Thunar](https://docs.xfce.org/xfce/thunar/the-file-manager-window) | File manager navigation and layout |
| [OpenSSH ssh_config](https://man.openbsd.org/ssh_config) | Shared connections, askpass and host routing |
| [Tailcat](https://github.com/tailscale/tailcat) | Peer pairing and relays |
| [Flatpak sandbox permissions](https://docs.flatpak.org/en/latest/sandbox-permissions.html) | Host access for the Linux version |
| [freedesktop.org Trash specification](https://specifications.freedesktop.org/trash-spec/latest/) | The Linux Trash |
| [iTerm2 color presets](https://iterm2.com/documentation-preferences-profiles-colors.html) | The color preset format |
