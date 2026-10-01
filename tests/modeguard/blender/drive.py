import subprocess, re, sys, os
calls = sys.argv[1]
ONE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "one.py")
names = re.findall(r"^### (\S+)$", open(calls).read(), re.M)
bad = 0
for n in names:
    out = subprocess.run(["/Applications/Blender.app/Contents/MacOS/Blender", "-b",
                          "--factory-startup", "--python", ONE, "--", calls, n],
                         capture_output=True, text=True, timeout=120).stdout
    rows = {r[0]: r for r in (l.split("|")[1:] for l in out.splitlines() if l.startswith("R|"))}
    cells = []
    for start in ["OBJECT", "EDIT", "SCULPT"]:
        if start not in rows:
            cells.append(f"{start}:CRASH"); bad += 1; continue
        _, ran, after, exists = rows[start]
        restored = after == start or exists == "False"
        if ran != "ok" or not restored:
            bad += 1
        note = "" if after == start else (" (object deleted)" if exists == "False" else f" (left in {after})")
        cells.append(f"{start}:{'ok' if ran == 'ok' else 'FAIL'}{note}")
    print(f"{n:<26}" + "  ".join(cells))
print("\nALL PASS" if bad == 0 else f"\n{bad} PROBLEMS")
raise SystemExit(0 if bad == 0 else 1)
