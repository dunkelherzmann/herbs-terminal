# Test bridge: what differs between platforms

Read this before writing a feature test; each point cost a rerun once.

- **Dialog responses:** button titles on the Mac and Windows ("Don't Save"), ids on Linux ("discard"). Match both,
  or use `pick(responses, words…)` in suite.py.
- **Order and default:** the Mac lists alert buttons by position, not in the order they were added, and reports
  `default` (the button Return presses, or null: macOS gives an alert with a destructive button no default).
  Linux and Windows list them in the order added, the default first.
- **Paths:** the Mac reports the explorer's folder with symlinks resolved (`/private/var/…`); Windows uses `\`.
- **Files written by tests:** open text files with `newline="\n"` (Windows would write `\r\n`).
- **Answers that never arrive** ("no answer in 10 s") are usually the bridge, not the app: every bridge now answers
  with an error when its result isn't valid JSON (send `NSNull()`, never an empty optional), and nothing may read a
  window's widgets after closing it.
- **Open and save dialogs:** call `choose-file` first; the next dialog answers with that path without showing.
- **Reruns:** after changing only `parity/tests`, run `all.sh … --no-build`.
- **Fault injection on the test host:** the three machines run at the same time against the same test account, so
  anything done to the host must be scoped to this client's own connections (`silence_test_host` matches the
  session's `SSH_CLIENT` address and uses a chain of its own), and must undo itself on a timer on the host.
  The kernel's owner match doesn't see the account: the root listener creates the sockets.

**Linux helpers in test copies.** ssh on the host runs the app's helpers (askpass, the Tailcat proxy). The installed app's helper command is `flatpak run org.herbsterminal.app`, which would run the installed version, so a test copy takes `HERBS_PARITY_HELPER` instead: a wrapper (`bridge.py`, `helper()`) that runs the build with `flatpak build`. Unlike `flatpak run`, `flatpak build` passes on neither the environment nor /dev/tty, and the scene shell's HOME hides the user's runtimes, so the wrapper adds `--env=` for the helper's variables, points its error output at the terminal and sets `FLATPAK_USER_DIR`.
