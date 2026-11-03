"""The Data API browser's reader (`_blenderkit_sync.inspect_data`) against
desktop Blender 5.2.1: each page says what it is and how it was reached, each
property how Blender draws it, each link what it leads to — and the fields the
browser always read are still there."""
import bpy, sys, json, importlib.util, types, pathlib

fail = 0
def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "  " + str(detail)))
    if not ok: fail += 1

root = pathlib.Path(__file__).resolve().parents[3]
sys.modules['_blenderkit'] = types.ModuleType('_blenderkit')
spec = importlib.util.spec_from_file_location('dataapi_test', root / 'Resources/python/site/_blenderkit_sync.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)

bpy.ops.wm.read_homefile(use_empty=True)
bpy.ops.mesh.primitive_cube_add()
cube = bpy.context.object
cube.modifiers.new("Bevel", 'BEVEL')

page = ui.inspect_data('bpy.context.object')
json.dumps(page)
props = {p['id']: p for p in page['properties']}
links = {c['identifier']: c for c in page['children'] if 'identifier' in c}
print("a struct's page")
check("the fields the browser always read are there",
      all(k in page for k in ('title', 'description', 'available', 'properties', 'children'))
      and all(k in props['location'] for k in ('id', 'name', 'description', 'kind', 'value', 'options',
                                                'editable', 'array', 'enumFlag')))
check("it is titled by the object's name and Blender's type", page['title'] == 'Cube' and page['typeName'] == 'Object',
      (page['title'], page['typeName']))
check("its breadcrumbs start at the object", [c['name'] for c in page['crumbs']] == ['Cube'], page['crumbs'])
check("Location: Translation in Length, three long",
      (props['location']['subtype'], props['location']['unit'], props['location']['arrayLength']) == ('TRANSLATION', 'LENGTH', 3),
      props['location'])
check("Euler Rotation is in Rotation units", props['rotation_euler']['unit'] == 'ROTATION'
      and props['rotation_euler']['name'] == 'Euler Rotation')
check("Color is a four-long Color", (props['color']['subtype'], props['color']['arrayLength']) == ('COLOR', 4))
check("a number carries its soft range and precision",
      props['empty_display_size']['softMin'] is not None and props['empty_display_size']['precision'] >= 1)
check("no limit reads as none, not FLT_MAX", props['location']['softMin'] is None)
check("an enum's items carry Blender's names", any(o['name'] == 'Bounds' for o in props['display_type']['options']))
check("Modifiers is a collection link of Modifier, counting 1",
      (links['modifiers']['kind'], links['modifiers']['typeName'], links['modifiers'].get('count')) == ('COLLECTION', 'Modifier', 1),
      links['modifiers'])
check("Data is a pointer link naming the mesh it leads to",
      (links['data']['kind'], links['data']['typeName'], links['data']['detail']) == ('POINTER', 'Mesh', 'Cube'),
      links['data'])
check("Parent, an editable pointer, names its datablock type", props['parent']['typeName'] == 'Object'
      and props['parent']['valueName'] is None)
check("rna_type is left out", 'rna_type' not in props and 'rna_type' not in links)
check("what every datablock has is grouped ID, the object's own is not",
      props['use_fake_user'].get('group') == 'ID' and props['location'].get('group') is None
      and props['name'].get('group') is None and props['users'].get('group') == 'ID',
      (props['use_fake_user'].get('group'), props['location'].get('group'), props['users'].get('group')))

print("\na nested struct, a collection, the file and an empty path")
mod = ui.inspect_data('bpy.context.object.modifiers[0]')
check("a modifier's breadcrumbs: the object, Modifiers, the modifier",
      [c['name'] for c in mod['crumbs']] == ['Cube', 'Modifiers', 'Bevel'], mod['crumbs'])
check("and its type is Blender's", mod['typeName'] == 'Bevel Modifier', mod['typeName'])
check("a modifier is no datablock: nothing of it is grouped ID",
      all(p.get('group') is None for p in mod['properties']))
items = ui.inspect_data('bpy.data.objects')
check("a collection's items are links with their type",
      items['children'] and all(c['kind'] == 'ITEM' and c['typeName'] == 'Object' for c in items['children']))
check("bpy.data is Blender's Blend-File Data", ui.inspect_data('bpy.data')['crumbs'][0]['name'] == 'Blend-File Data',
      ui.inspect_data('bpy.data')['crumbs'])
for o in bpy.context.view_layer.objects:
    o.select_set(False)
bpy.context.view_layer.objects.active = None
empty = ui.inspect_data('bpy.context.object')
check("with no active object it says so, and is not available",
      empty['available'] is False and 'no active object' in (empty['missing'] or ''), empty)
json.dumps(empty)

print("\nwriting")
bpy.context.view_layer.objects.active = cube
ui.set_property('bpy.context.object', 'location', [1, 2, 3])
check("set_property still writes a vector", tuple(cube.location) == (1, 2, 3))

print("\n" + ("ALL PASS" if fail == 0 else f"{fail} FAILED"))
sys.exit(1 if fail else 0)
