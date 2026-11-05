# Herb's Terminal feature audit

**Audited 4 November 2026** against the working tree after commit `d92bcca` (branch `feat/explorer-actions-terminal-settings`, plus the uncommitted Administrator mode). It replaces [the earlier parity audit](2026-11-04-terminal-parity-audit.md).

It answers two questions:
1. **Your requests:** has everything you asked for been delivered?
2. **Other apps:** how does Herb's Terminal compare with macOS Terminal, Ptyxis, MobaXterm and iTerm2?

**Method.** Herb's Terminal was checked against its code, the 75-test suite, and runs of the app. Each item says whether it was verified in the app, by tests, or only built. The four reference apps are compared from their documented feature sets: macOS Terminal 2.14, Ptyxis 46–48, MobaXterm 24/25 (Windows), and iTerm2 3.5/3.6. They weren't run side by side.

**Legend:** ✅ present · ◐ partial · ✗ missing · — not offered by that app.

## Summary

- **Your requests:** 31 of 34 are delivered. Three are partial, and each has a named gap: Tailcat and remote desktop haven't been exercised live, the old Keychain logins were lost during testing, and "at least Terminal and Ptyxis" isn't met yet.
- **Ahead of all four apps:**
  - a verified SSH session per tab, with the explorer following both typed and GUI logins,
  - Administrator mode (sudo) in the explorer, locally and remotely,
  - Tailcat routing,
  - an Administrator Password vault.
- **On par with MobaXterm:** MultiExec, the SSH-following file browser, and the session-and-explorer split.
- **Behind Terminal and Ptyxis** (the stated minimum), five gaps remain:
  1. ~~split panes within a tab~~ — done after this audit,
  2. moving a tab to another window, and a tab overview,
  3. marks and prompt navigation,
  4. an inspector,
  5. custom key bindings.

  Cmd-click links, regex find and inline images are also unverified.
- **Behind MobaXterm:**
  - remote editing,
  - drag-and-drop transfers,
  - a sessions sidebar,
  - SSH tunnels,
  - more protocols (RDP/VNC embedded, Telnet, Mosh, serial, X11),
  - macros.

## Part 1 — Your requests

| # | You asked for | Status | Evidence / notes |
|---|---|---|---|
| 1 | Toolbar visible with one tab | ✅ | Pixel regression test; verified in app |
| 2 | Thunar-style navigation (local) | ✅ | Back/forward, up, home, path bar, ⌘L location, Places/Devices/Bookmarks, hidden files; tests + app |
| 3 | Remove the side-pane toggle | ✅ | Places always shown (narrowed or hidden only when a pane is too small) |
| 4 | Action menu replacing "create file": Upload/Download, Undo, Redo, Cut, Copy, Paste, Delete, Select All, Find, with shortcuts | ✅ | Keys work and don't steal terminal ⌘C/⌘V (verified in app). Upload/Download are disabled in a local tab by design: they need an SSH connection |
| 5 | Font size up/down like stock Terminal | ✅ | ⌘+ / ⌘− / ⌘0, View menu |
| 6 | SSH button right of New Tab | ✅ | |
| 7 | Hover bubble explaining every element | ✅ | Custom bubble, ~0.45 s, also in the title bar and when the app is in the background; menu items use native tooltips |
| 8 | Customizable font, size, window size, colors (as Ptyxis/iTerm2) | ✅ | Settings ▸ Profiles/Text/Terminal/Window/Colors; built-in palettes and .itermcolors import |
| 9 | SSH "No route to host" fixed | ✅ | Local Network usage description and bundle signing; verified against 192.0.2.10 |
| 10 | Multi-host, Tailcat and remote control working | ◐ | MultiExec verified in app. Tailcat (pair, ping, connect, share) and remote desktop (VNC/RDP over SSH) are built and unit-tested, not exercised live |
| 11 | Hide the askpass/ssh command line | ✅ | One-shot launcher erases its line; verified with your saved login |
| 12 | Right-click menu in the terminal | ✅ | Verified in app |
| 13 | Remote explorer looks like Thunar | ✅ | Same sidebar, rows, Home, bookmarks; symlinked folders open as folders |
| 14 | SSH button shows connection details and Disconnect when connected | ✅ | Connection panel; Disconnect verified |
| 15 | At least the features of Ptyxis and stock Terminal | ◐ | See Part 2: tab moving/overview, marks, inspector, key bindings still missing (split panes done) |
| 16 | Fully self-contained, no external dependencies | ✅ | Bundled `tailcat`; helpers are the app's own binary; only macOS components otherwise. RDP viewing needs Microsoft's Windows App |
| 17 | Logins encrypted with an Administrator Password, not the Keychain | ✅ | PBKDF2-SHA256 + AES-GCM; tests confirm nothing readable on disk |
| 18 | "Manage Logins" with Create/Modify Admin Password, Import, Export | ✅ | |
| 19 | First-use explanation about the Administrator Password and plain-text risk | ✅ | Shown on first SSH use or first Manage Logins click; plain text needs a second confirmation |
| 20 | Remove all Keychain code | ✅ | Nothing calls the Keychain. Your two Keychain-era saved logins were deleted during my testing and can't be recovered |
| 21 | Rename to Herb's Terminal | ✅ | Modules, bundle, executable, bundle ID; settings and data migrated |
| 22 | Close the audit gaps | ◐ | Profiles, session restore, tabs, close/quit confirmation, transparency, new folder/rename, retry, typed-ssh following done; see Part 2 |
| 23 | ⌘+/⌘− size persists across sessions | ✅ | Saved per profile |
| 24 | Terminal Theme ▸ Restore Defaults under Import | ✅ | Resets font, size, zoom, cursor, colors, transparency, appearance |
| 25 | Explorer follows a typed `ssh` | ✅ | zsh/bash shell integration; tests with real shells. Not yet tried through a real login to your server |
| 26 | Window widens for Split View | ✅ | Doubles width; verified 1200 → 2400 |
| 27 | GUI SSH "path too long for Unix domain socket" fixed | ✅ | Sockets in `/tmp/herbs-<uid>` (checked private); test asserts the 104-byte limit |
| 28 | Split View: Places not cut off, equal panes | ✅ | Verified at 1200 and 2400 points |
| 29 | Columns × rows shown while resizing (with a toggle) | ✅ | Badge over the terminal; Settings ▸ Window |
| 30 | Double-click the title to return to default size | ✅ | Verified in app |
| 31 | Make the current window/font size the default | ✅ | Right-click the title ▸ Make Current Size the Default (my reading of the request) |
| 32 | Multi-host like MobaXterm's MultiExec | ✅ | Grid, captions, include checkboxes, broadcast typing; verified with three shells |
| 33 | sudo in the explorer, local and remote | ✅ | Administrator mode; tested with a sudo stand-in, and the in-app flow up to the password prompt. Not yet run with a real sudo password |
| 34 | Spec kept current; audits | ✅ | SPECIFICATION.md and this document |

