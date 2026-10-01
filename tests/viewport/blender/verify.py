import bpy, sys
fail = 0
def check(l, ok, d=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + l + ("" if ok else "  " + str(d)))
    if not ok: fail += 1

blocks = open(sys.argv[-1]).read().split("### ")
SELECT = [b for b in blocks if b.startswith("SELECT")][0].split("\n",1)[1].strip()
TRANSLATE = [b for b in blocks if b.startswith("TRANSLATE")][0].split("\n",1)[1].strip()

def scene():
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(location=(0,0,0)); bpy.context.object.name = "Other"
    bpy.ops.mesh.primitive_cube_add(location=(0,4,0)); bpy.context.object.name = "Target"
    # Blender's selection is left on "Other", as it would be after a previous
    # operation — the viewport tap is what is supposed to change it.
    bpy.ops.object.select_all(action='DESELECT')
    o = bpy.data.objects["Other"]
    o.select_set(True); bpy.context.view_layer.objects.active = o

print("with the tap running its selection Python (the fix)")
scene()
exec(compile(SELECT, "<sel>", "exec"), {"bpy": bpy})
exec(compile(TRANSLATE, "<tr>", "exec"), {"bpy": bpy})
t = bpy.data.objects["Target"].location
o = bpy.data.objects["Other"].location
check("the tapped object moved", round(t.x, 3) == 1.5, f"Target at {tuple(round(c,2) for c in t)}")
check("and the other one did not", round(o.x, 3) == 0.0, f"Other at {tuple(round(c,2) for c in o)}")

print("\nwithout it (what the app was doing)")
scene()
exec(compile(TRANSLATE, "<tr>", "exec"), {"bpy": bpy})
t = bpy.data.objects["Target"].location
o = bpy.data.objects["Other"].location
check("the tapped object stays put — this is the snap-back",
      round(t.x, 3) == 0.0, f"Target at {tuple(round(c,2) for c in t)}")
check("and the wrong object moves instead",
      round(o.x, 3) == 1.5, f"Other at {tuple(round(c,2) for c in o)}")

SELECTVERTS = [b for b in blocks if b.startswith("SELECTVERTS")][0].split("\n",1)[1].strip()

print("\nedit mode: the vertex selection reaches Blender too")
# The same bug one level down — the operator acts on Blender's vertex
# selection, which the interface never set.
bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2, location=(0,0,0))
ob = bpy.context.object
ob.name = "Target"
before = [tuple(round(c,3) for c in v.co) for v in ob.data.vertices]
exec(compile(SELECTVERTS, "<sv>", "exec"), {"bpy": bpy})
exec(compile("bpy.ops.transform.translate(value=(0.0, 0.0, 0.5))", "<t>", "exec"), {"bpy": bpy})
bpy.ops.object.mode_set(mode='OBJECT')
after = [tuple(round(c,3) for c in v.co) for v in ob.data.vertices]
moved = [(a, b) for a, b in zip(before, after) if a != b]
check("exactly the two named vertices moved", len(moved) == 2, f"{len(moved)} moved")
check("and by the amount asked for",
      all(round(b[2] - a[2], 3) == 0.5 for a, b in moved), moved[:2])

