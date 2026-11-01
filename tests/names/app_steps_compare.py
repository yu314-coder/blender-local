"""The steps the app records, held to the ones a Blender recorded itself.

    python3 tests/names/app_steps_compare.py <names.json> <steps.json>

<names.json> is tests/names/main.swift's dump (the app's label for each call);
<steps.json> is what tests/names/app_steps.py wrote: each call made with its
undo on and Blender's own step read back from its stack — in the app, the
app's embedded bpy (5.3); in desktop Blender, 5.2.1. Every call measured has
to carry, in the app, exactly the step that Blender recorded.

The comparison is first run on a measurement with one name changed, which it
must fail.
"""
import json
import sys

rows = json.load(open(sys.argv[1]))
measured = json.load(open(sys.argv[2]))
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


app = {}
for row in rows:
    if row.get("undo") and row.get("call"):
        app.setdefault(row["call"], set()).add(row["undo"])


def differences(steps):
    out = []
    for call, step in steps.items():
        labels = app.get(call)
        if not labels or labels != {step}:
            out.append((call, sorted(labels or []), step))
    return out


steps = measured["steps"]
print(f"\nBlender {measured.get('version')}: {len(steps)} calls made with their undo on")
check("the comparison fails a measurement with one step renamed (negative control)",
      differences(dict(steps, **{"mesh.duplicate_move": "Duplicate Mesh"})) != [])
check("every call was measured: Blender pushed a step of its own for each",
      all(step and not str(step).startswith("ERROR") for step in steps.values()),
      {c: s for c, s in steps.items() if not s or str(s).startswith("ERROR")})
for call, labels, step in differences(steps):
    check(f"{call}: the app records {labels}, Blender {step!r}", False)
same = len(steps) - len(differences(steps))
check(f"{same} of {len(steps)}: the app's step is the one this Blender records", same == len(steps))
print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
sys.exit(1 if fail else 0)
