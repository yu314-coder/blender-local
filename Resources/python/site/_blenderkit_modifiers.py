"""The buttons of the modifier rows round 4, group 8 added — Surface Deform's
and Mesh Deform's Bind, Data Transfer's Generate Data Layers, the Hook's and
the Skin's operators — and Add Modifier's Essentials rows, each checked before
Blender runs it and refused in a sentence the banner shows.

Measured in desktop Blender 5.2.1 with the app's context (its undo push,
`gpu.init()`, the window and screen with no area, as the Operator Search and
the panel's buttons run), probe in round 4 group 8's notes:

  * Bind is a toggle. `surfacedeform_bind` and `meshdeform_bind` with the
    modifier's name bind an unbound modifier and unbind a bound one, and both
    answer FINISHED with nothing to bind to, leaving it unbound. Run in Edit
    Mode, Surface Deform's answered FINISHED and left a bound modifier
    unbound: Blender binds at the next evaluation, which Edit Mode does not
    run for the modifier. So both run in Object Mode, and what Blender holds
    afterwards (`is_bound`) is checked against what was asked.
  * Mesh Deform's bind is priced by its Precision: on the cube inside a 4 m
    cube cage, precision 2 to 4 bound in 0.0 to 0.03 s, 5 (Blender's default)
    in 3.2 s, and 6 had not finished after 120 s. The app runs it on the main
    thread, so 6 and above are refused.
  * Hook's Reset, Recenter, Select and Assign pass their poll only in Edit
    Mode (Blender's panel shows them only there); in Object Mode, even with
    the modifier in the context, the poll fails ("context is incorrect").
    Assign takes the selected vertices: with x > 0 selected, 4, 5, 6 and 7.
  * The Skin's Mark Root, Mark Loose, Clear Loose and Equalize Radii are Edit
    Mode operators on the selected vertices; Create Armature runs in Object
    Mode and adds an armature with an Armature modifier on the mesh.
  * Data Transfer's Generate Data Layers (`datalayout_transfer`) runs in
    Object Mode and makes the destination's layers (the source's "Top" group
    on the cube, weights 1.0 on the four top vertices after it).
"""

import bpy

# Mesh Deform's Precision above which Bind is refused (measured above).
MESH_DEFORM_MAX_PRECISION = 5

_EDIT_MODE_OPS = {
    'hook_reset': ('HOOK', 'hook_reset', 'Reset'),
    'hook_recenter': ('HOOK', 'hook_recenter', 'Recenter'),
    'hook_select': ('HOOK', 'hook_select', 'Select'),
    'hook_assign': ('HOOK', 'hook_assign', 'Assign'),
    'skin_root': ('SKIN', 'skin_root_mark', 'Mark Root'),
    'skin_loose_mark': ('SKIN', 'skin_loose_mark_clear', 'Mark Loose'),
    'skin_loose_clear': ('SKIN', 'skin_loose_mark_clear', 'Clear Loose'),
    'skin_equalize': ('SKIN', 'skin_radii_equalize', 'Equalize Radii'),
}
_OBJECT_MODE_OPS = {
    'bind_surface': ('SURFACE_DEFORM', 'surfacedeform_bind', 'Bind'),
    'bind_mesh': ('MESH_DEFORM', 'meshdeform_bind', 'Bind'),
    'generate': ('DATA_TRANSFER', 'datalayout_transfer', 'Generate Data Layers'),
    'skin_armature': ('SKIN', 'skin_armature_create', 'Create Armature'),
}
_TYPE_NAMES = {'HOOK': 'Hook', 'SKIN': 'Skin', 'SURFACE_DEFORM': 'Surface Deform',
               'MESH_DEFORM': 'Mesh Deform', 'DATA_TRANSFER': 'Data Transfer'}


def _is_real_blender():
    return hasattr(bpy.ops.object.mode_set, 'get_rna_type')


def _modifier(name, kind, what):
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        raise RuntimeError(what + " needs an active object.")
    modifier = obj.modifiers.get(name)
    if modifier is None or modifier.type != kind:
        raise RuntimeError("%s has no %s modifier called %r." % (obj.name, _TYPE_NAMES[kind], name))
    return obj, modifier


def run(op, name):
    """One of the buttons above on the active object's modifier `name`.
    Returns a sentence saying what Blender holds afterwards."""
    if not _is_real_blender():
        raise RuntimeError("This runs in Blender, which the simulator does not have.")
    if op in _EDIT_MODE_OPS:
        return _edit_mode_op(op, name)
    if op in _OBJECT_MODE_OPS:
        return _object_mode_op(op, name)
    raise RuntimeError("No modifier button %r" % (op,))


