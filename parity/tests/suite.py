"""The feature tests: one or more checks per feature in parity/features.md, the same on every platform.

Each test gets a fresh app (`Context`) and ends in one outcome:
  works      every expectation held;
  broken     the feature is there but an expectation failed (the detail says what was seen);
  missing    the platform has no such command, or it's greyed out where the Mac's isn't;
  unverified the feature can't be checked automatically yet (the reason says why), so a person must try it.
Tests registered with `manual` don't start the app.
"""
import os
import re
import shutil
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

    def uia(self, press=None, find=None):
        """Windows: the app's windows as UI Automation shows them to screen readers (uia.ps1), after pressing the
        element with identifier `press` the way an assistive tool would."""
        if self.platform != "windows":
            raise Outcome("unverified", "this platform's accessibility tree is checked by parity/check.sh, not the feature tests")
        import json, subprocess
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uia.ps1")
        arguments = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProcessId", str(self.app.process.pid)]
        if press:
            arguments += ["-Press", press]
        if find:
            arguments += ["-Find", find]
        result = subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90)
        try:
            nodes = json.loads(result.stdout)
        except ValueError as error:
            raise Outcome("broken", f"UI Automation couldn't read the window: {error}: {result.stderr.strip()[-300:]} / around it {result.stdout[max(0, error.pos - 80):error.pos + 80]!r}")
        if isinstance(nodes, dict) and nodes.get("error"):
            raise Outcome("broken", f"UI Automation: {nodes['error']} ({press})")
        return nodes

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


def logged_in(c, account, s):
    """The remote shell's prompt is on screen (user@host:folder$), not just a line naming the account (an error does too)."""
    import re
    prompt = re.compile(r"^" + re.escape(account["user"]) + r"@[^\s:]+:[^\s]*[$#]\s*$")
    return any(prompt.match(line.rstrip()) for line in c.text(s).splitlines())


def expect_connected(c, account, s):
    c.expect(connection(c, s).get("state") == "connected" and logged_in(c, account, s),
             f"expected a login to {account['label']} (saw: {connection(c, s)}; {summary(s)})")


def connect_test_host(c, password=None):
    """Connects the selected tab to the test host, answering a first host-key question."""
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
        if state == "connected" and logged_in(c, account, s):
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

