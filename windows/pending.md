# Windows: closing the gap with the Mac and Linux versions

What the Windows version still needs so it works 1:1 like the Mac and Linux versions, in the order it's being
built. Each item names the `SPECIFICATION.md` section it follows and lands in its own pull request, stacked on the
one before. An item is ticked when its PR is open, built and tested on Windows, with the PR number; the
project's `enhancements.md` and `bugs.md` stay the record of requests and releases.

## To build

- [x] **1. File explorer, this PC's files** (#17) (§5, §12). Places, location bar with back / forward / up / home and
      an editable location, the file list, opening items, Copy / Cut / Paste shared with File Explorer, Recycle
      Bin, rename, New Folder / New File, hidden files, Properties, Open in New Terminal Tab, and the terminal ⇄
      explorer switch (toolbar button, Ctrl+Shift+X).
- [x] **2. File explorer, hosts** (#18) (§4, §5): browse the SSH tab's host over SFTP (Windows OpenSSH has no
      `ControlMaster`, so the explorer opens its own session with the saved password), Home and File System
      places, rename, delete, New Folder / New File, copy and move on the host.
- [x] **3. Transfers** (#19) (§5): upload and download files and folder trees, the progress strip with Cancel and
      Retry, staged uploads, new names instead of overwriting; copy between this PC and a host with the clipboard.
- [x] **4. Text editor** (#20) (§5): open text files as a tab, Find, Wrap Lines, status line, encodings and line endings
      kept, Save locally and to hosts, unsaved-changes prompts.
- [x] **5. Get Info on hosts** (#21) (§5): permissions, owner and group, Apply to enclosed items.
- [x] **6. Administrator mode on hosts** (#PR) (§5): SFTP under `sudo` over the tab's connection, the red bar.
- [ ] **7. Undo and Redo** in the explorer (§5), and bookmarks per host.
- [ ] **8. Split panes** (§2): Split Vertically / Horizontally, Close Pane, Next / Previous Pane, the focused
      pane outline.
- [ ] **9. MultiExec** (§7): every terminal in a grid, typing into all of them, include / leave out.
- [ ] **10. Run Command on Hosts** (§7).
- [ ] **11. Find in Terminal** (§2), the terminal's right-click menu, Paste Escaped Text.
- [ ] **12. Named profiles** (§3): New Tab with Profile, Use Profile, editing profiles in Settings.
- [ ] **13. Session restore** (§2) and the size badge while resizing.
- [ ] **14. Following an `ssh` typed in a local tab** (§4), and the explorer following that host.
- [ ] **15. Tailcat peers** (§8): pairing, sharing, connecting through Tailcat, the Lock / Unlock button.
- [ ] **16. Accessibility** (§9): UI Automation names for the toolbar, tabs and terminal.
- [ ] **17. Dark mode for Settings and dialogs**, mouse reporting for full-screen programs, IME composition.
- [ ] **18. App icon, MSIX installer and code signing** (§1).

## Done

- [x] Terminal with tabs, ConPTY, colors, scrollback, selection, copy and paste (#1)
- [x] Settings (#2)
- [x] SSH with saved logins and Manage Logins (#3)
- [x] Toolbar, Main Menu and tab strip laid out as on Linux; self-contained package (#4)
- [x] SSH keepalive, Take Screenshot, toolbar spacing (#5)
- [x] Dropping files on the terminal types their paths (#15)
