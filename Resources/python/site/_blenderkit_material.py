"""Properties ▸ Material: what the tab shows and what its controls do, as
Blender 5.x's Material Properties have them, and what the 3D View draws a
material slot with.

`state` reads the active object's material slots and the active slot's
material for the tab (printed as one JSON line); every other public function
is one control of the tab, held to the conditions Blender's own button is held
to and refusing in words where Blender would do nothing without saying so.
`push` hands the 3D View each slot's look and each triangle's slot during a
mirroring pass (`_blenderkit.sync_materials`).

Measured in desktop Blender 5.2.1 under `-b --factory-startup`, with an undo
stack as the app makes one (scripts/run-material-blender-check.sh):

  * `object.material_slot_add`, `_remove`, `_move`, `_assign`, `_select`,
    `_deselect`, `_copy`, `_remove_unused` and `_remove_all` run headless on
    the active object (`context.object` is the view layer's active object
    with no area). `_remove`, `_remove_unused` and `_remove_all` fail their
    poll in Edit Mode ("Unable to remove material slot in edit mode"); a move
    past the end returns CANCELLED, saying nothing — said here.
    `_remove_unused` and `_remove_all` act on every selected object, as
    Blender's do.
  * There is no `context.material` headless, so Copy Material and Paste
    Material (`material.copy`, `material.paste`) run under
    `temp_override(material=...)`, the context Blender's Material tab gives
    them. Copy writes Blender's own copy buffer, Paste reads it back into the
    material in place (its name kept).
  * `material.new` called from Python makes the material and assigns it to
    nothing, and leaves it with the user the operator gives a new ID, which
    its own `id_us_min` takes back only when a button assigns it: assigned
    afterwards it read 2 users with one object. `bpy.data.materials.new`
    makes the same node tree (a Principled BSDF into a Material Output, the
    same values and locations, compared node by node) with no stray user, so
    New is that, named "Material" as `new_material_exec` names it, and given
    a slot first when the object has none (`BKE_object_material_slot_add`).
    With a material in the slot, Blender's New button is a duplicate
    (`BKE_id_copy_ex`), which `ID.copy()` is.
  * Unlink (Blender's X, "Unlink Data-Block") only clears the slot: the
    material stays in the file, as it does in Blender.
  * Undo: in Object Mode one Undo takes back every control here. In Edit
    Mode Blender's undo step holds the mesh, and none of a material's values,
    its viewport display or its settings, nor a slot added or its link: each
    stayed changed after Undo, and so did the active slot, a material
    browsed into the slot and Unlink. The interface pushes no step for those
    in Edit Mode (the Swift's `MaterialBpy`), as the Data tab does for a
    shape key's settings. Assign, Select and Deselect were taken back.
  * Writes to a socket's `default_value` from Python are not clamped (a
    Metallic of -1e9 read back -1e9); Blender's interface drags within the
    socket's declared range, which `SOFT_RANGES` holds (from the nodes'
    declarations, held to Blender by the check).
"""
import json
import math

import bpy

Refusal = RuntimeError

# Blender's Surface and Volume menus (`uiTemplateNodeLink`'s Shader column):
# every shader node type with a Shader output, by its interface name, sorted
# as `ui_node_item_name_compare` sorts them. The check holds this to the
# types Blender registers. Glossy BSDF's type is ShaderNodeBsdfAnisotropic.
SHADERS = (
    ('ShaderNodeAddShader', 'Add Shader'),
    ('ShaderNodeBackground', 'Background'),
    ('ShaderNodeBsdfDiffuse', 'Diffuse BSDF'),
    ('ShaderNodeEmission', 'Emission'),
    ('ShaderNodeBsdfGlass', 'Glass BSDF'),
    ('ShaderNodeBsdfAnisotropic', 'Glossy BSDF'),
    ('ShaderNodeBsdfHair', 'Hair BSDF'),
    ('ShaderNodeHoldout', 'Holdout'),
    ('ShaderNodeBsdfMetallic', 'Metallic BSDF'),
    ('ShaderNodeMixShader', 'Mix Shader'),
    ('ShaderNodeBsdfPrincipled', 'Principled BSDF'),
    ('ShaderNodeBsdfHairPrincipled', 'Principled Hair BSDF'),
    ('ShaderNodeVolumePrincipled', 'Principled Volume'),
    ('ShaderNodeBsdfRayPortal', 'Ray Portal BSDF'),
    ('ShaderNodeBsdfRefraction', 'Refraction BSDF'),
    ('ShaderNodeBsdfSheen', 'Sheen BSDF'),
    ('ShaderNodeEeveeSpecular', 'Specular BSDF'),
    ('ShaderNodeSubsurfaceScattering', 'Subsurface Scattering'),
    ('ShaderNodeBsdfToon', 'Toon BSDF'),
    ('ShaderNodeBsdfTranslucent', 'Translucent BSDF'),
    ('ShaderNodeBsdfTransparent', 'Transparent BSDF'),
    ('ShaderNodeVolumeAbsorption', 'Volume Absorption'),
    ('ShaderNodeVolumeCoefficients', 'Volume Coefficients'),
    ('ShaderNodeVolumeScatter', 'Volume Scatter'),
)
_SHADER_TYPES = {idname for idname, _ in SHADERS}