## Part 2 — Comparison with macOS Terminal, Ptyxis, MobaXterm and iTerm2

### Core terminal

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| xterm-256color, truecolor, mouse reporting | ✅ | ✅ | ✅ | ✅ | ✅ |
| Font, size, cursor shape/blink | ✅ | ✅ | ✅ | ✅ | ✅ |
| Zoom ⌘+ / ⌘− / ⌘0 | ✅ | ✅ | ✅ | ✅ | ✅ saved per profile |
| Bright colors for bold, line spacing, ligatures | ✅ | ✅ | ◐ | ✅ | ✗ |
| Unicode ambiguous-width option | ✅ | ✅ | ◐ | ✅ | ✗ |
| Scrollback length | ✅ (unlimited) | ✅ | ✅ | ✅ | ◐ 100–1,000,000, no unlimited |
| Bell audible/visual/off | ✅ | ✅ | ✅ | ✅ | ✅ |
| Option as Meta | ✅ | — | — | ✅ | ✅ |
| Secure Keyboard Entry | ✅ | — | — | ✅ | ✅ |
| Clear to Start / Clear Scrollback / Reset / Hard Reset | ✅ | ◐ | ◐ | ✅ | ✅ |
| Inline images (sixel/iTerm/kitty) | — | ◐ | ✗ | ✅ | ◐ supported by SwiftTerm, unverified |
| Progress reporting (OSC 9;4) | ◐ | ✅ | ✗ | ✅ | ✗ |

### Tabs, windows, panes

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| Tabs, ⌘1–9, next/previous | ✅ | ✅ | ✅ | ✅ | ✅ |
| Rename and reorder tabs | ✅ | ✅ | ✅ | ✅ | ✅ |
| New tab in same folder | ✅ | ✅ | ✅ | ✅ | ✅ |
| Move tab to another window / merge | ✅ | ✅ | ✅ (detach) | ✅ | ✗ |
| Tab overview | ✅ | ✅ | — | ◐ | ✗ (MultiExec grid shows all tabs, but as a broadcast mode) |
| Split panes inside a tab | ◐ | — | ✅ (2/4-way) | ✅ | ✅ nested, ⌘D / ⇧⌘D; equal sizes, no dragging yet |
| Broadcast typing to many sessions | — | — | ✅ MultiExec | ✅ | ✅ MultiExec grid with include toggles |
| Confirm close tab / window / quit | ✅ | ✅ | ✅ | ✅ | ✅ |
| Restore windows and tabs | ✅ | ✅ | ✅ (sessions) | ✅ | ✅ folders, layouts, names, profiles |
| Restore scrollback | ✅ | ◐ | — | ✅ | ✗ |
| Columns × rows while resizing | ✅ (title) | ✅ | ✗ | ✅ | ✅ badge, toggle |
| Double-click title to reset size | — | — | — | — | ✅ (your request) |
| Hotkey / drop-down window | — | — | ✗ | ✅ | ✗ |

### Profiles and appearance

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| Multiple named profiles | ✅ | ✅ | ✅ (per session) | ✅ | ✅ |
| Per-profile startup command / folder | ✅ | ✅ | ✅ | ✅ | ✅ |
| Built-in and imported color schemes | ✅ | ✅ | ✅ | ✅ | ✅ 7 built-in, .itermcolors import |
| Transparency and blur | ✅ | ✅ | ◐ | ✅ | ✅ (not yet checked visually) |
| Export/import settings | ✅ | — | ✅ | ✅ | ✗ |
| Restore theming defaults | ◐ | ◐ | ◐ | ◐ | ✅ including zoom |

