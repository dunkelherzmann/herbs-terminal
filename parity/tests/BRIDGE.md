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
