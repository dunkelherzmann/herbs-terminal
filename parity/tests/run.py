#!/usr/bin/env python3
"""Runs the feature tests against one platform's app and writes the results.

  python3 parity/tests/run.py --platform linux [--only W1,T3] [--out results/linux.json]

Run it on the machine that runs the app, inside its desktop session: on the Mac as is; on Linux inside a
headless KWin (parity/tests/linux.sh does that); on Windows from the logged-in desktop (parity/tests/windows.ps1).
Each test starts a fresh private copy of the app and stops it afterwards.
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
    for fid, tests in suite.TESTS.items():
        if only and fid not in only:
            continue
        for title, body in tests:
            started = time.time()
            if isinstance(body, str):
                status, detail = "unverified", body
            else:
                status, detail = run_one(app, body)
            results.append({"id": fid, "test": title, "status": status, "detail": detail, "seconds": round(time.time() - started, 1)})
            print(f"{status.upper():10} {fid:4} {title}" + (f"  — {detail}" if detail and status != "works" else ""), flush=True)
            # Saved after every test, so an interrupted run keeps what it found.
            with open(out, "w", encoding="utf-8") as f:
                json.dump({"platform": args.platform, "run": time.strftime("%Y-%m-%d %H:%M"), "results": previous + results},
                          f, indent=1, ensure_ascii=False)
    print("results:", out)

def run_one(app, body):
    try:
        app.start()
    except Exception as error:
        return "error", f"the app didn't start: {error}"
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
        app.stop()
    except Exception:
        pass
    return status, detail

if __name__ == "__main__":
    main()
