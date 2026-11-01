"""Runs freed.py, one Blender per case, under MallocScribble=1 and
MallocGuardEdges=1 (freed memory is overwritten with 0x55, so a read of it
crashes instead of finding what was there), and fails on any case that
crashes, hangs or fails a price it checks (fix round 3, October 29).

    python3 freed_drive.py [cases=a,b] [rounds=N] [repeat=N]

`BK_SITE` points the cases at another copy of the app's modules: the
negative control runs them against 6d31b90's, which has to crash.

Every Blender gets a HOME, BLENDER_USER_RESOURCES and TMPDIR of its own and
runs from a temporary folder (Mantaflow writes into its working folder).
Nothing here opens a window, a browser or another app.
"""
import os, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "freed.py")
OPTS = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
ROUNDS = OPTS.get("rounds", "6")
REPEAT = int(OPTS.get("repeat", "1"))
PER_CASE = 240.0


def run(case, rounds=ROUNDS, extra_env=None):
    base = tempfile.mkdtemp(prefix="bk-freed-")
    try:
        home = os.path.join(base, "home")
        tmp = os.path.join(base, "tmp")
        os.makedirs(os.path.join(home, "res"))
        os.makedirs(tmp)
        env = dict(os.environ, HOME=home, BLENDER_USER_RESOURCES=os.path.join(home, "res"), TMPDIR=tmp,
                   MallocScribble="1", MallocGuardEdges="1")
        env.update(extra_env or {})
        started = time.time()
        try:
            proc = subprocess.run([BLENDER, "-b", "--factory-startup", "--python-exit-code", "1",
                                   "--python", SCRIPT, "--", base, "case=" + case, "rounds=" + str(rounds)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=base, env=env,
                                  timeout=PER_CASE)
            code, out = proc.returncode, proc.stdout
        except subprocess.TimeoutExpired as error:
            code, out = "hung", (error.stdout or b"").decode("utf-8", "replace") if isinstance(
                error.stdout, bytes) else (error.stdout or "")
        crash = ""
        report = os.path.join(tmp, "blender.crash.txt")
        if os.path.exists(report):
            lines = open(report, errors="replace").read().splitlines()
            frames = [l for l in lines if l[:3].strip().isdigit() and "Blender" in l][4:9]
            py = [l.strip() for l in lines if l.strip().startswith("File ")][:4]
            crash = " | ".join([f.split()[3] if len(f.split()) > 3 else f for f in frames] + py)
        return case, code, out, crash, time.time() - started
    finally:
        shutil.rmtree(base, ignore_errors=True)


def cases():
    listed = OPTS.get("cases")
    if listed:
        return listed.split(",")
    _, code, out, _, _ = run("list", 1)
    for line in out.splitlines():
        if line.startswith("CASES "):
            return line.split()[1:]
    print("  FAIL  could not list the cases (exit %s)\n%s" % (code, out[-2000:]))
    sys.exit(1)


names = cases()
bad = 0
started = time.time()
with ThreadPoolExecutor(max_workers=int(OPTS.get("jobs", "4"))) as pool:
    results = list(pool.map(run, [n for n in names for _ in range(REPEAT)]))
for case, code, out, crash, took in results:
    survived = ("SURVIVED " + case) in out
    for line in out.splitlines():
        if line.startswith(("  PASS", "  FAIL")):
            print("    " + line.strip())
    if code == 0 and survived:
        print("  PASS  %s: %s rounds under MallocScribble, no crash (%.1f s)" % (case, ROUNDS, took))
        continue
    bad += 1
    if code == "hung":
        why = "HUNG past %d s" % PER_CASE
    elif isinstance(code, int) and (code < 0 or code >= 128):
        why = "CRASHED (exit %s) %s" % (code, crash)
    else:
        why = "FAILED (exit %s)" % code
    tail = [l for l in out.splitlines() if l.strip()][-6:]
    print("  FAIL  %s: %s\n        %s" % (case, why, "\n        ".join(tail)))
print("  %d cases x %d in %.0f s, %d failed" % (len(names), REPEAT, time.time() - started, bad))
sys.exit(1 if bad else 0)