@test("W19", "Every menu in the window; shortcuts still reach the commands")
def _(c):
    menus = c.bridge.call("menus")
    if c.platform != "mac":
        # No system menu bar: the Main Menu holds every menu, in the Mac's order.
        main = menus["main"]
        titles = [item.get("title") for item in main]
        expected = ["Toggle Full Screen", "Edit", "Shell", "Window", "Settings…", "About Herb's Terminal", "Quit Herb's Terminal"]
        if [t for t in titles if t in expected] != expected:
            raise Outcome("broken", f"the Main Menu reads {titles}, expected {expected} in that order")
        def sub(title):
            return [item.get("title") for item in next(m for m in main if m.get("title") == title).get("items", [])]
        for title, items in (("Edit", ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Clear to Start", "Clear Scrollback"]),
                             ("Window", ["Minimize", "Zoom", "Show Tab 1", "Show Last Tab"])):
            missing = [i for i in items if i not in sub(title)]
            if missing:
                raise Outcome("broken", f"the Main Menu's {title} menu lacks {missing}")
        if sub("Shell")[0] != "New Tab" or sub("Shell")[-1] != "Hard Reset":
            raise Outcome("broken", f"the Shell menu isn't in the Mac's order: {sub('Shell')}")
        return
    if menus["bar"] != ["Herb's Terminal"]:
        raise Outcome("broken", f"the macOS menu bar shows {menus['bar']}, expected only the app menu")
    for title in ("Edit", "Shell", "Window"):
        if title not in menus["full"]:
            raise Outcome("broken", f"shortcuts can't reach the {title} menu ({menus['full']})")
    # The test copy never takes focus, so a command can't act on a window here (the same holds with the menu bar
    # shown); this checks that ⌘T reaches the hidden Shell menu. Running it in a focused window is checked by hand.
    if not c.bridge.call("shortcut", key="t"):
        raise Outcome("broken", "⌘T didn't reach the hidden Shell menu")


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
    c.command("find", settle=1)
    if "find" not in (c.pane() or {}):
        c.unverified("the command runs; whether the search field opens isn't reported by this platform's bridge yet")
    c.until(lambda s: c.pane(s)["find"]["shown"], "expected the find bar to open")

@test("W12", "Main Menu: New Tab, New Window, Connect via SSH")
def _(c):
    c.probe("new-tab", "new-window", "connect")

@test("W13", "Find in Terminal")
def _(c):
    c.probe("find-in-terminal")
    c.command("find-in-terminal", settle=1)
    if "find" not in (c.pane() or {}):
        c.unverified("the command runs; whether the search field opens isn't reported by this platform's bridge yet")
    c.until(lambda s: c.pane(s)["find"]["shown"], "expected the find bar to open")

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

@test("T2", "The only terminal tab left becomes Terminal 1")
def _(c):
    c.command("new-tab"); c.command("new-tab")
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1", "Terminal 2", "Terminal 3"], "expected three tabs")
    c.command("tab-1"); c.command("close-tab", settle=1.2)
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 2", "Terminal 3"], "expected Terminal 2 and 3 after closing 1")
    c.command("tab-1"); c.command("close-tab", settle=1.2)
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1"], "expected the last tab to become Terminal 1")
    c.command("new-tab")
    c.until(lambda s: [t["name"] for t in c.tabs(s)] == ["Terminal 1", "Terminal 2"], "expected the next tab to be Terminal 2")

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

@test("T11", "Session restore reopens tabs with their names, folders, splits and explorer")
def _(c):
    c.cd_root()
    c.command("new-tab", settle=1.5)
    c.command("rename-tab", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the Rename dialog")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), ["Saved Tab"])
    c.command("split-vertical", settle=1.5)
    c.command("new-tab", settle=1.5)
    c.command("toggle-explorer", settle=1.5)
    try:
        # The test copy never writes the session file; the bridge hands over what would be saved instead.
        snapshot = c.bridge.call("session-snapshot")
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("this platform's test bridge can't read or reopen a session yet")
        raise
    c.bridge.call("session-open", windows=snapshot)
    s = c.until(lambda s: len(s["windows"]) == 2 and len(c.tabs(s)) == 3, "expected a second window with the three tabs", timeout=10)
    tabs = c.tabs(s)
    c.expect(tabs[1]["name"] == "Saved Tab", f"expected the renamed tab back, saw {[t['name'] for t in tabs]}")
    c.expect([len(t["panes"]) for t in tabs[:2]] == [1, 2], f"expected the split back, saw {[len(t['panes']) for t in tabs]}")
    c.expect(tabs[2]["layout"] == "explorer", f"expected the third tab's explorer back, saw {tabs[2]['layout']}")
    c.command("tab-1", settle=1)
    c.pwd()
    c.until(lambda s: any(l.strip() in ("/", "C:\\") for l in c.text(s).splitlines()), "expected the first tab back in /")

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
        # Command Prompt: special characters, % included, are taken literally.
        c.app.set_clipboard(text="a&b %PATH% (x)")
        c.type("echo ", settle=0.4)
        run("paste-escaped")
        c.type(c.app.enter, settle=1.2)
        c.until(lambda s: "a&b %PATH% (x)" in [l.strip() for l in c.text(s).splitlines()], "expected Paste Escaped Text to keep the text literal")
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
    if "find" not in (c.pane() or {}):
        c.unverified("Copy, Paste, Paste Escaped Text and Select All work; Find… runs, but this platform's bridge doesn't report the find bar yet")
    c.until(lambda s: c.pane(s)["find"]["shown"], "expected Find… to open the find bar")

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
@test("B7", "Size badge while resizing")
def _(c):
    try:
        c.bridge.call("resize-grid", columns=90, rows=26)
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("this platform's test bridge can't resize the window yet")
        raise
    c.until(lambda s: c.pane(s).get("badge") == "90 × 26", "expected the badge to show 90 × 26")
    c.until(lambda s: c.pane(s).get("badge") is None, "expected the badge to go away after the resize", timeout=5)

@test("B8", "Find in Terminal")
def _(c):
    c.probe("find-in-terminal")
    first, second = c.say("FINDME"), c.say("FINDME")
    c.until(lambda s: c.text(s).count(first) >= 2, "expected the word printed twice")
    if c.platform == "mac":
        c.unverified("opening the find bar is checked in W13; typing into it would use the Mac's shared find pasteboard, which the tests leave alone")
    try:
        c.bridge.call("find", text="findme")
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("the command is there; this platform's bridge doesn't report the find bar and its matches yet")
        raise
    c.until(lambda s: c.pane(s)["find"]["shown"], "expected the find bar to open")
    if "matches" not in c.pane()["find"]:
        c.unverified("the find bar opens with the text; this platform's terminal (VTE) highlights matches but doesn't count them")
    # Case is ignored, and only the printed words match (the typed lines hide the word).
    s = c.until(lambda s: c.pane(s)["find"]["shown"] and c.pane(s)["find"]["matches"] == 2 and c.pane(s)["selection"] == "FINDME",
                "expected the find bar with 2 matches and the last one selected")
    c.bridge.call("find-step", up=True)
    c.until(lambda s: c.pane(s)["selection"] == "FINDME", "expected Previous to select the other match")

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

manual("B14", "Colors, styles, wide characters", "visual: needs the window's picture compared with the Mac's")


def mouse(c, kind, column, row, **extra):
    result = c.bridge.call("mouse", kind=kind, column=column, row=row, **extra)
    if result == "unsupported":
        c.unverified("this platform's test bridge can't send mouse events yet")
    time.sleep(0.3)
    return result


# Turns on SGR mouse reporting on the host, reads one press (ends in M) and one release (ends in m), turns it off
# and prints them with the escape shown as ^[.
MOUSE_READER = (r"""printf '\033[?1000h\033[?1006h'; IFS= read -rs -d M a; IFS= read -rs -d m b; """
                r"""printf '\033[?1000l\033[?1006l'; printf 'GO''T%s|%s\n' "$a" "$b" | cat -v""")


@test("B14", "Mouse reporting: a full-screen program gets clicks, the wheel, and Shift+drag still selects")
def _(c):
    if c.platform != "windows":
        c.unverified("this platform's test bridge can't send mouse events yet")
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.type(MOUSE_READER + "\r", settle=1.5)
    # Shift+drag selects instead of reporting, as on the Mac.
    mouse(c, "down", 2, 0, shift=True)
    mouse(c, "move", 9, 0, shift=True, held=True)
    result = mouse(c, "up", 9, 0, shift=True)
    c.expect(result["selection"].strip(), "Shift+drag didn't select while the program tracks the mouse")
    mouse(c, "down", 5, 2)
    mouse(c, "up", 5, 2)
    s = c.until(lambda s: "GOT" in c.text(s), "the program didn't get the click")
    line = next(l for l in c.text(s).splitlines() if l.startswith("GOT"))
    c.expect(line.strip() == "GOT^[[<0;6;3|^[[<0;6;3", f"the click was reported as {line.strip()!r}, not at column 6, row 3")
    # The wheel: button 64 (up) with SGR reporting.
    c.type(MOUSE_READER.replace("-d m b", "-d M b") + "\r", settle=1.5)
    mouse(c, "wheel", 3, 1, delta=40)
    mouse(c, "wheel", 3, 1, delta=-40)
    s = c.until(lambda s: sum(l.startswith("GOT") for l in c.text(s).splitlines()) >= 2, "the program didn't get the wheel")
    line = [l for l in c.text(s).splitlines() if l.startswith("GOT")][-1]
    c.expect(line.strip() == "GOT^[[<64;4;2|^[[<65;4;2", f"the wheel was reported as {line.strip()!r}")


@test("B15", "Input methods compose at the cursor and type their result")
def _(c):
    if c.platform != "windows":
        c.unverified("this platform's test bridge can't drive an input method yet")
    c.type("echo ", settle=0.5)
    result = c.bridge.call("ime", text="\u4f60\u597d")
    c.expect(result.get("window"), "the terminal has no input context for input methods")
    window, cursor = result["window"], result["cursor"]
    c.expect(abs(window[0] - cursor[0]) <= 1 and abs(window[1] - cursor[1]) <= 1,
             f"the composition window is at {window}, not at the cursor {cursor}")
    c.until(lambda s: "echo \u4f60\u597d" in c.text(s), "the input method's result wasn't typed")
    c.type(c.app.enter, settle=1)
    c.until(lambda s: any(l.strip() == "\u4f60\u597d" for l in c.text(s).splitlines()), "the shell didn't get the composed text")

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

@test("R1", "New Tab with Profile, and new tabs keep the current tab's profile")
def _(c):
    word = "SECOND" + "PROFILE"
    command = f"echo {word[:3]}\"\"{word[3:]}" if c.app.shell == "posix" else f"echo {word[:3]}^{word[3:]}"
    try:
        profile = c.bridge.call("profile-add", name="Test Two", startupCommand=command)
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("this platform's test bridge can't make or choose profiles yet")
        raise
    c.bridge.call("profile-new-tab", profile=profile)
    time.sleep(2)
    c.until(lambda s: len(c.tabs(s)) == 2 and c.pane(s).get("profile") == "Test Two", "expected a new tab with the profile Test Two")
    c.until(lambda s: word in c.text(s), "expected the profile's startup command to run in it", timeout=8)
    c.command("new-tab", settle=2)
    c.until(lambda s: len(c.tabs(s)) == 3 and c.pane(s).get("profile") == "Test Two", "expected the next new tab to keep Test Two")

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

@test("S2", "Connecting while the tab is busy opens a new tab for it")
def _(c):
    c.run("sleep 40", "ping -n 41 127.0.0.1 >nul", settle=1.5)
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.expect(len(c.tabs(s)) == 2, f"expected a second tab for the login, saw {[t['name'] for t in c.tabs(s)]}")

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

def explorer_follows_with_password(c, account):
    """The explorer shows the host's home folder; where it signs in on its own (Windows), it may ask for the password."""
    c.command("toggle-explorer", settle=2)
    deadline = time.time() + 60
    while time.time() < deadline:
        s = c.state()
        for dialog in s.get("dialogs", []):
            if "Sign in" in dialog["heading"]:
                c.answer(next(r for r in dialog["responses"] if r.lower() != "cancel"), [account["password"]], heading=dialog["heading"])
        explorer = c.tab(s).get("explorer", {})
        if explorer.get("remote") and explorer.get("path", "").rstrip("/") == f"/home/{account['user']}":
            return
        time.sleep(0.5)
    s = c.state()
    raise Outcome("broken", f"expected the explorer in {account['user']}'s home on the host (explorer: {c.tab(s).get('explorer')}; {summary(s)})")

@test("S3", "A typed ssh is followed, and exit returns the tab")
def _(c):
    account = ssh_account()
    if not account:
        c.unverified(NEEDS_SSH)
    if c.app.shell == "posix":
        c.unverified("the test scene's /bin/sh runs ssh unchanged by design; zsh and bash tabs follow it")
    c.run(f"ssh -p {account['port']} {account['user']}@{account['host']}", settle=2)
    deadline, typed_password = time.time() + 30, False
    while time.time() < deadline:
        s = c.state()
        text = c.text(s)
        last = text.rstrip().splitlines()[-1] if text.strip() else ""
        if "(yes/no" in last:
            c.type("yes" + c.app.enter, settle=1)
        elif not typed_password and last.lower().endswith("password:"):
            c.type(account["password"] + c.app.enter, settle=2)
            typed_password = True
        elif connection(c, s).get("state") == "connected" and logged_in(c, account, s):
            break
        time.sleep(0.5)
    s = c.state()
    expect_connected(c, account, s)
    c.expect(account["label"] in c.window(s)["title"], f"the title doesn't name {account['label']}: {c.window(s)['title']!r}")
    explorer_follows_with_password(c, account)
    c.command("toggle-explorer", settle=1.5)
    c.run("exit", settle=2)
    c.until(lambda s: connection(c, s).get("state") == "local" and account["label"] not in c.window(s)["title"],
            "expected exit to return the tab to this computer", timeout=15)

HOST_SILENT_FOR = 30  # seconds the test host stays silent; the rule removes itself after that

def silence_test_host(c, account):
    """Makes the test host stop answering the test account (as when it's switched off): firewall rules on the host
    drop everything sent on that account's SSH connections from this computer (found from its sshd processes and the
    session's SSH_CLIENT, so the other machines' runs, which share the account, carry on), and remove themselves
    after HOST_SILENT_FOR seconds. Typed into the tab's own session; sudo's password goes in at sudo's prompt, never
    on a command line or the screen. (The kernel's owner match can't be used: the root listener creates the sockets.)"""
    user = account["user"]
    script = ("iptables -N '\"$HTC\"' 2>/dev/null; iptables -F '\"$HTC\"'; iptables -C OUTPUT -j '\"$HTC\"' 2>/dev/null || iptables -I OUTPUT -j '\"$HTC\"'; "
              f"for port in $(ss -Htnp state established \"( sport = :22 )\" | grep -E \"pid=($(pgrep -d\"|\" -u {user} sshd)),\" "
              "| awk \"{print \\$4}\" | grep \"^'\"${SSH_CLIENT%% *}\"':\" | sed \"s/.*://\"); do iptables -A '\"$HTC\"' -p tcp --sport 22 --dport $port -j DROP; done; "
              f"nohup setsid sh -c \"sleep {HOST_SILENT_FOR}; iptables -D OUTPUT -j '\"$HTC\"'; iptables -F '\"$HTC\"'; iptables -X '\"$HTC\"'\" >/dev/null 2>&1 &")
    # A chain of its own per client, so runs from different machines don't clear each other's rules.
    c.type("HTC=HT$(echo ${SSH_CLIENT%% *} | tr -d .:); sudo -k; sudo sh -c '" + script + "'" + c.app.enter, settle=1.5)
    c.until(lambda s: "password" in c.text(s).lower().split("sudo -k")[-1], "expected sudo to ask for the password", timeout=10)
    c.type(account["password"] + c.app.enter, settle=0.5)
    return time.time()

@test("S6", "Keepalive ends a session whose host has gone away")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    started = silence_test_host(c, account)
    try:
        # The spec says about 15 s (ServerAlive every 5 s, two misses); allow some slack, never the TCP timeout.
        c.until(lambda s: connection(c, s).get("state") != "connected", "expected the session to end once the host stopped answering",
                timeout=25)
        c.expect(time.time() - started < 25, "expected the dead session to end within about 15 seconds")
        c.until(lambda s: account["label"] not in c.window(s)["title"], "expected the title back on this computer", timeout=8)
    finally:
        time.sleep(max(0, HOST_SILENT_FOR + 2 - (time.time() - started)))

@test("Z4", "A host that goes away is an error, never a crash")
def _(c):
    account, s = connect_test_host(c)
    expect_connected(c, account, s)
    c.command("toggle-explorer", settle=2)
    c.until(lambda s: c.tab(s).get("explorer", {}).get("remote"), "expected the host's files", timeout=15)
    started = silence_test_host_from_explorer(c, account)
    try:
        c.bridge.call("explorer-go", path="/etc")
        # The app keeps answering while the explorer waits on a host that's gone, and ends up reporting it.
        c.until(lambda s: connection(c, s).get("state") != "connected" or c.tab(s)["explorer"].get("status"),
                "expected the explorer or the session to report the lost host", timeout=45)
        c.expect(c.state() is not None, "expected the app to keep answering")
    finally:
        time.sleep(max(0, HOST_SILENT_FOR + 2 - (time.time() - started)))

def silence_test_host_from_explorer(c, account):
    """silence_test_host, typed in the terminal while the explorer shows."""
    c.command("toggle-explorer", settle=1)
    started = silence_test_host(c, account)
    c.command("toggle-explorer", settle=1)
    return started

for fid, what in (("S6", "Shared connection (ControlMaster)"), ("S8", "Host-key questions in the terminal"),
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

def names(c, s=None):
    """The list's names without the folder mark some bridges add."""
    return [i.rstrip("/\\") for i in items(c, s)]

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
    def at(target):
        return lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\").lower() == target.rstrip("/\\").lower()
    home, sub = c.app.home, c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub")
    for name in ("explorer.back", "explorer.forward", "explorer.up", "explorer.home"):
        if c.bridge.call("probe", name=name) in ("missing", "unsupported"):
            c.unverified("going into a folder works; Back, Forward, Up and Home are buttons the bridge doesn't press yet")
    c.command("explorer.back", settle=1)
    c.until(at(home), "expected Back to return to the first folder")
    c.command("explorer.forward", settle=1)
    c.until(at(sub), "expected Forward to go into sub again")
    c.command("explorer.up", settle=1)
    c.until(at(home), "expected Up to open the folder holding sub")
    c.bridge.call("explorer-go", path=sub)
    c.until(at(sub), "expected to be in sub again")
    c.command("explorer.home", settle=1)
    c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\") not in ("", sub.rstrip("/\\")), "expected Home to leave sub for the home folder")

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
    # A Rename dialog (Mac, Linux), or the name edited in place in the list (Windows, as in File Explorer).
    s = c.until(lambda s: s.get("dialogs") or c.tab(s).get("explorer", {}).get("renaming"), "expected Rename to ask for the new name")
    if s.get("dialogs"):
        c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), ["renamed-by-test"])
    else:
        c.bridge.call("explorer-rename", name="renamed-by-test")
    c.until(lambda s: any(i.rstrip("/\\") == "renamed-by-test" for i in items(c, s)), "expected the folder renamed")

@test("E14", "Find files")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s) and "sub" in names(c, s), "expected note.txt and sub in the list")
    c.probe("explorer.find")
    try:
        c.bridge.call("explorer-filter", text="NOTE")
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("the command is there; this platform's bridge doesn't type into the Find field yet")
        raise
    # Case is ignored, and only names containing the text stay.
    s = c.until(lambda s: "note.txt" in items(c, s) and "sub" not in names(c, s), "expected Find to keep note.txt and hide sub")
    c.expect(all("note" in i.lower() for i in items(c, s)), f"expected only names with 'note', saw {items(c, s)}")
    c.expect(c.tab(s)["explorer"].get("finding") is not False, "expected the Find field to be open")
    # Going to another folder closes Find; coming back shows everything again.
    sub = c.app.home.rstrip("/\\") + ("/sub" if c.platform != "windows" else "\\sub")
    c.bridge.call("explorer-go", path=sub)
    c.until(lambda s: c.tab(s)["explorer"]["path"].rstrip("/\\").endswith("sub") and not c.tab(s)["explorer"].get("filter")
            and not c.tab(s)["explorer"].get("finding"), "expected going to another folder to close Find")
    c.bridge.call("explorer-go", path=c.app.home)
    c.until(lambda s: "sub" in names(c, s), "expected every item back in the first folder")

