#!/usr/bin/env python3
"""Runs the feature tests against one platform's app and writes the results.

  python3 parity/tests/run.py --platform linux [--only W1,T3] [--out results/linux.json]

Run it on the machine that runs the app, inside its desktop session: on the Mac as is; on Linux inside a
headless KWin (linux/parity/tests.sh does that); on Windows from the logged-in desktop (windows/parity/tests.ps1).
Each test starts a fresh private copy of the app and stops it afterwards. On Linux and Windows the master-control skill
watches each copy in the background (--no-observe turns it off): a crash, a hang, a write outside the test folders
or a change to the real app's settings marks the test broken; error lines in its log are printed as notes.
"""
import argparse, json, os, sys, time, traceback
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bridge, suite

def main():
    # Test titles use characters such as "▸"; Windows consoles default to a narrower encoding.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=["mac", "linux", "windows"])
    parser.add_argument("--only", default="")
    parser.add_argument("--out", default="")
    parser.add_argument("--exe", default="")
    parser.add_argument("--no-observe", action="store_true", help="don't watch the app in the background")
    args = parser.parse_args()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = args.out or os.path.join(repo, "parity", "results", f"{args.platform}.json")
    only = set(filter(None, args.only.split(",")))
    app = bridge.for_platform(args.platform, repo, args.exe)
    previous = []
    if only and os.path.exists(out):
        previous = [r for r in json.load(open(out, encoding="utf-8"))["results"] if r["id"] not in only]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    results = []
    watcher = None if args.no_observe else observer_for(args.platform, os.path.dirname(out))
    for fid, tests in suite.TESTS.items():
        if only and fid not in only:
            continue
        for title, body in tests:
            started = time.time()
            if isinstance(body, str):
                status, detail = "unverified", body
            else:
                status, detail, seen = run_one(app, body, watcher, f"{fid} {title}")
            results.append({"id": fid, "test": title, "status": status, "detail": detail, "seconds": round(time.time() - started, 1)})
            if seen and (seen["problems"] or seen["notes"]):
                results[-1]["observer"] = {"problems": seen["problems"], "notes": seen["notes"]}
            print(f"{status.upper():10} {fid:4} {title}" + (f"  — {detail}" if detail and status != "works" else ""), flush=True)
            # Saved after every test, so an interrupted run keeps what it found.
            with open(out, "w", encoding="utf-8") as f:
                json.dump({"platform": args.platform, "run": time.strftime("%Y-%m-%d %H:%M"), "results": previous + results},
                          f, indent=1, ensure_ascii=False)
    if watcher:
        watcher.close()
    print("results:", out)

def observer_for(platform, results):
    """The background watch (master-control skill) on Linux and Windows: crashes, hangs, writes outside the test
    folders, changes to the real app's settings, error lines in the app's log. None where it isn't available."""
    scripts = os.path.expanduser("~/.agents/library/master-control/scripts")
    if platform == "mac" or not os.path.exists(os.path.join(scripts, "observer.py")):
        return None
    sys.path.insert(0, scripts)
    import observer
    # Moving a test file to the Trash (E8) writes there by design; tailcat caches its public relay map per user.
    if platform == "linux":
        settings = dict(allow=["/tmp/", "~/.local/share/Trash/"], logs=["/tmp/herbs-tests-app.log"],
                        guard=["~/.var/app/org.herbsterminal.app", "~/.config/herbs-terminal"])
    else:
        settings = dict(allow=[r"C:\$Recycle.Bin", r"%LOCALAPPDATA%\tailcat"],
                        guard=[r"%LOCALAPPDATA%\HerbsTerminal\settings.json"])
    watcher = observer.Observer(os.path.join(results, f"observer-{platform}"), **settings).start()
    print(f"OBSERVER   watching the test copy (timeline in {watcher.out})", flush=True)
    return watcher

def run_one(app, body, watcher=None, name=""):
    if watcher:
        watcher.arm()
    try:
        app.start()
    except Exception as error:
        return "error", f"the app didn't start: {error}", None
    process = getattr(app, "process", None)
    if watcher and process:
        watcher.begin(name, process.pid)
    context = suite.Context(app)
    try:
        body(context)
        status, detail = "works", ""
    except suite.Outcome as outcome:
        status, detail = outcome.status, outcome.detail
    except bridge.BridgeError as error:
        status, detail = ("broken", f"the app stopped answering ({error})") if not app.alive() else ("error", str(error))
    except Exception as error:
        status, detail = "error", "".join(traceback.format_exception_only(type(error), error)).strip()
    if status != "broken" and not app.alive():
        status, detail = "broken", "the app crashed or quit during the test"
    try:
        # Windows reports whether its windows went to the test desktop; a failure there is said, not hidden.
        desktop = app.bridge.call("state", timeout=3).get("testDesktop") or {}
        if desktop and not getattr(run_one, "reported", False):
            run_one.reported = True
            print(f"DESKTOP    test desktop {'on' if desktop.get('active') else 'off'}: {desktop.get('moved', 0)} window(s) moved, "
                  f"{desktop.get('failed', 0)} failed", flush=True)
        if desktop.get("failed"):
            print(f"WARNING    {desktop['failed']} window(s) couldn't move to the test desktop; they opened on the one in use", flush=True)
        elif desktop.get("active") and not desktop.get("moved"):
            print("WARNING    no window moved to the test desktop (is there a desktop named \"Herb's Terminal tests\"?)", flush=True)
    except Exception:
        pass
    seen = None
    if watcher and watcher.test:
        seen = watcher.end()
        for line in watcher_lines(seen):
            print(line, flush=True)
        if seen["problems"] and status in ("works", "unverified"):
            status, detail = "broken", "observer: " + "; ".join(p["kind"] for p in seen["problems"])
    try:
        app.stop()
    except Exception:
        pass
    return status, detail, seen

def watcher_lines(seen):
    lines = []
    for item in seen["problems"]:
        lines.append("  PROBLEM  " + json.dumps(item, ensure_ascii=False)[:400])
    for item in seen["notes"]:
        if item["kind"] != "connections":  # the SSH tests connect by design
            lines.append("  note     " + json.dumps(item, ensure_ascii=False)[:400])
    return lines

if __name__ == "__main__":
    main()
