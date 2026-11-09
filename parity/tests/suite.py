"""The feature tests: one or more checks per feature in parity/features.md, the same on every platform.

Each test gets a fresh app (`Context`) and ends in one outcome:
  works      every expectation held;
  broken     the feature is there but an expectation failed (the detail says what was seen);
  missing    the platform has no such command, or it's greyed out where the Mac's isn't;
  unverified the feature can't be checked automatically yet (the reason says why), so a person must try it.
Tests registered with `manual` don't start the app.
"""
import os
import time

import bridge as bridge_module

TESTS = {}      # feature id -> list of (title, function or reason)


class Outcome(Exception):
    def __init__(self, status, detail=""):
        super().__init__(detail)
        self.status, self.detail = status, detail


def test(fid, title):
    def register(function):
        TESTS.setdefault(fid, []).append((title, function))
        return function
    return register


def manual(fid, title, reason):
    TESTS.setdefault(fid, []).append((title, reason))


class Context:
    def __init__(self, app):
        self.app, self.bridge, self.platform = app, app.bridge, app.platform
        self.notes = []

    # State
    def state(self):
        return self.bridge.call("state")

    def window(self, state=None):
        windows = (state or self.state())["windows"]
        if not windows:
            raise Outcome("broken", "no window is open")
        return windows[-1]

    def tabs(self, state=None):
        return self.window(state)["tabs"]

    def tab(self, state=None):
        return next(t for t in self.tabs(state) if t["selected"])

    def panes(self, state=None):
        return self.tab(state)["panes"]

    def pane(self, state=None):
        panes = self.panes(state)
        return next((p for p in panes if p["focused"]), panes[0] if panes else None)

    def text(self, state=None):
        pane = self.pane(state)
        return pane["text"] if pane else ""

    # Acting
    def command(self, name, settle=0.8):
        result = self.bridge.call("command", name=name)
        if result == "unsupported":
            raise Outcome("unverified", f"this platform's test bridge can't run `{name}` yet")
        if result == "missing":
            raise Outcome("missing", f"no `{name}` command")
        if result == "disabled":
            raise Outcome("missing", f"`{name}` is greyed out")
        time.sleep(settle)

    def probe(self, *names, enabled=True):
        for name in names:
            result = self.bridge.call("probe", name=name)
            if result == "unsupported":
                raise Outcome("unverified", f"this platform's test bridge can't reach `{name}` yet")
            if result == "missing" or (enabled and result == "disabled"):
                raise Outcome("missing", f"`{name}` is {'not there' if result == 'missing' else 'greyed out'}")

    def context_menu(self):
        """The focused terminal's right-click menu: a list of {"title", "enabled"}."""
        result = self.bridge.call("context-menu")
        if result == "unsupported":
            raise Outcome("unverified", "this platform's test bridge can't open the right-click menu yet")
        if result == "missing":
            raise Outcome("missing", "the terminal has no right-click menu")
        return result

    def expect_menu(self, *titles):
        """The right-click menu has these items, in this order."""
        menu = [item["title"] for item in self.context_menu()]
        absent = [title for title in titles if title not in menu]
        if absent:
            raise Outcome("missing", f"the right-click menu has no {', '.join(absent)} (it has: {', '.join(menu)})")
        order = [menu.index(title) for title in titles]
        self.expect(order == sorted(order), f"the right-click menu's order differs: {', '.join(menu)}")

    def choose(self, title, settle=0.8):
        """Chooses an item of the focused terminal's right-click menu."""
        result = self.bridge.call("context-choose", title=title)
        if result == "missing":
            raise Outcome("missing", f"the right-click menu has no {title}")
        if result == "disabled":
            raise Outcome("missing", f"{title} is greyed out in the right-click menu")
        time.sleep(settle)

    def type(self, text, settle=0.6):
        self.bridge.call("type", text=text)
        time.sleep(settle)

    def run(self, posix, cmd=None, settle=1.0):
        line = posix if self.app.shell == "posix" else (cmd if cmd is not None else posix)
        self.type(line + self.app.enter, settle)

    def say(self, word, settle=1.0):
        """Prints `word` without it appearing in the typed line, so finding it proves the shell ran it."""
        posix = f'echo {word[:2]}""{word[2:]}'
        cmd = f"echo {word[:2]}^{word[2:]}"
        self.run(posix, cmd, settle)
        return word

    def cd_root(self):
        self.run("cd /", "cd \\")

    def pwd(self):
        self.run("pwd", "cd")

    def answer(self, response, fields=None, heading=None):
        self.bridge.call("answer", response=response, fields=fields or [], heading=heading)
        time.sleep(0.8)

    def until(self, check, what, timeout=6):
        """Polls the state until `check(state)` is true; otherwise the feature is broken."""
        deadline, state = time.time() + timeout, None
        while time.time() < deadline:
            state = self.state()
            try:
                if check(state):
                    return state
            except (KeyError, IndexError, StopIteration, TypeError):
                pass
            time.sleep(0.25)
        raise Outcome("broken", f"{what} (saw: {summary(state)})")

    def expect(self, condition, what):
        if not condition:
            raise Outcome("broken", what)

    def unverified(self, reason):
        raise Outcome("unverified", reason)

    def only(self, *platforms, reason="not part of this platform's design"):
        if self.platform not in platforms:
            raise Outcome("n/a", reason)


def summary(state):
    if not state:
        return "nothing"
    try:
        w = state["windows"][-1]
        tab = next(t for t in w["tabs"] if t["selected"])
        pane = next((p for p in tab["panes"] if p["focused"]), (tab["panes"] or [None])[0])
        tail = (pane or {}).get("text", "").strip().splitlines()[-3:]
        return (f"{len(state['windows'])} window(s), tabs {[t['name'] for t in w['tabs']]}, "
                f"{len(tab['panes'])} pane(s), title {w.get('title')!r} {w.get('subtitle')!r}, "
                f"dialogs {[d['heading'] for d in state.get('dialogs', [])]}, last lines {tail}")
    except Exception:
        return str(state)[:300]


def has_dialog(state, words=""):
    return any(words.lower() in d["heading"].lower() for d in state.get("dialogs", []))


def has_window(state, title):
    return any(title.lower() in (t or "").lower() for t in state.get("toplevels", []))


NEEDS_SSH = "needs an SSH test host (HERBS_TEST_SSH or ~/.config/herbs-terminal/test-ssh: user@host:port:password)"


def ssh_account():
    """The SSH test account, from HERBS_TEST_SSH or a private file outside the repository; None when not set up."""
    value = os.environ.get("HERBS_TEST_SSH", "").strip()
    if not value:
        try:
            with open(os.path.expanduser("~/.config/herbs-terminal/test-ssh"), encoding="utf-8") as f:
                value = f.read().strip()
        except OSError:
            return None
    login, _, rest = value.partition(":")
    port, _, password = rest.partition(":")
    user, _, host = login.partition("@")
    if not (user and host and port.isdigit()):
        return None
    return {"user": user, "host": host, "port": int(port), "password": password, "label": f"{user}@{host}"}


