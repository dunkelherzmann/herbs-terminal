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
        os.replace(temporary, os.path.join(self.folder, "request.json"))
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

    def clipboard_has_image(self):
        return None  # unknown on this platform


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

    def clipboard_has_image(self):
        types = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True).stdout.split()
        return "image/png" in types


class MacApp(App):
    """The parity copy made by parity/mac-copy.sh, opened in the background."""
    platform = "mac"
    bundle_id = "org.herbsterminal.parity"

    def __init__(self, repo):
        self.repo = repo
        self.home = os.path.realpath(os.path.join(tempfile.gettempdir(), "herbs-parity"))
        super().__init__()

    def bridge_folder(self):
        return os.path.join(tempfile.gettempdir(), "herbs-parity-app", "bridge")

    def launch(self):
        executable = subprocess.run(["parity/mac-copy.sh"], cwd=self.repo, capture_output=True, text=True).stdout.strip()
        self.app_path = executable.split("/Contents/MacOS/")[0]
        self.quit_running()
        subprocess.run(["defaults", "delete", self.bundle_id], capture_output=True)
        shutil.rmtree(self.home, ignore_errors=True)
        os.makedirs(self.home, exist_ok=True)
        subprocess.run(["open", "-n", "-g", "-a", self.app_path, "--args", "--parity-scene", "main", "--test-bridge"])

    def quit_running(self):
        for _ in range(20):
            if subprocess.run(["pgrep", "-f", "parity/Herb"], capture_output=True).returncode != 0:
                return
            subprocess.run(["osascript", "-e", f'tell application id "{self.bundle_id}" to quit'], capture_output=True)
            time.sleep(0.5)

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
        self.process = subprocess.Popen([self.exe, "--parity-scene", "main", "--test-bridge"], env=environment)

    def stop(self):
        if self.process:
            subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"], capture_output=True)
            self.process = None

    def clipboard_has_image(self):
        script = "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::ContainsImage()"
        out = subprocess.run(["powershell", "-NoProfile", "-STA", "-Command", script], capture_output=True, text=True).stdout
        return out.strip() == "True"


def for_platform(name, repo, exe=None):
    if name == "linux":
        return LinuxApp()
    if name == "mac":
        return MacApp(repo)
    if name == "windows":
        return WindowsApp(exe)
    raise SystemExit(f"unknown platform {name}")