# The panels a node's inputs sit in, as its declaration groups them, with the
# property its panel draws first (`add_layout`). Inputs in no panel come
# first, in socket order. From the 5.3 sources
# (nodes/shader/nodes/node_shader_*.cc); the check holds the panel counts and
# socket identifiers to Blender's.
PANELS = {
    'ShaderNodeBsdfPrincipled': (
        ('Diffuse', None, ('Diffuse Roughness',)),
        ('Subsurface', 'subsurface_method', ('Subsurface Weight', 'Subsurface Radius', 'Subsurface Scale',
                                             'Subsurface IOR', 'Subsurface Anisotropy')),
        ('Specular', 'distribution', ('Specular IOR Level', 'Specular Tint', 'Anisotropic',
                                      'Anisotropic Rotation', 'Tangent')),
        ('Transmission', None, ('Transmission Weight',)),
        ('Coat', None, ('Coat Weight', 'Coat Roughness', 'Coat IOR', 'Coat Tint', 'Coat Normal')),
        ('Sheen', None, ('Sheen Weight', 'Sheen Roughness', 'Sheen Tint')),
        ('Emission', None, ('Emission Color', 'Emission Strength')),
        ('Thin Film', None, ('Thin Film Thickness', 'Thin Film IOR')),
    ),
    'ShaderNodeBsdfGlass': (('Thin Film', None, ('Thin Film Thickness', 'Thin Film IOR')),),
    'ShaderNodeBsdfMetallic': (('Thin Film', None, ('Thin Film Thickness', 'Thin Film IOR')),),
    'ShaderNodeVolumeCoefficients': (
        ('Absorption', None, ('Absorption Coefficients',)),
        ('Scatter', 'phase', ('Scatter Coefficients', 'Anisotropy', 'IOR', 'Backscatter', 'Alpha', 'Diameter')),
        ('Emission', None, ('Emission Coefficients',)),
    ),
}
# Panels Blender opens by default (`default_closed(false)`); every other is
# closed until opened, as Blender draws it.
OPEN_PANELS = {('ShaderNodeVolumeCoefficients', 'Absorption'), ('ShaderNodeVolumeCoefficients', 'Scatter'),
               ('ShaderNodeVolumeCoefficients', 'Emission')}

# A socket's `short_label` in its panel (the declarations'); a socket with
# none is shown with its panel's name taken off its own when it starts with
# it (`node_socket_get_label`): Thin Film Thickness reads Thickness.
SHORT_LABELS = {
    'ShaderNodeBsdfPrincipled': {
        'Subsurface Weight': 'Weight', 'Subsurface Radius': 'Radius', 'Subsurface Scale': 'Scale',
        'Subsurface IOR': 'IOR', 'Subsurface Anisotropy': 'Anisotropy', 'Specular IOR Level': 'IOR Level',
        'Specular Tint': 'Tint', 'Anisotropic': 'Anisotropy', 'Transmission Weight': 'Weight',
        'Coat Weight': 'Weight', 'Coat Roughness': 'Roughness', 'Coat IOR': 'IOR', 'Coat Tint': 'Tint',
        'Coat Normal': 'Normal', 'Sheen Weight': 'Weight', 'Sheen Roughness': 'Roughness',
        'Sheen Tint': 'Tint', 'Emission Color': 'Color', 'Emission Strength': 'Strength',
    },
}

# The node properties a node's own buttons draw above its inputs
# (`draw_buttons`), for the nodes that have them; Principled BSDF and Volume
# Coefficients draw theirs inside a panel (PANELS).
NODE_BUTTONS = {
    'ShaderNodeBsdfGlass': ('distribution',),
    'ShaderNodeBsdfAnisotropic': ('distribution',),
    'ShaderNodeBsdfMetallic': ('distribution', 'fresnel_type'),
    'ShaderNodeBsdfRefraction': ('distribution',),
    'ShaderNodeBsdfSheen': ('distribution',),
    'ShaderNodeBsdfHair': ('component',),
    'ShaderNodeBsdfToon': ('component',),
    'ShaderNodeSubsurfaceScattering': ('falloff',),
    'ShaderNodeVolumeScatter': ('phase',),
    'ShaderNodeBsdfHairPrincipled': ('model', 'parametrization'),
}

