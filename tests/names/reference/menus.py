import bpy, json
class Props:
    def __setattr__(self, k, v): pass
    def __getattr__(self, k): return Props()
class Layout:
    def __init__(self, items): self.items = items
    def __getattr__(self, name):
        # Any other layout call (scale_y, enabled, ...) is ignored.
        def other(*a, **k): return self
        return other
    def __setattr__(self, k, v):
        if k == 'items': object.__setattr__(self, k, v)
    def _label(self, idname, text):
        if text not in (None, ''):
            return text
        try:
            mod, op = idname.split('.')
            return getattr(getattr(bpy.ops, mod), op).get_rna_type().name
        except Exception:
            return idname
    def operator(self, idname, text=None, **k):
        self.items.append(('op', self._label(idname, text), idname)); return Props()
    def operator_menu_enum(self, idname, prop=None, text=None, **k):
        prop = prop or k.get('property')
        self.items.append(('enum', text or self._label(idname, None), idname + ':' + prop)); return Props()
    def operator_enum(self, idname, prop=None, **k):
        prop = prop or k.get('property')
        try:
            mod, op = idname.split('.')
            enum = getattr(getattr(bpy.ops, mod), op).get_rna_type().properties[prop]
            for item in enum.enum_items:
                self.items.append(('op', item.name, idname + ':' + prop + '=' + item.identifier))
        except Exception:
            self.items.append(('enum-items', idname + ':' + prop, idname))
    def menu(self, name, text=None, **k):
        cls = getattr(bpy.types, name, None)
        self.items.append(('menu', text or getattr(cls, 'bl_label', name), name))
    def menu_contents(self, name): self.menu(name)
    def prop(self, data, prop=None, text=None, **k):
        prop = prop or k.get('property')
        self.items.append(('prop', text if text is not None else prop, type(data).__name__ + '.' + prop))
    def prop_menu_enum(self, data, prop=None, text=None, **k): self.prop(data, prop or k.get('property'), text)
    def label(self, text='', **k): self.items.append(('label', text, ''))
    def separator(self, **k): self.items.append(('sep', '', ''))
    def separator_spacer(self, **k): pass
    def column(self, *a, **k): return self
    def row(self, *a, **k): return self
    def box(self, *a, **k): return self
    def split(self, *a, **k): return self
    def grid_flow(self, *a, **k): return self
    def column_flow(self, *a, **k): return self
    def popover(self, *a, **k): pass
    def template_ID(self, *a, **k): pass
def dump(prefixes):
    out = {}
    for name in dir(bpy.types):
        if not name.startswith(prefixes): continue
        cls = getattr(bpy.types, name)
        if not (isinstance(cls, type) and issubclass(cls, bpy.types.Menu)): continue
        items = []
        fake = cls.__new__(cls) if False else None
        class Self: pass
        s = Self(); s.layout = Layout(items); s.bl_label = getattr(cls, 'bl_label', name)
        try:
            cls.draw(s, bpy.context)
        except Exception as e:
            items.append(('error', str(e)[:80], ''))
        out[name] = dict(label=getattr(cls, 'bl_label', name), items=[i for i in items if i[0] != 'sep'])
    return out
result = {}
bpy.ops.object.select_all(action='SELECT')
bpy.context.view_layer.objects.active = bpy.data.objects.get('Cube')
result['OBJECT'] = dump(('VIEW3D_MT_', 'TOPBAR_MT_'))
bpy.ops.object.mode_set(mode='EDIT')
result['EDIT_MESH'] = dump(('VIEW3D_MT_edit_mesh', 'VIEW3D_MT_select_edit_mesh', 'VIEW3D_MT_uv_map'))
bpy.ops.object.mode_set(mode='OBJECT')
open('blender_menus.json', 'w').write(json.dumps(result, indent=1))
