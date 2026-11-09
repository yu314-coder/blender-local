import bpy, json
from bl_ui.space_toolsystem_common import ToolDef
from bl_ui.space_toolsystem_toolbar import VIEW3D_PT_tools_active as T
out = {}
def labels(item):
    if item is None or callable(item):
        return []
    if isinstance(item, ToolDef):
        return [item.label]
    if isinstance(item, tuple):
        return [l for sub in item for l in labels(sub)]
    return []
for mode in ('OBJECT', 'EDIT_MESH', 'EDIT_CURVE', 'EDIT_LATTICE', 'EDIT_TEXT', 'SCULPT', 'PAINT_WEIGHT', 'PAINT_VERTEX', 'PAINT_TEXTURE',
             'PAINT_GREASE_PENCIL'):
    out[mode] = [l for item in T.tools_from_context(bpy.context, mode=mode) for l in labels(item)]
open('blender_toolbar.json', 'w').write(json.dumps(out, indent=1))
