"""Runs opsweep.py, one Blender per state four at a time, restarting Blender
after anything that takes it down and naming the operator; fails on any run
the sweep found growing Blender past the budget unpriced (GREW), leaving a
face or a vertex too many-sided for Subdivision Surface's time (SHARP), past
its time (SLOW), or crashing or hanging Blender.

    python3 opdrive.py [only=op,op,...] [states=OBJECT:A,EDIT:S]

Every Blender gets a HOME, BLENDER_USER_RESOURCES and TMPDIR of its own and
runs from a temporary folder (Mantaflow writes into its working folder).
Nothing here opens a window, a browser or another app.
"""
import os, select, shutil, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
HERE = os.path.dirname(os.path.abspath(__file__))
SWEEP = os.path.join(HERE, "opsweep.py")
STATES = ('OBJECT:A', 'OBJECT:O', 'OBJECT:S', 'OBJECT:K', 'OBJECT:M', 'EDIT:S', 'EDIT:R', 'EDIT:K', 'EDIT:M',
          'OBJECT:N', 'OBJECT:W', 'EDIT:W', 'OBJECT:G', 'EDIT:G', 'OBJECT:H')
PER_OPERATOR = 60.0
extra = [a for a in sys.argv[1:] if a.startswith("only=") or a == "control"]
CONTROL = "control" in sys.argv[1:]
for a in sys.argv[1:]:
    if a.startswith("states="):
        STATES = tuple(a[7:].split(","))
lock = threading.Lock()


def partition(state):
    rows, problems, first = {}, [], 0
    base = tempfile.mkdtemp(prefix="bk-budget-opsweep-")
    try:
        while True:
            home = os.path.join(base, "home")
            os.makedirs(os.path.join(home, "res"), exist_ok=True)
            tmp = os.path.join(base, "tmp")
            os.makedirs(tmp, exist_ok=True)
            env = dict(os.environ, HOME=home, BLENDER_USER_RESOURCES=os.path.join(home, "res"), TMPDIR=tmp)
            # --python-exit-code 1: a Python error that escapes the sweep
            # exits 1, so it is told apart from a crash (a signal) and from
            # Blender's own exit 0 (the control tree's run had one, unnamed).
            proc = subprocess.Popen([BLENDER, "-b", "--factory-startup", "--python-exit-code", "1",
                                     "--python", SWEEP, "--", *extra,
                                     "part=" + state, str(first)],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                    cwd=base, env=env)
            begun, done, hung = None, False, False
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], PER_OPERATOR)
                if not ready:
                    hung = True
                    proc.kill()
                    break
                line = proc.stdout.readline()
                if not line:
                    break
                parts = line.rstrip("\n").split("|")
                if parts[0] == "B":
                    begun = (int(parts[1]), parts[3])
                elif parts[0] == "E":
                    rows[int(parts[1])] = (begun[1] if begun else "?", parts[2], parts[3], parts[4])
                    begun = None
                elif parts[0] == "S":
                    rows[int(parts[1])] = (parts[3], "skipped", parts[4], "0")
                elif parts[0] == "DONE":
                    done = True
            code = proc.wait()
            if done and not hung:
                return state, rows, problems
            if begun is None:
                problems.append((state, "?", "Blender stopped outside an operator (exit %s)" % code))
                return state, rows, problems
            index, name = begun
            if hung:
                why = "HUNG past %d s" % PER_OPERATOR
            elif code < 0:
                why = "CRASHED (signal %d)" % -code
            else:
                why = "STOPPED (exit %d: %s)" % (code, "a Python error escaped the sweep" if code == 1
                                                 else "Blender quit inside the operator")
            problems.append((state, name, why))
            first = index + 1
    finally:
        shutil.rmtree(base, ignore_errors=True)


started = time.time()
with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(partition, STATES))
bad = []
total = 0
for state, rows, problems in results:
    total += len(rows)
    for index, (name, verdict, outcome, took) in sorted(rows.items()):
        if verdict not in ("ok", "skipped"):
            bad.append((state, name, verdict, outcome))
    bad += [(s, n, why, "") for s, n, why in problems]
print("  %d runs of %d states in %.0f s" % (total, len(STATES), time.time() - started))
if CONTROL:
    # The control passes when the sweep finds what it exists to find.
    grew = sorted({(s, n, v.split(":")[0]) for s, n, v, o in bad if v.startswith(("GREW", "SHARP"))})
    for state, name, verdict in grew:
        print("        found with the gate off: %s %s %s" % (state, name, verdict))
    ok = len(grew) >= 5
    print(("  PASS" if ok else "  FAIL") + "  control: with the gate off and nothing priced, the sweep finds %d runs "
          "growing Blender past the budget or making a face or vertex past 48 sides" % len(grew))
    sys.exit(0 if ok else 1)
for state, name, verdict, outcome in bad:
    print("  FAIL  %s %s: %s  (%s)" % (state, name, verdict, outcome))
if not bad:
    print("  PASS  no operator the search lists grew Blender past the budget, left a face or vertex past %d sides "
          "under a Subdivision Surface, crashed, hung or ran past its time, unpriced" % 48)
sys.exit(1 if bad else 0)
