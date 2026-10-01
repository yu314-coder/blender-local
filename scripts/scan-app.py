#!/usr/bin/env python3
"""Pre-upload scan of a built Blender Local app.

  scripts/scan-app.py <BlenderLocal.app> release   debug hooks must be absent
  scripts/scan-app.py <BlenderLocal.app> control   and visible here, proving the scan can see them

Two kinds of marker: the launch-hook flags themselves ("-mesh"), and the long
plain literals that exist only inside #if DEBUG blocks.
"""
import pathlib, re, subprocess, sys

HOOKS = ["-workspace", "-eval64", "-stub", "-add", "-adjust", "-mesh", "-caret", "-fold", "-mirror", "-console64",
         "-editor-smoke", "-render", "-timeline", "-paint-stroke", "-focus-log", "-undo-checkpoints", "-undo", "-redo",
         "-image3d", "-image3d-whole", "-image3d-detail", "-image3d-mode", "-panel", "-export",
         "-modifier-dump", "-modifier-steps", "-properties-tab", "-opsearch", "-opsearch-args", "-uv-row",
         "-dump-state", "-sculpt-stroke", "-sculpt-brush", "-sculpt-stroke-points", "-sculpt-stroke-span",
         "-sculpt-undo", "-sculpt-enter", "-sculpt-ops", "-sculpt-no-frame", "-sculpt-header-only",
         "-sculpt-midstroke",
         "-region-select", "-region-mode", "-region-view", "-region-wait", "-region-action", "-xray", "-select-menu", "-select-menu-delay",
         "-object-ops", "-symmetry-ops", "-points-ops", "-groups-ops", "-standin-dab", "-frames", "-frames-wait"]
app, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
root = pathlib.Path(__file__).resolve().parent.parent / "Sources"
lit = re.compile(r'"([^"\\]{16,})"')
debug, other = set(), set()
for p in root.rglob("*.swift"):
    stack = []
    for line in p.read_text(errors="replace").splitlines():
        s = line.strip()
        if s.startswith("#if "): stack.append(s[4:].strip()); continue
        if s.startswith("#elseif ") or s.startswith("#else"):
            if stack: stack[-1] = "!" + stack[-1]
            continue
        if s.startswith("#endif"):
            if stack: stack.pop()
            continue
        if s.startswith("//"): continue
        for m in lit.findall(line):
            (debug if "DEBUG" in stack else other).add(m)
markers = sorted(debug - other)

bins = [b for b in app.iterdir()
        if b.is_file() and (b.name == "BlenderLocal" or b.name.endswith(".debug.dylib"))]
# With no binary to read, every question below answers "not present" and the
# release scan prints CLEAN — a pass that means nothing. That is how a
# Designed-for-iPad build gets scanned by mistake: the outer .app is a wrapper
# and the real bundle is inside Wrapper/. Say so instead.
if not bins:
    print(f"no BlenderLocal binary in {app}")
    print("  (a Designed-for-iPad wrapper keeps the real bundle in Wrapper/BlenderLocal.app)")
    sys.exit(1)
lines = set()
for b in bins:
    out = subprocess.run(["strings", "-a", str(b)], capture_output=True, text=True, errors="replace").stdout
    lines.update(out.splitlines())
hooks = [h for h in HOOKS if h in lines]
lits = [m for m in markers if m in lines]
print(f"scanned {', '.join(b.name for b in bins)}")
print(f"  hook flags present:          {len(hooks)} of {len(HOOKS)}  {hooks}")
print(f"  debug-only literals present: {len(lits)} of {len(markers)}  {lits}")

if mode == "control":
    missing = [h for h in HOOKS if h not in hooks]
    bad = not hooks or not lits
    print(f"  not seen: {missing or 'none'}")
    print("CONTROL:", "VACUOUS" if bad else "the scan sees the debug hooks")
else:
    hits = subprocess.run(["grep", "-rlE", "itms-services|itms-apps", str(app)],
                          capture_output=True, text=True).stdout.split()
    print(f"  itms-services/itms-apps:     {len(hits)} file(s)")
    for h in hits[:10]: print("    ", h)
    stdlib = app / "python/lib/python3.14"
    junk = [d for d in ("ensurepip", "test") if (stdlib / d).exists()]
    print(f"  ensurepip/test staged:       {junk or 'neither'}")
    bad = bool(hooks) or bool(lits) or bool(hits) or bool(junk)
    print("SCAN:", "PROBLEMS" if bad else "CLEAN")
sys.exit(1 if bad else 0)
