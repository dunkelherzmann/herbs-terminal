"""Talks to an app's test bridge, and starts and stops the app, on each platform.

The bridge is a pair of files in the scene's private folder: the runner writes `request.json`, the app answers
in `response.json` (see TestBridge in each version). Nothing here touches the user's own app or settings: every
platform runs the private parity copy, whose files live in a temporary folder.
"""
import json, os, platform, shutil, subprocess, tempfile, time


class BridgeError(Exception):
    pass


class Bridge:
    def __init__(self, folder):
        self.folder = folder
        self.next_id = int(time.time() * 1000) % 1_000_000_000

    def call(self, op, timeout=10, **arguments):
        self.next_id += 1
        request = dict(arguments, op=op, id=self.next_id)
        os.makedirs(self.folder, exist_ok=True)
        temporary = os.path.join(self.folder, "request.tmp")
        with open(temporary, "w", encoding="utf-8") as f:
            json.dump(request, f)
        # On Windows the swap fails while the app has the previous request open; it lets go within moments.
        for attempt in range(40):
            try:
                os.replace(temporary, os.path.join(self.folder, "request.json"))
                break
            except PermissionError:
                if attempt == 39:
                    raise
                time.sleep(0.05)
        deadline = time.time() + timeout
        path = os.path.join(self.folder, "response.json")
        while time.time() < deadline:
            try:
                with open(path, encoding="utf-8-sig") as f:
                    response = json.load(f)
                if response.get("id") == self.next_id:
                    if not response.get("ok"):
                        raise BridgeError(response.get("error", "failed"))
                    return response.get("result")
            except (OSError, ValueError):
                pass
            time.sleep(0.05)
        raise BridgeError(f"no answer to {op} in {timeout} s (did the app quit?)")


class App:
    """One platform's parity copy with its bridge. Subclasses know how to start and stop it."""
    platform = "?"
    shell = "posix"          # how to type commands: "posix" (sh) or "cmd" (Command Prompt)
    home = ""                # the scene's home folder, where the shell starts
    enter = "\r"

    def __init__(self):
        self.bridge = Bridge(self.bridge_folder())
        self.process = None

    def bridge_folder(self):
        raise NotImplementedError

    def start(self, settle=2.5):
        shutil.rmtree(self.bridge.folder, ignore_errors=True)
        self.launch()
        deadline = time.time() + 40
        while time.time() < deadline:
            try:
                state = self.bridge.call("state", timeout=1)
                if state and state.get("windows"):
                    time.sleep(settle)
                    return
            except BridgeError:
                pass
            time.sleep(0.3)
        raise BridgeError("the app didn't start its test bridge")

    def launch(self):
        raise NotImplementedError

    def stop(self):
        raise NotImplementedError

    def alive(self):
        try:
            self.bridge.call("state", timeout=3)
            return True
        except BridgeError:
            return False

    # The app's clipboard. The Mac and Windows test copies keep a private one of their own (never the user's),
    # which the bridge reads and fills; Linux runs in its own headless session, whose clipboard the runner reads.
    def clipboard(self):
        """{"text": ..., "files": [paths], "image": bool}"""
        return self.bridge.call("clipboard")

    def set_clipboard(self, text=None, files=None):
        """Puts text, or files as the system's file manager copies them, on the app's clipboard."""
        if files is not None:
            self.bridge.call("clipboard-set", files=files)
        else:
            self.bridge.call("clipboard-set", text=text)

    def clipboard_has_image(self):
        return self.clipboard()["image"]


