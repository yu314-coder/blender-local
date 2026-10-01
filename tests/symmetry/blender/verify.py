"""Mirror editing, run by the Blender it runs on.

scripts/run-symmetry-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: no user settings and no 3D View area, as for the bpy
module on a device. Every string run here is one the Swift sends, printed by
tests/symmetry/blender/main.swift:

  * the header's X / Y / Z and Topology Mirror toggles, in edit and object
    mode, read back through the flag the mirror carries
    (`_blenderkit_sync._kind`, parsed by `SceneMirror.symmetry`);
  * every drag's commit, against where its preview left each vertex — and
    each case also shows that a preview which ignored the symmetry would have
    been caught, because Blender's result differs from it;
  * the Mesh menu's transforms, which mirror with the flag on and not off.
"""
import bpy, sys, pathlib, importlib.util, json

sys.dont_write_bytecode = True
CALLS = sys.argv[-1]
HERE = pathlib.Path(__file__).resolve().parent
fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split("#--"):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition("\n")
        blocks[head[4:].strip()] = body


def floats(name):
    return [float(x) for x in blocks[name].split()]


spec = importlib.util.spec_from_file_location("fixtures", HERE / "fixtures.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def run(source, name="<swift>"):
    exec(compile(source, name, "exec"), {"bpy": bpy})


# ---------------------------------------------------------------------------
print("the flags reach the app: `_kind` writes them, SceneMirror reads them")
# ---------------------------------------------------------------------------
parsed = json.loads(blocks["KINDS_PARSED"])
for key, got in sorted(parsed.items()):
    want = '' if key == 'LIGHT' else key.split(':', 1)[1]
    check("%-12s -> %r" % (key, got), got == want, want)

# ---------------------------------------------------------------------------
print("\nthe toggles write Blender's flags, in edit mode and in object mode")
# ---------------------------------------------------------------------------
toggles = json.loads(blocks["TOGGLES"])
for mode in ('EDIT', 'OBJECT'):
    obj = fixtures.build('grid')
    bpy.ops.object.mode_set(mode=mode)
    for key, source in sorted(toggles.items()):
        if not key.startswith('grid:'):
            continue
        prop, value = key[len('grid:'):].split('=')
        run(source, key)
        got = getattr(bpy.data.objects['grid'].data, prop)
        check("%s mode: %s" % (mode.lower(), source), got == (value == 'true'), got)
    bpy.ops.object.mode_set(mode='OBJECT')

def evaluated_positions(obj):
    """What the viewport draws for `obj`: its evaluated mesh, flat."""
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    flat = [c for v in mesh.vertices for c in v.co]
    evaluated.to_mesh_clear()
    return flat


def moved_set(after, before, eps=1e-4):
    return {i for i in range(len(before) // 3)
            if max(abs(after[3 * i + k] - before[3 * i + k]) for k in range(3)) > eps}


def check_deformed(name, setup, python, obj, start, drawn_start):
    """A drag over a modifier that moves what is drawn (the `twisted`
    fixture). The preview moves the drawn positions, Blender the edit mesh's,
    so they are held to each other by which vertices move — the pairing, which
    is exact — and the drawn result is measured against the preview but not
    required to match it: what SimpleDeform makes of a moved vertex is
    Blender's to know, and a plain drag over it is approximate the same way."""
    got = [c for v in obj.data.vertices for c in v.co]
    flat_start = [c for v in start for c in v]
    blender = moved_set(got, flat_start)
    preview = moved_set(floats(name + "_EXPECT"), drawn_start)
    drawn_pairs = moved_set(floats(name + "_DRAWN_PAIRS"), drawn_start)
    drawn_after = evaluated_positions(obj)
    want = floats(name + "_EXPECT")

    def gap(indices):
        return max((max(abs(drawn_after[3 * i + k] - want[3 * i + k]) for k in range(3)) for i in indices),
                   default=0.0)
    selected = set(setup["selected"])
    held, followed = gap(selected), gap(blender - selected)
    check("%s: Blender moved %s on its edit mesh, the preview %s" % (name, sorted(blender), sorted(preview)),
          blender == preview and len(blender) > len(selected) and "mirror=True" in python, python)
    # The drawn result: off by what the modifier does to a moved vertex,
    # for the vertices dragged as for their images — symmetry adds no error
    # of its own (measured: TWIST_X 0.144 dragged, 0.172 images).
    check("%s: drawn gap %.1e on the dragged vertices, %.1e on their images" % (name, held, followed),
          followed <= 2 * held + 1e-3)
    check("%s: paired on the drawn positions, as before, the preview moved %s instead"
          % (name, sorted(drawn_pairs)), drawn_pairs != blender)


# ---------------------------------------------------------------------------
print("\nwhat a drag previews is what Blender commits, with the mesh's symmetry on")
# ---------------------------------------------------------------------------
for name in blocks["CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    obj = fixtures.build(setup["fixture"])
    if "mirror" in setup:
        m = obj.modifiers.new("Mirror", 'MIRROR')
        m.use_axis = setup["mirror"]["axes"]
        m.use_clip = setup["mirror"]["clip"]
        m.merge_threshold = setup["mirror"]["merge_threshold"]
    if "automerge" in setup:
        bpy.context.scene.tool_settings.use_mesh_automerge = True
        bpy.context.scene.tool_settings.double_threshold = setup["automerge"]
    symmetry = setup["symmetry"]
    # As the header's toggles set them: by the string each sends.
    for flag, prop in (("x", "use_mirror_x"), ("y", "use_mirror_y"), ("z", "use_mirror_z"),
                       ("topology", "use_mirror_topology")):
        run(toggles["%s:%s=%s" % (setup["fixture"], prop, "true" if symmetry[flag] else "false")])
    start = [v.co.copy() for v in obj.data.vertices]
    deformed = (name + "_DRAWN_PAIRS") in blocks
    if deformed:
        drawn_start = evaluated_positions(obj)
    fixtures.select_vertices(obj, setup["selected"], setup["hidden"])
    python = blocks[name]
    try:
        run(python, name)
    except Exception as exc:                       # noqa: BLE001 - reported, not swallowed
        check(name + ": Blender accepts what it sends", False, exc)
        bpy.ops.object.mode_set(mode='OBJECT')
        continue
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.scene.tool_settings.use_mesh_automerge = False
    if deformed:
        check_deformed(name, setup, python, obj, start, drawn_start)
        continue
    got = [c for v in obj.data.vertices for c in v.co]
    want = floats(name + "_EXPECT")
    plain = floats(name + "_PLAIN")
    if len(got) != len(want):
        check("%s: Blender kept %d vertices, the preview %d" % (name, len(got) // 3, len(want) // 3),
              False, python)
        continue
    gap = max(abs(a - b) for a, b in zip(got, want))
    n = len(start)
    moved_blender = sum(1 for i in range(min(n, len(got) // 3))
                        if max(abs(got[3 * i + k] - start[i][k]) for k in range(3)) > 1e-4)
    moved_preview = sum(1 for i in range(min(n, len(want) // 3))
                        if max(abs(want[3 * i + k] - start[i][k]) for k in range(3)) > 1e-4)
    # The case would have caught a preview that ignored the symmetry: the
    # same drag previewed with it off lands elsewhere, or keeps a different
    # number of vertices.
    caught = len(plain) != len(got) or max(abs(a - b) for a, b in zip(got, plain)) > 1e-3
    if setup.get("control"):
        # A control: the symmetry finds nothing to do here, and Blender agrees
        # (`control` says why) — it moves what the plain drag moves, or, when
        # it is `still`, nothing.
        if setup["still"]:
            ok, said = moved_blender == 0 and moved_preview == 0, "nothing moved in Blender or the preview"
        else:
            ok, said = not caught, "Blender's result is the plain drag's"
        check("%s: %s — %s" % (name, setup["control"], said), ok and gap < 1e-4, python)
        continue
    check("%s: %d vertices moved in Blender, %d in the preview, largest gap %.1e%s"
          % (name, moved_blender, moved_preview, gap,
             "; welded to %d" % (len(got) // 3) if len(got) // 3 != n else ""),
          gap < 1e-4 and moved_blender == moved_preview and "mirror=True" in python, python)
    check("%s: a preview without the symmetry would have been caught" % name, caught)

# ---------------------------------------------------------------------------
print("\nTopology Mirror finds Blender's pairs (each pair measured with a proportional move)")
# ---------------------------------------------------------------------------
# What the Swift's table says, against Blender's own: every visible vertex in
# the quadrant drives its mirror under proportional editing, so after a move
# along Z a vertex whose table entry names a partner stands where that
# partner does, X negated — and one with no partner keeps its own place.
#
# Each mesh's +X half is pushed out of place first. Topology Mirror pairs by
# the edges alone, so the table does not change; but on a symmetric mesh a -X
# vertex lands at its start plus the step whether it is paired or not, and the
# check could not tell a right table from a wrong one (measured: 0 vertices
# off the step on the unpushed cube, grid and Suzanne).
for fixture in ("monkey", "skewed", "cube", "grid", "sphere", "cylinder", "torus", "monkey2"):
    table = json.loads(blocks["TOPOLOGY_" + fixture])
    obj = fixtures.build(fixture)
    obj.data.use_mirror_x = True
    obj.data.use_mirror_topology = True
    for v in obj.data.vertices:
        if v.co.x > 2e-5:
            v.co.x += 0.011 * (1 + v.index % 7)
            v.co.y += 0.005 * (v.index % 3)
    start = [v.co.copy() for v in obj.data.vertices]
    # One vertex selected with x >= 0 so the quadrant is +X; a reach past
    # the whole mesh and Constant falloff, so every vertex in it moves 1.
    seed = max(range(len(start)), key=lambda i: (start[i].x, -i))
    fixtures.select_vertices(obj, [seed])
    bpy.ops.transform.translate(value=(0, 0, 1), mirror=True, use_proportional_edit=True,
                                proportional_edit_falloff='CONSTANT', proportional_size=100)
    bpy.ops.object.mode_set(mode='OBJECT')
    after = [v.co.copy() for v in obj.data.vertices]
    # The move in the mesh's own space: what every transformed vertex got.
    step = after[seed] - start[seed]
    wrong = []
    for i, p in enumerate(after):
        j = table[i]
        if start[i].x < -2e-5 and j >= 0 and j != i and start[j].x >= -2e-5:
            # A follower: its partner's result, X negated.
            q = after[j]
            if abs(p.x + q.x) > 1e-5 or abs(p.y - q.y) > 1e-5 or abs(p.z - q.z) > 1e-5:
                wrong.append(i)
        elif start[i].x < -2e-5 and (j < 0 or j == i):
            # No partner on the other side: moved by itself, as TransData.
            if (p - start[i] - step).length > 1e-5:
                wrong.append(i)
    pairs = sum(1 for i, j in enumerate(table) if j >= 0 and j != i) // 2
    # With the +X half out of place, a -X vertex Blender paired is off the
    # step and one it did not is on it, so the check holds the table to
    # Blender's both ways. The cube, grid, sphere, cylinder and torus are
    # symmetric more than two ways, so their edge hashes come in groups of
    # three or more and neither side pairs anything there.
    told = sum(1 for i, p in enumerate(after) if start[i].x < -2e-5 and (p - start[i] - step).length > 1e-4)
    check("%s: %d pairs in the Swift's table; Blender moved %d -X vertices onto a partner; "
          "every vertex where Blender's table put it" % (fixture, pairs, told), not wrong, wrong[:10])

# ---------------------------------------------------------------------------
print("\nthe Mesh menu's transforms mirror when the flag is on")
# ---------------------------------------------------------------------------
for name in blocks["MENU_CASES"].split():
    setup = json.loads(blocks[name + "_SETUP"])
    obj = fixtures.build('grid')
    obj.data.use_mirror_x = setup["symmetry"]
    if setup["op"] == "smooth":
        # A flat, even grid smooths to itself; a bump the same on both sides
        # gives Smooth something to move and keeps the mirror images in place.
        for v in obj.data.vertices:
            v.co.z = 0.4 * abs(v.co.x) * abs(v.co.x) + 0.3 * v.co.y * v.co.y * v.co.y
    co = [v.co.copy() for v in obj.data.vertices]
    if setup["column"]:
        chosen = [i for i, c in enumerate(co) if abs(c.x - 0.4) < 1e-4]
    else:
        chosen = [i for i, c in enumerate(co) if 0.2 < c.x < 0.7 and -0.3 < c.y < 0.3]
    fixtures.select_vertices(obj, chosen)
    try:
        run(blocks[name], name)
    except Exception as exc:                       # noqa: BLE001
        check(name + ": Blender accepts what it sends", False, exc)
        bpy.ops.object.mode_set(mode='OBJECT')
        continue
    bpy.ops.object.mode_set(mode='OBJECT')
    after = obj.data.vertices
    if len(after) != len(co):
        far = sum(1 for v in after[len(co):] if v.co.x < -1e-4)
    else:
        far = sum(1 for i, v in enumerate(after) if co[i].x < -1e-4 and (v.co - co[i]).length > 1e-5)
    sent = "mirror=True" in blocks[name]
    if setup["honours"]:
        # Sent on a mesh whether the flag is on or not, as Blender's 3D View
        # stores it; Blender mirrors only with the flag on.
        ok = sent and (far > 0) == setup["symmetry"]
    elif setup["op"] == "smooth":
        # Smooth Vertices reads the flag itself: nothing to send, mirrored anyway.
        ok = not sent and (far > 0) == setup["symmetry"]
    else:
        # Inset does not mirror: nothing sent, nothing made on the far side.
        ok = not sent and far == 0
    check("%s: sends mirror=True: %s; %d vertices changed on the -X side" % (name, sent, far), ok, blocks[name])

print("\nALL PASS" if fail == 0 else "\n%d FAILED" % fail)
sys.exit(1 if fail else 0)