def connection(c, s=None):
    return c.tab(s).get("connection", {})


def expect_connected(c, account, s):
    c.expect(connection(c, s).get("state") == "connected" and any(l.startswith(account["user"] + "@") for l in c.text(s).splitlines()),
             f"expected a login to {account['label']} (saw: {connection(c, s)}; {summary(s)})")


def connect_test_host(c, password=None):
    """Connects the selected tab (Windows: a new tab) to the test host, answering a first host-key question."""
    account = ssh_account()
    if not account:
        c.unverified(NEEDS_SSH)
    c.bridge.call("connect", host=account["host"], port=account["port"], user=account["user"],
                  password=account["password"] if password is None else password)
    # The scene has its own empty known_hosts, so ssh asks about the host key first. A login can be reported
    # failed while that question waits; only a failure that lasts with no question pending counts.
    deadline, answered, failed_since = time.time() + 30, False, None
    while time.time() < deadline:
        s = c.state()
        if not answered and "(yes/no" in c.text(s):
            c.type("yes" + c.app.enter, settle=1)
            answered, failed_since = True, None
            continue
        state = connection(c, s).get("state")
        # Connected means logged in: the remote shell's prompt names the account (Windows reports a running
        # ssh as connected before the login is done).
        if state == "connected" and any(line.startswith(account["user"] + "@") for line in c.text(s).splitlines()):
            return account, s
        if state == "failed":
            failed_since = failed_since or time.time()
            if time.time() - failed_since > 5:
                return account, s
        else:
            failed_since = None
        time.sleep(0.5)
    return account, c.state()
NEEDS_GUI = "needs pointer or keyboard input the test bridge doesn't reach yet"

# ---------------------------------------------------------------- W: Window and toolbar

@test("W1", "New Tab adds a tab named Terminal 2")
def _(c):
    c.command("new-tab")
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1", "Terminal 2"] and c.tab(s)["name"] == "Terminal 2",
            "expected tabs Terminal 1 and Terminal 2, with the new one selected")

manual("W2", "Connection details while connected", "checked as S10")

@test("W3", "The title follows the folder and the program")
def _(c):
    c.cd_root()
    c.until(lambda s: c.window(s)["subtitle"] in ("/", "C:\\", "\\"), "expected the location / in the title")
    c.run("sleep 4", "ping -n 5 127.0.0.1 >nul", settle=1.5)
    c.until(lambda s: "sleep" in (c.window(s)["title"] + c.window(s)["subtitle"]) or "ping" in (c.window(s)["title"] + c.window(s)["subtitle"]),
            "expected the running program in the title")

@test("W4", "Secrets in a command line are hidden in the title")
def _(c):
    # The secrets ride on a program that keeps running and isn't a shell (the title leaves shells out, and
    # whether `sh -c` replaces itself with its command depends on the shell), so the hiding is really checked.
    # ping refuses unknown options and would end at once.
    c.run("awk 'BEGIN { system(\"sleep 4\") }' x --password=hunter2 API_TOKEN=s3cr3t",
          'cmd /d /c "ping -n 5 127.0.0.1 >nul & rem --password=hunter2 API_TOKEN=s3cr3t"', settle=1.5)
    s = c.state()
    seen = c.window(s)["title"] + " " + c.window(s)["subtitle"]
    c.expect("hunter2" not in seen and "s3cr3t" not in seen, f"the title shows a secret: {seen!r}")
    c.expect(any(word in seen for word in ("awk", "ping", "cmd")), f"the program isn't in the title, so hiding wasn't shown: {seen!r}")

@test("W5", "Restore Default Size and Make Current Size the Default")
def _(c):
    c.probe("restore-size", "default-size")
    c.command("restore-size", settle=1.5)
    c.until(lambda s: (c.pane(s)["columns"], c.pane(s)["rows"]) == (100, 30), "expected 100 × 30 after Restore Default Size")

@test("W6", "Export Session")
def _(c):
    c.probe("export-session")
    c.unverified("the command is there; saving goes through the system's save dialog, which the bridge can't fill")

@test("W7", "Take Screenshot copies the window")
def _(c):
    c.probe("take-screenshot")
    c.command("take-screenshot", settle=1.5)
    has = c.app.clipboard_has_image()
    if has is None:
        c.unverified("the command ran; this platform's clipboard can't be read by the runner")
    c.expect(has, "no picture on the clipboard after Take Screenshot")

@test("W8", "Show File Explorer / Show Terminal")
def _(c):
    c.command("toggle-explorer")
    c.until(lambda s: c.tab(s)["layout"] == "explorer", "expected the explorer to show")
    c.command("toggle-explorer")
    c.until(lambda s: c.tab(s)["layout"] == "terminal", "expected the terminal back")

@test("W9", "MultiExec button")
def _(c):
    c.command("multiexec")
    c.until(lambda s: c.window(s)["multiExec"], "expected MultiExec on")

@test("W10", "Tailcat Peers")
def _(c):
    c.command("tailcat", settle=1.5)
    c.until(lambda s: has_window(s, "Tailcat"), "expected the Tailcat Peers window")

@test("W11", "Search")
def _(c):
    c.probe("find")
    c.unverified("the command is there; whether the search field opens isn't reported by the bridge yet")

@test("W12", "Main Menu: New Tab, New Window, Connect via SSH")
def _(c):
    c.probe("new-tab", "new-window", "connect")

@test("W13", "Find in Terminal")
def _(c):
    c.probe("find-in-terminal")
    c.unverified("the command is there; the search bar isn't reported by the bridge yet")

@test("W14", "Zoom: Bigger, Smaller, Default")
def _(c):
    base = c.pane()["fontSize"]
    c.command("zoom-in")
    c.until(lambda s: c.pane(s)["fontSize"] == base + 1, f"expected {base + 1} pt after Bigger")
    c.command("zoom-out"); c.command("zoom-out")
    c.until(lambda s: c.pane(s)["fontSize"] == base - 1, f"expected {base - 1} pt after Smaller twice")
    c.command("zoom-reset")
    c.until(lambda s: c.pane(s)["fontSize"] == base, f"expected {base} pt after Default")

@test("W15", "Appearance: color scheme, presets, import, Restore Defaults")
def _(c):
    c.probe("color-scheme", "color-preset", "import-preset", "restore-theming")

@test("W16", "Full Screen, Settings and About")
def _(c):
    c.probe("fullscreen", "settings", "about")
    before = len(c.state()["toplevels"])
    c.command("settings", settle=1.5)
    c.until(lambda s: len(s["toplevels"]) > before, "expected the Settings window to open")

