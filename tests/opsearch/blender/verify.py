"""The operator search's run_operator in desktop Blender, with the app's
context: the mode rule, what it refuses and why, and the Multires operators
that crashed the app from Edit Mode.

    Blender -b --factory-startup --python verify.py
"""
import bpy, gpu, sys, types, pathlib, importlib.util, subprocess, os
sys.dont_write_bytecode = True
here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import fixtures

root = here.parents[2]
sys.modules['_blenderkit'] = types.ModuleType('_blenderkit')
spec = importlib.util.spec_from_file_location('_blenderkit_sync', root / 'Resources/python/site/_blenderkit_sync.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
gpu.init()

fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok:
        fail += 1


def mode():
    a = bpy.context.view_layer.objects.active
    return getattr(a, 'mode', 'OBJECT') if a is not None else 'OBJECT'


def run(path, values=None):
    try:
        return 'ran', ui.run_operator(path, dict(values or {}))
    except RuntimeError as error:
        return 'refused', str(error)


print("== the rule: the menus' modes, and the mode put back ==")
check("object.* runs in Object Mode", ui.operator_mode('object.shade_smooth') == 'OBJECT')
check("mesh.* runs in Edit Mode", ui.operator_mode('mesh.subdivide') == 'EDIT')
check("uv.* runs in Edit Mode", ui.operator_mode('uv.unwrap') == 'EDIT')
check("adds run in Object Mode", ui.operator_mode('mesh.primitive_cube_add') == 'OBJECT')
for changer in ('object.mode_set', 'object.mode_set_with_submode', 'object.editmode_toggle',
                'object.posemode_toggle', 'object.transfer_mode'):
    check(changer + " is left alone: it sets the mode itself", ui.operator_mode(changer) is None)
check("and so is everything outside the three namespaces",
      ui.operator_mode('transform.translate') is None and ui.operator_mode('sculpt.sculptmode_toggle') is None)
changers = [n for n in dir(bpy.ops.object) if 'mode' in n]
check("the five are every object.* operator with 'mode' in its name in this Blender",
      sorted('object.' + n for n in changers) == sorted(ui._MODE_CHANGERS), changers)

fixtures.build('plain', 'EDIT')
outcome = run('object.shade_smooth')
check("object.shade_smooth from Edit Mode runs, and Edit Mode comes back",
      outcome[0] == 'ran' and mode() == 'EDIT', (outcome, mode()))
check("its smoothing reached the mesh", all(p.use_smooth for p in bpy.data.objects['Cube'].data.polygons))
fixtures.build('plain', 'OBJECT')
before = len(bpy.data.objects['Cube'].data.vertices)
outcome = run('mesh.subdivide')
check("mesh.subdivide from Object Mode runs in Edit Mode, and Object Mode comes back",
      outcome[0] == 'ran' and mode() == 'OBJECT', (outcome, mode()))
check("and subdivided the mesh", len(bpy.data.objects['Cube'].data.vertices) > before,
      len(bpy.data.objects['Cube'].data.vertices))
fixtures.build('plain', 'SCULPT')
outcome = run('mesh.subdivide')
check("from Sculpt Mode too, back to Sculpt Mode", outcome[0] == 'ran' and mode() == 'SCULPT', (outcome, mode()))
fixtures.build('plain', 'EDIT')
outcome = run('mesh.primitive_cube_add', {'location': [4, 0, 0]})
check("an add from Edit Mode makes a new object, not a cube inside the edited mesh",
      outcome[0] == 'ran' and len(bpy.data.objects) == 2
      and len(bpy.data.objects['Cube'].data.vertices) == 8, (outcome, len(bpy.data.objects)))

print("\n== Edit Mode's own object.* operators run where they work ==")
def polls(fixture, start):
    fixtures.build(fixture, start)
    out = set()
    for n in dir(bpy.ops.object):
        try:
            if getattr(bpy.ops.object, n).poll():
                out.add('object.' + n)
        except Exception:
            pass
    return out


measured = set()
for fixture in fixtures.FIXTURES:
    in_object, in_edit = polls(fixture, 'OBJECT'), polls(fixture, 'EDIT')
    measured |= in_edit - in_object
check("the list in _blenderkit_sync is every object.* operator whose poll fails in Object Mode "
      "and passes in Edit Mode on one of the three fixtures",
      sorted(ui._EDIT_MODE_OBJECT_OPS) == sorted(measured),
      sorted(set(measured) ^ set(ui._EDIT_MODE_OBJECT_OPS)))
fixtures.build('rich', 'EDIT')
outcome = run('object.vertex_group_deselect')
check("object.vertex_group_deselect from Edit Mode runs there",
      outcome[0] == 'ran' and mode() == 'EDIT', (outcome, mode()))
fixtures.build('rich', 'OBJECT')
outcome = run('object.vertex_group_deselect')
check("and from Object Mode is refused in Blender's words, not tried in Edit Mode",
      outcome[0] == 'refused' and mode() == 'OBJECT', (outcome, mode()))

print("\n== refusals ==")
bpy.ops.wm.read_homefile(use_empty=True, load_ui=False)
fixtures.undo_stack()
bpy.ops.object.camera_add()
outcome = run('mesh.subdivide')
check("a mesh.* operator with a camera active is refused: Blender cannot enter Edit Mode on it... or its poll fails",
      outcome[0] == 'refused' and mode() == 'OBJECT', (outcome, mode()))
bpy.ops.wm.read_homefile(use_empty=True, load_ui=False)
fixtures.undo_stack()
outcome = run('mesh.subdivide')
check("with no active object at all it is refused in words",
      outcome[0] == 'refused' and 'could not switch' in outcome[1], outcome)
for name in ui._UNSAFE_OPERATORS:
    fixtures.build('plain', 'EDIT')
    outcome = run(name)
    check(name + " is refused by name, before Blender sees it",
          outcome[0] == 'refused' and outcome[1] == ui._UNSAFE_OPERATORS[name], outcome)
    info = ui.operator_info(name)
    check(name + "'s form says why and cannot run it",
          info['available'] is False and info['refused'] == ui._UNSAFE_OPERATORS[name], info.get('refused'))

print("\n== what the form shows ==")
fixtures.build('plain', 'EDIT')
info = ui.operator_info('object.shade_smooth')
check("an object.* operator seen from Edit Mode says it runs in Object Mode",
      info['mode'] == 'Object Mode' and info['currentMode'] == 'Edit Mode' and info['available'] is True, info)
check("and reading the form switched no mode", mode() == 'EDIT')
info = ui.operator_info('mesh.subdivide')
check("a mesh.* operator in Edit Mode shows Blender's poll, no mode note",
      info['mode'] is None and info['available'] is True, info)
fixtures.build('plain', 'OBJECT')
info = ui.operator_info('object.vertex_group_assign')
check("an operator whose poll fails in its own mode shows unavailable",
      info['mode'] is None and info['available'] is False, info)

print("\n== the Multires operators that crashed the app from Edit Mode ==")
# Round 3's first group: both pass their poll in Edit (and Apply Base in
# Sculpt) Mode and segfault there. Through run_operator they run in Object
# Mode and the mode comes back.
for start in ('EDIT', 'SCULPT'):
    fixtures.build('rich', start)
    outcome = run('object.multires_base_apply', {'modifier': 'Multires'})
    check(f"Apply Base from {start} runs, in Object Mode, and {start} comes back",
          outcome[0] == 'ran' and mode() == start, (outcome, mode()))
fixtures.build('rich', 'EDIT')
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.object.multires_subdivide(modifier='Multires', mode='CATMULL_CLARK')
bpy.ops.object.mode_set(mode='EDIT')
outcome = run('object.multires_unsubdivide', {'modifier': 'Multires'})
check("Unsubdivide from Edit Mode runs or is refused in words, and Edit Mode comes back",
      mode() == 'EDIT', (outcome, mode()))

# The negative control: the same call through run_operator as it was before
# the rule, in a Blender of its own, which it is expected to crash. That
# Blender gets a home of its own too, as drive.py gives the sweep's: sweep.py
# refuses to run against this Mac's own Blender settings.
home = os.path.join(os.environ.get("TMPDIR", "/tmp"), "blenderlocal-opsearch-home")
os.makedirs(home, exist_ok=True)
old = subprocess.run([bpy.app.binary_path, "-b", "--factory-startup",
                      "--python", str(here / "sweep.py"), "--",
                      "only=object.multires_base_apply", "part=rich:EDIT", "old", "0"],
                     capture_output=True, text=True, timeout=120, cwd=home,
                     env=dict(os.environ, HOME=home, BLENDER_USER_RESOURCES=os.path.join(home, "res")))
crashed = any(l.startswith("B|") and "modifier=Multires" in l for l in old.stdout.splitlines()) \
    and not any(l.startswith("E|1|") for l in old.stdout.splitlines())
check("without the rule, the same Apply Base from Edit Mode crashes Blender (negative control)",
      crashed and old.returncode != 0, (old.returncode, old.stdout[-300:]))

print("\nALL PASS" if fail == 0 else f"\n{fail} FAILED")
sys.exit(0 if fail == 0 else 1)