@test("E15", "Open in Text Editor, Open with Default App, Show in the file manager")
def _(c):
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt")
    c.bridge.call("explorer-select", names=["note.txt"])
    c.probe("explorer.edit", "explorer.open-default", "explorer.reveal")

manual("E16", "Open with Administrator Mode", "needs a sudo password (not automated)")

# ---------------------------------------------------------------- X, D, G, A

def host_folder(c, account, prefix):
    """A fresh folder in the test account's home on the host, made with New Folder, shown in the explorer."""
    home = f"/home/{account['user']}"
    c.bridge.call("explorer-go", path=home)
    c.until(lambda s: c.tab(s)["explorer"].get("path", "").rstrip("/") == home and not c.tab(s)["explorer"].get("loading"),
            "expected the account's home on the host", timeout=15)
    name = f"{prefix}-{int(time.time())}"
    c.command("explorer.new-folder", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected the New Folder dialog")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"), [name])
    c.until(lambda s: name in names(c, s), "expected the new folder on the host", timeout=10)
    c.bridge.call("explorer-go", path=f"{home}/{name}")
    c.until(lambda s: c.tab(s)["explorer"].get("path", "").rstrip("/") == f"{home}/{name}", "expected the new folder open", timeout=10)
    return home, name

def remove_host_folder(c, home, name):
    """Deletes a folder host_folder made (best effort: a failed clean-up doesn't fail the test)."""
    try:
        c.bridge.call("explorer-go", path=home)
        c.until(lambda s: name in names(c, s), "expected the folder", timeout=10)
        c.bridge.call("explorer-select", names=[name + "/", name])
        c.command("explorer.delete", settle=1.2)
        s = c.state()
        if s.get("dialogs"):
            c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() != "cancel"))
    except Exception:
        pass

def transfers_done(c, s, count):
    """At least `count` transfers in the strip, and every one finished."""
    items_ = c.tab(s)["explorer"].get("transfers") or []
    return len(items_) >= count and all(t["state"].startswith(("completed", "failed", "cancelled")) for t in items_)

def local_tree(c, root):
    """A file and a folder tree with a nested folder, in a fresh local folder; returns the paths to upload."""
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "tree", "deep"))
    # newline="\n": the same bytes on every platform (Windows would write \r\n).
    with open(os.path.join(root, "one.txt"), "w", encoding="utf-8", newline="\n") as f: f.write("one\n")
    with open(os.path.join(root, "tree", "a.txt"), "w", encoding="utf-8", newline="\n") as f: f.write("alpha\n")
    with open(os.path.join(root, "tree", "deep", "b.txt"), "w", encoding="utf-8", newline="\n") as f: f.write("beta " * 4000)
    return [os.path.join(root, "one.txt"), os.path.join(root, "tree")]

def upload(c, paths):
    try:
        result = c.bridge.call("explorer-upload", timeout=45, paths=paths)
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("this platform's test bridge can't upload without the open dialog yet")
        raise
    if result == "unsupported":
        c.unverified("this platform's test bridge can't upload without the open dialog yet")

