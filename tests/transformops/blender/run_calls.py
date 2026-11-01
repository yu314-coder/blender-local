"""Stage 3: the Swift's calls (main.swift dump) run in Blender, each on its
fixture built afresh, and Blender's result held to the preview the Swift
drew: every gizmo drag in every orientation, then the redo panel's changes.
What runs is what the app runs for a gizmo release — `BpyBridge.performBody`
of the commit's operator: into the mode it needs, the call, back.

A preview that differs from its commit is the defect this codebase has
shipped seven times; here it is a FAIL with the distance between them."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
import fixtures

TOLERANCE = 1e-4
cases = json.load(open(sys.argv[-1]))


def places(obj):
    if obj.mode == 'EDIT':
        bm = bmesh.from_edit_mesh(obj.data)
        m = obj.matrix_world
        return [c for v in bm.verts for c in (m @ v.co)]
    out = []
    for o in bpy.context.view_layer.objects:
        if o.select_get():
            m = o.matrix_world
            for i in range(4):
                out += list(m.col[i].xyz)
    return out


worst = 0.0
by_orient = {}
for c in cases:
    obj = fixtures.build(c['fixture'])
    scene = bpy.context.scene
    # The header's setting, as the app leaves it: the call carries its own.
    if c['orient'] in orient.TYPES:
        scene.transform_orientation_slots[0].type = c['orient']
    if c['individual']:
        scene.tool_settings.transform_pivot_point = 'INDIVIDUAL_ORIGINS'
    obj = bpy.context.view_layer.objects.active
    label = "%s, %s, %s" % (c['fixture'], c['orient'].capitalize(), c['label'])
    try:
        if 'early' in c:
            # A tap read early (`captureWithSelection`): the step before is
            # the fixture's own selection; the read hands the tap over
            # outside any step; the Move and the redo panel's re-run go as
            # the bridge sent them, the re-run after a rewind.
            push("before")
            exec(c['early'], {'bpy': bpy})
            exec(c['first'], {'bpy': bpy})
            push("Move")
            undo.rewind()
            exec(c['python'], {'bpy': bpy})
            push("Move", replace=True)
        elif 'first' in c:
            # The redo panel's way, as the bridge goes it: the first call
            # recorded as a step, rewound (Blender's undo), the change run,
            # and its step put in the rewound one's place.
            push("before")
            exec(c['first'], {'bpy': bpy})
            push("Move")
            rewound = undo.rewind()
            exec(c['python'], {'bpy': bpy})
            push("Move", replace=True)
        else:
            exec(c['python'], {'bpy': bpy})
    except Exception as error:
        check(label + ": runs", False, "%r\n%s" % (error, c['call']))
        continue
    got = places(bpy.context.view_layer.objects.active)
    want = c['expect']
    if len(got) != len(want):
        check(label + ": the same elements", False, "%d numbers against %d" % (len(got), len(want)))
        continue
    gap = max(abs(a - b) for a, b in zip(got, want)) if got else 0.0
    worst = max(worst, gap)
    by_orient.setdefault(c['orient'], []).append(gap)
    check("%s: Blender's result is the preview (%.1e)" % (label, gap), gap < TOLERANCE,
          "\n      " + c['call'])

print("  %d calls; worst gap %.2e m; by orientation: %s" % (
    len(cases), worst, ", ".join("%s %d (worst %.1e)" % (k.capitalize(), len(v), max(v))
                                 for k, v in sorted(by_orient.items()))))

# The negative control: the same calls with their orientation's matrix left
# out (the type alone), which is how a gizmo drawn on one set of axes would
# commit on whatever Blender works out headless — View as Global, Active
# Element's Normal as the median's. They must not all agree.
differ = 0
tried = 0
import re
for c in cases:
    if c['orient'] not in ('VIEW',) or c['label'].startswith('redo') or 'Move' not in c['label']:
        continue
    bare = re.sub(r", orient_matrix=\(\(.*?\)\), orient_matrix_type='[A-Z]+'", "", c['python'])
    if bare == c['python']:
        continue
    fixtures.build(c['fixture'])
    exec(bare, {'bpy': bpy})
    got = places(bpy.context.view_layer.objects.active)
    tried += 1
    if max(abs(a - b) for a, b in zip(got, c['expect'])) > TOLERANCE:
        differ += 1
check("negative control: without its matrix, a View drag lands somewhere else (%d of %d)" % (differ, tried),
      tried > 0 and differ == tried)

# The tap read early — or carried by a setting — re-run as the bridge sent it
# before round 4's review: without the tap, which the read (or the setting)
# had cleared. It must move the fixture's own selection instead — the defect
# the review measured.
early = [c for c in cases if 'early' in c]
for c in early:
    fixtures.build(c['fixture'])
    push("before")
    exec(c['early'], {'bpy': bpy})
    exec(c['first'], {'bpy': bpy})
    push("Move")
    undo.rewind()
    exec(c['python_without_tap'], {'bpy': bpy})
    push("Move", replace=True)
    got = places(bpy.context.view_layer.objects.active)
    gap = max(abs(a - b) for a, b in zip(got, c['expect']))
    check("negative control: the re-run without the tap moves the selection from before it (%.2f m off)" % gap,
          gap > 0.1)
check("the tap read early and the tap a setting carried were among the cases", len(early) == 2, "%d" % len(early))
finish()
