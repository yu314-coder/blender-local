"""Runs sweep.py, restarting Blender after each operator that crashes it.

One Blender per fixture and starting mode, four at a time. An operator that
kills Blender, or runs for more than a minute, is named with its fixture and
mode, and the sweep carries on after it. For the `new` variant it also lists
the runs that ended in another mode than they began in. Exit status 0 only
when `new` crashed nothing.

    python3 drive.py [new|old] [only=op,op,...]
"""
import subprocess, sys, os, select, time, threading
from concurrent.futures import ThreadPoolExecutor
BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
HERE = os.path.dirname(os.path.abspath(__file__))
SWEEP = os.path.join(HERE, "sweep.py")
sys.path.insert(0, HERE)
variant = sys.argv[1] if len(sys.argv) > 1 else "new"
extra = sys.argv[2:]
FIXTURES = ('plain',) if 'mods=rest' in extra else ('plain', 'rich', 'skin')
MODES = ('OBJECT', 'EDIT', 'SCULPT', 'TEXTURE_PAINT')
PER_OPERATOR = 60.0
lock = threading.Lock()


def partition(part):
    first, crashes, rows, begun = 0, [], {}, {}
    while True:
        # A home of its own: an operator that writes a file, a preference or a
        # startup file writes it here, not into this Mac's Blender.
        sandbox = os.path.join(os.environ.get("TMPDIR", "/tmp"), "blenderlocal-opsearch-home")
        os.makedirs(sandbox, exist_ok=True)
        env = dict(os.environ, HOME=sandbox, BLENDER_USER_RESOURCES=os.path.join(sandbox, "res"))
        proc = subprocess.Popen([BLENDER, "-b", "--factory-startup", "--python", SWEEP, "--",
                                 *extra, "part=" + part, variant, str(first)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                cwd=sandbox, env=env)
        last, done, hung, buffer = None, False, False, ""
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
                last = int(parts[1]); begun[last] = parts[2:5]
            elif parts[0] == "E":
                rows[int(parts[1])] = (begun[int(parts[1])], parts[2], "|".join(parts[3:]))
                last = None
            elif parts[0] == "DONE":
                done = True
        code = proc.wait()
        if done and not hung:
            return crashes, rows
        if last is None:
            with lock:
                print(f"  ERROR {part}: Blender stopped outside an operator (exit {code})", flush=True)
            crashes.append((("?", part, "outside an operator"), f"exit {code}"))
            return crashes, rows
        crashes.append((begun[last], "hung" if hung else f"exit {code}"))
        with lock:
            print(f"  CRASH {begun[last][2]} ({begun[last][0]} fixture, from {begun[last][1]}): "
                  + ("ran past a minute" if hung else f"exit {code}"), flush=True)
        first = last + 1


start = time.time()
parts = [f"{f}:{m}" for f in FIXTURES for m in MODES]
with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(partition, parts))
crashes = [c for r in results for c in r[0]]
rows = [row for r in results for row in r[1].values()]
ran = sum(1 for r in rows if r[2].startswith("ran:"))
refused = sum(1 for r in rows if r[2].startswith("refused:"))
print(f"{variant}: {len(rows) + len(crashes)} runs in {time.time() - start:.0f} s, "
      f"{ran} FINISHED, {refused} refused or failed, {len(crashes)} crashed")
if variant == "new":
    changers = {'object.mode_set', 'object.mode_set_with_submode', 'object.editmode_toggle',
                'object.posemode_toggle', 'object.transfer_mode'}
    left = [r for r in rows if r[0][2].split('(')[0] not in changers and r[1] not in (r[0][1], "NONE")]
    for r in left[:60]:
        print(f"  NOTE  {r[0][2]} from {r[0][1]} ({r[0][0]}) left Blender in {r[1]}: {r[2][:110]}")
    print(f"  {len(left)} runs ended in another mode than they started in")
if os.environ.get("OPSEARCH_ROWS"):
    with open(os.environ["OPSEARCH_ROWS"], "w") as out:
        for r in rows:
            out.write("|".join([*r[0], r[1], r[2]]) + "\n")
raise SystemExit(0 if (variant != "new" or not crashes) else 1)