@test("X1", "Upload and download single files and folder trees")
def _(c):
    account = host_explorer(c)
    home, name = host_folder(c, account, "x1")
    try:
        source = os.path.join(c.app.home, "x1-source")
        upload(c, local_tree(c, source))
        c.until(lambda s: {"one.txt", "tree"} <= set(names(c, s)) and transfers_done(c, s, 1), "expected one.txt and tree on the host", timeout=30)
        failed = [t for t in c.tab()["explorer"]["transfers"] if not t["state"].startswith("completed")]
        c.expect(not failed, f"expected every upload to finish, saw {failed}")
        c.bridge.call("explorer-go", path=f"{home}/{name}/tree")
        c.until(lambda s: {"a.txt", "deep"} <= set(names(c, s)), "expected the tree's files and its nested folder on the host", timeout=10)
        # And back down again, into a fresh local folder.
        c.bridge.call("explorer-go", path=f"{home}/{name}")
        c.until(lambda s: {"one.txt", "tree"} <= set(names(c, s)), "expected the uploaded items", timeout=10)
        c.bridge.call("explorer-select", names=["one.txt", "tree/", "tree"])
        target = os.path.join(c.app.home, "x1-back")
        shutil.rmtree(target, ignore_errors=True); os.makedirs(target)
        c.bridge.call("explorer-download", into=target)
        def same():
            try:
                return (open(os.path.join(target, "one.txt"), "rb").read() == b"one\n"
                        and open(os.path.join(target, "tree", "a.txt"), "rb").read() == b"alpha\n"
                        and open(os.path.join(target, "tree", "deep", "b.txt"), encoding="utf-8").read() == "beta " * 4000)
            except OSError:
                return False
        c.until(lambda s: same(), "expected the file and the whole tree downloaded unchanged", timeout=30)
    finally:
        remove_host_folder(c, home, name)

@test("X2", "Progress strip lists each transfer and its outcome")
def _(c):
    account = host_explorer(c)
    home, name = host_folder(c, account, "x2")
    try:
        upload(c, local_tree(c, os.path.join(c.app.home, "x2-source"))[:1])
        s = c.until(lambda s: transfers_done(c, s, 1), "expected the upload in the transfer strip, finished", timeout=30)
        c.expect(any(t["name"] == "one.txt" and t["state"].startswith("completed") for t in c.tab(s)["explorer"]["transfers"]),
                 f"expected one.txt listed as completed, saw {c.tab(s)['explorer']['transfers']}")
    finally:
        remove_host_folder(c, home, name)

manual("X2", "Cancel, Retry and Clear Finished", "needs a transfer slow enough to cancel; not automated yet")

@test("X7", "Name clashes get new names, never overwrites")
def _(c):
    account = host_explorer(c)
    home, name = host_folder(c, account, "x7")
    try:
        one = local_tree(c, os.path.join(c.app.home, "x7-source"))[0]
        upload(c, [one])
        c.until(lambda s: "one.txt" in names(c, s) and transfers_done(c, s, 1), "expected one.txt on the host", timeout=30)
        upload(c, [one])
        s = c.until(lambda s: len([n for n in names(c, s) if n.startswith("one")]) == 2 and transfers_done(c, s, 2),
                    "expected the second upload under a new name beside one.txt", timeout=30)
        c.expect("one.txt" in names(c, s), f"expected the first one.txt kept, saw {names(c, s)}")
    finally:
        remove_host_folder(c, home, name)

for fid, title in (("X3", "Up to 16 requests in flight"), ("X6", "Staged uploads")):
    manual(fid, title, "inside the SFTP client, where the bridge can't see its requests; not automated yet")
manual("X4", "A silent server ends the request after 30 s", "needs a dropped connection (fault injection, not automated yet)")
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

def editor(c, action=None, text=""):
    """The editor tab's state, after running an action on it (type, undo, find, save, wrap, start)."""
    if action is None:
        return c.tab().get("editor", {})
    try:
        return c.bridge.call("editor", action=action, text=text)
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("the bridge can't type into the editor or read its status yet")
        raise

def open_in_editor(c, name, data):
    """Writes a file in the scene's folder and opens it in the text editor from the explorer."""
    with open(os.path.join(c.app.home, name), "wb") as f:
        f.write(data)
    explorer_at_home(c, files=False)
    c.until(lambda s: name in items(c, s), f"expected {name} in the list")
    c.bridge.call("explorer-select", names=[name])
    c.command("explorer.edit", settle=1.5)
    c.until(lambda s: c.tab(s).get("kind") == "editor", f"expected {name} in the editor")
    editor(c, "start")
    return c.until(lambda s: c.tab(s).get("editor", {}).get("loaded", True) and c.tab(s)["editor"].get("text") is not None,
                   "expected the file loaded")["windows"][0]

def file_bytes(c, name):
    with open(os.path.join(c.app.home, name), "rb") as f:
        return f.read()

STATUS = re.compile(r"Line (\d+), Column (\d+) · (\d+) lines? · (.+) · (LF|CRLF)$")

def status_of(c, s=None):
    found = STATUS.match(c.tab(s).get("editor", {}).get("status", ""))
    return found.groups() if found else None

@test("D3", "Text editor: monospaced font, undo, Find")
def _(c):
    open_in_editor(c, "notes.txt", b"alpha\nbeta\ngamma\n")
    c.expect(editor(c).get("monospaced") is True, "expected a monospaced font")
    editor(c, "type", "XYZ")
    c.until(lambda s: c.tab(s)["editor"]["text"].startswith("XYZalpha"), "expected the typed text at the start")
    editor(c, "undo")
    c.until(lambda s: c.tab(s)["editor"]["text"] == "alpha\nbeta\ngamma\n", "expected Undo to take the typing back")
    editor(c, "find", "BETA")
    c.until(lambda s: c.tab(s)["editor"].get("finding"), "expected the find bar")
    # The Mac's find bar is AppKit's, which the bridge opens but doesn't type into; Linux and Windows search here.
    if c.platform != "mac":
        c.until(lambda s: c.tab(s)["editor"].get("selection", "").lower() == "beta", "expected Find to select the match, ignoring case")

@test("D4", "Text editor: Wrap Lines")
def _(c):
    open_in_editor(c, "wide.txt", b"x" * 400 + b"\n")
    before = editor(c).get("wrap")
    editor(c, "wrap")
    c.until(lambda s: c.tab(s)["editor"].get("wrap") == (not before), "expected Wrap Lines to switch")
    editor(c, "wrap")
    c.until(lambda s: c.tab(s)["editor"].get("wrap") == before, "expected Wrap Lines to switch back")

@test("D5", "Text editor: status line")
def _(c):
    open_in_editor(c, "lines.txt", b"one\ntwo\nthree")
    s = c.until(lambda s: status_of(c, s), "expected a status line with line, column, line count, encoding and endings")
    line, column, count, encoding, endings = status_of(c, s)
    c.expect((line, column, count, endings) == ("1", "1", "3", "LF"), f"expected Line 1, Column 1, 3 lines, LF; saw {c.tab(s)['editor']['status']!r}")
    c.expect("UTF-8" in encoding, f"expected UTF-8, saw {encoding!r}")
    editor(c, "type", "ab")
    c.until(lambda s: (status_of(c, s) or ())[:2] == ("1", "3"), "expected the column to follow the caret")

@test("D5", "Text editor: CRLF line endings shown")
def _(c):
    open_in_editor(c, "crlf.txt", b"one\r\ntwo\r\n")
    c.until(lambda s: (status_of(c, s) or ("",) * 5)[4] == "CRLF", "expected CRLF in the status line")

@test("D6", "Text editor: Save, and the dot on the tab while unsaved")
def _(c):
    open_in_editor(c, "save.txt", b"hello\n")
    editor(c, "type", "x")
    s = c.until(lambda s: c.tab(s)["editor"].get("edited"), "expected the editor to show unsaved changes")
    c.expect("•" in c.tab(s)["name"], f"expected a dot on the tab, saw {c.tab(s)['name']!r}")
    editor(c, "save")
    s = c.until(lambda s: not c.tab(s)["editor"].get("edited"), "expected Save to clear the unsaved mark")
    c.expect("•" not in c.tab(s)["name"], f"expected the dot gone, saw {c.tab(s)['name']!r}")
    c.expect(file_bytes(c, "save.txt") == b"xhello\n", f"expected the file saved, it holds {file_bytes(c, 'save.txt')!r}")