manual("W17", "Hover hints", "covered by parity/check.sh (hover texts through the accessibility tree)")

@test("W18", "New Window")
def _(c):
    c.command("new-window", settle=2)
    c.until(lambda s: len(s["windows"]) == 2, "expected a second window")

# ---------------------------------------------------------------- T: Tabs

@test("T1", "Each tab keeps its own shell and scrollback")
def _(c):
    mark = c.say("TABONE")
    c.until(lambda s: mark in c.text(s), "expected the first tab to print its marker")
    c.command("new-tab", settle=1.5)
    c.until(lambda s: c.tab(s)["name"] == "Terminal 2" and mark not in c.text(s), "expected the new tab without the first tab's text")
    c.command("tab-1")
    c.until(lambda s: mark in c.text(s), "expected the first tab's text back after switching")

@test("T2", "New tabs take the lowest free number")
def _(c):
    c.command("new-tab"); c.command("new-tab")
    c.command("tab-2"); c.command("close-tab", settle=1.2)
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1", "Terminal 3"], "expected Terminal 1 and 3 after closing 2")
    c.command("new-tab")
    c.until(lambda s: "Terminal 2" in [t["name"] for t in c.tabs(s)], "expected the new tab to be Terminal 2")

@test("T3", "Rename Tab")
def _(c):
    c.command("rename-tab", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the Rename dialog")
    responses = s["dialogs"][0]["responses"]
    ok = next((r for r in responses if r not in ("cancel", "Cancel")), None)
    c.answer(ok, ["Renamed"])
    c.until(lambda s: c.tab(s)["name"] == "Renamed", "expected the tab to be called Renamed")

@test("T4", "Move Tab Left / Right")
def _(c):
    c.command("new-tab")
    c.command("move-tab-left")
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 2", "Terminal 1"], "expected Terminal 2 first after Move Tab Left")
    c.command("move-tab-right")
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1", "Terminal 2"], "expected the order back after Move Tab Right")

@test("T5", "Show Tab 1–8 and Last Tab")
def _(c):
    c.command("new-tab"); c.command("new-tab")
    c.command("tab-1")
    c.until(lambda s: c.tab(s)["name"] == "Terminal 1", "expected Terminal 1 selected")
    c.command("tab-9")
    c.until(lambda s: c.tab(s)["name"] == "Terminal 3", "expected the last tab selected")

@test("T6", "Previous / Next Tab")
def _(c):
    c.command("new-tab")
    c.command("previous-tab")
    c.until(lambda s: c.tab(s)["name"] == "Terminal 1", "expected Terminal 1 after Previous Tab")
    c.command("next-tab")
    c.until(lambda s: c.tab(s)["name"] == "Terminal 2", "expected Terminal 2 after Next Tab")

@test("T7", "Close Tab")
def _(c):
    c.command("new-tab")
    c.command("close-tab", settle=1.2)
    c.until(lambda s: len(c.tabs(s)) == 1, "expected one tab left")

@test("T8", "exit closes the pane, then the tab")
def _(c):
    c.command("split-vertical", settle=1.5)
    c.run("exit", settle=1.5)
    c.until(lambda s: len(c.panes(s)) == 1, "expected the pane to close")
    c.command("new-tab", settle=1.5)
    c.run("exit", settle=1.5)
    c.until(lambda s: len(c.tabs(s)) == 1, "expected the tab to close")

@test("T9", "Asks before closing a tab with a running program")
def _(c):
    c.command("new-tab", settle=1.5)
    c.run("sleep 30", "ping -n 31 127.0.0.1 >nul", settle=1.5)
    c.command("close-tab", settle=1.5)
    s = c.until(lambda s: s.get("dialogs") or len(c.tabs(s)) == 1, "expected a question or a closed tab")
    c.expect(s.get("dialogs"), "the tab closed without asking")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() == "cancel"))
    c.until(lambda s: len(c.tabs(s)) == 2, "expected the tab to stay after Cancel")

@test("T10", "New tabs open in the current tab's folder")
def _(c):
    c.cd_root()
    c.command("new-tab", settle=1.5)
    c.pwd()
    c.until(lambda s: any(l.strip() in ("/", "C:\\") for l in c.text(s).splitlines()), "expected the new tab to start in /")

manual("T11", "Session restore", "the test scene never saves or restores a session")

# ---------------------------------------------------------------- P: Split panes

@test("P1", "Split Vertically and Horizontally")
def _(c):
    c.command("split-vertical", settle=1.2); c.command("split-horizontal", settle=1.2)
    c.until(lambda s: len(c.panes(s)) == 3, "expected three panes")

@test("P2", "A new pane starts in the current pane's folder")
def _(c):
    c.cd_root()
    c.command("split-vertical", settle=1.5)
    c.pwd()
    c.until(lambda s: any(l.strip() in ("/", "C:\\") for l in c.text(s).splitlines()), "expected the new pane in /")

@test("P3", "Close Pane")
def _(c):
    c.command("split-vertical", settle=1.2)
    c.command("close-pane", settle=1.2)
    c.until(lambda s: len(c.panes(s)) == 1, "expected one pane after Close Pane")

@test("P4", "Select Next / Previous Pane")
def _(c):
    c.command("split-vertical", settle=1.2)
    focused = c.pane()["number"]
    c.command("next-pane")
    c.until(lambda s: c.pane(s)["number"] != focused, "expected the focus to move")
    c.command("previous-pane")
    c.until(lambda s: c.pane(s)["number"] == focused, "expected the focus back")

manual("P5", "Focused pane outline", "visual: shown in the window's picture, not reported by the bridge")
manual("P6", "The first pane owns the SSH connection", NEEDS_SSH)

# ---------------------------------------------------------------- B: Terminal behavior

def check_copy_paste(c, run):
    """Copy, Paste and Paste Escaped Text through `run(name)`, on the app's own clipboard (never the user's)."""
    mark = c.say("COPYME")
    c.until(lambda s: mark in c.text(s), "expected the marker to print")
    run("select-all"); run("copy")
    copied = c.app.clipboard()["text"]
    c.expect(mark in copied, f"expected Copy to put the selected text on the clipboard (it has {copied[-80:]!r})")
    # A command on the clipboard, written so the word only appears once the shell runs it.
    c.app.set_clipboard(text='echo PA""STED' if c.app.shell == "posix" else "echo PA^STED")
    run("paste")
    c.type(c.app.enter, settle=1.2)
    c.until(lambda s: "PASTED" in c.text(s), "expected Paste to type the clipboard's command")
    if c.app.shell != "posix":
        return
    c.app.set_clipboard(text="it's $HOME; a b")
    c.type("printf '%s\\n' ", settle=0.4)
    run("paste-escaped")
    c.type(c.app.enter, settle=1.2)
    c.until(lambda s: "it's $HOME; a b" in c.text(s).splitlines(), "expected Paste Escaped Text to keep the text literal")

