# Herb's Terminal parity audit: macOS Terminal, Ptyxis, iTerm2

> **Superseded** by [2026-11-04-feature-audit.md](2026-11-04-feature-audit.md), which adds MobaXterm and the owner's own feature requests.

**Audited 4 November 2026 against commit `8ad61d4`; updated the same day after the first gap-closing pass** (rename to Herb's Terminal, tabs, session restore, transparency, close/quit confirmation, new folder/rename, transfer retry). The requirement in [SPECIFICATION.md](../SPECIFICATION.md) is that Herb's Terminal at minimum matches the everyday functionality of macOS Terminal and Ptyxis. iTerm2 is included as the upper bound for power features, not as a requirement.

**Method.** Herb's Terminal was checked by reading the code, running the 55-test suite, and driving the app (menus, right-click, toolbar, panels, a live SSH session to a ZimaOS host). The reference apps were compared from their documented feature sets: macOS Terminal 2.14 on macOS 15/26, Ptyxis 46–48 (GNOME, VTE), and iTerm2 3.5/3.6. "Partial" means part of the behavior is present and the missing part is named.

**Legend:** ✅ present · ◐ partial · ✗ missing · — not offered by that app.

## Summary

| Area | vs Terminal | vs Ptyxis | vs iTerm2 |
|---|---|---|---|
| Core emulation and text | ◐ | ◐ | ◐ |
| Tabs, windows and panes | ◐ (close to ✅) | ◐ | ✗ (no panes) |
| Profiles and appearance | ◐ (close to ✅) | ◐ | ◐ |
| Keyboard and input | ◐ | ◐ | ◐ |
| Search, selection and clipboard | ✅ | ✅ | ◐ |
| Session management | ◐ (restore, no marks) | ◐ | ✗ |
| Remote work (SSH, files, desktop) | ✅ ahead | ✅ ahead | ✅ ahead |

Herb's Terminal is already **ahead of all three** at remote work: a verified SSH session per tab, a Thunar-style explorer that follows it, SFTP transfers, multi-host commands, Tailcat and remote desktop. It is **behind Terminal and Ptyxis** on everyday terminal structure: multiple profiles, split panes, window-close confirmation, session restore, transparency, and marks. Those are the gaps to close to meet the stated minimum.

## 1. Core emulation and text

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| xterm-256color, truecolor | ✅ | ✅ | ✅ | ✅ | SwiftTerm; `TERM=xterm-256color`, `COLORTERM=truecolor` |
| Mouse reporting (vim, htop) | ✅ | ✅ | ✅ | ✅ | SwiftTerm |
| Font choice and size | ✅ | ✅ | ✅ | ✅ | Any monospaced font, 6–72 pt |
| Bold / bright-bold options | ✅ | ✅ | ✅ | ✗ | No "use bright colors for bold" setting |
| Ligatures | — | ✅ (VTE) | ✅ | ✗ | |
| Line and character spacing | ✅ | ✅ | ✅ | ✗ | |
| Unicode width (East Asian ambiguous) | ✅ | ✅ | ✅ | ✗ | No setting |
| Cursor shape and blink | ✅ | ✅ | ✅ | ✅ | |
| Bell: audible, visual, off | ✅ | ✅ | ✅ | ✅ | |
| Bell badge / dock bounce on background activity | ✅ | ◐ | ✅ | ✗ | |
| Scrollback length | ✅ (incl. unlimited) | ✅ | ✅ | ◐ | 100–1,000,000; no "unlimited" |
| Inline images (sixel / iTerm / kitty) | — | ◐ (sixel builds) | ✅ | ◐ | SwiftTerm supports them; not verified in Herb's Terminal |
| Progress reporting (OSC 9;4) | ◐ | ✅ | ✅ | ✗ | |
| Secure Keyboard Entry | ✅ | — | ✅ | ✅ | |

## 2. Tabs, windows and panes

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| Tabs with independent shells | ✅ | ✅ | ✅ | ✅ | Own tab strip; macOS window tabbing disabled |
| New tab in same folder | ✅ | ✅ | ✅ | ✅ | Read from the shell process |
| Next/previous tab shortcuts | ✅ | ✅ | ✅ | ✅ | ⇧⌘[ / ⇧⌘] |
| Select tab by number (⌘1…⌘9) | ✅ | ✅ (Alt+n) | ✅ | ✅ | |
| Rename tab / custom title | ✅ | ✅ | ✅ | ✅ | Double-click, right-click, ⇧⌘I |
| Reorder tabs by drag | ✅ | ✅ | ✅ | ✅ | Drag, or Move Tab Left/Right |
| Move tab to new window / merge windows | ✅ | ✅ | ✅ | ✗ | |
| Tab overview (grid of tabs) | ✅ (Show All Tabs) | ✅ | ◐ | ✗ | |
| Pinned tabs | — | ✅ | — | ✗ | |
| Multiple windows | ✅ | ✅ | ✅ | ✅ | |
| Split panes inside a tab | ◐ (one split of the same session) | — | ✅ | ✗ | Herb's Terminal's Split View is terminal + explorer |
| Confirm before closing a tab with processes | ✅ | ✅ | ✅ | ✅ | |
| Confirm before closing a window / quitting | ✅ | ✅ | ✅ | ✅ | |
| Full screen | ✅ | ✅ | ✅ | ✅ | |
| Hotkey / drop-down window | — | — | ✅ | ✗ | Power feature |
| Window size in rows × columns | ✅ | ✅ | ✅ | ◐ | Points, not rows × columns |

## 3. Profiles and appearance

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| Multiple named profiles | ✅ | ✅ | ✅ | ✅ | Per tab; New Tab with Profile, Use Profile |
| Per-profile command / shell | ✅ | ✅ | ✅ | ◐ | Startup command and start folder; same login shell |
| Per-profile container default | — | ✅ | — | — | Linux-specific; not applicable on macOS |
| Built-in color schemes | ✅ (10+ profiles) | ✅ (palettes) | ✅ | ✅ | Basic plus six palettes |
| Import color schemes | ◐ (.terminal) | ✅ | ✅ (.itermcolors) | ✅ | .itermcolors |
| Export settings / profiles | ✅ | — | ✅ | ✗ | |
| Light / dark / system | ✅ | ✅ | ✅ | ✅ | |
| Background transparency / blur | ✅ | ✅ | ✅ | ✅ | 20–100% opacity, optional blur; not yet checked visually |
| Background image | — | — | ✅ | ✗ | Power feature |
| Minimum contrast enforcement | — | — | ✅ | ✗ | Power feature |
| Title content options (process, cwd, size) | ✅ | ◐ | ✅ | ◐ | Fixed legend; credentials redacted |

## 4. Keyboard and input

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| Option as Meta | ✅ | — (Alt is Meta) | ✅ | ✅ | Off by default, as in Terminal |
| Font zoom ⌘+ / ⌘− / ⌘0 | ✅ | ✅ | ✅ | ✅ | Saved per profile across sessions |
| Clear to Start ⌘K, Clear Scrollback ⌥⌘K | ✅ | ◐ | ✅ | ✅ | |
| Soft / hard reset | ✅ | ✅ | ✅ | ✅ | |
| Custom key bindings | ✅ | ✅ | ✅ | ✗ | |
| Option-click to move the cursor | ✅ | — | ✅ | ✗ | |
| Natural text-editing keys (⌥←/→, ⌘←/→) | ◐ | ✅ | ✅ | ◐ | Depends on Option as Meta; no presets |
| Paste escaped text | ✅ | — | ✅ | ✅ | |
| Bracketed paste | ✅ | ✅ | ✅ | ✅ | SwiftTerm |

## 5. Search, selection and clipboard

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| Find in scrollback | ✅ | ✅ | ✅ | ✅ | |
| Regex search | — | ✅ | ✅ | ◐ | SwiftTerm find bar; regex not verified |
| Copy, paste, select all | ✅ | ✅ | ✅ | ✅ | |
| Right-click context menu | ✅ | ✅ | ✅ | ✅ | |
| Cmd/Ctrl-click URLs | ✅ | ✅ | ✅ | ◐ | SwiftTerm default handling; not verified |
| Open files and paths from output | ◐ | — | ✅ (semantic history) | ✗ | |
| Rectangular selection | ✅ (⌥-drag) | — | ✅ | ◐ | Not verified |
| Copy on select | — | — | ✅ | ✗ | |
| Drag files in as paths | ✅ | ✅ | ✅ | ✅ | |

## 6. Session management and output

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| Restore windows and tabs at relaunch | ✅ | ✅ (saved sessions) | ✅ | ✅ | Folders, layouts, names; remote tabs reopen local |
| Restore scrollback | ✅ | ◐ | ✅ | ✗ | |
| Marks and bookmarks, jump between prompts | ✅ | ◐ (prompt navigation) | ✅ | ✗ | |
| Inspector (processes, size, title) | ✅ | ✅ (terminal inspector) | ✅ | ✗ | |
| Save / print scrollback | ✅ | ◐ | ✅ | ✗ | |
| Session logging | — | — | ✅ | ✗ | |
| Notify when a background command finishes | — | ✅ | ✅ | ✗ | |
| Shell integration (cwd, command status) | ◐ | ✅ | ✅ | ◐ | OSC 7 title only; no integration script |
| Per-tab process isolation | — | ✅ (cgroups) | — | — | Linux-specific |

## 7. Remote work (Herb's Terminal's own scope)

| Feature | Terminal | Ptyxis | iTerm2 | Herb's Terminal | Notes |
|---|---|---|---|---|---|
| New Remote Connection dialog | ✅ (ssh, sftp) | — | ◐ (profiles) | ✅ | Saved logins, port, one-time use |
| Saved logins | ◐ (server list, no passwords) | — | ✅ (password manager) | ✅ | Administrator Password vault |
| Verified per-tab SSH state | — | — | ◐ (shell integration) | ✅ | Shared connection, attach and detach |
| Typed `ssh` attaching tools | — | — | ◐ | ✅ | zsh and bash shell integration |
| File explorer following the host | — | — | — | ✅ | Thunar-style, local and remote |
| SFTP upload / download | ◐ (sftp in terminal) | — | ◐ (scp via shell integration) | ✅ | Progress, cancel, Retry, staged uploads |
| Remote editing round trip | — | — | — | ✗ | Code exists, not wired to the UI |
| Broadcast / multi-host commands | — | — | ✅ (broadcast input) | ✅ | MultiExec grid with broadcast typing (as MobaXterm); Run Command on Hosts |
| NAT traversal route (Tailcat) | — | — | — | ◐ | Built; not tested live |
| Remote desktop | — | — | — | ◐ | VNC/RDP over SSH into system viewers |
| tmux integration | — | — | ✅ | ✗ | Power feature |
| Containers (Toolbox, Distrobox, Podman) | — | ✅ | — | ✗ | Ptyxis's core feature; see below |

## Gaps to close, in priority order

**Required to meet the Terminal / Ptyxis minimum**

Closed in the first pass: session restore, window and quit confirmation, transparency and blur, ⌘1–⌘9, rename and reorder tabs.

1. ~~Multiple profiles~~ — done (font, colors, zoom, command, start folder, default).
2. ~~Restore windows and tabs~~ — done.
3. ~~Confirm before closing a window or quitting~~ — done.
4. ~~Background transparency and blur~~ — done.
5. **Tab management, remainder:** move a tab to a new window, merge windows, a tab overview (Terminal, Ptyxis).
6. **Marks and prompt navigation** (⌘↑/⌘↓ between prompts) and an **inspector** (Terminal, Ptyxis).
7. **Verify, then fix where needed:** cmd-click URLs, rectangular selection, regex find and inline images. SwiftTerm supports them, but Herb's Terminal hasn't been checked.
8. **Custom key bindings** and **option-click to move the cursor** (Terminal).
9. **Text options:** bright colors for bold, line spacing, Unicode ambiguous width, unlimited scrollback; window size in rows × columns (Terminal).
10. **Export and import of settings** (Terminal).
11. **Background command notifications and progress (OSC 9;4)** (Ptyxis).

**Ptyxis's container integration** discovers Toolbox, Distrobox and Podman containers and opens tabs inside them. It is Linux-specific and has no direct macOS equivalent. The closest Mac counterpart would be opening tabs inside local Docker or OrbStack containers, or Linux VMs. That is a scope decision, not a parity gap.

**Worth taking from iTerm2 later** (beyond the stated minimum): split panes with independent sessions, a hotkey window, semantic history (cmd-click files), copy on select, session logging, tmux integration and triggers.

**The app's own open items** (from the spec): reconnect after a drop, remote editing in the UI, drag-and-drop transfers and resume, and live validation of Tailcat and remote desktop. Typed `ssh` following, new folder, rename and transfer Retry are done.

## Sources

- [Ptyxis on GitHub](https://github.com/taoky/ptyxis) and [Flathub listing](https://flathub.org/el/apps/app.devsuite.Ptyxis)
- [It's FOSS: Ptyxis terminal features](https://itsfoss.com/ptyxis-terminal-features.md)
- [macOS Terminal User Guide](https://support.apple.com/guide/terminal/welcome/mac)
- [iTerm2 documentation](https://iterm2.com/documentation.html)