@test("D7", "Text editor: closing with unsaved changes asks first")
def _(c):
    open_in_editor(c, "close.txt", b"hello\n")
    editor(c, "type", "x")
    c.until(lambda s: c.tab(s)["editor"].get("edited"), "expected unsaved changes")
    c.command("close-tab", settle=1.2)
    s = c.until(lambda s: s.get("dialogs"), "expected a question before the changes are lost")
    responses = s["dialogs"][0]["responses"]
    # Button titles, or their ids where the bridge reports those (Linux: discard, cancel, save).
    c.expect(any("don" in r.lower() or r.lower() == "discard" for r in responses) and any(r.lower() == "cancel" for r in responses),
             f"expected Don't Save and Cancel, saw {responses}")
    c.answer(next(r for r in responses if r.lower() == "cancel"))
    c.until(lambda s: c.tab(s).get("kind") == "editor" and c.tab(s)["editor"].get("edited"), "expected Cancel to keep the tab and its changes")
    c.expect(file_bytes(c, "close.txt") == b"hello\n", "expected the file untouched")

@test("D8", "Text editor: a file changed elsewhere asks before it's replaced")
def _(c):
    open_in_editor(c, "changed.txt", b"mine\n")
    time.sleep(1.1)
    with open(os.path.join(c.app.home, "changed.txt"), "wb") as f:
        f.write(b"theirs\n")
    later = time.time() + 5
    os.utime(os.path.join(c.app.home, "changed.txt"), (later, later))
    editor(c, "type", "x")
    editor(c, "save")
    s = c.until(lambda s: s.get("dialogs"), "expected a question about the file changed since it was opened")
    c.expect("changed" in s["dialogs"][0]["heading"].lower(), f"expected the question to say the file changed, saw {s['dialogs'][0]['heading']!r}")
    c.answer(next(r for r in s["dialogs"][0]["responses"] if r.lower() == "cancel"))
    time.sleep(1)
    c.expect(file_bytes(c, "changed.txt") == b"theirs\n", "expected Cancel to leave the other change in place")

@test("D9", "Text editor: keeps UTF-16 and CRLF")
def _(c):
    original = "\ufeffeins\r\nzwei\r\n".encode("utf-16-le")
    open_in_editor(c, "wide16.txt", original)
    editor(c, "type", "x")
    editor(c, "save")
    c.until(lambda s: not c.tab(s)["editor"].get("edited"), "expected the save to finish")
    saved = file_bytes(c, "wide16.txt")
    c.expect(saved == "\ufeffxeins\r\nzwei\r\n".encode("utf-16-le"), f"expected UTF-16 with its BOM and CRLF kept, saw {saved[:40]!r}")

@test("D9", "Text editor: keeps Latin-1 and the file's permissions")
def _(c):
    open_in_editor(c, "latin.txt", b"caf\xe9\n")
    path = os.path.join(c.app.home, "latin.txt")
    if c.platform != "windows":
        os.chmod(path, 0o640)
    editor(c, "type", "x")
    editor(c, "save")
    c.until(lambda s: not c.tab(s)["editor"].get("edited"), "expected the save to finish")
    c.expect(file_bytes(c, "latin.txt") == b"xcaf\xe9\n", f"expected Latin-1 kept, saw {file_bytes(c, 'latin.txt')!r}")
    if c.platform != "windows":
        c.expect(os.stat(path).st_mode & 0o777 == 0o640, f"expected the permissions kept, saw {oct(os.stat(path).st_mode & 0o777)}")

def refused(c, name, data, words):
    with open(os.path.join(c.app.home, name), "wb") as f:
        f.write(data)
    explorer_at_home(c, files=False)
    c.until(lambda s: name in items(c, s), f"expected {name} in the list")
    c.bridge.call("explorer-select", names=[name])
    try:
        c.command("explorer.edit", settle=2)
    except Outcome:
        raise
    s = c.until(lambda s: s.get("dialogs"), f"expected a message that {name} can't be edited", timeout=15)
    dialog = s["dialogs"][0]
    seen = (dialog.get("heading", "") + " " + dialog.get("text", "")).lower()
    c.answer(dialog["responses"][0])
    c.until(lambda s: c.tab(s).get("kind") != "editor", "expected no editor tab left open")
    return seen

@test("D10", "Text editor: refuses files over 20 MB")
def _(c):
    refused(c, "huge.txt", b"a" * (21 * 1024 * 1024), ("mb",))

@test("D10", "Text editor: refuses binary files")
def _(c):
    refused(c, "blob.txt", bytes(range(256)) * 64, ("text",))
def info(c, **request):
    """The newest Get Info window's state, after editing it as given (octal, toggle, owner, group, recursive, action)."""
    try:
        return c.bridge.call("info", **request)
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("the Get Info window isn't driven by the bridge yet")
        raise

def symbolic(mode):
    """`ls -l`'s rwx text for a mode, with s/S and t/T."""
    out = ""
    for shift, special, letter in ((6, 0o4000, "s"), (3, 0o2000, "s"), (0, 0o1000, "t")):
        r, w, x = (mode >> shift) & 4, (mode >> shift) & 2, (mode >> shift) & 1
        out += ("r" if r else "-") + ("w" if w else "-")
        out += (letter if x else letter.upper()) if mode & special else ("x" if x else "-")
    return out

def info_on(c, selection):
    """Selects items and opens Get Info on them; waits until it has loaded."""
    c.bridge.call("explorer-select", names=selection + [n + "/" for n in selection])
    c.command("explorer.info", settle=1.5)
    return c.until(lambda s: (lambda i: i.get("open") and not i.get("busy") and i.get("names"))(info(c)), "expected Get Info to show the items",
                   timeout=15) and info(c)

def host_items(c):
    """The test host's explorer in a fresh folder holding one.txt and the folder tree (a.txt and deep/ inside)."""
    account = host_explorer(c)
    home, name = host_folder(c, account, "g")
    upload(c, local_tree(c, os.path.join(c.app.home, "g-source")))
    c.until(lambda s: {"one.txt", "tree"} <= set(names(c, s)) and transfers_done(c, s, 1), "expected the items on the host", timeout=30)
    return account, home, name

@test("G1", "Get Info: name, location, kind, size, modified, permissions")
def _(c):
    account, home, name = host_items(c)
    try:
        i = info_on(c, ["one.txt"])
        c.expect(i["names"] == ["one.txt"] and i["location"].rstrip("/").endswith(name), f"expected one.txt in {name}, saw {i['names']} in {i['location']!r}")
        c.expect(i.get("size") == 4 and i.get("modified"), f"expected its size (4 bytes) and date, saw size {i.get('size')}")
        c.expect(i["symbolic"] == symbolic(int(i["octal"], 8)), f"expected the rwx text to match the octal {i['octal']}, saw {i['symbolic']!r}")
        info(c, action="close")
        i = info_on(c, ["one.txt", "tree"])
        c.expect(sorted(i["names"]) == ["one.txt", "tree"] and i["folders"] == ["tree"], f"expected both items, saw {i['names']}")
        info(c, action="close")
    finally:
        remove_host_folder(c, home, name)

@test("G2", "Get Info: permission checkboxes, special bits and the octal field in step")
def _(c):
    account, home, name = host_items(c)
    try:
        info_on(c, ["one.txt"])
        i = info(c, octal="640")
        c.until(lambda s: info(c)["symbolic"] == "rw-r-----", "expected 640 to show as rw-r-----")
        i = info(c, toggle=[0o001])
        c.until(lambda s: info(c)["octal"].lstrip("0") == "641" and info(c)["symbolic"] == "rw-r----x", "expected others' execute to make it 641")
        info(c, toggle=[0o4000])
        c.until(lambda s: info(c)["octal"] == "4641" and info(c)["symbolic"] == "rwSr----x", "expected set-UID to make it 4641 (rwS…)")
        info(c, octal="640", action="apply")
        c.until(lambda s: not info(c).get("busy") and not info(c).get("changed"), "expected Apply to finish", timeout=15)
        info(c, action="close")
        c.until(lambda s: info_on(c, ["one.txt"])["octal"].lstrip("0") == "640", "expected 640 kept on the host after Apply", timeout=20)
        info(c, action="close")
    finally:
        remove_host_folder(c, home, name)

@test("G3", "Get Info: owner and group looked up on the host")
def _(c):
    account, home, name = host_items(c)
    try:
        i = info_on(c, ["one.txt"])
        c.expect(i["owner"] == account["user"], f"expected the owner by name, {account['user']}, saw {i['owner']!r}")
        c.expect(i["group"] != "", "expected a group")
        info(c, owner="no-such-user-herbs", action="apply")
        c.until(lambda s: not info(c).get("busy") and info(c).get("message", info(c).get("error", "")), "expected an unknown owner to be refused with a message", timeout=15)
        info(c, action="revert")
        c.until(lambda s: info(c)["owner"] == account["user"] and not info(c).get("busy"), "expected the owner unchanged", timeout=15)
        info(c, action="close")
    finally:
        remove_host_folder(c, home, name)