@test("B1", "Right-click menu: Copy, Paste, Paste Escaped Text, Select All, Find")
def _(c):
    c.expect_menu("Copy", "Paste", "Paste Escaped Text", "Select All", "Find…")
    titles = {"select-all": "Select All", "copy": "Copy", "paste": "Paste", "paste-escaped": "Paste Escaped Text"}
    check_copy_paste(c, lambda name: c.choose(titles[name]))
    c.choose("Find…")
    c.unverified("Copy, Paste, Paste Escaped Text and Select All work; Find… runs, but the bridge doesn't report the find bar yet")

@test("B2", "Right-click menu: Clear to Start, Clear Scrollback, Reset")
def _(c):
    c.expect_menu("Clear to Start", "Clear Scrollback", "Reset")
    mark = c.say("CLEARME")
    c.until(lambda s: mark in c.text(s), "expected the marker to print")
    c.choose("Clear to Start", settle=1.2)
    c.until(lambda s: mark not in c.text(s), "expected Clear to Start to remove the marker")
    c.run("seq 1 300 | sed 's/^/L/'", "for /l %i in (1,1,300) do @echo L%i", settle=2)
    c.until(lambda s: "L150" in c.text(s), "expected 300 lines of output")
    c.choose("Clear Scrollback", settle=1.2)
    c.until(lambda s: "L5\n" not in c.text(s) and "L150" not in c.text(s), "expected Clear Scrollback to drop the old lines")
    c.choose("Reset")
    mark = c.say("ALIVE")
    c.until(lambda s: mark in c.text(s), "expected the shell to answer after Reset")

@test("B3", "Right-click menu: Split Vertically, Split Horizontally, Close Pane, New Tab, Show File Explorer")
def _(c):
    c.expect_menu("Split Vertically", "Split Horizontally", "New Tab", "Show File Explorer")
    c.expect("Close Pane" not in [item["title"] for item in c.context_menu()], "Close Pane is offered with only one pane")
    c.choose("Split Vertically", settle=1.5)
    c.until(lambda s: len(c.panes(s)) == 2, "expected Split Vertically to make two panes")
    c.choose("Split Horizontally", settle=1.5)
    c.until(lambda s: len(c.panes(s)) == 3, "expected Split Horizontally to make a third pane")
    c.choose("Close Pane", settle=1.2)
    s = c.state()
    if s.get("dialogs"):
        dialog = s["dialogs"][0]
        c.answer(next(r for r in dialog["responses"] if r.lower() != "cancel"), heading=dialog["heading"])
    c.until(lambda s: len(c.panes(s)) == 2, "expected Close Pane to leave two panes")
    c.choose("New Tab", settle=1.5)
    c.until(lambda s: len(c.tabs(s)) == 2, "expected New Tab to add a tab")
    c.choose("Show File Explorer", settle=1.2)
    c.until(lambda s: c.tab(s)["layout"] == "explorer", "expected Show File Explorer to show the explorer")

@test("B4", "Right-click menu: Connect via SSH, Bigger, Smaller, Settings")
def _(c):
    c.expect_menu("Connect via SSH…", "Bigger", "Smaller", "Settings…")
    base = c.pane()["fontSize"]
    c.choose("Bigger")
    c.until(lambda s: c.pane(s)["fontSize"] == base + 1, "expected Bigger to zoom in")
    c.choose("Smaller")
    c.until(lambda s: c.pane(s)["fontSize"] == base, "expected Smaller to zoom back out")
    before = len(c.state()["toplevels"])
    c.choose("Settings…", settle=1.5)
    c.until(lambda s: len(s["toplevels"]) > before, "expected the Settings window to open")
    c.choose("Connect via SSH…", settle=1.5)
    c.until(lambda s: has_window(s, "Connect") or has_dialog(s, "Administrator") or s.get("dialogs"), "expected the Connect via SSH dialog")

@test("B4", "Right-click menu: Disconnect while connected")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    title = next((item["title"] for item in c.context_menu() if item["title"].startswith("Disconnect from")), None)
    c.expect(title is not None, "the right-click menu has no Disconnect while connected")
    c.choose(title, settle=1.5)
    c.until(lambda s: connection(c, s).get("state") in ("local", "failed"), "expected Disconnect to end the connection")

@test("B5", "Dropping files types their paths, quoted for the shell")
def _(c):
    folder = os.path.join(c.app.home, "drop")
    os.makedirs(folder, exist_ok=True)
    names = ["a b.txt", "it's.txt"] if c.app.shell == "posix" else ["a b.txt", "x&y.txt"]
    paths = [os.path.join(folder, name) for name in names]
    for path in paths:
        open(path, "w").close()
    # The shell lists what the typed paths name: a path that isn't quoted right lists something else, or fails.
    c.type("printf '%s\\n' " if c.app.shell == "posix" else "dir /b ", settle=0.4)
    c.bridge.call("drop", paths=paths)
    time.sleep(0.6)
    c.type(c.app.enter, settle=1.5)
    expected = paths if c.app.shell == "posix" else names
    c.until(lambda s: all(any(line.strip() == item for line in c.text(s).splitlines()) for item in expected),
            f"expected the shell to list {', '.join(expected)} from the dropped paths")
manual("B6", "Bell", "sound and flash can't be observed by the bridge")
manual("B7", "Size badge while resizing", "needs a window resize by the pointer")

@test("B8", "Find in Terminal")
def _(c):
    c.probe("find-in-terminal")
    c.unverified("the command is there; the search bar and its matches aren't reported by the bridge yet")

@test("B9", "Copy, Paste and Paste Escaped Text")
def _(c):
    c.probe("copy", "paste", "paste-escaped", "select-all")
    check_copy_paste(c, c.command)

@test("B10", "Clear to Start and Clear Scrollback")
def _(c):
    mark = c.say("CLEARME")
    c.until(lambda s: mark in c.text(s), "expected the marker to print")
    c.command("clear-to-start", settle=1.2)
    c.until(lambda s: mark not in c.text(s), "expected Clear to Start to remove the marker")
    c.run("seq 1 300 | sed 's/^/L/'", "for /l %i in (1,1,300) do @echo L%i", settle=2)
    c.until(lambda s: "L150" in c.text(s), "expected 300 lines of output")
    c.command("clear-scrollback", settle=1.2)
    c.until(lambda s: "L5\n" not in c.text(s) and "L150" not in c.text(s), "expected Clear Scrollback to drop the old lines")

@test("B11", "Reset and Hard Reset keep the shell working")
def _(c):
    c.command("reset"); c.command("hard-reset")
    mark = c.say("ALIVE")
    c.until(lambda s: mark in c.text(s), "expected the shell to answer after Reset and Hard Reset")