### Input, search, selection

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| Find in scrollback | ✅ | ✅ | ✅ | ✅ | ✅ |
| Regex find | — | ✅ | ◐ | ✅ | ◐ unverified |
| Right-click menu | ✅ | ✅ | ✅ | ✅ | ✅ |
| Cmd-click URLs | ✅ | ✅ | ✅ | ✅ | ◐ SwiftTerm default, unverified |
| Drop files as paths | ✅ | ✅ | ✅ | ✅ | ✅ |
| Paste escaped text | ✅ | — | — | ✅ | ✅ |
| Custom key bindings | ✅ | ✅ | ✅ | ✅ | ✗ |
| Option-click moves cursor | ✅ | — | — | ✅ | ✗ |
| Copy on select | — | — | ✅ | ✅ | ✗ |

### Session management and output

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| Marks / jump between prompts | ✅ | ◐ | ✗ | ✅ | ✗ |
| Inspector (processes, size, title) | ✅ | ✅ | ◐ | ✅ | ✗ |
| Save/print scrollback, session logging | ✅ | ◐ | ✅ | ✅ | ✗ |
| Notify when a background command ends | — | ✅ | ✗ | ✅ | ✗ |
| Shell integration | ◐ | ✅ | ◐ | ✅ | ◐ ssh following only (zsh, bash) |
| Macros (record/replay keystrokes) | — | — | ✅ | ◐ (triggers, snippets) | ✗ |

### Remote work

| Feature | Terminal | Ptyxis | MobaXterm | iTerm2 | Herb's Terminal |
|---|---|---|---|---|---|
| New Remote Connection dialog | ✅ | — | ✅ | ◐ | ✅ |
| Saved logins / session manager | ◐ | — | ✅ sessions sidebar with folders | ✅ password manager | ◐ encrypted logins in Connect sheet; no sidebar or folders |
| Master password for saved credentials | — | — | ✅ | ✅ | ✅ Administrator Password |
| Verified per-tab SSH state, connection details, Disconnect | — | — | ◐ | ◐ | ✅ |
| File browser following the SSH session | — | — | ✅ | — | ✅ GUI and typed ssh |
| File operations (new, rename, delete, copy/move) remote | — | — | ✅ | — | ✅ with undo for moves |
| Upload/download with queue | — | — | ✅ | ◐ | ✅ progress, cancel, Retry, staged uploads |
| Drag-and-drop transfers | — | — | ✅ | ◐ | ✗ |
| Resume interrupted transfers | — | — | ◐ | — | ✗ |
| Edit remote file in a local editor | — | — | ✅ MobaTextEditor | — | ✗ (staging code exists, not wired) |
| sudo / root file access in the browser | — | — | ✗ | — | ✅ Administrator mode, local and remote |
| Reconnect after a drop | — | — | ✅ ("R to restart") | ◐ | ✗ |
| SSH tunnels GUI | — | — | ✅ MobaSSHTunnel | ◐ | ◐ only for remote desktop |
| Remote desktop | — | — | ✅ embedded RDP/VNC | — | ◐ VNC/RDP over SSH in the system viewers |
| NAT traversal without public SSH (Tailcat) | — | — | — | — | ✅ built, not tested live |
| Containers (Toolbox/Distrobox/Podman) | — | ✅ | ◐ (WSL, Docker) | — | ✗ (Linux-specific) |
| Telnet, Mosh, serial, X11 server | — | — | ✅ | — | ✗ |
| Multi-host non-interactive run with per-host results | — | — | ◐ | — | ✅ Run Command on Hosts |

## What to close next

**To meet the Terminal / Ptyxis minimum:**
1. ~~Split panes inside a tab~~ — done (resizing panes by dragging remains).
2. Move a tab to another window, merge windows, and a tab overview.
3. Marks and prompt navigation (⌘↑/⌘↓), via shell integration.
4. Inspector: processes, size, title, working folder.
5. Custom key bindings, and Option-click to move the cursor.
6. Text options: bright colors for bold, line spacing, unlimited scrollback, ambiguous width.
7. Export and import of settings and profiles.
8. Check, and fix where needed: cmd-click links, regex find, inline images.

**From MobaXterm, the closest match to how you use Herb's Terminal:**
1. Edit a remote file in a Mac editor and save it back (the staging code exists).
2. Reconnect a dropped session with one key, as MobaXterm's "Press R to restart session" does.
3. Drag and drop between Finder and the remote explorer, with resume.
4. A sessions sidebar with folders, built on the saved logins.
5. An SSH tunnel manager (local, remote and dynamic forwards).
6. Macros. Telnet, Mosh, serial and X11 are a larger scope decision.

**Live checks still owed:**
- typed `ssh` and Administrator mode with your real passwords,
- Tailcat across two networks,
- remote desktop on macOS and Windows hosts,
- transparency and blur visually.