@test("G5", "Get Info: Revert, and Apply to enclosed items")
def _(c):
    account, home, name = host_items(c)
    try:
        i = info_on(c, ["one.txt"])
        original = i["octal"]
        c.expect(not i["hasFolders"], "expected no Apply to enclosed items for a file")
        info(c, octal="600")
        c.until(lambda s: info(c).get("changed"), "expected the edit to count as a change")
        info(c, action="revert")
        c.until(lambda s: info(c)["octal"] == original and not info(c).get("changed"), "expected Revert to bring back the values on the host", timeout=15)
        info(c, action="close")
        i = info_on(c, ["tree"])
        c.expect(i["hasFolders"], "expected Apply to enclosed items for a folder")
        info(c, octal="700", recursive=True, action="apply")
        # With Apply to enclosed items ticked there is always something to apply, so wait for the message instead.
        c.until(lambda s: (lambda i: not i.get("busy") and "applied" in (i.get("message", "") + i.get("notice", "")).lower())(info(c)),
                "expected Apply to finish with “Changes applied.”", timeout=20)
        info(c, action="close")
        c.bridge.call("explorer-go", path=f"{home}/{name}/tree")
        c.until(lambda s: "a.txt" in names(c, s), "expected the tree's files", timeout=10)
        c.until(lambda s: info_on(c, ["a.txt"])["octal"].lstrip("0") == "700", "expected the file inside changed to 700 too", timeout=20)
        info(c, action="close")
    finally:
        remove_host_folder(c, home, name)

@test("G6", "Get Info on this computer")
def _(c):
    c.only("mac", "linux", reason="on Windows, this PC's items open Windows' own Properties (SPECIFICATION.md §12)")
    explorer_at_home(c)
    c.until(lambda s: "note.txt" in items(c, s), "expected note.txt")
    i = info_on(c, ["note.txt"])
    c.expect(i["names"] == ["note.txt"] and i["size"] == 6, f"expected note.txt (6 bytes), saw {i['names']} size {i.get('size')}")
    info(c, octal="600", action="apply")
    c.until(lambda s: not info(c).get("busy") and not info(c).get("changed"), "expected Apply to finish", timeout=10)
    mode = os.stat(os.path.join(c.app.home, "note.txt")).st_mode & 0o777
    c.expect(mode == 0o600, f"expected the file's mode 600 on disk, saw {oct(mode)}")
    info(c, action="close")
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
def logins(c, action=None, value=None):
    """The Manage Logins window's state, after pressing one of its controls."""
    try:
        request = {} if action is None else {"action": action, "value": value}
        return c.bridge.call("logins", **request)
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("the Manage Logins window isn't driven by the bridge yet")
        raise

def pick(responses, *words, avoid=("cancel", "not now", "later")):
    """The first response containing one of the words (titles or ids), else the first that isn't a way out."""
    for word in words:
        for response in responses:
            if word in response.lower():
                return response
    return next(r for r in responses if r.lower() not in avoid)

def open_logins(c):
    """Opens Manage Logins in the fresh test copy, choosing plain-text storage when it asks how to keep them."""
    c.command("manage-logins", settle=1.5)
    for _ in range(4):
        s = c.state()
        if logins(c).get("open"):
            return
        if s.get("dialogs"):
            dialog = s["dialogs"][0]
            c.answer(pick(dialog["responses"], "plain"), heading=dialog["heading"])
        else:
            time.sleep(0.8)
    c.until(lambda s: logins(c).get("open"), "expected the Manage Logins window")

PROTECTION = ("administrator password", "plain text")

def settle_protection(c, rounds=4):
    """Answers the questions about how to keep saved logins (first use), choosing plain text."""
    for _ in range(rounds):
        s = c.state()
        dialog = (s.get("dialogs") or [None])[0]
        if not dialog or not any(word in dialog["heading"].lower() for word in PROTECTION):
            return
        c.answer(pick(dialog["responses"], "plain"), heading=dialog["heading"])

def fill_login(c, host, port, user, password):
    """Fills in New Login or Edit Login and saves: the Mac's form sheet, or the dialog Linux and Windows show."""
    deadline = time.time() + 8
    while time.time() < deadline:
        try:
            form = c.bridge.call("login-form")
        except Exception:
            form = {"open": False}
        if form.get("open"):
            c.bridge.call("login-form", host=host, port=port, username=user, password=password, action="save")
            time.sleep(0.8)
            return
        s = c.state()
        dialog = (s.get("dialogs") or [None])[0]
        if dialog and dialog["heading"] in ("New Login", "Edit Login"):
            c.answer(pick(dialog["responses"], "save"), [host, str(port), user, password], heading=dialog["heading"])
            return
        if dialog:
            # How to keep saved logins, asked on first use.
            c.answer(pick(dialog["responses"], "plain"), heading=dialog["heading"])
        time.sleep(0.5)
    raise Outcome("broken", "expected the New Login form")

def add_login(c, host, port, user, password):
    logins(c, "new")
    fill_login(c, host, port, user, password)
    return c.until(lambda s: any(r["host"] == host and r["username"] == user for r in logins(c)["rows"]), f"expected {user}@{host} in the list")

@test("L6", "Manage Logins: the list shows host, port, username, a hidden password and how it's stored")
def _(c):
    open_logins(c)
    add_login(c, "alpha.example", 2222, "alice", "s3cret-test")
    add_login(c, "beta.example", 22, "bob", "")
    rows = {r["host"]: r for r in logins(c)["rows"]}
    a, b = rows["alpha.example"], rows["beta.example"]
    c.expect((a["port"], a["username"]) == (2222, "alice"), f"expected port 2222 and alice, saw {a}")
    c.expect("s3cret" not in a["password"] and a["password"].strip("•") == "", f"expected the password hidden, saw {a['password']!r}")
    c.expect("key" in b["password"].lower(), f"expected an empty password to read as SSH keys, saw {b['password']!r}")
    c.expect(a["stored"] == "Plain text", f"expected Plain text, saw {a['stored']!r}")

manual("L7", "Manage Logins: locked at start", "needs the logins locked at start, which takes a second launch of the same test copy")

@test("L8", "Manage Logins: Edit changes a login")
def _(c):
    open_logins(c)
    add_login(c, "gamma.example", 22, "carol", "pw-one")
    index = next(i for i, r in enumerate(logins(c)["rows"]) if r["host"] == "gamma.example")
    logins(c, "edit", index)
    fill_login(c, "gamma.example", 2200, "carol", "pw-two")
    c.until(lambda s: any(r["host"] == "gamma.example" and r["port"] == 2200 for r in logins(c)["rows"]), "expected Edit to change the port")
    c.expect(len([r for r in logins(c)["rows"] if r["host"] == "gamma.example"]) == 1, "expected the edited login to replace the old one")

@test("L9", "Manage Logins: Import a CSV, all or nothing")
def _(c):
    open_logins(c)
    good = os.path.join(c.app.home, "logins_in.csv")
    with open(good, "w", encoding="utf-8") as f:
        f.write("host,port,username,password\nimp1.example,22,dave,pw1\nimp2.example,2022,erin,\n")
    c.bridge.call("choose-file", path=good)
    logins(c, "import")
    time.sleep(1)
    settle_protection(c)
    c.until(lambda s: {"imp1.example", "imp2.example"} <= {r["host"] for r in logins(c)["rows"]}, "expected both imported logins", timeout=10)
    s = c.state()
    if s.get("dialogs"):
        c.answer(s["dialogs"][0]["responses"][0])
    bad = os.path.join(c.app.home, "logins_bad.csv")
    with open(bad, "w", encoding="utf-8") as f:
        f.write("host,port,username,password\nimp3.example,22,frank,pw\nimp4.example,notaport,gina,pw\n")
    c.bridge.call("choose-file", path=bad)
    logins(c, "import")
    s = c.until(lambda s: s.get("dialogs"), "expected a broken CSV to be refused with a message", timeout=10)
    c.answer(s["dialogs"][0]["responses"][0])
    c.expect("imp3.example" not in {r["host"] for r in logins(c)["rows"]}, "expected nothing imported from a CSV with a bad row")