@test("B12", "Zoom is saved in the profile and Default clears it")
def _(c):
    base = c.pane()["fontSize"]
    c.command("zoom-in")
    c.command("new-tab", settle=1.5)
    c.until(lambda s: c.pane(s)["fontSize"] == base + 1, "expected a new tab to keep the zoom")
    c.command("zoom-reset")
    c.until(lambda s: c.pane(s)["fontSize"] == base, "expected Default to clear the zoom")

@test("B13", "Secure Keyboard Entry")
def _(c):
    c.only("mac", reason="exempt on Linux and Windows (SPECIFICATION.md §11)")
    c.probe("secure-keyboard-entry")

manual("B14", "Colors, styles, wide characters, mouse reporting", "visual: needs the window's picture compared with the Mac's")

# ---------------------------------------------------------------- M: Menus

MENU = {"M1": ("new-tab", "export-session", "take-screenshot", "new-tab-profile", "use-profile"),
        "M2": ("split-vertical", "split-horizontal", "close-pane", "next-pane", "previous-pane"),
        "M3": ("multiexec", "run-on-hosts"),
        "M4": ("connect", "disconnect"),
        "M5": ("previous-tab", "next-tab", "rename-tab", "move-tab-left", "move-tab-right"),
        "M6": ("reset", "hard-reset"), "M7": ("clear-to-start", "clear-scrollback"),
        "M8": ("zoom-in", "zoom-out", "zoom-reset"), "M9": tuple(f"tab-{n}" for n in range(1, 10))}
for fid, names in MENU.items():
    def menu_test(c, names=names):
        c.command("new-tab", settle=1.0)   # two tabs, so tab commands are available
        for name in names:
            c.probe(name, enabled=name not in ("disconnect", "move-tab-right"))
    test(fid, "Menu commands: " + ", ".join(names))(menu_test)

# ---------------------------------------------------------------- R: Profiles, appearance, Settings

@test("R1", "Named profiles")
def _(c):
    c.expect(c.state().get("profiles"), "no profiles")
    c.probe("new-tab-profile", "use-profile")

@test("R2", "A profile's startup command runs when a tab opens")
def _(c):
    word = "STARTED" + "OK"
    c.bridge.call("profile-set", key="startupCommand", value=f"echo {word[:3]}\"\"{word[3:]}" if c.app.shell == "posix" else f"echo {word[:3]}^{word[3:]}")
    c.command("new-tab", settle=2)
    c.until(lambda s: word in c.text(s), "expected the startup command's output in the new tab", timeout=8)

@test("R3", "Default look: 13 pt, 100 × 30")
def _(c):
    p = c.pane()
    c.expect(p["fontSize"] == 13, f"text is {p['fontSize']} pt")
    c.expect((p["columns"], p["rows"]) == (100, 30), f"the terminal is {p['columns']} × {p['rows']}")

@test("R4", "Color presets")
def _(c):
    names = c.state().get("presets", [])
    want = ["Solarized Dark", "Solarized Light", "Tango Dark", "Tango Light", "Gruvbox Dark", "Nord"]
    c.expect(all(n in names for n in want), f"presets are {names}")

manual("R5", "iTerm2 preset import", "needs the system's open dialog")

@test("R6", "Restore Defaults asks first")
def _(c):
    c.command("restore-theming", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected Restore Defaults to ask first")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() == "cancel"))

for fid, what in (("R7", "Profiles"), ("R8", "Text"), ("R9", "Terminal"), ("R10", "Window"), ("R11", "Colors")):
    def settings_test(c, what=what):
        before = len(c.state()["toplevels"])
        c.command("settings", settle=1.5)
        c.until(lambda s: len(s["toplevels"]) > before, "expected the Settings window to open")
        c.unverified(f"Settings opens; its {what} page isn't read by the bridge yet")
    test(fid, f"Settings ▸ {what}")(settings_test)
manual("R12", "Light and dark for the whole app", "visual: needs pictures in light and dark mode")

# ---------------------------------------------------------------- S: SSH

@test("S1", "Connect via SSH dialog")
def _(c):
    c.command("connect", settle=1.5)
    c.until(lambda s: has_window(s, "Connect") or has_dialog(s, "Administrator") or s.get("dialogs"), "expected the Connect via SSH dialog")
@test("S2", "Once logged in, the explorer moves to the same host and account")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.expect(account["label"] in c.window(s)["title"], f"the title doesn't name {account['label']}: {c.window(s)['title']!r}")
    c.command("toggle-explorer", settle=2)
    c.until(lambda s: c.tab(s).get("explorer", {}).get("remote") and c.tab(s)["explorer"].get("path", "").rstrip("/") == f"/home/{account['user']}",
            f"expected the explorer in {account['user']}'s home on the host", timeout=15)

@test("S4", "Disconnect returns the tab and title to this computer")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("disconnect", settle=2)
    c.until(lambda s: connection(c, s).get("state") in ("local", "failed") and account["label"] not in c.window(s)["title"],
            "expected the tab back on this computer", timeout=15)

@test("S5", "A failed login says so, and the title goes back to this computer")
def _(c):
    account, s = connect_test_host(c, password="wrong-" + str(int(time.time())))
    # ssh asks again in the terminal after a refused saved password; give up there.
    c.type("\x03", settle=1)
    c.until(lambda s: connection(c, s).get("state") != "connected" and account["label"] not in c.window(s)["title"],
            "expected the failed login to leave the tab on this computer", timeout=20)

@test("S7", "No password on screen")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.expect(account["password"] not in c.text(s), "the password is on the screen")

@test("S10", "Connection details while connected")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("connect-button", settle=1.5)
    c.until(lambda s: has_window(s, "Connection") or any(account["label"] in d["heading"] or "Connection" in d["heading"] for d in s.get("dialogs", [])),
            "expected the connection details")

for fid, what in (("S3", "Following a typed ssh"), ("S6", "Shared connection and keepalive"), ("S8", "Host-key questions in the terminal"),
                  ("S9", "Your own ssh configuration")):
    manual(fid, what, "needs the user's own ssh setup or a dropped link; not automated yet")

# ---------------------------------------------------------------- E: File explorer (in the scene's own folder only)

def explorer_at_home(c, files=True):
    if files:
        c.run("mkdir -p sub && printf 'hello\\n' > note.txt", "mkdir sub & echo hello> note.txt", settle=1.5)
    c.command("toggle-explorer", settle=1.2)
    if c.bridge.call("explorer-go", path=c.app.home) == "unsupported":
        c.unverified("this platform's test bridge can't drive the explorer yet")
    s = c.until(lambda s: c.tab(s).get("explorer", {}).get("path", "").rstrip("/\\").lower() == c.app.home.rstrip("/\\").lower(),
                "expected the explorer in the scene's folder")
    return s

def items(c, s=None):
    return c.tab(s).get("explorer", {}).get("items", [])

def safe(c):
    """Never change files outside the scene's folder."""
    path = c.tab().get("explorer", {}).get("path", "")
    if not path.lower().startswith(c.app.home.lower()):
        raise Outcome("error", f"refused: the explorer is at {path}, outside the scene's folder")

manual("E1", "Places", "checked in the accessibility tree by parity/check.sh; the bridge doesn't report places")
@test("E2", "Bookmarks: add and remove a folder")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "sub/" in items(c, s) or "sub" in items(c, s), "expected the folder sub in the list")
    sub = c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub")
    def bookmark_sub():
        c.bridge.call("explorer-go", path=c.app.home)
        c.until(lambda s: "sub/" in items(c, s) or "sub" in items(c, s), "expected the folder sub in the list")
        c.bridge.call("explorer-select", names=["sub"])
        c.command("explorer.bookmark-selected", settle=0.8)
        c.bridge.call("explorer-go", path=sub)
    bookmark_sub()
    c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\").endswith("sub") and c.tab(s)["explorer"].get("bookmarked") is True,
            "expected sub to be bookmarked")
    bookmark_sub()
    c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\").endswith("sub") and c.tab(s)["explorer"].get("bookmarked") is False,
            "expected Remove Bookmark to take sub out")