class LinuxApp(App):
    """The Flatpak build folder, run in the current (headless KWin) Wayland session."""
    platform = "linux"
    home = "/tmp/herbs-parity"

    def __init__(self, build=os.path.expanduser("~/src/herbs-parity-build")):
        self.build = build
        super().__init__()

    def bridge_folder(self):
        return "/tmp/herbs-parity-app/bridge"

    def launch(self):
        subprocess.run("rm -rf /tmp/herbs-parity-app /tmp/herbs-parity; mkdir -p /tmp/herbs-parity", shell=True)
        # The scene's /bin/sh is bash on many distributions; bracketed paste would hold typed newlines.
        with open("/tmp/herbs-parity/.inputrc", "w") as f:
            f.write("set enable-bracketed-paste off\n")
        command = ["flatpak", "build", "--with-appdir", "--socket=wayland", "--share=ipc", "--device=all",
                   "--filesystem=host", "--filesystem=/tmp", "--talk-name=org.freedesktop.Flatpak",
                   "--talk-name=org.a11y.Bus", "--filesystem=xdg-run/at-spi", "--env=HERBS_PARITY=1",
                   self.build, "herbs-terminal", "--parity-scene", "main", "--test-bridge"]
        self.process = subprocess.Popen(command, stdout=open("/tmp/herbs-tests-app.log", "a"), stderr=subprocess.STDOUT)

    def stop(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        subprocess.run("pkill -f 'herbs-terminal --parity-scene' ; sleep 0.5", shell=True)
        self.process = None

    def clipboard(self):
        def paste(*arguments):
            return subprocess.run(["wl-paste", "--no-newline", *arguments], capture_output=True, text=True, timeout=5).stdout
        types = paste("--list-types").split()
        files = []
        if "text/uri-list" in types:
            from urllib.parse import unquote, urlparse
            files = [unquote(urlparse(line).path) for line in paste("--type", "text/uri-list").splitlines() if line.startswith("file:")]
        text = paste("--type", "text/plain;charset=utf-8") if any(t.startswith("text/plain") for t in types) else ""
        return {"text": text, "files": files, "image": "image/png" in types}

    def set_clipboard(self, text=None, files=None):
        # wl-copy stays in the background to serve the clipboard, as a clipboard owner does.
        if files is not None:
            from urllib.parse import quote
            uris = "".join(f"file://{quote(path)}\r\n" for path in files)
            subprocess.run(["wl-copy", "--type", "text/uri-list", "--", uris], timeout=5)
        else:
            subprocess.run(["wl-copy", "--", text], timeout=5)


class MacApp(App):
    """The parity copy made by macos/parity/copy.sh, opened in the background."""
    platform = "mac"
    bundle_id = "org.herbsterminal.parity"

    def __init__(self, repo):
        self.repo = repo
        self.home = os.path.realpath(os.path.join(tempfile.gettempdir(), "herbs-parity"))
        super().__init__()

    def bridge_folder(self):
        return os.path.join(tempfile.gettempdir(), "herbs-parity-app", "bridge")

    def launch(self):
        executable = subprocess.run(["macos/parity/copy.sh"], cwd=self.repo, capture_output=True, text=True).stdout.strip()
        self.app_path = executable.split("/Contents/MacOS/")[0]
        self.quit_running()
        subprocess.run(["defaults", "delete", self.bundle_id], capture_output=True)
        shutil.rmtree(self.home, ignore_errors=True)
        os.makedirs(self.home, exist_ok=True)
        subprocess.run(["open", "-n", "-g", "-a", self.app_path, "--args", "--parity-scene", "main", "--test-bridge", "--test-desktop"])

    def quit_running(self):
        for _ in range(20):
            if subprocess.run(["pgrep", "-f", "parity/Herb"], capture_output=True).returncode != 0:
                return
            subprocess.run(["osascript", "-e", f'tell application id "{self.bundle_id}" to quit'], capture_output=True)
            time.sleep(0.5)
        # A test copy that still won't quit (an alert holding it, a hang) must not stay on screen.
        subprocess.run(["pkill", "-9", "-f", "parity/Herb"], capture_output=True)

    def stop(self):
        try:
            self.bridge.call("quit", timeout=3)
        except BridgeError:
            pass
        time.sleep(1)
        self.quit_running()


class WindowsApp(App):
    """The Windows build, started from a runner that is itself in the logged-in desktop session."""
    platform = "windows"
    shell = "cmd"

    def __init__(self, exe):
        self.exe = exe
        self.home = os.path.join(os.environ["TEMP"], "herbs-parity")
        super().__init__()

    def bridge_folder(self):
        return os.path.join(os.environ["TEMP"], "herbs-parity-app", "bridge")

    def launch(self):
        for folder in ("herbs-parity", "herbs-parity-app"):
            shutil.rmtree(os.path.join(os.environ["TEMP"], folder), ignore_errors=True)
        os.makedirs(self.home, exist_ok=True)
        environment = dict(os.environ, HERBS_PARITY="1")
        self.process = subprocess.Popen([self.exe, "--parity-scene", "main", "--test-bridge", "--test-desktop"], env=environment)

    def stop(self):
        if self.process:
            subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"], capture_output=True)
            self.process = None



def for_platform(name, repo, exe=None):
    if name == "linux":
        return LinuxApp()
    if name == "mac":
        return MacApp(repo)
    if name == "windows":
        return WindowsApp(exe)
    raise SystemExit(f"unknown platform {name}")