@test("L10", "Manage Logins: Export the ticked logins, readable only by you")
def _(c):
    open_logins(c)
    add_login(c, "exp1.example", 22, "hank", "pw-h")
    add_login(c, "exp2.example", 22, "ivy", "pw-i")
    rows = logins(c)["rows"]
    logins(c, "check", next(i for i, r in enumerate(rows) if r["host"] == "exp1.example"))
    c.until(lambda s: logins(c)["export"].replace("…", "") == "Export (1)", f"expected Export (1), saw {logins(c)['export']!r}")
    folder = os.path.join(c.app.home, "export-here")
    os.makedirs(folder, exist_ok=True)
    c.bridge.call("choose-file", path=folder)
    logins(c, "export")
    for _ in range(3):
        s = c.state()
        if os.path.exists(os.path.join(folder, "logins_export.csv")):
            break
        if s.get("dialogs"):
            dialog = s["dialogs"][0]
            c.answer(pick(dialog["responses"], "export", "ok"), heading=dialog["heading"])
        time.sleep(1)
    path = os.path.join(folder, "logins_export.csv")
    c.until(lambda s: os.path.exists(path), "expected logins_export.csv written", timeout=8)
    text = open(path, encoding="utf-8").read()
    c.expect("exp1.example" in text and "exp2.example" not in text, f"expected only the ticked login exported, saw {text!r}")
    if c.platform != "windows":
        c.expect(os.stat(path).st_mode & 0o777 == 0o600, f"expected the file readable only by you, saw {oct(os.stat(path).st_mode & 0o777)}")
    if logins(c).get("checkAll") is False:
        raise Outcome("missing", "the list has no select-all checkbox in its heading")
    logins(c, "check-all", True)
    c.until(lambda s: all(r["checked"] for r in logins(c)["rows"]), "expected the heading's checkbox to tick every login")

@test("L11", "Manage Logins: Delete asks first, with Cancel as the default")
def _(c):
    open_logins(c)
    add_login(c, "del.example", 22, "jack", "pw-j")
    index = next(i for i, r in enumerate(logins(c)["rows"]) if r["host"] == "del.example")
    logins(c, "delete", index)
    s = c.until(lambda s: s.get("dialogs"), "expected a question before the login is deleted")
    dialog = s["dialogs"][0]
    responses = dialog["responses"]
    # Return must never delete: the default is Cancel, or (macOS with a destructive button) there is no default.
    # Bridges that don't report the default list the buttons in the order they were added, the default first.
    default = dialog["default"] if "default" in dialog else responses[0]
    c.expect(default is None or default.lower() == "cancel", f"expected Cancel (or nothing) as the default, saw {default!r} of {responses}")
    c.answer(next(r for r in responses if r.lower() == "cancel"))
    c.expect(any(r["host"] == "del.example" for r in logins(c)["rows"]), "expected Cancel to keep the login")
    logins(c, "delete", index)
    s = c.until(lambda s: s.get("dialogs"), "expected the question again")
    c.answer(pick(s["dialogs"][0]["responses"], "delete"))
    c.until(lambda s: not any(r["host"] == "del.example" for r in logins(c)["rows"]), "expected Delete to remove the login")

def passwords(c, action=None, value=None):
    try:
        request = {} if action is None else {"action": action, "value": value}
        return c.bridge.call("passwords", **request)
    except Exception as error:
        if "unknown op" in str(error):
            c.unverified("Snippets isn't driven by this platform's bridge yet")
        raise

def open_passwords(c):
    """Opens Manage Passwords, choosing plain-text storage if it asks how to keep saved passwords."""
    c.command("manage-passwords", settle=1.5)
    if c.state().get("dialogs"):
        settle_protection(c)
    c.until(lambda s: passwords(c).get("open"), "expected the Manage Snippets window")

def fill_password(c, name, password, description):
    """Fills in New or Edit Password and saves: the Mac's form sheet, or the dialog Linux and Windows show."""
    deadline = time.time() + 8
    while time.time() < deadline:
        try:
            form = c.bridge.call("password-form")
        except Exception:
            form = {"open": False}
        if form.get("open"):
            c.bridge.call("password-form", name=name, password=password, description=description, action="save")
            time.sleep(0.8)
            return
        dialog = (c.state().get("dialogs") or [None])[0]
        if dialog and dialog["heading"] in ("New Snippet", "Edit Snippet"):
            c.answer(pick(dialog["responses"], "save"), [name, password, description], heading=dialog["heading"])
            return
        if dialog:
            c.answer(pick(dialog["responses"], "plain"), heading=dialog["heading"])
        time.sleep(0.5)
    raise Outcome("broken", "expected the New Snippet form")

def add_password(c, name, password, description=""):
    passwords(c, "new")
    fill_password(c, name, password, description)
    return c.until(lambda s: any(r["name"] == name for r in passwords(c)["rows"]), f"expected {name} in Manage Passwords")

@test("L12", "Snippets: choosing one types only its text, without Return")
def _(c):
    open_passwords(c)
    add_password(c, "nas sudo", "Typed-Pw-42", "root on the NAS")
    menu = c.bridge.call("saved-passwords")
    entry = next((e for e in menu if e["title"] == "nas sudo"), None)
    c.expect(entry is not None, f"expected nas sudo in the toolbar's menu, saw {[e['title'] for e in menu]}")
    c.expect(entry["help"] == "root on the NAS", f"expected its description as the hover hint, saw {entry['help']!r}")
    c.expect(menu[-1]["title"].startswith("Manage Snippets"), "expected Manage Snippets… at the end of the menu")
    # A prompt that reads a line without echo, like sudo's.
    c.run("stty -echo; read -r P; stty echo; echo \"GOT:$P:\"", "set /p P=& call echo GOT:%P%:", settle=1.2)
    c.bridge.call("saved-passwords", choose=entry["action"])
    time.sleep(1.2)
    c.expect("GOT:" not in c.text().replace("GOT:$P:", "").replace("GOT:%P%:", ""), "expected no Return after the password")
    c.type(c.app.enter, settle=1.2)
    c.until(lambda s: "GOT:Typed-Pw-42:" in c.text(s), "expected the password typed into the terminal")

@test("L13", "Manage Snippets: Edit and Delete")
def _(c):
    open_passwords(c)
    add_password(c, "db", "pw-one", "database")
    index = next(i for i, r in enumerate(passwords(c)["rows"]) if r["name"] == "db")
    row = passwords(c)["rows"][index]
    c.expect(row["password"].strip("•") == "" and "pw-one" not in str(row), f"expected the password hidden, saw {row}")
    c.expect(row["stored"] == "Plain text", f"expected Plain text, saw {row['stored']!r}")
    passwords(c, "edit", index)
    fill_password(c, "db", "pw-two", "database (changed)")
    c.until(lambda s: any(r["description"] == "database (changed)" for r in passwords(c)["rows"]), "expected Edit to change the description")
    c.expect(len(passwords(c)["rows"]) == 1, "expected the edit to replace the entry")
    passwords(c, "delete", 0)
    s = c.until(lambda s: s.get("dialogs"), "expected a question before the password is deleted")
    dialog = s["dialogs"][0]
    default = dialog["default"] if "default" in dialog else dialog["responses"][0]
    c.expect(default is None or default.lower() == "cancel", f"expected Cancel (or nothing) as the default, saw {default!r}")
    c.answer(pick(dialog["responses"], "delete"))
    c.until(lambda s: not passwords(c)["rows"], "expected Delete to remove it")

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

def tailcat_window(c):
    c.command("tailcat", settle=1.5)
    c.until(lambda s: has_window(s, "Tailcat"), "expected the Tailcat Peers window")
    try:
        return c.bridge.call("tailcat-state")
    except bridge_module.BridgeError as error:
        if "unknown op" in str(error):
            c.unverified("the window opens; this platform's test bridge can't drive it yet")
        raise

def tailcat_self_peer(c):
    """Shares this computer and adds that address as a peer (this computer is its own Tailcat peer)."""
    tailcat_window(c)
    c.bridge.call("tailcat-share", persistent=False)
    s = None
    deadline = time.time() + 30
    while time.time() < deadline:
        s = c.bridge.call("tailcat-state")
        if s.get("shareAddress") or s.get("error"):
            break
        time.sleep(0.5)
    c.expect(s and s.get("shareAddress"), f"expected Share to report an address (saw: {s and s.get('error')})")
    c.expect(c.bridge.call("tailcat-add", name="self", username="nobody", address=s["shareAddress"], persistent=False),
             "expected Add Peer to save the peer")
    return s["shareAddress"]

@test("C6", "Share this computer: an address to give a peer, and Stop")
def _(c):
    tailcat_self_peer(c)
    c.bridge.call("tailcat-stop")
    c.until(lambda s: not c.bridge.call("tailcat-state")["sharing"], "expected Stop Sharing to stop the server")

@test("C1", "Tailcat Peers: add a peer")
def _(c):
    tailcat_self_peer(c)
    peers = c.bridge.call("tailcat-state")["peers"]
    c.expect([p["name"] for p in peers] == ["self"] and peers[0]["persistent"] is False, f"expected the one-time peer 'self', saw {peers}")
    c.bridge.call("tailcat-stop")