@test("E3", "Navigate: go into a folder and back")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "sub/" in items(c, s) or "sub" in items(c, s), "expected the folder sub in the list")
    c.bridge.call("explorer-go", path=c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub"))
    c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\").endswith("sub"), "expected to be in sub")
    c.unverified("going into a folder works; Back, Forward, Up and Home are buttons the bridge doesn't press yet")

manual("E4", "Path segments and editable location", NEEDS_GUI)

@test("E5", "Open a text file from the explorer")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.open", settle=2)
    c.until(lambda s: c.tab(s)["kind"] == "editor", "expected note.txt to open in the text editor")

@test("E6", "File Actions commands")
def _(c):
    explorer_at_home(c, files=False)
    c.probe("explorer.cut", "explorer.copy", "explorer.delete", enabled=False)
    c.probe("explorer.paste", "explorer.select-all", "explorer.new-folder", "explorer.new-file", "explorer.undo", "explorer.redo",
            "explorer.find", "explorer.upload", "explorer.download", enabled=False)

@test("E7", "Copy and paste here gives a 'copy' name")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    safe(c)
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.copy"); c.command("explorer.paste", settle=2)
    c.until(lambda s: any(i.startswith("note copy") for i in items(c, s)), "expected a 'note copy.txt'")

@test("E8", "Undo and Redo a move to Trash")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    safe(c)
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.delete", settle=2)
    s = c.state()
    if s.get("dialogs"):
        c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() not in ("cancel",)))
    c.until(lambda s: "note.txt" not in items(c, s), "expected note.txt to go to the Trash")
    c.command("explorer.undo", settle=2)
    c.until(lambda s: "note.txt" in items(c, s), "expected Undo to bring note.txt back")
    c.command("explorer.redo", settle=2)
    c.until(lambda s: "note.txt" not in items(c, s), "expected Redo to move it again")

@test("E8", "Undo and Redo a copy")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    safe(c)
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.copy", settle=0.6)
    c.command("explorer.paste", settle=2)
    c.until(lambda s: "note copy.txt" in items(c, s), "expected the copy, note copy.txt")
    c.command("explorer.undo", settle=2)
    c.until(lambda s: "note copy.txt" not in items(c, s) and "note.txt" in items(c, s), "expected Undo to remove the copy")
    c.command("explorer.redo", settle=2)
    c.until(lambda s: "note copy.txt" in items(c, s), "expected Redo to bring the copy back")

@test("E8", "Undo and Redo a move")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    safe(c)
    sub = c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub")
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.cut", settle=0.6)
    c.bridge.call("explorer-go", path=sub)
    c.command("explorer.paste", settle=2)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt moved into sub")
    c.command("explorer.undo", settle=2)
    c.until(lambda s: "note.txt" not in items(c, s), "expected Undo to move note.txt back out of sub")
    c.command("explorer.redo", settle=2)
    c.until(lambda s: "note.txt" in items(c, s), "expected Redo to move it into sub again")

@test("E8", "Host: Undo and Redo a move")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("toggle-explorer", settle=2)
    home = f"/home/{account['user']}"
    if c.bridge.call("explorer-go", path=home) == "unsupported":
        c.unverified("this platform's test bridge can't drive the explorer yet")
    c.until(lambda s: c.tab(s).get("explorer", {}).get("remote"), "expected the host's files", timeout=15)
    stamp = int(time.time())
    moved, box = f"undo-item-{stamp}", f"undo-box-{stamp}"
    for name in (moved, box):
        c.command("explorer.new-folder", settle=1.2)
        s = c.until(lambda s: s.get("dialogs"), "expected the New Folder dialog")
        c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), [name])
        c.until(lambda s: any(i.rstrip("/") == name for i in items(c, s)), "expected the new folder on the host", timeout=10)
    try:
        c.bridge.call("explorer-select", names=[moved + "/", moved])
        c.command("explorer.cut", settle=0.6)
        c.bridge.call("explorer-go", path=f"{home}/{box}")
        c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/").endswith(box), "expected to be in the box folder", timeout=10)
        c.command("explorer.paste", settle=2)
        c.until(lambda s: any(i.rstrip("/") == moved for i in items(c, s)), "expected the folder moved into the box", timeout=10)
        c.command("explorer.undo", settle=2)
        c.until(lambda s: not any(i.rstrip("/") == moved for i in items(c, s)), "expected Undo to move it back out", timeout=10)
        c.command("explorer.redo", settle=2)
        c.until(lambda s: any(i.rstrip("/") == moved for i in items(c, s)), "expected Redo to move it in again", timeout=10)
    finally:
        # Leave the test account as it was.
        c.bridge.call("explorer-go", path=home)
        time.sleep(1.5)
        c.bridge.call("explorer-select", names=[box + "/", box, moved + "/", moved])
        c.command("explorer.delete", settle=1.2)
        for d in c.state().get("dialogs", []):
            c.answer(next(r for r in d["responses"] if r.lower() not in ("cancel",)))

@test("E9", "System file clipboard, both ways")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt in the list")
    safe(c)
    # Out: the explorer's Copy puts the file on the clipboard as files, for the system's file manager.
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.copy", settle=1)
    note = os.path.join(c.app.home, "note.txt")
    files = c.app.clipboard()["files"]
    c.expect(any(os.path.normcase(f) == os.path.normcase(note) for f in files), f"expected note.txt on the clipboard as a file (it has {files})")
    # In: a file the file manager copied pastes into the explorer.
    other = os.path.join(c.app.home, "sub", "from-files.txt")
    os.makedirs(os.path.dirname(other), exist_ok=True)
    with open(other, "w") as f:
        f.write("from the file manager\n")
    c.app.set_clipboard(files=[other])
    c.command("explorer.paste", settle=2)
    c.until(lambda s: "from-files.txt" in items(c, s), "expected the copied file to paste into the explorer")