# The range Blender's interface drags a socket within: the declaration's
# min and max, which `rna_NodeSocketStandard_float_range` gives the slider as
# its soft range. Python's writes are not clamped to it.
SOFT_RANGES = {
    'ShaderNodeBackground': {'Strength': (0.0, 1000000.0)},
    'ShaderNodeBsdfAnisotropic': {'Roughness': (0.0, 1.0), 'Anisotropy': (-1.0, 1.0), 'Rotation': (0.0, 1.0)},
    'ShaderNodeBsdfDiffuse': {'Roughness': (0.0, 1.0)},
    'ShaderNodeBsdfGlass': {'Roughness': (0.0, 1.0), 'IOR': (0.0, 1000.0), 'Thin Film Thickness': (0.0, 100000.0),
                            'Thin Film IOR': (1.0, 1000.0)},
    'ShaderNodeBsdfHair': {'RoughnessU': (0.0, 1.0), 'RoughnessV': (0.0, 1.0)},
    'ShaderNodeBsdfHairPrincipled': {'Melanin': (0.0, 1.0), 'Melanin Redness': (0.0, 1.0),
                                     'Absorption Coefficient': (0.0, 1000.0), 'Aspect Ratio': (0.0, 1.0),
                                     'Roughness': (0.0, 1.0), 'Radial Roughness': (0.0, 1.0), 'Coat': (0.0, 1.0),
                                     'IOR': (0.0, 1000.0), 'Random Color': (0.0, 1.0),
                                     'Random Roughness': (0.0, 1.0), 'R lobe': (0.0, 1.0), 'TT lobe': (0.0, 1.0),
                                     'TRT lobe': (0.0, 1.0)},
    'ShaderNodeBsdfMetallic': {'IOR': (0.0, 100.0), 'Extinction': (0.0, 100.0), 'Roughness': (0.0, 1.0),
                               'Anisotropy': (0.0, 1.0), 'Rotation': (0.0, 1.0),
                               'Thin Film Thickness': (0.0, 100000.0), 'Thin Film IOR': (1.0, 1000.0)},
    'ShaderNodeBsdfPrincipled': {'Metallic': (0.0, 1.0), 'Roughness': (0.0, 1.0), 'IOR': (1.0, 1000.0),
                                 'Alpha': (0.0, 1.0), 'Diffuse Roughness': (0.0, 1.0),
                                 'Subsurface Weight': (0.0, 1.0), 'Subsurface Radius': (0.0, 100.0),
                                 'Subsurface Scale': (0.0, 10.0), 'Subsurface IOR': (1.01, 3.8),
                                 'Subsurface Anisotropy': (-1.0, 1.0), 'Specular IOR Level': (0.0, 1.0),
                                 'Anisotropic': (0.0, 1.0), 'Anisotropic Rotation': (0.0, 1.0),
                                 'Transmission Weight': (0.0, 1.0), 'Coat Weight': (0.0, 1.0),
                                 'Coat Roughness': (0.0, 1.0), 'Coat IOR': (1.0, 4.0), 'Sheen Weight': (0.0, 1.0),
                                 'Sheen Roughness': (0.0, 1.0), 'Emission Strength': (0.0, 1000000.0),
                                 'Thin Film Thickness': (0.0, 100000.0), 'Thin Film IOR': (1.0, 1000.0)},
    'ShaderNodeBsdfRefraction': {'Roughness': (0.0, 1.0), 'IOR': (0.0, 1000.0)},
    'ShaderNodeBsdfSheen': {'Roughness': (0.0, 1.0)},
    'ShaderNodeBsdfToon': {'Size': (0.0, 1.0), 'Smooth': (0.0, 1.0)},
    'ShaderNodeEeveeSpecular': {'Roughness': (0.0, 1.0), 'Transparency': (0.0, 1.0), 'Clear Coat': (0.0, 1.0),
                                'Clear Coat Roughness': (0.0, 1.0)},
    'ShaderNodeEmission': {'Strength': (0.0, 1000000.0)},
    'ShaderNodeMixShader': {'Fac': (0.0, 1.0)},
    'ShaderNodeSubsurfaceScattering': {'Scale': (0.0, 1000.0), 'Radius': (0.0, 100.0), 'IOR': (1.01, 3.8),
                                       'Roughness': (0.0, 1.0), 'Anisotropy': (-1.0, 1.0)},
    'ShaderNodeVolumeAbsorption': {'Density': (0.0, 1000.0)},
    'ShaderNodeVolumeCoefficients': {'Absorption Coefficients': (0.0, 1000.0),
                                     'Scatter Coefficients': (0.0, 1000.0), 'Anisotropy': (-1.0, 1.0),
                                     'IOR': (1.0, 2.0), 'Backscatter': (0.0, 0.5), 'Alpha': (0.0, 500.0),
                                     'Diameter': (0.0, 50.0), 'Emission Coefficients': (0.0, 1000.0)},
    'ShaderNodeVolumePrincipled': {'Density': (0.0, 1000.0), 'Anisotropy': (-1.0, 1.0),
                                   'Emission Strength': (0.0, 1000.0), 'Blackbody Intensity': (0.0, 1.0),
                                   'Temperature': (0.0, 6500.0)},
    'ShaderNodeVolumeScatter': {'Density': (0.0, 1000.0), 'Anisotropy': (-1.0, 1.0), 'IOR': (1.0, 2.0),
                                'Backscatter': (0.0, 0.5), 'Alpha': (0.0, 500.0), 'Diameter': (0.0, 50.0)},
}

# The Settings panel's properties (`draw_material_surface_settings`,
# `draw_material_volume_settings` and EEVEE_MATERIAL_PT_settings in 5.2.1's
# properties_material.py), by their RNA names.
SETTINGS = ('pass_index', 'use_backface_culling', 'use_backface_culling_shadow',
            'use_backface_culling_lightprobe_volume', 'displacement_method', 'max_vertex_displacement',
            'use_transparent_shadow', 'surface_render_method', 'use_transparency_overlap',
            'use_raytrace_refraction', 'thickness_mode', 'use_thickness_from_shadow',
            'volume_intersection_method')
_ENUM_SETTINGS = ('displacement_method', 'surface_render_method', 'thickness_mode', 'volume_intersection_method')


# ---------------------------------------------------------------------------
# Reading

def _finite(v, fallback=0.0):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return fallback
    return v if math.isfinite(v) else fallback