@test("C2", "Ping: Direct or Relayed with latency")
def _(c):
    tailcat_self_peer(c)
    c.bridge.call("tailcat-ping", name="self")
    deadline, route = time.time() + 40, ""
    while time.time() < deadline:
        route = c.bridge.call("tailcat-state")["peers"][0]["route"]
        if route.startswith(("Direct", "Relayed", "Unreachable")):
            break
        time.sleep(1)
    c.bridge.call("tailcat-stop")
    import re
    c.expect(route.startswith(("Direct", "Relayed")) and re.search(r"\d(\.\d+)?(µs|us|ms|s)\b", route),
             f"expected a Direct or Relayed route with its latency, saw {route!r}")

@test("C5", "Remove a peer")
def _(c):
    tailcat_self_peer(c)
    c.bridge.call("tailcat-remove", name="self")
    c.until(lambda s: c.bridge.call("tailcat-state")["peers"] == [], "expected the peer gone")
    c.bridge.call("tailcat-stop")

@test("C3", "Connect through Tailcat: the shell, and the address nowhere on screen")
def _(c):
    account = ssh_account()
    path = os.path.expanduser("~/.config/herbs-terminal/test-tailcat")
    if not account or not os.path.exists(path):
        c.unverified("needs the test host shared over tailcat (~/.config/herbs-terminal/test-tailcat holds its address)")
    address = open(path, encoding="utf-8").read().strip()
    tailcat_window(c)
    c.bridge.call("tailcat-add", name="testhost", username=account["user"], address=address, persistent=False)
    c.bridge.call("tailcat-connect", name="testhost")
    deadline, typed_password = time.time() + 45, False
    while time.time() < deadline:
        s = c.state()
        text = c.text(s)
        last = text.rstrip().splitlines()[-1] if text.strip() else ""
        if "(yes/no" in last:
            c.type("yes" + c.app.enter, settle=1)
        elif not typed_password and last.lower().endswith("password:"):
            c.type(account["password"] + c.app.enter, settle=2)
            typed_password = True
        elif connection(c, s).get("state") == "connected" and logged_in(c, account, s):
            break
        time.sleep(0.5)
    s = c.state()
    if connection(c, s).get("state") != "connected":
        tail = [line for line in c.text(s).splitlines() if line.strip()][-12:]
        raise Outcome("broken", f"expected a login through Tailcat; the terminal shows: {tail}")
    expect_connected(c, account, s)
    c.expect(address not in c.text(s), "the Tailcat address is on the screen")
    explorer_follows_with_password(c, account)

manual("C4", "Tailcat", "needs a peer whose SSH service is off")
manual("C7", "Unlock / Lock", "the Tailcat window isn't driven by the bridge yet")
def uia_node(nodes, identifier):
    return next((n for n in nodes if n.get("identifier") == identifier), None)


@test("Y1", "Every drawn control has a name, and buttons a hover text")
def _(c):
    nodes = c.uia()
    drawn = [n for n in nodes if n.get("identifier", "").startswith(("toolbar.", "tabStrip.", "window."))]
    c.expect(len(drawn) >= 12, f"UI Automation shows only {len(drawn)} toolbar, tab and window controls")
    unnamed = [n["identifier"] for n in drawn if not n.get("name")]
    c.expect(not unnamed, f"controls without a name: {unnamed}")
    hintless = [n["identifier"] for n in drawn if n["identifier"].startswith("toolbar.") and n["role"] == "Button" and not n.get("help")]
    c.expect(not hintless, f"toolbar buttons without a hover text: {hintless}")
    repeated = [n["identifier"] for n in drawn if n.get("help") and n.get("name") and n["help"].startswith(n["name"])]
    c.expect(not repeated, f"hover texts that repeat the control's name: {repeated}")
    c.command("toggle-explorer", settle=1.5)
    nodes = c.uia()
    explorer = [n for n in nodes if n.get("identifier", "").startswith("explorer.")]
    for identifier in ("explorer.back", "explorer.up", "explorer.home", "explorer.bookmarkFolder", "explorer.actions", "explorer.place.1"):
        node = uia_node(explorer, identifier)
        c.expect(node and node.get("name"), f"the explorer's {identifier} isn't named for screen readers (saw {[n['identifier'] for n in explorer]})")


@test("Y1", "Screen readers read the terminal's text, and hear new output")
def _(c):
    word = c.say("READ" + "ME42")
    nodes = c.uia(find="DME4")
    terminal = next((n for n in nodes if n.get("identifier") == "terminal"), None)
    c.expect(terminal, "the terminal isn't in the UI Automation tree: " + "; ".join(f"{n['depth']}:{n['role']}:{n.get('identifier', n.get('name', ''))}" for n in nodes))
    c.expect(terminal.get("name") == "Terminal 1", f"the terminal is named {terminal.get('name')!r}")
    c.expect(word in (terminal.get("text") or ""), "the terminal's Text pattern doesn't have the output")
    prompt = [line for line in c.text().splitlines() if line.strip()][-1].strip()
    c.expect(terminal.get("caretLine", "").strip() == prompt, f"the caret's line isn't the prompt {prompt!r}: {terminal.get('caretLine')!r}")
    c.expect((terminal.get("foundWord") or "").strip() == word, f"the word around the output is {terminal.get('foundWord')!r}")
    c.expect(terminal.get("lineRects", 0) >= 1, "the caret's line has no place on screen")
    c.say("NEW" + "LINE7")
    pane = c.until(lambda s: "NEWLINE7" in (c.pane(s).get("announcement") or ""), "new output isn't announced")
    announcement = c.pane(pane)["announcement"]
    c.expect("echo" not in announcement, f"the announcement repeats the typed command: {announcement!r}")


@test("Y2", "The selected tab and toggle buttons report their state")
def _(c):
    nodes = c.uia()
    c.expect((uia_node(nodes, "tabStrip.tab.1") or {}).get("selected") is True, "tab 1 isn't reported as selected")
    c.expect((uia_node(nodes, "toolbar.multiExec") or {}).get("toggle") == "Off", "MultiExec isn't a toggle button that is off")
    c.command("new-tab", settle=1.5)
    nodes = c.uia()
    c.expect(uia_node(nodes, "tabStrip.tab.2").get("selected") is True and uia_node(nodes, "tabStrip.tab.1").get("selected") is False,
             "the new tab isn't the one reported as selected")
    nodes = c.uia(press="tabStrip.tab.1")
    c.until(lambda s: c.tabs(s)[0]["selected"], "selecting tab 1 through UI Automation didn't switch to it")
    nodes = c.uia(press="toolbar.multiExec")
    c.until(lambda s: c.window(s).get("multiExec") or c.window(s).get("multiExecOn"), "toggling MultiExec through UI Automation didn't turn it on")
    c.expect(uia_node(c.uia(), "toolbar.multiExec").get("toggle") == "On", "MultiExec doesn't report On")
    c.command("multiexec")
    c.command("toggle-explorer", settle=1.5)
    nodes = c.uia(press="explorer.bookmarkFolder")
    c.expect(uia_node(nodes, "explorer.bookmarkFolder").get("toggle") == "On", "Bookmark doesn't report On after toggling it")
    selected = [n["name"] for n in nodes if n.get("identifier", "").startswith("explorer.place.") and n.get("selected")]
    c.expect(selected, "no place in the side pane is reported as the current one")

manual("Y3", "Password field labels", "covered by the accessibility tree; not automated here")
@test("Y4", "The visual bell flashes at most twice a second")
def _(c):
    if c.platform != "windows":
        c.unverified("this platform's test bridge doesn't report the visual bell yet")
    c.bridge.call("profile-set", key="bell", value="visual")
    bells = "\u0007" * 3
    c.run(f"printf '{bells}'", f"echo {bells}", settle=0.3)
    first = c.until(lambda s: c.pane(s)["bellFlashes"] >= 1, "the visual bell didn't flash")
    c.expect(c.pane(first)["bellFlashes"] == 1, f"three bells at once flashed {c.pane(first)['bellFlashes']} times")
    time.sleep(0.6)
    c.run(f"printf '{bells}'", f"echo {bells}", settle=0.3)
    c.until(lambda s: c.pane(s)["bellFlashes"] == 2, "a bell half a second later didn't flash again")

manual("Y4", "Reduce Motion", "window resizing isn't animated on Windows; the slower fade with animations off is visual")
manual("Y5", "Shared identifiers", "covered by parity/check.sh")
for fid in ("Z1", "Z2", "Z3"):
    manual(fid, "Safety", "needs damaged files or a dropped connection (fault injection, not automated yet)")
manual("Z5", "Self-contained", "checked by each platform's packaging script")