@test("E10", "Host: new folder, rename and delete")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("toggle-explorer", settle=2)
    if c.bridge.call("explorer-go", path=f"/home/{account['user']}") == "unsupported":
        c.unverified("this platform's test bridge can't drive the explorer yet")
    c.until(lambda s: c.tab(s).get("explorer", {}).get("remote"), "expected the host's files", timeout=15)
    name = f"made-by-test-{int(time.time())}"
    c.command("explorer.new-folder", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the New Folder dialog")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), [name])
    c.until(lambda s: any(i.rstrip("/") == name for i in items(c, s)), "expected the new folder on the host", timeout=10)
    c.bridge.call("explorer-select", names=[name + "/", name])
    c.command("explorer.delete", settle=1.2)
    s = c.state()
    if s.get("dialogs"):
        c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() not in ("cancel",)))
    c.until(lambda s: not any(i.rstrip("/") == name for i in items(c, s)), "expected the folder gone from the host", timeout=10)
manual("E11", "Pasting between this computer and a host", NEEDS_SSH)

@test("E12", "A folder can't be pasted into itself")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "sub/" in items(c, s) or "sub" in items(c, s), "expected the folder sub")
    safe(c)
    c.bridge.call("explorer-select", names=["sub"])
    c.command("explorer.copy")
    c.bridge.call("explorer-go", path=c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub"))
    time.sleep(1)
    c.command("explorer.paste", settle=2)
    s = c.state()
    c.expect(not any(i.startswith("sub") for i in items(c, s)), f"the folder was pasted into itself: {items(c, s)}")
    for d in s.get("dialogs", []):
        c.answer(d["responses"][0])

@test("E13", "New Folder and Rename")
def _(c):
    explorer_at_home(c, files=False)
    safe(c)
    c.command("explorer.new-folder", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the New Folder dialog")
    ok = next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel")
    c.answer(ok, ["made-by-test"])
    c.until(lambda s: any(i.rstrip("/\\") == "made-by-test" for i in items(c, s)), "expected the new folder")
    c.bridge.call("explorer-select", names=["made-by-test"])
    c.command("explorer.rename", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the Rename dialog")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), ["renamed-by-test"])
    c.until(lambda s: any(i.rstrip("/\\") == "renamed-by-test" for i in items(c, s)), "expected the folder renamed")

@test("E14", "Find files")
def _(c):
    explorer_at_home(c, files=False)
    c.probe("explorer.find")
    c.unverified("the command is there; the filter field isn't driven by the bridge yet")

@test("E15", "Open in Text Editor, Open with Default App, Show in the file manager")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt")
    c.bridge.call("explorer-select", names=["note.txt"])
    c.probe("explorer.edit", "explorer.open-default", "explorer.reveal")

manual("E16", "Open with Administrator Mode", "needs a sudo password (not automated)")

# ---------------------------------------------------------------- X, D, G, A

for fid in ("X1", "X2", "X3", "X4", "X6", "X7"):
    manual(fid, "Transfers", NEEDS_SSH)
manual("X5", "Local copies in the background", "needs a large folder and timing; not automated yet")

@test("D1", "Text files open as a tab")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt")
    c.bridge.call("explorer-select", names=["note.txt"])
    c.command("explorer.edit", settle=2)
    c.until(lambda s: c.tab(s)["kind"] == "editor" and "hello" in c.tab(s)["editor"]["text"], "expected note.txt in an editor tab")

@test("D2", "New File opens in the editor")
def _(c):
    explorer_at_home(c, files=False)
    safe(c)
    c.command("explorer.new-file", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the New File dialog")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), ["fresh.txt"])
    c.until(lambda s: c.tab(s)["kind"] == "editor", "expected the new file in the editor")

for fid, what in (("D3", "Find and undo"), ("D4", "Wrap Lines"), ("D5", "Status line"), ("D6", "Save"),
                  ("D7", "Unsaved-changes question"), ("D8", "Changed on disk"), ("D9", "Encodings kept"), ("D10", "Size and binary limits")):
    manual(fid, f"Text editor: {what}", "the bridge can't type into the editor or read its status yet")
for fid in ("G1", "G2", "G3", "G5", "G6"):
    manual(fid, "Get Info", "the Get Info window isn't driven by the bridge yet")
manual("G4", "Hidden and Locked", "Mac only")
def host_explorer(c):
    """Connects to the test host and shows its files in the explorer."""
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("toggle-explorer", settle=2)
    c.until(lambda s: c.tab(s).get("explorer", {}).get("remote"), "expected the host's files", timeout=15)
    return account


def administrator(c, s=None):
    return c.tab(s).get("explorer", {}).get("administrator")


def enter_administrator(c, account, password):
    """Presses the lock button and answers the sudo password question."""
    c.command("explorer.administrator", settle=1.5)
    s = c.until(lambda s: s.get("dialogs"), "expected the sudo password question", timeout=10)
    dialog = s["dialogs"][0]
    ok = next(r for r in dialog["responses"] if r.lower() not in ("cancel", "not now"))
    c.answer(ok, [password], heading=dialog["heading"])


@test("A1", "The lock button starts Administrator mode on the connected host, after the sudo password")
def _(c):
    account = host_explorer(c)
    enter_administrator(c, account, account["password"])
    c.until(lambda s: administrator(c, s), "expected Administrator mode", timeout=15)

@test("A2", "In Administrator mode the explorer works as root")
def _(c):
    account = host_explorer(c)
    enter_administrator(c, account, account["password"])
    c.until(lambda s: administrator(c, s), "expected Administrator mode", timeout=15)
    if c.bridge.call("explorer-go", path="/root") == "unsupported":
        c.unverified("this platform's test bridge can't drive the explorer yet")
    # /root can be listed only as root; a fresh account's folder there holds at least its dotfiles.
    c.until(lambda s: c.tab(s)["explorer"].get("path", "").rstrip("/") == "/root" and c.tab(s)["explorer"].get("items") is not None,
            "expected to list /root as root", timeout=10)
    s = c.state()
    c.expect(not s.get("dialogs") or not any("permission" in d["heading"].lower() for d in s["dialogs"]), "listing /root was refused")

@test("A3", "A wrong sudo password doesn't start Administrator mode")
def _(c):
    account = host_explorer(c)
    enter_administrator(c, account, "wrong-" + str(int(time.time())))
    time.sleep(4)
    c.expect(not administrator(c), "Administrator mode started with a wrong password")

@test("A5", "Leaving Administrator mode")
def _(c):
    account = host_explorer(c)
    enter_administrator(c, account, account["password"])
    c.until(lambda s: administrator(c, s), "expected Administrator mode", timeout=15)
    c.command("explorer.administrator", settle=1.5)
    c.until(lambda s: not administrator(c, s), "expected Administrator mode to end", timeout=10)

manual("A4", "Safe root delete rules", "deleting system folders as root isn't something to try on a real machine")

# ---------------------------------------------------------------- L: Saved logins

for fid in ("L1", "L2", "L3", "L4"):
    manual(fid, "Login vault", "covered by the unit and self tests of the shared vault code")

@test("L5", "First use explains the Administrator Password")
def _(c):
    c.command("connect", settle=2)
    c.until(lambda s: has_dialog(s, "Administrator") or has_window(s, "Administrator"), "expected the Administrator Password explanation")
for fid in ("L6", "L7", "L8", "L9", "L10", "L11"):
    manual(fid, "Manage Logins", "the Manage Logins window isn't driven by the bridge yet")

# ---------------------------------------------------------------- U: MultiExec and Run Command on Hosts

def multiexec_with(c, panes=3):
    for _ in range(panes - 1):
        c.command("split-vertical", settle=1.2)
    c.command("multiexec", settle=1.2)
    c.until(lambda s: c.window(s)["multiExec"], "expected MultiExec on")

@test("U1", "Every terminal joins the grid, included")
def _(c):
    multiexec_with(c)
    c.until(lambda s: c.window(s)["excluded"] == [] and len(c.panes(s)) == 3, "expected three included terminals")

@test("U2", "Typing reaches every included terminal once; an excluded one is left out")
def _(c):
    multiexec_with(c)
    mark = c.say("ALLOFUS", settle=2)
    s = c.until(lambda s: all(mark in p["text"] for p in c.panes(s)), "expected the line in every terminal")
    counts = [p["text"].count(mark) for p in c.panes(s)]
    c.expect(all(n == 1 for n in counts), f"expected each terminal to run it once, saw {counts}")
    typing = c.pane()["number"]
    other = next(p["number"] for p in c.panes() if p["number"] != typing)
    c.bridge.call("include", pane=other, on=False)
    c.until(lambda s: c.window(s)["excluded"] == [other], f"expected terminal {other} left out")
    only = c.say("SOMEOFUS", settle=2)
    s = c.until(lambda s: only in c.pane(s)["text"], "expected the line in the typing terminal")
    seen = {p["number"]: only in p["text"] for p in c.panes(s)}
    want = {n: n != other for n in seen}
    c.expect(seen == want, f"expected every terminal but {other} to get it, saw {seen}")

@test("U3", "Leave MultiExec")
def _(c):
    multiexec_with(c, 2)
    c.command("multiexec")
    c.until(lambda s: not c.window(s)["multiExec"], "expected MultiExec off")

@test("U4", "Close All")
def _(c):
    multiexec_with(c, 2)
    c.probe("close-all")

@test("U5", "Text the app types isn't broadcast")
def _(c):
    multiexec_with(c, 2)
    c.command("clear-to-start", settle=1)
    c.bridge.call("profile-set", key="startupCommand", value="echo QUIET" + ("\"\"" if c.app.shell == "posix" else "^") + "ONE")
    c.command("split-vertical", settle=2.5)
    s = c.state()
    counts = [p["text"].count("QUIETONE") for p in c.panes(s)]
    c.expect(counts[-1] >= 1 and sum(counts[:-1]) == 0, f"expected the new pane's startup command in that pane only, saw {counts}")

@test("U5", "Connecting in a new tab while MultiExec is on types only into that tab")
def _(c):
    multiexec_with(c, 2)
    before = [p["text"] for p in c.panes()]
    c.command("new-tab", settle=1.5)
    # A port nothing listens on: the login fails fast, but the launcher line is typed into the new tab all the same.
    c.bridge.call("connect", host="127.0.0.1", port=1, user="nobody", password="")
    time.sleep(4)
    c.expect(c.app.alive(), "the app crashed while connecting")
    c.command("tab-1", settle=1)
    after = [p["text"] for p in c.panes()]
    leaked = [i + 1 for i, (a, b) in enumerate(zip(before, after)) if "herbs" in b[len(a):] or "nobody@" in b[len(a):]]
    c.expect(not leaked, f"the login was typed into MultiExec terminal(s) {leaked} too")

@test("U6", "Run Command on Hosts window")
def _(c):
    c.command("run-on-hosts", settle=1.5)
    c.until(lambda s: has_window(s, "Run Command") or has_window(s, "Hosts"), "expected the Run Command on Hosts window")
@test("U7", "Run Command on Hosts runs on the host and reports the result")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("run-on-hosts", settle=1.5)
    try:
        state = c.bridge.call("hosts-state")
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("this platform's test bridge can't drive Run Command on Hosts yet")
        raise
    host = next((h for h in state["hosts"] if h.startswith(account["user"] + "@")), None)
    c.expect(host is not None, f"the tab's connection isn't offered as a host: {state['hosts']}")
    c.bridge.call("hosts-run", hosts=[host], command="echo RAN-ON-$(hostname); exit 3")
    deadline = time.time() + 30
    while time.time() < deadline:
        state = c.bridge.call("hosts-state")
        if not state["running"] and state["results"]:
            break
        time.sleep(0.5)
    result = next((r for r in state["results"] if r["host"] == host), None)
    c.expect(result is not None, f"no result for {host}: {state}")
    c.expect("RAN-ON-" in result["output"], f"expected the command's output, saw {result['output']!r}")
    c.expect(result["summary"].startswith("exit 3"), f"expected exit 3 reported, saw {result['summary']!r}")

# ---------------------------------------------------------------- C, Y, Z

@test("C1", "Tailcat Peers: add a peer")
def _(c):
    c.command("tailcat", settle=1.5)
    c.until(lambda s: has_window(s, "Tailcat"), "expected the Tailcat Peers window")
    c.unverified("the window opens; adding a peer needs its form, which the bridge doesn't fill yet")
for fid in ("C2", "C3", "C4", "C5", "C6"):
    manual(fid, "Tailcat", "needs a second machine running tailcat")
manual("C7", "Unlock / Lock", "the Tailcat window isn't driven by the bridge yet")
manual("Y1", "Names and hints for screen readers", "covered by parity/check.sh and a screen-reader pass")
manual("Y2", "States announced", "needs a screen reader")
manual("Y3", "Password field labels", "covered by the accessibility tree; not automated here")
manual("Y4", "Reduce Motion", "visual")
manual("Y5", "Shared identifiers", "covered by parity/check.sh")
for fid in ("Z1", "Z2", "Z3", "Z4"):
    manual(fid, "Safety", "needs damaged files or a dropped connection (fault injection, not automated yet)")
manual("Z5", "Self-contained", "checked by each platform's packaging script")