# Native controls and coding assistance must use this installed Blender's RNA.
import importlib.util, types, pathlib, tempfile, json, os
root = pathlib.Path(__file__).resolve().parents[3]
sys.modules['_blenderkit'] = types.ModuleType('_blenderkit')
spec = importlib.util.spec_from_file_location('blender_ui_test', root / 'Resources/python/site/_blenderkit_sync.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)

metadata = ui.editor_metadata()
check('Monaco snapshot includes actual Blender operator parameters',
      'size' in metadata['operators']['bpy.ops.mesh.primitive_cube_add']['parameters'])
check('Monaco snapshot includes scene member completion', 'frame_set' in metadata['members']['bpy.context.scene'])
print("\nRNA controls and safe assistance")
quoted = [b for b in blocks if b.startswith("QUOTED")][0].split("\n", 1)[1].strip()
import ast
check('Swift quotes multiline Unicode Python without executing it', ast.literal_eval(quoted) == 'import bpy\n# "quotes", slash /, backslash \\, 中文\n')

info = ui.operator_info('mesh.primitive_cube_add')
check('operator metadata comes from RNA', any(p['id'] == 'size' for p in info['properties']))
check('vector defaults retain all components', any(p['id'] == 'location' and json.loads(p['value']) == [0, 0, 0] for p in info['properties']))
ui.run_operator('mesh.primitive_cube_add', {'size': 3.0})
check('parameter form executes real geometry', round(bpy.context.object.dimensions.x, 3) == 3.0)
ui.set_property('bpy.context.object', 'location', [2, 3, 4])
check('property editor updates Blender', tuple(bpy.context.object.location) == (2, 3, 4))
check('scene inspector exposes render settings', any(c['path'].endswith('.render') for c in ui.inspect_data('bpy.context.scene')['children']))
check('collection inspector lists objects', len(ui.inspect_data('bpy.data.objects')['children']) == len(bpy.data.objects))
check('syntax check locates bad line', 'Line 2' in ui.assist('import bpy\nif :'))
count = len(bpy.data.objects)
ui.assist('bpy.ops.object.delete()')
check('checking a script never executes it', len(bpy.data.objects) == count)
for forbidden in ["bpy.ops.object.delete()", "__import__('os')", "bpy.__dict__"]:
    try:
        ui.resolve(forbidden)
        check('rejects executable path ' + forbidden, False)
    except ValueError:
        check('rejects executable path ' + forbidden, True)
items = ui.complete_source('import bpy as B\nobj = B.context.object\nobj.loc', 'obj')
check('completion resolves unexecuted bpy alias', any(i['name'] == 'location' for i in items))
ui.complete_source('import bpy\nx = bpy.ops.object.delete()\nx.', 'x')
check('completion never runs factory calls', len(bpy.data.objects) == count)

bpy.ops.object.camera_add(location=(0, 0, 8))
camera_name = bpy.context.object.name
ui.set_property('bpy.context.scene', 'camera', 'bpy.data.objects[' + repr(camera_name) + ']')
check('datablock picker assigns the real scene camera', bpy.context.scene.camera.name == camera_name)

print("\nEvaluated viewport extraction")
mesh = bpy.data.meshes.new('Dense viewport test')
mesh.from_pydata([(i % 300, i // 300, 0) for i in range(70000)], [],
                 [(i, i + 1, i + 300) for i in range(69700) if i % 300 < 299])
dense = bpy.data.objects.new('Dense viewport test', mesh)
bpy.context.collection.objects.link(dense)
pushed = {}
ui._blenderkit.sync_begin = lambda: pushed.clear()
ui._blenderkit.sync_push = lambda *args: pushed.update({args[0]: len(args[3]) // 12})
ui._blenderkit.sync_end = lambda: None
materials = {}
ui._blenderkit.material_set = lambda name, key, *value: materials.update({(name, key): value})
material = bpy.data.materials.new('Viewport material test')
material.use_nodes = True
material.node_tree.nodes.get('Principled BSDF').inputs['Roughness'].default_value = 0.27
dense.data.materials.append(material)
ui.sync()
check('real extraction mirrors a mesh above 65535 vertices', pushed.get(dense.name) == 70000)
check('real Principled values reach the native material callback',
      abs(materials[(dense.name, 'Roughness')][0] - 0.27) < 0.0001)
dense.hide_viewport = True
ui.sync()
check('hidden objects keep an outliner origin without visible mesh', pushed.get(dense.name) == 1)
bpy.data.objects.remove(dense, do_unlink=True)
bpy.ops.mesh.primitive_cube_add(location=(2, 3, 4))

print("\nFull Blender checkpoints")
# Temporary test outputs stay on the external drive.
with tempfile.TemporaryDirectory(prefix='blender-history-test-', dir='/Volumes/D/tmp') as tmp:
    history = os.path.join(tmp, 'history')
    obj = bpy.context.object
    name = obj.name
    material = bpy.data.materials.new('Checkpoint material')
    material.use_nodes = True
    obj.data.materials.append(material)
    obj.keyframe_insert(data_path='location', frame=1)
    vertex_count = len(obj.data.vertices)
    ui.checkpoint(history, 'Original')
    obj.location.x = 42
    obj.keyframe_insert(data_path='location', frame=1)
    ui.checkpoint(history, 'Move')
    check('undo is available after edit', ui.history_state()['undo'])
    ui.history_step(-1)
    restored = bpy.data.objects[name]
    check('undo changes authoritative Blender state', restored.location.x == 2)
    check('undo preserves geometry', len(restored.data.vertices) == vertex_count)
    check('undo preserves nodes', restored.data.materials[0].use_nodes)
    check('undo preserves animation', restored.animation_data.action is not None)
    ui.history_step(1)
    check('redo changes authoritative Blender state', bpy.data.objects[name].location.x == 42)
    check('autosave is a real blend file', pathlib.Path(tmp, 'autosave.blend').read_bytes()[:7] == b'BLENDER')
    ui.history_step(-1)
    bpy.data.objects[name].location.x = 7
    ui.checkpoint(history, 'New branch')
    check('editing after undo discards redo', not ui.history_state()['redo'])

print("\n" + ("ALL PASS" if not fail else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