def _edit_mode_op(op, name):
    kind, operator, label = _EDIT_MODE_OPS[op]
    what = "%s %s" % (_TYPE_NAMES[kind], label)
    obj, modifier = _modifier(name, kind, what)
    if obj.mode != 'EDIT':
        raise RuntimeError(what + " works in Edit Mode, on the selected vertices, as Blender's "
                           + _TYPE_NAMES[kind] + " panel shows it. Press Tab first.")
    function = getattr(bpy.ops.object, operator)
    arguments = {}
    if kind == 'HOOK':
        arguments['modifier'] = name
        if op in ('hook_reset', 'hook_recenter') and modifier.object is None:
            raise RuntimeError(what + " needs the Hook's Object: pick one first.")
    if op == 'skin_loose_mark':
        arguments['action'] = 'MARK'
    if op == 'skin_loose_clear':
        arguments['action'] = 'CLEAR'
    result = function(**arguments)
    if 'FINISHED' not in result:
        raise RuntimeError("Blender did not run %s (%s)." % (what, ', '.join(sorted(result))))
    if op == 'hook_assign':
        obj.update_from_editmode()
        return "%s moves %d vertices" % (name, len(modifier.vertex_indices))
    return what


def _object_mode_op(op, name):
    kind, operator, label = _OBJECT_MODE_OPS[op]
    what = "%s %s" % (_TYPE_NAMES[kind], label)
    obj, modifier = _modifier(name, kind, what)
    was_bound = getattr(modifier, 'is_bound', None)
    if kind == 'SURFACE_DEFORM' and not was_bound and modifier.target is None:
        raise RuntimeError("Surface Deform binds to its Target, and %s has none. Pick a mesh first."
                           % name)
    if kind == 'MESH_DEFORM' and not was_bound:
        if modifier.object is None:
            raise RuntimeError("Mesh Deform binds to its Object, the cage, and %s has none. "
                               "Pick a mesh first." % name)
        if modifier.precision > MESH_DEFORM_MAX_PRECISION:
            raise RuntimeError(
                "Mesh Deform's Bind at Precision %d is refused here: on a desktop Mac Blender "
                "bound a cube in a cube cage at Precision 5 in 3.2 s and had not finished at 6 "
                "after two minutes, with the app frozen meanwhile. Lower Precision to %d or less."
                % (modifier.precision, MESH_DEFORM_MAX_PRECISION))
    if kind == 'DATA_TRANSFER' and modifier.object is None:
        raise RuntimeError("Generate Data Layers copies the Source's layers, and %s has no "
                           "Source. Pick a mesh first." % name)
    if was_bound is not None and not was_bound and not modifier.show_viewport:
        # Blender binds when it next evaluates the modifier, which it does not
        # while the modifier is hidden: measured, Bind on a hidden Surface
        # Deform answered FINISHED and left it unbound.
        raise RuntimeError("%s binds when Blender evaluates it, which it does not while Show in "
                           "Viewport is off. Turn it on first." % name)
    import _blenderkit_multires
    start = _blenderkit_multires._leave_for_object_mode(obj, what)
    try:
        function = getattr(bpy.ops.object, operator)
        result = function(modifier=name)
        if 'FINISHED' not in result:
            raise RuntimeError("Blender did not run %s (%s)." % (what, ', '.join(sorted(result))))
        if was_bound is not None:
            # Blender binds at the next evaluation.
            bpy.context.view_layer.update()
            obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
            bound = modifier.is_bound
            if not was_bound and not bound:
                if kind == 'SURFACE_DEFORM':
                    raise RuntimeError(
                        "Blender did not bind %s to %s. Its Surface Deform refuses a target with "
                        "concave faces, overlapping faces or edges shared by more than two faces, "
                        "or one that does not reach the mesh." % (obj.name, modifier.target.name))
                raise RuntimeError("Blender did not bind %s to the cage %s: the cage must "
                                   "enclose the mesh and be closed." % (obj.name, modifier.object.name))
            return ("%s is bound" if bound else "%s is unbound") % name
        return what
    finally:
        if start != 'OBJECT' and bpy.context.view_layer.objects.active is not None:
            try:
                bpy.ops.object.mode_set(mode=start)
            except RuntimeError:
                pass


# Add Modifier ▸ Generate's three node-group rows (`operator_modifier_add_asset`
# in properties_data_modifier.py): each loads a node group from Blender's
# Essentials library. The device's bpy has no `datafiles/assets`, and in
# desktop 5.2.1 run headless the operator added nothing ("Asset loading is
# unfinished"), so the row is greyed out without the library and the call
# checks that a modifier arrived.
ESSENTIALS_ASSETS = ('Array', 'Curve to Tube', 'Scatter on Surface')


def add_asset(name):
    if name not in ESSENTIALS_ASSETS:
        raise RuntimeError("Add Modifier has no %r row" % (name,))
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        raise RuntimeError("Add Modifier needs an active object.")
    import _blenderkit_context
    if not _blenderkit_context.essentials_available():
        raise RuntimeError(name + " adds a node group from Blender's Essentials asset library, "
                           "which this build of Blender does not include.")
    before = len(obj.modifiers)
    with _blenderkit_context.needs_essentials(name, "Add it from a Blender that has the library."):
        bpy.ops.object.modifier_add_node_group(
            asset_library_type='ESSENTIALS', asset_library_identifier='',
            relative_asset_identifier='nodes/geometry_nodes_essentials.blend/NodeTree/' + name)
    if len(obj.modifiers) == before:
        raise RuntimeError("Blender added no %s modifier: its asset library had not finished "
                           "loading." % name)
    return obj.modifiers[-1].name