def _srgb(c):
    """Blender's `linearrgb_to_srgb`, for a swatch the interface draws."""
    c = _finite(c)
    if c < 0.0031308:
        return max(c, 0.0) * 12.92
    return 1.055 * pow(c, 1.0 / 2.4) - 0.055


def output_node(material):
    """The Material Output EEVEE renders through (`get_output_node('EEVEE')`),
    as Blender's Surface panel finds it (`panel_node_draw`)."""
    tree = getattr(material, 'node_tree', None)
    if tree is None:
        return None
    try:
        return tree.get_output_node('EEVEE')
    except (AttributeError, TypeError):
        return next((n for n in tree.nodes if n.type == 'OUTPUT_MATERIAL'), None)


def surface_node(material):
    """The node linked into the output's Surface, or None."""
    out = output_node(material)
    if out is None:
        return None
    socket = out.inputs.get('Surface')
    if socket is None or not socket.is_linked:
        return None
    link = socket.links[0] if socket.links else None
    return link.from_node if link is not None else None


def _base_input(node):
    """The colour a shader's look takes: Base Color, else Color."""
    if node is None:
        return None
    return node.inputs.get('Base Color') or node.inputs.get('Color')


def swatch(material):
    """A material's colour for the slot list and the browse menu, sRGB: the
    surface's unlinked Base Color (or Color), else its Viewport Display
    Color. Blender draws a rendered preview there; this is its colour."""
    if material is None:
        return None
    colour = None
    if not getattr(material, 'grease_pencil', None):
        socket = _base_input(surface_node(material))
        if socket is not None and not socket.is_linked and socket.type == 'RGBA':
            colour = tuple(socket.default_value)[:3]
    if colour is None:
        colour = tuple(material.diffuse_color)[:3]
    return [round(_srgb(c), 4) for c in colour]


def real_users(material):
    """Blender's `ID_REAL_USERS`: the number its user button shows."""
    return int(material.users) - (1 if material.use_fake_user else 0)


def _value(socket):
    v = getattr(socket, 'default_value', None)
    if v is None:
        return None
    if isinstance(v, (bool, int, str)):
        return v
    try:
        return [round(_finite(x), 6) for x in v]
    except TypeError:
        return round(_finite(v), 6)


def _link_name(tree, socket):
    """What Blender's link button names (`ui_node_sock_name`): the linked
    node's label, `node | socket` for a node with no inputs and several
    outputs, None when nothing is linked."""
    if not socket.is_linked or not socket.links:
        return None
    link = socket.links[0]
    node = link.from_node
    label = node.label or node.bl_rna.name
    if len(node.inputs) == 0 and len(node.outputs) > 1:
        return label + ' | ' + link.from_socket.name
    return label


def _input(node, socket, index, panel=None):
    """One input as the tab draws it, or None for one Blender does not draw
    (an unavailable socket: `SOCK_UNAVAIL`)."""
    if not socket.enabled:
        return None
    label = socket.name
    if panel is not None:
        short = SHORT_LABELS.get(node.bl_idname, {}).get(socket.identifier)
        if short is not None:
            label = short
        elif label.startswith(panel + ' '):
            label = label[len(panel) + 1:]
    entry = {'kind': 'input', 'id': socket.identifier, 'index': index, 'label': label,
             'type': socket.type, 'hide_value': bool(socket.hide_value),
             'inactive': bool(getattr(socket, 'is_inactive', False)),
             'link': _link_name(node.id_data, socket)}
    if not socket.is_linked and not socket.hide_value:
        entry['value'] = _value(socket)
        rna = socket.bl_rna.properties.get('default_value')
        if rna is not None:
            entry['subtype'] = getattr(rna, 'subtype', 'NONE')
        soft = SOFT_RANGES.get(node.bl_idname, {}).get(socket.identifier)
        if soft is not None:
            entry['min'], entry['max'] = soft
    return entry


def _prop(node, identifier):
    rna = node.bl_rna.properties.get(identifier)
    if rna is None or rna.type != 'ENUM':
        return None
    return {'kind': 'prop', 'id': identifier, 'label': rna.name, 'value': getattr(node, identifier),
            'options': [[item.identifier, item.name] for item in rna.enum_items]}


def node_items(node):
    """A node's buttons and inputs in Blender's order (`ui_node_draw_node`):
    its own buttons, the inputs in no panel, then each panel."""
    items = []
    for identifier in NODE_BUTTONS.get(node.bl_idname, ()):
        prop = _prop(node, identifier)
        if prop is not None:
            items.append(prop)
    panels = PANELS.get(node.bl_idname, ())
    in_panel = {sid for _, _, ids in panels for sid in ids}
    by_id = {}
    for index, socket in enumerate(node.inputs):
        by_id[socket.identifier] = (index, socket)
        if socket.identifier in in_panel:
            continue
        entry = _input(node, socket, index)
        if entry is not None:
            items.append(entry)
    for name, layout, ids in panels:
        body = []
        if layout is not None:
            prop = _prop(node, layout)
            if prop is not None:
                body.append(prop)
        for sid in ids:
            if sid in by_id:
                entry = _input(node, by_id[sid][1], by_id[sid][0], panel=name)
                if entry is not None:
                    body.append(entry)
        items.append({'kind': 'panel', 'label': name, 'open': (node.bl_idname, name) in OPEN_PANELS,
                      'items': body})
    return items


