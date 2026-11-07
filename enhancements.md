# Enhancements

Every enhancement requested for Herb's Terminal, oldest first. New requests are added at the end and nothing is removed.
A box is ticked once the change has shipped. A request that covers several platforms has a box for each, and its main box is ticked when they're all done.

- [ ] **Take Screenshot button.** A button next to Export Session copies a picture of the whole window to the clipboard, ready to paste. *Requested 2026-11-07.*
  - [x] Mac: camera button and Shift-Cmd-S. Shipped in 1.0.11.
  - [x] Linux: camera button and Ctrl+Alt+S. Shipped in 1.0.25.
  - [ ] Windows: camera button and Ctrl+Alt+S, in #5. Not yet built or tested.
- [x] **Build the Linux version on a real Linux machine.** It's built and tested natively on Aurora (KDE on Wayland), as well as in the Mac's Linux VM. *Requested 2026-11-07.* Shipped in 1.0.25.
- [x] **Get the repository ready to be public.** Personal data was removed from the whole history, the repo was recreated with that clean history, and it was made public. *Requested 2026-11-07.* Done 2026-11-07.
- [x] **Say that the app is provided as is, without support,** in the README and release notes. *Requested 2026-11-07.* Done in the README's Support section and the release notes from 1.0.25.
- [x] **Audit the Linux version against the Mac version** and test it. The findings are in `bugs.md`. *Requested 2026-11-07.* Done 2026-11-07 (#7).
- [x] **Protect the `main` branch** from force pushes and deletion. *Requested 2026-11-07.* Done 2026-11-07 (a "Protect main" ruleset).
- [x] **Typing `exit` in the last terminal quits the app.** With other windows open, it closes just its own window. *Requested 2026-11-07 · Mac, Linux.* Shipped in 1.0.35 (#10). Windows already quit when its last window closed.
- [x] **Keep these trackers:** `enhancements.md` and `bugs.md`, updated as requests come in and as they're done. *Requested 2026-11-07.* Set up in #11.