def _socket_view(material, socket_name):
    """The output's Surface or Volume as Blender's panel draws it."""
    out = output_node(material)
    if out is None:
        return {'output': None}
    socket = out.inputs.get(socket_name)
    if socket is None:
        return {'output': out.name, 'missing': True}
    view = {'output': out.name, 'socket': socket_name, 'index': list(out.inputs).index(socket),
            'link': _link_name(material.node_tree, socket)}
    node = surface_node(material) if socket_name == 'Surface' else (
        socket.links[0].from_node if socket.is_linked and socket.links else None)
    if node is not None:
        view['node'] = {'name': node.name, 'type': node.bl_idname,
                        'label': node.label or node.bl_rna.name, 'items': node_items(node)}
    return view


def _settings(material):
    found = {}
    for identifier in SETTINGS:
        if not hasattr(material, identifier):
            continue
        value = getattr(material, identifier)
        if isinstance(value, float):
            value = round(_finite(value), 6)
        found[identifier] = value
    return found


def _material_view(material):
    return {
        'name': material.name, 'users': real_users(material), 'fake_user': bool(material.use_fake_user),
        'library': material.library is not None,
        'viewport': {'color': [round(_finite(c), 6) for c in material.diffuse_color],
                     'metallic': round(_finite(material.metallic), 6),
                     'roughness': round(_finite(material.roughness), 6)},
        'settings': _settings(material),
        'surface': _socket_view(material, 'Surface'),
        'volume': _socket_view(material, 'Volume'),
    }


def _sort_key(name):
    """`BLI_strcasecmp_natural`, near enough: case folded, digit runs by value."""
    import re
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r'(\d+)', name)]


def state(name):
    """The tab's whole state for the object `name`, as one JSON line."""
    obj = bpy.data.objects.get(name)
    if obj is None:
        return json.dumps({'object': None})
    slots = []
    for slot in obj.material_slots:
        material = slot.material
        slots.append({'material': material.name if material is not None else None, 'link': slot.link,
                      'swatch': swatch(material)})
    materials = [m for m in bpy.data.materials if not getattr(m, 'grease_pencil', None)]
    materials.sort(key=lambda m: _sort_key(m.name))
    active = obj.active_material
    view = {
        'object': obj.name, 'type': obj.type, 'mode': obj.mode,
        'slots': slots, 'active': int(obj.active_material_index) if slots else -1,
        'materials': [{'name': m.name, 'users': real_users(m), 'fake_user': bool(m.use_fake_user),
                       'swatch': swatch(m)} for m in materials],
        'material': _material_view(active) if active is not None else None,
        'has_materials': hasattr(obj.data, 'materials') if obj.data is not None else False,
    }
    return json.dumps(view, separators=(',', ':'))


# ---------------------------------------------------------------------------
# What every control needs

def _object(name, editing_ok=True):
    obj = bpy.data.objects.get(name)
    if obj is None:
        raise Refusal("There is no object called " + repr(name) + ".")
    if obj.data is None or not hasattr(obj.data, 'materials'):
        raise Refusal(obj.name + " has no material slots: a " + obj.type.title() + " takes no material.")
    if bpy.context.view_layer.objects.active != obj:
        raise Refusal(obj.name + " is not the active object.")
    if obj.mode not in ('OBJECT', 'EDIT'):
        raise Refusal("Material slots are changed here in Object or Edit Mode; " + obj.name + " is in "
                      + obj.mode.replace('_', ' ').title() + " Mode.")
    if not editing_ok and obj.mode == 'EDIT':
        raise Refusal("Unable to remove material slot in edit mode")
    return obj


def _material(name):
    material = bpy.data.materials.get(name)
    if material is None:
        raise Refusal("There is no material called " + repr(name) + ".")
    if material.library is not None:
        raise Refusal(material.name + " is linked from a library and cannot be edited here.")
    return material


def _node(material, node_name):
    tree = material.node_tree
    node = tree.nodes.get(node_name) if tree is not None else None
    if node is None:
        raise Refusal(material.name + " has no node called " + repr(node_name) + ".")
    return node


def _finished(result, refusal):
    if 'FINISHED' not in result:
        raise Refusal(refusal)


def _active_material(obj):
    material = obj.active_material
    if material is None:
        raise Refusal("The active material slot of " + obj.name + " is empty.")
    return material


# ---------------------------------------------------------------------------
# The slot list (MATERIAL_PT_context_material)

def set_active_slot(name, index):
    obj = _object(name)
    if not 0 <= index < len(obj.material_slots):
        raise Refusal(obj.name + " has no material slot " + str(index + 1) + ".")
    obj.active_material_index = index


def slot_add(name):
    """Blender's + : an empty slot after the last, made active."""
    _object(name)
    _finished(bpy.ops.object.material_slot_add(), "Add Material Slot did nothing.")


def slot_remove(name):
    """Blender's - : the active slot. Not in Edit Mode (Blender's poll)."""
    obj = _object(name, editing_ok=False)
    if not obj.material_slots:
        raise Refusal(obj.name + " has no material slot to remove.")
    _finished(bpy.ops.object.material_slot_remove(), "Remove Material Slot did nothing.")


def slot_move(name, direction):
    obj = _object(name)
    count = len(obj.material_slots)
    index = obj.active_material_index
    if count < 2:
        raise Refusal("Move Material needs two slots; " + obj.name + " has " + str(count) + ".")
    if (direction == 'UP' and index == 0) or (direction == 'DOWN' and index == count - 1):
        raise Refusal("The active slot is already the " + ("first" if direction == 'UP' else "last") + ".")
    _finished(bpy.ops.object.material_slot_move(direction=direction), "Move Material did nothing.")


def _edit_mesh(obj):
    if obj.mode != 'EDIT':
        raise Refusal("Assign, Select and Deselect work in Edit Mode; " + obj.name + " is in Object Mode.")


def assign(name):
    """Assign: the selected faces take the active slot."""
    obj = _object(name)
    _edit_mesh(obj)
    if not obj.material_slots:
        raise Refusal(obj.name + " has no material slot to assign.")
    if obj.type == 'MESH':
        obj.update_from_editmode()
        if not any(p.select for p in obj.data.polygons):
            raise Refusal("Assign gives the selected faces the active slot, and no face is selected.")
    _finished(bpy.ops.object.material_slot_assign(), "Assign Material Slot did nothing.")


def select(name, select=True):
    """Select or Deselect: the faces using the active slot."""
    obj = _object(name)
    _edit_mesh(obj)
    if not obj.material_slots:
        raise Refusal(obj.name + " has no material slot.")
    op = bpy.ops.object.material_slot_select if select else bpy.ops.object.material_slot_deselect
    _finished(op(), ("Select" if select else "Deselect") + " Material Slot did nothing.")


# Material Specials (MATERIAL_MT_context_menu)

def copy_material(name):
    obj = _object(name)
    material = _active_material(obj)
    with bpy.context.temp_override(material=material):
        _finished(bpy.ops.material.copy(), "Copy Material did nothing.")


def paste_material(name):
    obj = _object(name)
    material = _active_material(obj)
    if material.library is not None:
        raise Refusal(material.name + " is linked from a library and cannot be pasted into.")
    with bpy.context.temp_override(material=material):
        _finished(bpy.ops.material.paste(), "Paste Material: there is no copied material to paste.")


def copy_to_selected(name):
    """Copy Material to Selected: every slot of the active object onto every
    other selected object, as `object.material_slot_copy` does."""
    obj = _object(name)
    others = [o for o in bpy.context.selected_editable_objects
              if o != obj and o.data is not None and hasattr(o.data, 'materials')]
    if not others:
        raise Refusal("Copy Material to Selected copies " + obj.name + "'s materials onto the other selected "
                      "objects, and no other object that takes materials is selected.")
    _finished(bpy.ops.object.material_slot_copy(), "Copy Material to Selected did nothing.")


def remove_unused(name):
    _object(name, editing_ok=False)
    _finished(bpy.ops.object.material_slot_remove_unused(), "Remove Unused Slots: no slot is unused.")


def remove_all(name):
    obj = _object(name, editing_ok=False)
    if not obj.material_slots:
        raise Refusal(obj.name + " has no material slots.")
    _finished(bpy.ops.object.material_slot_remove_all(), "Remove All Materials did nothing.")


# ---------------------------------------------------------------------------
# The material datablock (the slot's template_ID)

def new_material(name):
    """New: a new material in the active slot — Blender's default node tree
    when the slot is empty, a copy of the slot's material when it is not."""
    obj = _object(name)
    current = obj.active_material
    if current is not None:
        material = current.copy()
    else:
        material = bpy.data.materials.new("Material")
        if not obj.material_slots:
            _finished(bpy.ops.object.material_slot_add(), "New Material could not add a slot.")
    obj.active_material = material
    return material.name


def browse(name, material_name):
    """Browse Material: the slot takes an existing material."""
    obj = _object(name)
    material = bpy.data.materials.get(material_name)
    if material is None:
        raise Refusal("There is no material called " + repr(material_name) + ".")
    obj.active_material = material


def unlink(name):
    """Unlink Data-Block: the slot is emptied; the material stays."""
    obj = _object(name)
    _active_material(obj)
    obj.active_material = None


def single_user(name):
    """Make Single User: the slot gets a copy of its shared material."""
    obj = _object(name)
    material = _active_material(obj)
    if real_users(material) < 2:
        raise Refusal(material.name + " has one user already.")
    obj.active_material = material.copy()


def fake_user(material_name, on):
    material = bpy.data.materials.get(material_name)
    if material is None:
        raise Refusal("There is no material called " + repr(material_name) + ".")
    material.use_fake_user = bool(on)


def rename(material_name, wanted):
    material = _material(material_name)
    if not wanted.strip():
        raise Refusal("A material needs a name.")
    material.name = wanted


def set_link(name, link):
    obj = _object(name)
    if not obj.material_slots:
        raise Refusal(obj.name + " has no material slot.")
    if link not in ('OBJECT', 'DATA'):
        raise Refusal("A slot links to its Object or its Data, not " + repr(link) + ".")
    obj.material_slots[obj.active_material_index].link = link


# ---------------------------------------------------------------------------
# The Surface and Volume panels

def _tag(tree, node):
    tree.update_tag()


def _remove_linked(tree, removed):
    """Blender's `node_remove_linked`: `removed` and every node upstream of
    it that no other node uses."""
    tagged = set()

    def tag(node):
        if node is None or node in tagged:
            return
        tagged.add(node)
        for socket in node.inputs:
            for link in socket.links:
                tag(link.from_node)

    tag(removed)

    def clear(node):
        if node is None or node not in tagged:
            return
        tagged.discard(node)
        for socket in node.inputs:
            for link in socket.links:
                clear(link.from_node)

    for node in list(tree.nodes):
        if node in tagged:
            continue
        for socket in node.inputs:
            for link in socket.links:
                if link.from_node != removed:
                    clear(link.from_node)
    for node in list(tree.nodes):
        if node in tagged:
            tree.nodes.remove(node)


def set_shader(material_name, socket_name, idname):
    """The Surface (or Volume) menu: `idname` linked into the output's socket,
    replacing what was there as `node_socket_add_replace` does — at the old
    node's place, with every input of the same identifier and type taking
    the old one's value and link, then the old node and what fed only it
    removed. The same type again keeps the node."""
    material = _material(material_name)
    if idname not in _SHADER_TYPES:
        raise Refusal(repr(idname) + " is not a shader Blender's " + socket_name + " menu offers.")
    out = output_node(material)
    if out is None:
        raise Refusal(material.name + " has no Material Output.")
    socket = out.inputs.get(socket_name)
    if socket is None:
        raise Refusal("The Material Output has no " + socket_name + " input.")
    tree = material.node_tree
    previous = socket.links[0].from_node if socket.is_linked and socket.links else None
    if previous is not None and previous.bl_idname == idname:
        return previous.name
    for link in list(socket.links):
        tree.links.remove(link)
    node = tree.nodes.new(idname)
    if previous is not None:
        node.location = previous.location
    else:
        node.location = (out.location[0] - node.width - 40.0, out.location[1])
    tree.nodes.active = node
    tree.links.new(node.outputs[0], socket)
    if previous is not None:
        for old in previous.inputs:
            for new in node.inputs:
                if new.identifier != old.identifier or new.type != old.type:
                    continue
                if old.is_linked and old.links:
                    link = old.links[0]
                    tree.links.new(link.from_socket, new)
                    tree.links.remove(link)
                if hasattr(old, 'default_value') and hasattr(new, 'default_value'):
                    try:
                        value = old.default_value
                        new.default_value = tuple(value) if hasattr(value, '__len__') and not isinstance(value, str) else value
                    except (TypeError, ValueError, AttributeError):
                        pass
        _remove_linked(tree, previous)
    _tag(tree, node)
    return node.name


def disconnect(material_name, socket_name):
    """The menu's Disconnect: the link goes, the nodes stay."""
    material = _material(material_name)
    out = output_node(material)
    socket = out.inputs.get(socket_name) if out is not None else None
    if socket is None or not socket.is_linked:
        raise Refusal("Nothing is connected to " + socket_name + ".")
    for link in list(socket.links):
        material.node_tree.links.remove(link)


def remove(material_name, socket_name):
    """The menu's Remove: the nodes connected to the input, unless used elsewhere."""
    material = _material(material_name)
    out = output_node(material)
    socket = out.inputs.get(socket_name) if out is not None else None
    if socket is None or not socket.is_linked:
        raise Refusal("Nothing is connected to " + socket_name + ".")
    _remove_linked(material.node_tree, socket.links[0].from_node)


def set_input(material_name, node_name, index, value):
    """One input's value. A colour is linear, as Blender stores it."""
    material = _material(material_name)
    node = _node(material, node_name)
    if not 0 <= index < len(node.inputs):
        raise Refusal(node.name + " has no input " + str(index) + ".")
    socket = node.inputs[index]
    if socket.is_linked:
        raise Refusal(socket.name + " is connected to " + (_link_name(material.node_tree, socket) or 'a node')
                      + ": its own value is not used.")
    if not hasattr(socket, 'default_value'):
        raise Refusal(socket.name + " has no value to set.")
    current = socket.default_value
    if hasattr(current, '__len__') and not isinstance(current, str):
        values = list(value)
        if len(values) == 3 and len(current) == 4:
            values.append(current[3])
        socket.default_value = values[:len(current)]
    else:
        socket.default_value = value
    _tag(material.node_tree, node)


def set_node_prop(material_name, node_name, identifier, value):
    material = _material(material_name)
    node = _node(material, node_name)
    if node.bl_rna.properties.get(identifier) is None:
        raise Refusal(node.name + " has no setting " + repr(identifier) + ".")
    setattr(node, identifier, value)
    _tag(material.node_tree, node)


# ---------------------------------------------------------------------------
# Settings and Viewport Display

def set_material(material_name, identifier, value):
    material = _material(material_name)
    if identifier not in SETTINGS + ('diffuse_color', 'metallic', 'roughness'):
        raise Refusal("The Material tab does not set " + repr(identifier) + ".")
    if identifier == 'diffuse_color':
        values = list(value)
        if len(values) == 3:
            values.append(material.diffuse_color[3])
        value = values[:4]
    setattr(material, identifier, value)


# ---------------------------------------------------------------------------
# What the 3D View draws a slot with

_ESCAPES = (('%', '%25'), (';', '%3B'), ('|', '%7C'), ('=', '%3D'), ('\n', '%0A'))


def _text(value):
    text = str(value)
    for raw, escaped in _ESCAPES:
        text = text.replace(raw, escaped)
    return text


def _numbers(values):
    return ','.join(repr(round(_finite(v), 6)) for v in values)


def _socket_number(node, *names, fallback=0.0):
    for name in names:
        socket = node.inputs.get(name)
        if socket is not None and socket.enabled and hasattr(socket, 'default_value'):
            value = socket.default_value
            if hasattr(value, '__len__'):
                return [_finite(v) for v in value]
            return _finite(value)
    return fallback


def look(material):
    """One slot's record: its Viewport Display (what Solid draws, Blender's
    default colour type being Material) and what Material Preview shades
    with, read off the surface shader as near as one metallic-roughness
    surface can say it."""
    if material is None:
        return 'kind=slot;none=1'
    pairs = [('kind', 'slot'), ('name', _text(material.name)),
             ('display', _numbers(material.diffuse_color)),
             ('display_metallic', _numbers([material.metallic])),
             ('display_roughness', _numbers([material.roughness]))]
    node = None if getattr(material, 'grease_pencil', None) else surface_node(material)
    if node is None:
        pairs.append(('connected', '0'))
        return ';'.join(k + '=' + v for k, v in pairs)
    kind = node.bl_idname
    base = _base_input(node)
    colour = [0.8, 0.8, 0.8]
    linked = 0
    if base is not None and base.type == 'RGBA':
        colour = [_finite(c) for c in tuple(base.default_value)[:3]]
        linked = 1 if base.is_linked else 0
    metallic, roughness, ior, alpha = 0.0, 0.5, 1.5, 1.0
    emission, strength = [0.0, 0.0, 0.0], 0.0
    if kind == 'ShaderNodeBsdfPrincipled':
        metallic = _socket_number(node, 'Metallic')
        roughness = _socket_number(node, 'Roughness', fallback=0.5)
        ior = _socket_number(node, 'IOR', fallback=1.5)
        alpha = _socket_number(node, 'Alpha', fallback=1.0)
        emission = _socket_number(node, 'Emission Color', fallback=[0.0, 0.0, 0.0])[:3]
        strength = _socket_number(node, 'Emission Strength')
    elif kind in ('ShaderNodeEmission', 'ShaderNodeBackground'):
        emission, colour = colour, [0.0, 0.0, 0.0]
        strength = _socket_number(node, 'Strength', fallback=1.0)
        ior = 1.0
    elif kind in ('ShaderNodeBsdfMetallic', 'ShaderNodeBsdfAnisotropic'):
        metallic = 1.0
        roughness = _socket_number(node, 'Roughness', fallback=0.5)
    elif kind in ('ShaderNodeBsdfDiffuse', 'ShaderNodeBsdfTranslucent', 'ShaderNodeSubsurfaceScattering',
                  'ShaderNodeBsdfSheen', 'ShaderNodeBsdfToon'):
        roughness, ior = 1.0, 1.0
    elif kind in ('ShaderNodeBsdfGlass', 'ShaderNodeBsdfRefraction'):
        roughness = _socket_number(node, 'Roughness', fallback=0.0)
        ior = _socket_number(node, 'IOR', fallback=1.5)
    elif kind == 'ShaderNodeEeveeSpecular':
        roughness = _socket_number(node, 'Roughness', fallback=0.5)
        emission = _socket_number(node, 'Emissive Color', fallback=[0.0, 0.0, 0.0])[:3]
        strength = 1.0
    elif kind == 'ShaderNodeHoldout':
        colour = [0.0, 0.0, 0.0]
    pairs += [('connected', '1'), ('shader', kind), ('base', _numbers(colour)), ('base_linked', str(linked)),
              ('metallic', _numbers([metallic])), ('roughness', _numbers([roughness])),
              ('ior', _numbers([ior])), ('alpha', _numbers([alpha])),
              ('emission', _numbers(emission)), ('strength', _numbers([strength]))]
    return ';'.join(k + '=' + v for k, v in pairs)


def record(obj, cache=None):
    """Every slot's look, `|`-joined, in slot order. `cache` keeps a pass from
    reading a material shared by many objects more than once."""
    parts = []
    for slot in obj.material_slots:
        material = slot.material
        if cache is None:
            parts.append(look(material))
            continue
        key = material.name if material is not None else None
        if key not in cache:
            cache[key] = look(material)
        parts.append(cache[key])
    return '|'.join(parts)


def triangle_slots(mesh, editing, hidden_flags=None):
    """Each triangle's slot (`material_index`) as the pass drew the triangles:
    hidden faces left out in Edit Mode, as `_unhidden_triangles` leaves them."""
    from array import array
    count = len(mesh.loop_triangles)
    slots = array('i', [0]) * count
    mesh.loop_triangles.foreach_get('material_index', slots)
    if editing and hidden_flags is not None:
        faces = array('I', [0]) * count
        mesh.loop_triangles.foreach_get('polygon_index', faces)
        slots = array('i', (slots[t] for t in range(count) if not hidden_flags[faces[t]]))
    return slots


def push(obj, mesh, editing, hidden_flags=None, cache=None):
    """Hand the 3D View `obj`'s slot looks and, for an object of two slots or
    more, each triangle's slot. None for an object with no slot."""
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_materials', None)
    if send is None or not hasattr(obj, 'material_slots'):
        return
    if len(obj.material_slots) == 0:
        send(obj.name, '', b'')
        return
    slots = b''
    if len(obj.material_slots) > 1 and mesh is not None:
        found = triangle_slots(mesh, editing, hidden_flags)
        if any(found):
            slots = found.tobytes()
    send(obj.name, record(obj, cache), slots)
