"""`Context.temp_override` on the thread scripts run on.

Scripts run on a thread of their own so the interface keeps drawing (the
Scripting tab's Options > Run Scripts Off the Main Thread). Blender's context gives out its window,
screen, area and region on the main thread only: anywhere else they read None.
`temp_override` reads those same members to learn what to put back. Off the
main thread it read None, and at the end of the block it wrote None into the
one context the main thread shares.

From then on the main thread had no window and no screen either. Every
operator that needs one failed its poll, Blender's undo included, which fell
back to .blend checkpoints until the app was restarted. One
`temp_override(window=...)` on a worker thread is enough, in desktop Blender
too.

Those members never reach the operators off the main thread anyway: inside
the block `context.area` still reads None there. So off the main thread they
are left out, and a warning says so. The other members, such as
`active_object` or `selected_objects`, still apply.

The session runs a script that mentions `temp_override` on the main thread
to begin with (`ScriptThread` in BpyRuntime.swift), where the override works
as it does in Blender. This covers the calls that check cannot see, such as
one in a module the script imports.

Loading a file is the other thing that needs the main thread. It takes down
Blender's screen on the way (`guard_file_reads`), and on the script thread
that crashed the app, so off the main thread the operators that do it are
refused in words instead.
"""
import os
import sys
import threading
import warnings

# The members Blender reads back through the main-thread-only accessors.
UI_MEMBERS = ('window', 'screen', 'area', 'region')

# The `bpy.ops.wm` operators that load a .blend over the scene. The same names
# as `ScriptThread.fileReads` in the Swift, which runs a script that mentions
# one on the main thread; run-scriptthread-tests.sh compares the two.
FILE_READS = ('read_homefile', 'read_factory_settings', 'open_mainfile',
              'revert_mainfile', 'recover_last_session', 'recover_auto_save')
# Of those, the ones with a Load UI option.
LOAD_UI_OPTION = ('read_homefile', 'open_mainfile')

# The operators that give the window another scene (fix round 3, October 29):
# New (`ED_scene_add`), New Sequencer Scene and Drop Scene Asset
# (`WM_window_set_active_scene`), Delete (`ED_scene_replace_active_for_deletion`,
# editors/scene/scene_edit.cc). Setting the window's scene clears an override's
# `scene` (`CTX_data_scene_set` drops the Python context's member) and keeps
# its `view_layer`, so Blender's own update after the call
# (`bpy_op_fn_call`) evaluates the new scene with another scene's view layer,
# or with the deleted scene's freed one. Measured in bare desktop 5.2.1 under
# MallocScribble, each in a Blender of its own, every call inside a
# temp_override that sets view_layer: Full Copy and Linked Copy with a new
# scene's view layer (`temp_override(scene=s2, view_layer=s2.view_layers[0])`,
# the review's) exited 139 in deg_update_eval_copy_datablock, New and Copy
# Settings with the window scene's own one in BKE_object_eval_eval_base_flags,
# New Sequencer Scene the same, and Delete of the override's scene in the
# depsgraph's build from the freed view layer (build_view_layer). With `scene`
# alone in the override, none crashed (the window's view layer follows the
# window's scene), and the other 21 of the 24 `scene.` and `workspace.`
# operators swept crashed with neither shape. So these are refused in words
# while an override in force sets view_layer (`_SceneSwitch`); elsewhere they
# are Blender's.
SCENE_SWITCHES = ('scene.new', 'scene.new_sequencer_scene', 'scene.delete', 'scene.drop_scene_asset')

# The `bpy.ops.mesh` operators that segfault Blender when the context has no
# 3D View region. Measured in desktop 5.2.1 with the app's context (its undo
# push, gpu.init(), window and screen but no area, which is what a script and
# the operator search have): `mesh.loopcut(edge_index=0)` and the line Blender's
# Info editor logs for every loop cut, `mesh.loopcut_slide(MESH_OT_loopcut={...,
# "edge_index": 4}, ...)`, both crashed in `loopcut_init` (called from
# `wm_macro_exec`). Under `temp_override_view3d` both work: the factory cube in
# Edit Mode went from 8/12/6 to 12/20/10 vertices/edges/faces.
NEEDS_VIEW = ('loopcut', 'loopcut_slide')

# Add ▸ Mesh's primitives, priced by the vertex budget before Blender makes
# them (`_PricedAdd`, `_blenderkit_budget.price_primitive`): RNA takes a UV
# Sphere's Segments and Rings to 100,000 and a grid's subdivisions and a
# circle's, cylinder's and cone's Vertices to 10,000,000, which a typed value
# in Adjust Last Operation, the Operator Search or a script line reaches
# (round 4's fix round; 10^10 vertices is past any device's memory). The
# Plane, Cube and Monkey make a fixed 4, 8 and 507, and are priced all the
# same: in a mesh's Edit Mode Blender adds them into the edited mesh, under
# its whole stack (round 4's second fix-round review: a cube under
# Subdivision 6, 24,578, then Add ▸ Monkey three times in Edit Mode, each
# passing, made 6,074,312 — about 2,000,000 a press).
PRICED_ADDS = ('primitive_circle_add', 'primitive_uv_sphere_add', 'primitive_ico_sphere_add',
               'primitive_cylinder_add', 'primitive_cone_add', 'primitive_torus_add',
               'primitive_grid_add', 'primitive_plane_add', 'primitive_cube_add',
               'primitive_monkey_add')

# The operators that give an object another's data or modifiers, or rebuild
# its own mesh under the modifiers it has, priced by the vertex budget before
# Blender runs them (`_PricedOperator`, `_blenderkit_budget.price_operator`),
# from the Object menu, an Edit Mode panel, the Operator Search or a script
# line alike. Round 4's fix-round review measured each with the app's own
# strings in desktop 5.2.1, unpriced: Join, Link/Transfer Data, Copy
# Modifiers to Selected Objects (a cube under Subdivision 4 onto a 120 × 120
# grid: 3,690,241 vertices), Apply ▸ Scale (an Array fitted to 100 m, 408 →
# 4,000,008), Edit Mode Subdivide (10 cuts under Subdivision 6: 2,973,698),
# the curve's Subdivide, QuadriFlow and Voxel Remesh under a Subdivision. The
# modifier operators the search priced itself are here too, so a script line
# is priced as the search is; and with them a render (at its render levels),
# Edit Mode's operators that add to the edited mesh (Bevel's Segments, Spin's
# Steps, Extrude, Duplicate, ...), Object Mode's moves (the gizmo's commit,
# the snaps, the clears: where an offset object or a Hook's empty is is what
# an Array or a Remesh after the Hook counts by) and a metaball's Duplicate.
# Each is priced from what it is called with, before Blender runs it: the
# moves evaluate the scene inside the operator (measured: right after a
# translate of an Array's offset object, its 3,199,472 vertices were made).
PRICED_OPERATORS = ('object.join', 'object.make_links_data', 'object.modifiers_copy_to_selected',
                    'object.modifier_copy_to_selected', 'object.modifier_add', 'object.modifier_copy',
                    'object.modifier_move_up', 'object.modifier_move_down',
                    'object.modifier_move_to_index', 'object.transform_apply', 'mesh.subdivide',
                    'curve.subdivide', 'object.quadriflow_remesh', 'object.voxel_remesh',
                    'object.metaball_add', 'object.subdivision_set', 'object.multires_subdivide',
                    'sculpt.detail_flood_fill', 'render.render',
                    # Edit Mode's operators that add to the edited mesh
                    # (`_blenderkit_budget._EDIT_GROWTH`).
                    'mesh.bevel', 'mesh.spin', 'mesh.screw', 'mesh.bridge_edge_loops', 'mesh.extrude_repeat',
                    'mesh.fill_grid', 'mesh.symmetrize', 'mesh.bisect', 'mesh.convex_hull', 'mesh.wireframe',
                    'mesh.poke', 'mesh.inset', 'mesh.extrude_region_move', 'mesh.extrude_region_and_move',
                    'mesh.extrude_region_shrink_fatten', 'mesh.extrude_manifold', 'mesh.extrude_context_move',
                    'mesh.extrude_region', 'mesh.extrude_context', 'mesh.solidify', 'mesh.extrude_faces_move',
                    'mesh.extrude_faces_indiv', 'mesh.extrude_edges_move', 'mesh.extrude_edges_indiv',
                    'mesh.extrude_vertices_move', 'mesh.extrude_verts_indiv', 'mesh.duplicate_move',
                    'mesh.duplicate', 'mesh.offset_edge_loops_slide', 'mesh.offset_edge_loops',
                    'mesh.rip_edge_move', 'mesh.rip_move', 'mesh.split', 'mesh.edge_split', 'mesh.vert_connect',
                    'mesh.vert_connect_path', 'mesh.face_split_by_edges', 'mesh.edge_face_add', 'mesh.fill_holes',
                    'mesh.fill', 'mesh.beautify_fill', 'mesh.intersect', 'mesh.intersect_boolean',
                    'mesh.subdivide_edgering', 'curve.extrude_move', 'curve.extrude',
                    # Object Mode's moves (`_blenderkit_budget._MOVES`); the
                    # rotation is `_Rotate`'s, which asks the same price.
                    'transform.translate', 'transform.resize', 'transform.mirror', 'object.location_clear',
                    'object.rotation_clear', 'object.scale_clear', 'view3d.snap_selected_to_cursor',
                    'view3d.snap_selected_to_active', 'view3d.snap_selected_to_grid', 'object.parent_clear',
                    'object.origin_set',
                    # A metaball's copy joins its family's polygonization, and so
                    # does an element's copy in its Edit Mode; a curve's copied
                    # points, and a primitive added in its Edit Mode, take its
                    # bevel and its stack.
                    'object.duplicate', 'object.duplicate_move', 'object.duplicate_move_linked',
                    'mball.duplicate_move', 'mball.duplicate_metaelems', 'curve.duplicate_move',
                    'curve.duplicate', 'curve.primitive_bezier_curve_add', 'curve.primitive_bezier_circle_add',
                    'curve.primitive_nurbs_curve_add', 'curve.primitive_nurbs_circle_add',
                    'curve.primitive_nurbs_path_add', 'surface.primitive_nurbs_surface_curve_add',
                    'surface.primitive_nurbs_surface_circle_add', 'surface.primitive_nurbs_surface_surface_add',
                    'surface.primitive_nurbs_surface_cylinder_add', 'surface.primitive_nurbs_surface_sphere_add',
                    'surface.primitive_nurbs_surface_torus_add',
                    # What evaluates the scene at its render settings besides a
                    # render: a bake, and the exporters set to Render (fix round
                    # 3, `_blenderkit_budget._RENDER_EVALUATIONS`).
                    'object.bake', 'object.bake_image', 'wm.obj_export', 'wm.stl_export', 'wm.usd_export',
                    'wm.alembic_export', 'export_scene.fbx')

# The operators that take the active object into Sculpt Mode, as
# (module, name). Sculpt Mode's way in is refused for a Multires level too
# heavy to sculpt here (`_blenderkit_sculpt.refuse_heavy_multires`), and only
# the bar's mode menu asked it: round 4's review measured, in desktop 5.2.1
# with the app's context, the operator search's `object.mode_set(mode='SCULPT')`
# and `sculpt.sculptmode_toggle` both entering Sculpt Mode on an 8,066-vertex
# base at Multires levels 1/1/1, which the menu refuses, and a script line can
# do the same. Each is asked here, as the operator is called (`_SculptEntry`).
# Operators of Blender's own interface — its menus, pies and panels, and the
# areas and regions it draws — that crash a Blender with no interface, which
# the app's bpy is (it draws its own). Refused in words there, from a script,
# the console or the operator search alike (`UNSAFE_OPERATORS`). Measured in
# desktop 5.2.1 with the app's context (its undo push, gpu.init(), window and
# screen), round 4's review of group 7:
#   * with or without an area, given what to open: `wm.call_menu(name=
#     'VIEW3D_MT_object')`, `wm.call_menu_pie(name='VIEW3D_MT_object_mode_pie')`,
#     `wm.call_panel(name='VIEW3D_PT_snapping')` and `wm.context_menu_enum(
#     data_path='scene.render.engine')` (or 'object.mode') each segfaulted
#     (exit 139); with no name they fail in words, and the operator sweep
#     (defaults only) never typed one;
#   * under the borrowed 3D View, where every command runs in Local View
#     (`_blenderkit_localview.run`, the search's rows among them): the sweep
#     from Local View (tests/opsearch/blender, LOCAL_VIEW) crashed on
#     `wm.toolbar`, `view3d.object_mode_pie_or_toggle`, `screen.region_quadview`,
#     `view2d.pan` and `view2d.scroll_down/left/right/up` (exit -11), and
#     `screen.area_close` ran past a minute. With no area each fails its poll.
_MENU = ("{name} opens {what} of Blender's own interface, which this Blender does not have — the "
         "app draws its own — and Blender crashes opening one. The app's menus are in its header, "
         "toolbar and editors.")
_REGION = ("{name} works on {what} in Blender's own interface, which this Blender does not have — "
           "the app draws its own — and Blender crashes in it.")
INTERFACE_ONLY = dict(
    [('wm.call_menu', _MENU.format(name='Call Menu', what='a menu')),
     ('wm.call_menu_pie', _MENU.format(name='Call Pie Menu', what='a pie menu')),
     ('wm.call_panel', _MENU.format(name='Call Panel', what='a panel')),
     ('wm.context_menu_enum', _MENU.format(name='Context Enum Menu', what='a menu')),
     ('wm.toolbar', _MENU.format(name='Toolbar', what='the toolbar popup')),
     ('view3d.object_mode_pie_or_toggle', _MENU.format(name='Object Mode Menu', what='a pie menu')),
     ('screen.region_quadview', _REGION.format(name='Toggle Quad View', what="a 3D View's regions")),
     ('screen.area_close', _REGION.format(name='Close Area', what='an area'))]
    # Blender's own names for them (`get_rna_type().name`, 5.2.1).
    + [('view2d.' + n, _REGION.format(name=label, what="a region's view"))
       for n, label in (('pan', 'Pan View'), ('scroll_down', 'Scroll Down'), ('scroll_left', 'Scroll Left'),
                        ('scroll_right', 'Scroll Right'), ('scroll_up', 'Scroll Up'))])


# ---------------------------------------------------------------------------
# Operators that must not run as they are called
#
# One table for every route an operator is called by: a script line on either
# thread, the console, Run, a module a script imports, and the operator
# search, whose `_blenderkit_sync._refusal` and `run_operator` read this table
# and nothing else. Round 4's final review found the search refusing
# `uv.stitch` and `uv.select_edge_ring` by a list of its own while the same
# call as a script line segfaulted or hung Blender, and the Brush menu giving
# `brush.asset_activate` the tool it needs while the search's and a script's
# call crashed. Each entry says what was measured and either refuses the call
# in words (`prepare` None) or gives it what it needs (`prepare`, which raises
# RuntimeError when it cannot). Every operator named here is wrapped as it is
# looked up (`guard_file_reads`, `_Unsafe`) and asked as it is called, so one
# looked up outside an override and called inside it is asked too.


class Unsafe:
    """One operator that must not run as it is called in the app's Blender.

    `refusal`: the sentence the banner shows when every call is refused.
    `measured`: what was measured, and where. `prepare`: None to refuse every
    call; otherwise a function of (args, keywords) that gives the call what it
    needs, or raises RuntimeError saying why it cannot. `without_interface`:
    only in a Blender with no interface (the app's bpy, a check's `-b`)."""
    __slots__ = ('refusal', 'measured', 'prepare', 'without_interface')

    def __init__(self, refusal, measured, prepare=None, without_interface=False):
        self.refusal = refusal
        self.measured = measured
        self.prepare = prepare
        self.without_interface = without_interface

    def applies(self):
        return not self.without_interface or _without_interface()

    def refuses(self):
        """Whether every call is refused here (the search greys its form out)."""
        return self.prepare is None and self.applies()


# The brush modes, as the view layer's active object holds them (`Object.mode`):
# the tool system's mode for each (`CTX_data_mode_enum_ex`, context.cc), which
# `brush.asset_activate` gives the brush to the 3D View's tool for, and the
# ToolSettings member whose brush it sets (`BKE_paint_get_active`, paint.cc).
# Blender's pick reads the mode from the view layer's active object
# (`WM_toolsystem_mode_from_spacetype`, `BKE_paintmode_get_active_from_context`),
# not from `bpy.context.mode`, which follows an overridden `active_object`:
# round 4's fix-round review measured a file saved in Vertex Paint, opened as
# the app opens it, and a pick under `temp_override(active_object=<an object in
# Object Mode>)` — `context.mode` read 'OBJECT', a guard that asked it made no
# tool, and the pick exited 139 in WM_toolsystem_activate_brush_and_tool
# (desktop 5.2.1, the app's context).
_BRUSH_MODE_KEYS = {
    'SCULPT': ('SCULPT', 'sculpt'), 'VERTEX_PAINT': ('PAINT_VERTEX', 'vertex_paint'),
    'WEIGHT_PAINT': ('PAINT_WEIGHT', 'weight_paint'), 'TEXTURE_PAINT': ('PAINT_TEXTURE', 'image_paint'),
    'SCULPT_CURVES': ('SCULPT_CURVES', 'curves_sculpt'),
    'PAINT_GREASE_PENCIL': ('PAINT_GREASE_PENCIL', 'gpencil_paint'),
    'SCULPT_GREASE_PENCIL': ('SCULPT_GREASE_PENCIL', 'gpencil_sculpt_paint'),
    'WEIGHT_GREASE_PENCIL': ('WEIGHT_GREASE_PENCIL', 'gpencil_weight_paint'),
    'VERTEX_GREASE_PENCIL': ('VERTEX_GREASE_PENCIL', 'gpencil_vertex_paint')}
# The context modes (`bpy.context.mode`) of those: Blender's paint modes.
BRUSH_MODES = tuple(key for key, _ in _BRUSH_MODE_KEYS.values())
# The editors besides the 3D View that have tools of their own
# (`WM_TOOLSYSTEM_SPACE_MASK`), by Blender's names for them. Called with one
# of them as the context's area, the pick gives the brush to that editor's
# tool instead (`toolsystem_active_tool_from_context_or_view3d`).
_OTHER_TOOL_SPACES = {'IMAGE_EDITOR': 'Image Editor', 'NODE_EDITOR': 'Node Editor',
                      'SEQUENCE_EDITOR': 'Video Sequencer'}

# The names a script can call that need the main thread for the workspace
# (`give_brush_tool`), as `ScriptThread.brushPicks` in the Swift, which runs a
# script that mentions one there; run-scriptthread-tests.sh compares the two.
BRUSH_PICKS = ('asset_activate',)


def give_brush_tool(what, keywords=None):
    """The 3D View's tool for the brush mode Blender is in, made if there is
    none, which `brush.asset_activate` needs; RuntimeError, its sentence
    beginning with `what`, where it cannot be had: off the main thread,
    outside a brush mode, in another editor that has tools, and for Toggle
    (`keywords['use_toggle']`) with no brush to swap with.

    `asset_activate` gives the brush to the mode's tool in the context's
    workspace (`WM_toolsystem_activate_brush_and_tool`) without asking whether
    there is one. A file saved in Vertex Paint, Weight Paint or Sculpt Mode,
    opened with `load_ui=False` as the app opens every file, keeps the startup
    workspace, which has no tool for that mode until the mode is entered: the
    app's own autosave, saved in Vertex Paint, crashed the app's bpy 5.3 on the
    Brush menu's first pick (EXC_BAD_ACCESS at 0xe0, 2026-10-19). Measured in
    desktop 5.2.1 with the app's context (round 4's fix round): the pick by a
    script line, under the borrowed 3D View and from the operator search each
    exited 139 there; with the tool made first by `wm.tool_set_by_id` under the
    borrowed view, each ran (FINISHED, and the brush is Blender's). Texture
    Paint, the Grease Pencil modes and Sculpt Curves opened with their tool.
    Off the main thread Blender gives out no workspace (`bpy.context.workspace`
    reads None there), and the pick exited 139 with the tool there too.

    Outside a brush mode Blender gives the brush to Texture Paint's settings
    (`BKE_paint_get_active`, its default) and the tool of the mode it is in,
    which has none: measured in desktop 5.2.1 with the app's context (round
    4's second fix round, 2026-10-21), a Texture Paint brush ('Paint Hard' from
    essentials_brushes-mesh_texture.blend) picked in Object Mode — the factory
    scene, and a file opened as the app opens it — and in Edit Mode each exited
    139 in WM_toolsystem_activate_brush_and_tool. A Vertex Paint or Sculpt
    brush there was FINISHED and changed nothing (Blender: "wrong object
    mode"), so refusing every pick outside a brush mode loses nothing. And
    under an Image Editor (an area of the startup screen turned into one), in
    Vertex Paint with the 3D View's tool made, the Texture Paint brush exited
    139 there too, where the Vertex Paint brush was FINISHED."""
    import bpy
    if not _is_main_thread():
        # Whatever the mode: off the main thread `bpy.context.mode` reads
        # 'OBJECT' with the object in Sculpt Mode (it has no window to read
        # the mode through), so a first version of this guard that asked it
        # there let the pick through in Sculpt Mode, Texture Paint and Grease
        # Pencil Draw, and each exited 139 (desktop 5.2.1, the app's context).
        # In Object Mode the pick changes nothing.
        raise RuntimeError(
            what + " needs the 3D View's tool in Blender's workspace, which Blender gives out "
            "on the main thread only, and on the script thread Blender crashes giving it the "
            "brush. A script that names asset_activate runs on the main thread; for a call "
            "from somewhere else, such as an imported module, turn off Run Scripts Off the "
            "Main Thread in the Scripting tab's Options menu.")
    context = bpy.context
    area = context.area
    if area is not None and area.type in _OTHER_TOOL_SPACES:
        raise RuntimeError(
            what + " gives the brush to the 3D View's tool, and this context's area is an "
            "editor with tools of its own (" + _OTHER_TOOL_SPACES[area.type] + "), whose tool "
            "Blender gives it to instead and crashes without. Call it with no area, or under "
            "the 3D View.")
    # As Blender's pick reads it: the view layer's active object, whatever
    # `active_object` the context was given.
    view_layer = context.view_layer
    obj = view_layer.objects.active if view_layer is not None else None
    mode = getattr(obj, 'mode', 'OBJECT') if obj is not None else 'OBJECT'
    keys = _BRUSH_MODE_KEYS.get(mode)
    if keys is None:
        try:
            name = bpy.types.Object.bl_rna.properties['mode'].enum_items[mode].name
        except (AttributeError, KeyError):
            name = mode
        raise RuntimeError(
            what + " gives a brush to the tool of the paint mode Blender is in, and the active "
            "object is in " + name + ", which has none: Blender crashes giving it a Texture "
            "Paint brush there. Enter the brush's paint mode first.")
    key, settings = keys
    if keywords and keywords.get('use_toggle'):
        # Toggle swaps with the brush the mode holds, which Blender reads
        # without asking whether there is one (`brush_asset_activate_exec`:
        # `BLI_assert(paint->brush_asset_reference)`, then `*paint->...`).
        # Read from the source; no measured file held none.
        paint = getattr(getattr(context.scene, 'tool_settings', None), settings, None)
        if paint is None or paint.brush_asset_reference is None:
            raise RuntimeError(
                what + " with Toggle swaps with the brush this mode holds, and it holds none, "
                "which Blender reads without asking. Pick the brush without Toggle.")
    workspace = context.workspace
    if workspace is None:
        raise RuntimeError(
            what + " needs the 3D View's tool in Blender's workspace, and this context has no "
            "workspace (its window was overridden away), so Blender would crash giving the "
            "brush to a tool it cannot find.")
    tool = workspace.tools.from_space_view3d_mode(key, create=False)
    # `use_brushes` reads False for a tool with no runtime data, which the
    # pick dereferences as it does the tool (`active_tool->runtime->brush_type`).
    if tool is not None and tool.use_brushes:
        return
    try:
        with temp_override_view3d(what):
            # `tool_set_by_id` makes the tool for `context.mode`, which follows
            # the context's `active_object`; measured: a script's own
            # `temp_override(active_object=...)` stays in force inside the
            # borrowed view. So the object Blender's pick reads is given.
            with bpy.context.temp_override(active_object=obj, object=obj):
                bpy.ops.wm.tool_set_by_id(name='builtin.brush', space_type='VIEW_3D')
    except RuntimeError as error:
        raise RuntimeError(
            what + ": the 3D View has no tool for this mode to give the brush to, and Blender "
            "could not make one (" + str(error).strip() + ").") from None
    workspace = bpy.context.workspace
    tool = workspace.tools.from_space_view3d_mode(key, create=False) if workspace is not None else None
    if tool is None or not tool.use_brushes:
        raise RuntimeError(
            what + ": the 3D View has no tool for this mode to give the brush to, and Blender "
            "made none.")


_MEASURED_UV = ("desktop Blender 5.2.1 with the app's context (its modules and guards, gpu.init(), its "
                "undo push), an unwrapped cube in Edit Mode with everything selected, round 4's final "
                "review and its fix round (2026-10-20): ")
UNSAFE_OPERATORS = dict(
    [('uv.stitch', Unsafe(
        "Stitch works in Blender's UV Editor, which this Blender does not have — the app draws its "
        "own — and without one Blender crashes in it, with no editor as it finishes and in the 3D "
        "View as it starts.",
        _MEASURED_UV + "with no area (a script line, and the operator search's sweep of 13,852 runs) "
        "exit 139 in stitch_exit; under the borrowed 3D View exit 139 in ED_region_draw_cb_activate "
        "(from stitch_init_all); off the main thread its poll fails.")),
     ('uv.select_edge_ring', Unsafe(
        "Edge Ring Select picks the ring under the pointer in Blender's UV Editor, which this "
        "Blender does not have, and without one Blender never returns from it. Select ▸ Select "
        "Loops ▸ Edge Rings selects edge rings in the 3D View.",
        _MEASURED_UV + "with no area (a script line) it ran past 30 s and was killed (the review's: "
        "past 60 s); under the borrowed 3D View CANCELLED; off the main thread its poll fails.")),
     ('brush.asset_activate', Unsafe(
        "Activate Brush Asset needs the 3D View's tool for the mode Blender is in.",
        "desktop Blender 5.2.1 with the app's context, a file saved in Vertex Paint, Weight Paint or "
        "Sculpt Mode (a copy of the app's autosave among them) opened as the app opens it: exit 139 "
        "in WM_toolsystem_activate_brush_and_tool by a script line, under the borrowed 3D View, by "
        "the operator search and off the main thread; with the tool made first, FINISHED on the "
        "main thread and exit 139 off it. The same exit under an overridden active_object, for a "
        "Texture Paint brush in Object or Edit Mode, and under an Image Editor "
        "(`give_brush_tool`).",
        prepare=lambda args, keywords: give_brush_tool('Activate Brush Asset', keywords)))]
    + [(path, Unsafe(sentence, "desktop Blender 5.2.1 with the app's context, round 4's review of group 7 "
                     "(the comment above INTERFACE_ONLY)", without_interface=True))
       for path, sentence in INTERFACE_ONLY.items()])


def refusal(path):
    """Why every call of `path` ('module.operator') is refused here, or None:
    what the operator search shows on its form and its banner."""
    entry = UNSAFE_OPERATORS.get(operator_path(path))
    return entry.refusal if entry is not None and entry.refuses() else None


def ask(path, args=(), keywords=None):
    """Raises RuntimeError, in words, when `path` must not run as it is
    called here, after giving it what it needs where that can be done
    (`Unsafe.prepare`). Nothing for an operator the table does not name."""
    path = operator_path(path)
    entry = UNSAFE_OPERATORS.get(path)
    if entry is None or not entry.applies():
        return
    if entry.prepare is None:
        raise RuntimeError('bpy.ops.' + path + ' was not run: ' + entry.refusal)
    try:
        entry.prepare(args, keywords if keywords is not None else {})
    except RuntimeError as error:
        raise RuntimeError('bpy.ops.' + path + ' was not run: ' + str(error)) from None


SCULPT_ENTRIES = (('object', 'mode_set'), ('object', 'mode_set_with_submode'),
                  ('sculpt', 'sculptmode_toggle'))


def _is_main_thread():
    try:
        import _blenderkit
        return _blenderkit.is_main_thread()
    except (ImportError, AttributeError):
        # Desktop Blender, in the checks: Python was started on its main thread.
        return threading.current_thread() is threading.main_thread()


def install(bpy):
    """Wrap `bpy.types.Context.temp_override`, once. Returns whether it is wrapped.

    Guards the file-reading operators too (`guard_file_reads`), and counts the
    file loads that free Blender's undo stack (`require_undo_stack`).
    """
    guard_file_reads(bpy)
    guard_library_write(bpy)
    _count_loads(bpy)
    # The one gate every write goes through before Blender evaluates it
    # (_blenderkit_gate.py): its handlers, once.
    gate = _gate_module()
    if gate is not None:
        gate.install()
    context_type = getattr(bpy.types, 'Context', None)
    original = getattr(context_type, 'temp_override', None)
    if original is None:
        return False
    if getattr(original, '_blenderkit_guard', False):
        return True
    doc = original.__doc__
    original = _Sealed(original, 'Context.temp_override')

    def temp_override(self, **members):
        # Every member Blender reads back as a pointer of its own type, given
        # only what that type holds (`refuse_members`: scene=None, and a
        # dozen more, crashed the next operator, desktop 5.2.1).
        refuse_members(members)
        # A screen with no window: Blender's enter reads the window's active
        # screen to put back (`bpy_rna_context_temp_override_enter`), and
        # with no window it segfaults in WM_window_get_active_screen.
        # Measured in desktop 5.2.1 with `temp_override(window=None,
        # screen=None)` (exit 139, 2026-10-20); window=None, screen=None,
        # area=None or region=None alone, and screen with area, enter.
        if 'screen' in members and _is_main_thread() and members.get(
                'window', getattr(self, 'window', None)) is None:
            raise RuntimeError(
                'temp_override was not entered: it was given a screen and no window, and '
                "Blender crashes putting back a screen it reads from no window. Give the "
                'window the screen belongs to, or leave the screen out.')
        if not _is_main_thread():
            dropped = [name for name in UI_MEMBERS if name in members]
            if dropped:
                for name in dropped:
                    del members[name]
                warnings.warn(
                    'temp_override ignored ' + ', '.join(dropped) + ': Blender gives out '
                    'the window, screen, area and region on the main thread only, and this '
                    'call ran on the script thread. A script that calls temp_override itself '
                    'runs on the main thread; for a call from somewhere else, such as an '
                    'imported module, turn off Run Scripts Off the Main Thread in the '
                    "Scripting tab's Options menu.",
                    RuntimeWarning, stacklevel=2)
        # Asked again as it is entered, and by every operator while it is in
        # force (`_Override`, `refuse_stale_members`).
        return _Override(original(self, **members), members)

    temp_override.__doc__ = doc
    temp_override.__name__ = 'temp_override'
    # A mark, not the original: that one, on the script thread, writes None
    # into the main thread's context (the module's docstring).
    temp_override._blenderkit_guard = True
    context_type.temp_override = temp_override
    # What a block frees from under its own override (the section after
    # `_Override`): every read of `bpy.context` and, from 3.12, every call
    # ask the watched overrides first. Measured in desktop 5.2.1: a read
    # through the hook took 184 ns against 125 with none in force.
    global _struct_getattribute
    struct = getattr(bpy.types, 'bpy_struct', None)
    if struct is not None and _struct_getattribute is None:
        _struct_getattribute = struct.__getattribute__
        context_type.__getattribute__ = _context_getattribute
    _take_tool()
    return True


class _Guarded:
    # An operator as `bpy.ops` hands it out, with a check before the call.
    # Everything but the call is the operator's own: poll, idname,
    # get_rna_type, bl_options, and the signature Blender prints for it.
    __slots__ = ('_operator', '_name')

    def __init_subclass__(cls, **keywords):
        # Every wrapper's call asks the overrides in force first
        # (`refuse_stale_members`), before its own checks and the gate read
        # the context: an ID removed inside a `temp_override` block that lists
        # it, then the next operator, crashed desktop 5.2.1.
        super().__init_subclass__(**keywords)
        call = cls.__dict__.get('__call__')
        if call is None:
            return

        def __call__(self, *args, **values):
            if _in_force:
                refuse_stale_members(self)
            return call(self, *args, **values)
        cls.__call__ = __call__

    def __init__(self, operator, name):
        # Made by this module only (`_op_create_function`). A wrapper a script
        # makes calls whatever it is given from this module's frame, which is
        # what a `_Sealed` holder lets through: fix round 3's review measured
        # `type(bpy.ops.scene.new)(holder, 'scene.new')('object',
        # 'select_all')`, the holder taken from `_bpy.ops.create_function`'s
        # closure, handing back Blender's raw BPyOpFunction (desktop 5.2.1,
        # every guard class constructible so). Read from the caller's frame as
        # `_module_only` reads it: `type.__call__` adds no Python frame.
        if sys._getframe(1).f_globals is not _GLOBALS:
            raise TypeError(_GUARD_REFUSAL)
        self._operator = operator
        self._name = name

    def __getattr__(self, name):
        # Reached for `_operator` only from outside this module, where it is
        # refused (`_module_only`); a method of the operator is passed on as a
        # plain function, whose `__self__` would be the operator (`_unbound`).
        if name == '_operator':
            raise AttributeError(_SLOT_REFUSAL.format(what='This operator'))
        return _unbound(getattr(self._operator, name))

    def __dir__(self):
        return dir(self._operator)

    def __repr__(self):
        return repr(self._operator)

    @property
    def __doc__(self):
        return self._operator.__doc__


# ---------------------------------------------------------------------------
# A file load in progress
#
# Blender runs Python inside a load: the load_pre handlers, then — once the
# file has replaced the scene — the texts registered as modules, the
# version_update and load_post handlers and the depsgraph's handlers, and only
# after those does it set up the modes the file's objects were saved in
# (`ED_editors_init`, wm_files.cc `wm_file_read_post`). An operator in that
# window finds an object in Sculpt Mode with no sculpt session. Measured in
# desktop 5.2.1 with every guard (round 4's second fix-round review): a
# persistent load_post handler running `paint.mask_flood_fill`, then
# `wm.open_mainfile` of a file saved in Sculpt Mode — exit 139 in
# `sculpt_update_object` from `mask_flood_fill_exec`, the handler first or
# last in load_post. One script line arms it, and any later load fires it,
# the app's File > Open and Revert among them. And a load inside a load: the
# outer load goes on with the database the inner one freed
# (`wm_file_read_post` holds `bmain` across load_post). Measured this round,
# `wm.open_mainfile` from a load_post handler: exit 139 in
# `wm_file_read_post` in 2 runs of 12 with an undo push after it (which
# `_FileRead` made after every load), none in 6 without, and every run with
# macOS filling freed memory (MallocScribble=1: 7 of 7 for the load alone, the
# handler first or last in load_post). Nothing the app does loads a file from
# inside a load.
#
# So every load the app or a script makes (`_FileRead`) notes the address of
# Blender's main database as it begins; while one is in progress and that
# address has changed — the file has replaced the scene, measured in 5.2.1:
# load_pre reads the old address, version_update and load_post the new one —
# an operator is refused in words while any object is in a mode other than
# Object Mode (`refuse_mid_load`), and a second load is refused outright.

# The address of Blender's main database (`bpy.data.as_pointer()`) as each
# load in progress began, innermost last; None where it could not be read.
_reading = []


def _main_address():
    try:
        import bpy
        return bpy.data.as_pointer()
    except (ImportError, AttributeError, RuntimeError, ReferenceError):
        return None


def refuse_mid_load(name):
    """Raises, in words, when the operator `name` ('module.operator') is
    called inside a file load after the file replaced the scene, while an
    object of it is in a mode Blender has not set up yet. Nothing outside a
    load, in its load_pre handlers, or where every object is in Object Mode."""
    if not _reading or _reading[-1] is None:
        return
    import bpy
    try:
        if bpy.data.as_pointer() == _reading[-1]:
            return
        modes = sorted({obj.mode for obj in bpy.data.objects} - {'OBJECT'})
    except (AttributeError, RuntimeError, ReferenceError, TypeError):
        return
    if not modes:
        return
    try:
        items = bpy.types.Object.bl_rna.properties['mode'].enum_items
        names = [items[mode].name for mode in modes]
    except (AttributeError, KeyError):
        names = modes
    raise RuntimeError(
        'bpy.ops.' + name + " was not run: Blender is still opening the file, and sets up the "
        "modes its objects were saved in (" + ', '.join(names) + ") only after its load "
        "handlers have run; a sculpt operator run before that crashed Blender. Run it after "
        "the load returns, in the script that opened the file.")


class _FileRead(_Guarded):
    # One of FILE_READS, refused off the main thread and inside another load.
    __slots__ = ()
    # A class body sets __doc__ (None without a docstring), which would hide
    # the operator's own, Blender's signature line.
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        if not _is_main_thread():
            raise RuntimeError(
                'bpy.ops.wm.' + self._name + ' was not run: loading a file takes down '
                "Blender's screen, which exists on the main thread only, and on the "
                'script thread it crashed the app. A script that calls it by name runs '
                'on the main thread; for a call from somewhere else, such as an imported '
                'module, turn off Run Scripts Off the Main Thread in the Scripting '
                "tab's Options menu.")
        if _reading:
            raise RuntimeError(
                'bpy.ops.wm.' + self._name + ' was not run: Blender is opening a file '
                'already (this call came from one of its load handlers), and the load in '
                'progress goes on with the scene a second load frees, which crashes Blender. '
                'Load the next file after this one returns.')
        if self._name in LOAD_UI_OPTION:
            keywords.setdefault('load_ui', False)
        _reading.append(_main_address())
        try:
            with _calling('wm.' + self._name):
                result = self._operator(*args, **keywords)
        finally:
            _reading.pop()
        # The load freed Blender's undo stack, and a sculpt operator after it
        # in the same script segfaulted (desktop 5.2.1: `read_homefile` or
        # `open_mainfile`, then `paint.mask_flood_fill` in Sculpt Mode).
        # Made again at once (`_blenderkit_undo.ensure_stack`).
        undo = sys.modules.get('_blenderkit_undo')
        if undo is not None and hasattr(undo, 'ensure_stack'):
            undo.ensure_stack('Original')
        return result


class _NeedsView(_Guarded):
    # One of NEEDS_VIEW, refused unless the context has a 3D View region.
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        import bpy
        refuse_mid_load('mesh.' + self._name)
        area, region = bpy.context.area, bpy.context.region
        if area is None or area.type != 'VIEW_3D' or region is None or region.type != 'WINDOW':
            raise RuntimeError(
                'bpy.ops.mesh.' + self._name + ' was not run: it cuts at the edge under '
                "the pointer in a 3D View, and with no 3D View in the context Blender "
                "crashes in it. Use the toolbar's Loop Cut, or run it "
                "inside `with _blenderkit_context.temp_override_view3d('Loop Cut'):`.")
        # `bpy.ops.mesh.loopcut_slide('EXEC_DEFAULT', True, ...)`: with its undo
        # on, Blender opens the operator's redo panel in the area it ran in,
        # and in the borrowed 3D View that segfaults (ED_area_type_hud_ensure,
        # from wm_operator_finished; desktop 5.2.1 with the app's context,
        # 2026-10-18). The app records the undo step itself. The undo is read
        # as Blender reads it (`undo_requested`): `1` crashed the same way.
        if undo_requested(args):
            raise RuntimeError(
                'bpy.ops.mesh.' + self._name + ' was not run with its undo on: in the '
                "borrowed 3D View Blender crashes opening its redo panel. Call it without "
                "the undo argument; the app records the undo step itself.")
        # Its time, which grows with the square of its cuts: refused before it
        # runs (`_blenderkit_loopcut.check_call`; round 4's fix round 2
        # review froze Blender for 342 s with 32,000 cuts on a cube).
        loopcut = _site_module('_blenderkit_loopcut')
        if loopcut is not None:
            loopcut.check_call('mesh.' + self._name, keywords)
        with _calling('mesh.' + self._name):
            return self._operator(*args, **keywords)


def enters_sculpt_mode(name, keywords):
    """Whether calling `name` (one of SCULPT_ENTRIES) with `keywords` takes
    the active object into Sculpt Mode from another mode. `mode_set` goes to
    `mode` (OBJECT when not given), and with `toggle` back out of it when the
    object is in it already; `sculptmode_toggle` goes in from any other mode."""
    import bpy
    obj = bpy.context.view_layer.objects.active
    current = getattr(obj, 'mode', 'OBJECT') if obj is not None else 'OBJECT'
    if current == 'SCULPT':
        return False
    if name == 'sculptmode_toggle':
        return True
    return keywords.get('mode', 'OBJECT') == 'SCULPT'


def refuse_sculpt_entry(name, keywords):
    """Raises Sculpt Mode's refusal (`_blenderkit_sculpt.refuse_heavy_multires`)
    when the call would take the active object into Sculpt Mode on a Multires
    level too heavy to sculpt here. Nothing without the sculpt module (the
    checks that do not load it) or on the simulator's stand-in, which has no
    Multires."""
    if not enters_sculpt_mode(name, keywords):
        return
    sculpt = sys.modules.get('_blenderkit_sculpt')
    if sculpt is None:
        try:
            import _blenderkit_sculpt as sculpt
        except ImportError:
            return
    sculpt.refuse_heavy_multires()


# ---------------------------------------------------------------------------
# Blender's undo stack, which Sculpt Mode's operators write to unchecked
#
# A Blender with no interface has no undo stack until `ed.undo_push` makes one,
# and a file load frees it. Sculpt Mode's undo code dereferences it without a
# check: measured in desktop 5.2.1 (tests/undostack/blender), entering Sculpt
# Mode with the undo argument on, and `paint.mask_flood_fill` or
# `sculpt.face_sets_init` in it, segfault with none (exit 139 in
# `ED_undosys_stack_memfile_id_changed_tag` from `push_begin_ex`). The history
# makes the stack with its first step, which the app pushes before the first
# command (`BpySession.prepareBackendChange`), and again after every load
# (`_FileRead`). That ordering is all that stood between a command and the
# crash: round 4's review of group 7 measured a launch whose recovery file
# opened in Sculpt Mode, then the Operator Search's Mask Flood Fill with no
# first push — exit 139 — and found a console line that skipped the push
# (`time python -c …`, which the console did not count as Python). So every
# operator asks here as it is called, and the stack is made, or the call is
# refused in words, before Sculpt Mode's undo code can read it missing.

# File loads seen: each frees the stack (`_bk_context_load_post`).
_loads = 0
# The `_loads` count at which the stack was last seen; None when it has to be
# looked at again.
_stack_seen = None


def _bk_context_load_post(*_):
    global _loads, _stack_seen
    _loads += 1
    _stack_seen = None


def _count_loads(bpy):
    """`_bk_context_load_post` on Blender's load_post, kept across loads: every
    load runs it, whichever way it was asked for. By name, so a second copy of
    this module — a check loads its own — replaces the first."""
    handlers = getattr(getattr(bpy, 'app', None), 'handlers', None)
    post = getattr(handlers, 'load_post', None)
    persistent = getattr(handlers, 'persistent', None)
    if post is None or persistent is None:
        return
    for existing in list(post):
        if getattr(existing, '__name__', '') == _bk_context_load_post.__name__:
            post.remove(existing)
    post.append(persistent(_bk_context_load_post))


def needs_undo_stack(name, keywords):
    """Whether calling the operator `name` ('module.operator') with `keywords`
    can reach Sculpt Mode's undo code: any operator but the undo stack's own
    (`ed.*`, which make it or poll for it) while the active object is in
    Sculpt Mode, and one of SCULPT_ENTRIES taking it in."""
    import bpy
    module, _, operator = name.partition('.')
    if module == 'ed':
        return False
    try:
        obj = bpy.context.view_layer.objects.active
    except (AttributeError, RuntimeError, ReferenceError):
        return False
    if obj is None:
        return False
    if getattr(obj, 'mode', 'OBJECT') == 'SCULPT':
        return True
    return (module, operator) in SCULPT_ENTRIES and enters_sculpt_mode(operator, keywords)


def require_undo_stack(name, keywords):
    """Makes Blender's undo stack before `name` runs, when the call can reach
    Sculpt Mode's undo code and Blender has none; refuses the call in words
    where none can be made (off the main thread, or a context with no window).
    Looked at once per file load: the stack, once made, stays until a load
    frees it (`ed_undo.cc`, `wm_files.cc`). Nothing where it cannot be read
    (the simulator's stand-in)."""
    global _stack_seen
    if _stack_seen is not None and _stack_seen == _loads:
        return
    if not needs_undo_stack(name, keywords):
        return
    try:
        import _blenderkit_undo as undo
    except ImportError:
        return
    rows = undo.blender_steps()
    if rows is None:
        return
    if not rows:
        import bpy
        context = bpy.context
        if not _is_main_thread() or context.window is None or context.screen is None:
            raise RuntimeError(
                'bpy.ops.' + name + " was not run: Sculpt Mode keeps its undo steps in "
                "Blender's undo, which has not started yet, and without it Blender "
                "crashes. It starts on the main thread: make any change in the 3D View "
                "first, or turn off Run Scripts Off the Main Thread in the Scripting "
                "tab's Options menu.")
        # The one way Blender makes it (`ed_undo_push_exec`, with no
        # interface). Its own, not the history's `ensure_stack`, so either
        # guard holds without the other (tests/undostack/blender).
        try:
            result = bpy.ops.ed.undo_push(message='Original')
        except RuntimeError:
            result = set()
        if 'FINISHED' not in result or not undo.blender_steps():
            raise RuntimeError(
                'bpy.ops.' + name + " was not run: Blender's undo could not be started, "
                "and Sculpt Mode crashes Blender without it.")
    _stack_seen = _loads


class _SculptEntry(_Guarded):
    # One of SCULPT_ENTRIES: asked Sculpt Mode's way in before it is called,
    # and refused with an undo argument inside an area override as every
    # other operator is (`_UndoInArea`).
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        refuse_mid_load(self._name)
        if undo_requested(args) and _in_area_without_interface():
            refuse_undo_in_area(self._operator, self._name)
        # A module global, looked up as the call is made, so a check's
        # negative control can switch it off.
        refuse_sculpt_entry(self._name.split('.', 1)[-1], keywords)
        require_undo_stack(self._name, keywords)
        with _calling(self._name):
            return self._operator(*args, **keywords)


class _Unsafe(_Guarded):
    # One of UNSAFE_OPERATORS (INTERFACE_ONLY among them): asked as it is
    # called (`ask`), which refuses it in words or gives it what it needs,
    # then whatever every other operator gets (`_operator` is that wrapper,
    # `_UndoInArea` in a Blender with no interface). Its poll, RNA and
    # signature stay Blender's, so the operator search still lists it and
    # reads its form.
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        refuse_mid_load(self._name)
        ask(self._name, args, keywords)
        return self._operator(*args, **keywords)


def _budget():
    """The vertex budget (_blenderkit_budget.py): imported, or loaded from
    beside this module where the site folder is not on the path (the desktop
    checks); None where it cannot be had (the simulator's stand-in, which has
    no budget to keep)."""
    module = sys.modules.get('_blenderkit_budget')
    if module is not None:
        return module
    try:
        import _blenderkit_budget as module
        return module
    except ImportError:
        pass
    import importlib.util
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_blenderkit_budget.py')
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location('_blenderkit_budget', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules['_blenderkit_budget'] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop('_blenderkit_budget', None)
        raise
    return module


def _site_module(name):
    """Another of the app's modules, loaded as `_budget` loads the budget;
    None where it cannot be had."""
    module = sys.modules.get(name)
    if module is not None:
        return module
    try:
        return __import__(name)
    except ImportError:
        pass
    import importlib.util
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + '.py')
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _gate_module():
    """The gate (_blenderkit_gate.py), loaded as `_budget` loads the budget;
    None where it cannot be had."""
    module = sys.modules.get('_blenderkit_gate')
    if module is not None:
        return module
    try:
        import _blenderkit_gate as module
        return module
    except ImportError:
        pass
    import importlib.util
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_blenderkit_gate.py')
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location('_blenderkit_gate', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules['_blenderkit_gate'] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop('_blenderkit_gate', None)
        raise
    return module


class _calling:
    # Around one operator's call: the gate first — every write Blender has not
    # evaluated priced, and refused in words, before Blender's own update in
    # front of the call evaluates it (`bpy_op_fn_call`, bpy_operator_function.cc)
    # — then the call, during which the gate's handler prices what the
    # operator changed before Blender's update after it evaluates that
    # (`_blenderkit_gate.calling`). A no-op where there is no gate.
    __slots__ = ('inner',)

    def __init__(self, path, priced=False, args=(), keywords=None):
        # `args` and `keywords`: the call's own, for the gate to tell an
        # executed move of an edited mesh from the Cursor's drag or a modal one.
        gate = _gate_module()
        self.inner = gate.calling(path, priced, args, keywords) if gate is not None else None

    def __enter__(self):
        if self.inner is not None:
            self.inner.__enter__()
        return self

    def __exit__(self, kind, error, traceback):
        if self.inner is not None:
            return self.inner.__exit__(kind, error, traceback)
        return False


class _PricedAdd(_Guarded):
    # One of PRICED_ADDS: its vertices counted from what it is called with
    # (and its RNA defaults) and refused in words past the budget, before
    # Blender makes anything.
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        refuse_mid_load('mesh.' + self._name)
        with _calling('mesh.' + self._name, True):
            budget = _budget()
            if budget is not None:
                budget.price_primitive(self._operator, self._name, keywords)
            return self._operator(*args, **keywords)


class _PricedOperator(_Guarded):
    # One of PRICED_OPERATORS: priced through the vertex budget with what it
    # is called with, before Blender runs it, and refused in words past it.
    __slots__ = ()
    __doc__ = _Guarded.__doc__
    _blenderkit_priced = True

    def __call__(self, *args, **keywords):
        refuse_mid_load(self._name)
        with _calling(self._name, True, args, keywords):
            budget = _budget()
            if budget is not None:
                budget.price_operator(self._name, keywords)
            return self._operator(*args, **keywords)


class _UndoInArea(_Guarded):
    # Every other operator: refused when it is called with its undo on inside
    # an area override, in a Blender with no interface.
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        # `bpy.ops.x.y('EXEC_DEFAULT', True)`: the undo argument, which
        # Blender takes as any int, `1` as well as True (`undo_requested`).
        # Every call without it costs one scan of a short tuple, a look at
        # whether a file is loading (`refuse_mid_load`) — and, once per file
        # load, a look at Blender's undo stack if the call is in Sculpt Mode
        # (`require_undo_stack`).
        refuse_mid_load(self._name)
        if undo_requested(args):
            refuse_undo_in_area(self._operator, self._name)
        require_undo_stack(self._name, keywords)
        with _calling(self._name, False, args, keywords):
            return self._operator(*args, **keywords)


def flips_rotation(args, keywords):
    """Whether Blender would turn this `transform.rotate` call the other way
    than the app means: under the borrowed view a command runs in while Blender
    is in Local View (`_blenderkit_localview.in_scope`), executed, with no
    constraint axis. In a 3D View Blender negates the axis of a rotation with
    no constraint (`transform_mode_rotation_axis_get`, transform_mode.cc: "so
    the rotation direction matches the mouse movement in view space"), and the
    app's rotations are the ones a Blender with no view makes — what the gizmo
    previews. Measured in desktop 5.2.1: value 0.4 about Z took a cube at 0.7
    rad to 0.3 under the view and 1.1 without; with the value negated, 1.1
    under the view too."""
    local_view = sys.modules.get('_blenderkit_localview')
    if local_view is None or not local_view.in_scope():
        return False
    if any(isinstance(a, str) and a.startswith('INVOKE') for a in args):
        return False
    if 'value' not in keywords:
        return False
    try:
        return not any(keywords.get('constraint_axis', ()))
    except TypeError:
        return False


class _Rotate(_Guarded):
    # `transform.rotate`: turned the way the app means under Local View's
    # scope (`flips_rotation`), and refused with an undo argument inside an
    # area override, as every other operator is (`_UndoInArea`).
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        refuse_mid_load(self._name)
        if undo_requested(args):
            refuse_undo_in_area(self._operator, self._name)
        require_undo_stack(self._name, keywords)
        if flips_rotation(args, keywords):
            keywords['value'] = -keywords['value']
        # Priced as every Object Mode move is (PRICED_OPERATORS), the value
        # as Blender will take it: the commit's turn about its pivot.
        with _calling(self._name, 'value' in keywords, args, keywords):
            budget = _budget()
            if budget is not None and 'value' in keywords:
                budget.price_operator('transform.rotate', keywords)
            return self._operator(*args, **keywords)


def scene_switch_refusal(path):
    """The words refusing `path`, one of SCENE_SWITCHES, while an override in
    force sets view_layer (see the note above SCENE_SWITCHES), or None."""
    for override in tuple(_in_force):
        if override._members.get('view_layer') is not None:
            return ('bpy.ops.%s was not run: it gives the window another scene, and inside a temp_override '
                    "that sets view_layer, Blender's own update after it evaluates that scene with the "
                    "override's view layer, another scene's, and crashed there. Leave view_layer out of the "
                    'override (the view layer then follows the scene), or call it outside the override.'
                    % path)
    return None


class _SceneSwitch(_Guarded):
    # SCENE_SWITCHES: refused inside an override that sets view_layer, else
    # what every other operator gets (`_UndoInArea`, or Blender's own).
    __slots__ = ()
    __doc__ = _Guarded.__doc__

    def __call__(self, *args, **keywords):
        refused = scene_switch_refusal(self._name)
        if refused is not None:
            raise RuntimeError(refused)
        return self._operator(*args, **keywords)


def undo_requested(args):
    """Whether an operator called with the positional arguments `args` runs
    with its undo on, read exactly as Blender reads them.

    `bpy_op_parse_args` (bpy_operator_function.cc; `_parse_args` in older
    bpy/ops.py) takes the first str as the execution context and the first
    int as the undo flag — `PyBool_Check || PyLong_Check`, then
    `PyObject_IsTrue` — so `1`, `2` or `-1` turn it on as True does, and `0`
    or False leave it off. Any other positional, a str after the int or a
    second int makes Blender raise ValueError before the operator runs, which
    is no undo. Round 4's review measured the cost of reading only True:
    under `temp_override_view3d`, `mesh.loopcut_slide('EXEC_DEFAULT', 1, …)`,
    `mesh.loopcut('EXEC_DEFAULT', 1, …)` and `transform.translate('EXEC_DEFAULT',
    1, …)` each segfaulted desktop 5.2.1 in `ED_area_type_hud_ensure` past a
    guard that refused True."""
    context_seen = undo_seen = False
    undo = False
    for argument in args:
        if not context_seen and isinstance(argument, str):
            if undo_seen:
                return False        # "string arg must come before the boolean"
            context_seen = True
        elif not undo_seen and isinstance(argument, int):
            undo = bool(argument)
            undo_seen = True
        else:
            return False            # "1-2 args execution context is supported"
    return undo


def _without_interface():
    # The app's bpy module and a check's `-b`: no window draws, and no area
    # has a type.
    try:
        import bpy
        return bool(getattr(bpy.app, 'background', False))
    except (ImportError, AttributeError):
        return False


def _in_area_without_interface():
    # A Blender with no interface (the app's bpy module, a check's `-b`)
    # whose context has an area: the borrowed 3D View, or a script's own
    # temp_override(area=...).
    try:
        import bpy
        return bool(getattr(bpy.app, 'background', False)) and bpy.context.area is not None
    except (AttributeError, RuntimeError):
        return False


def refuse_undo_in_area(operator, name):
    """Raises when calling `operator` with its undo on would crash Blender.

    An operator Blender registers (bl_options 'REGISTER'), called with its
    undo argument on, opens its redo panel in the area it ran in when it
    finishes (`wm_operator_finished`), and in a Blender with no interface
    that area has no type: `ED_area_type_hud_ensure` segfaults on it. Measured
    in desktop 5.2.1 with the app's context, under `temp_override_view3d`
    (round 4): `mesh.loop_select`, `mesh.select_linked_pick` and
    `mesh.select_next_item` given `'EXEC_DEFAULT', True` each crashed there
    (backtrace `ED_area_type_hud_ensure` ← `wm_operator_finished`), as round 4
    group 1 found for `object.hide_view_set` and three others and group 3 for
    `mesh.loopcut_slide`; `select_linked_pick` with no area in the context ran.

    An operator that is not registered can still get there: one that runs a
    registered operator itself, with the undo it was given. Round 4's review
    of Loop Cut measured `object.mode_set('EXEC_DEFAULT', True, mode='EDIT')`
    (bl_options empty) under `temp_override_view3d` segfaulting desktop 5.2.1
    the same way, one call deeper: `mode_set_ex` runs `editmode_toggle`
    (REGISTER, UNDO) and its `wm_operator_finished` opened the panel. Which
    operators do that cannot be read off them, so with the undo on only the
    unregistered BLOCKING ones run: the strokes (`sculpt.brush_stroke`,
    `paint.vertex_paint`, `paint.weight_paint`, `paint.image_paint`), which
    the app itself calls with their undo on, and the editors' navigation,
    eyedroppers and area edits — 49 operators in 5.2.1 (measured: every
    `bpy.ops` operator's bl_options), none of which reads as running another,
    though that is not something RNA shows. A script calls the
    rest without the undo argument, as the app does; the app records its own
    undo steps. Every operator is wrapped as it is looked up
    (`guard_file_reads`), and this is asked as it is called, so an operator
    looked up outside the override and called inside it is refused too.

    Except a macro, BLOCKING or not: it runs operators of its own, its steps.
    Round 4's second fix-round review measured a script's
    `bpy.types.Macro` with `bl_options = {'BLOCKING'}` and the one step
    `OBJECT_OT_mode_set` (mode EDIT), called `('EXEC_DEFAULT', True)` inside
    `temp_override_view3d`: exit 139 in `ED_area_type_hud_ensure` from
    `wm_operator_finished`, the step's `editmode_toggle` opening the panel,
    where the same `mode_set` called directly was refused. Blender gives a
    macro 'MACRO' in its bl_options; none of Blender's own 58 macros is
    BLOCKING without REGISTER (measured, 5.2.1), so this refuses nothing the
    first rule let through but a script's own macro."""
    import bpy
    if not getattr(bpy.app, 'background', False):
        return
    try:
        area = bpy.context.area
    except AttributeError:
        return
    if area is None:
        return
    try:
        options = operator.bl_options
    except (AttributeError, RuntimeError):
        options = ()
    if 'REGISTER' in options or 'BLOCKING' not in options or 'MACRO' in options:
        raise RuntimeError(
            'bpy.ops.' + name + ' was not run with its undo on inside an area override: '
            "when it, or an operator it runs, finishes, Blender opens a redo panel in "
            "that area, and with no interface it crashes doing so. Call it without the "
            "undo argument; the app records the undo step itself.")


def guard_file_reads(bpy):
    """Refuse the operators that load a file anywhere but the main thread, once.

    Every one of FILE_READS goes through `wm_file_read_setup_wm_init`, which
    calls `ED_screen_exit` for every window before it looks at `load_ui`, and
    that asks the context for the window. Blender gives the window out on the
    main thread only (`ctx_wm_python_context_get`), so on the script thread it
    read NULL and `WM_event_modal_handler_region_replace` read `win->runtime`
    at 0xf0: EXC_BAD_ACCESS at 0xf0 in the app, from a script's
    `bpy.ops.wm.read_homefile()` (reports BlenderLocal-2026-09-22-100656 and
    -100743). A script that names one runs on the main thread
    (`ScriptThread.needsMainThread`); this refuses the calls that check cannot
    see, such as one in a module the script imports.

    On the main thread each is Blender's, measured in desktop 5.2.1 with the
    app's context (undo stack, gpu.init, a 3D View override): all six return
    FINISHED and the undo push and the view override still work after. One
    thing differs from Blender: `read_homefile` and `open_mainfile` keep the
    app's screen unless the call asks for the file's (`load_ui=True`), as
    File > New and File > Open do. The app draws its own interface, and Knife
    Project, sculpting and hiding borrow the 3D View of the screen Blender
    started with; a file saved with no 3D View on its screen, opened with its
    own interface, left them nothing to borrow.

    `bpy.ops.wm.read_homefile` is made on every access, by
    `bpy.ops._op_create_function`, so that is what is wrapped. The same wrapper
    refuses NEEDS_VIEW outside a 3D View, asks SCULPT_ENTRIES Sculpt Mode's
    way in (`_SculptEntry`), and in a Blender with no interface hands out
    every other operator wrapped, to refuse its undo argument inside an area
    override (`_UndoInArea`, `refuse_undo_in_area`). Returns whether the operators are
    guarded: the simulator's stand-in has no such function and needs no guard.
    """
    ops = sys.modules.get('bpy.ops')
    # From the module's own namespace: its __getattr__ answers any name.
    create = getattr(ops, '__dict__', {}).get('_op_create_function')
    if create is None:
        return False
    if getattr(create, '_blenderkit_guard', False):
        return True
    raw_create = create
    # Held sealed, not as it is: a closure's cell is a script's to read (the
    # note above `_Sealed`).
    create = _Sealed(raw_create, '_bpy.ops.create_function')

    def _op_create_function(module, name):
        # Blender's own first: it raises for anything but two strings.
        operator = create(module, name)
        # As Blender reads them (`pyop_create_function`): the module part
        # upper-cased in ASCII, the name as it is, so `bpy.ops.UV.stitch` is
        # UV_OT_stitch. Round 4's second fix-round review measured every
        # guard here keyed on the module as typed: `bpy.ops.UV.stitch()`,
        # `bpy.ops.WM.call_menu(...)` and `bpy.ops.BRUSH.asset_activate(...)`
        # each exited 139, `bpy.ops.UV.select_edge_ring()` never returned,
        # `bpy.ops.MESH.primitive_grid_add(x_subdivisions=1700,
        # y_subdivisions=1700)` made 2,893,401 vertices past the budget and
        # `bpy.ops.WM.read_homefile()` on a thread exited 139, each refused
        # in lower case in the same run (desktop 5.2.1, every guard).
        module, name = _ascii_lower(_exact(module)), _exact(name)
        path = module + '.' + name
        if path in UNSAFE_OPERATORS:
            # Asked first (`ask`), then what every operator gets.
            inner = _UndoInArea(operator, path) if _without_interface() else operator
            return _Unsafe(inner, path)
        if module == 'wm' and name in FILE_READS:
            return _FileRead(operator, name)
        if module == 'mesh' and name in NEEDS_VIEW:
            return _NeedsView(operator, name)
        if (module, name) in SCULPT_ENTRIES:
            return _SculptEntry(operator, path)
        if path == 'transform.rotate':
            return _Rotate(operator, path)
        if path in SCENE_SWITCHES:
            inner = _UndoInArea(operator, path) if _without_interface() else operator
            return _SceneSwitch(inner, path)
        if module == 'mesh' and name in PRICED_ADDS:
            # Priced first, then whatever every operator gets below.
            inner = _UndoInArea(operator, path) if _without_interface() else operator
            return _PricedAdd(inner, name)
        if path in PRICED_OPERATORS:
            inner = _UndoInArea(operator, path) if _without_interface() else operator
            return _PricedOperator(inner, path)
        # Every operator, in a Blender with no interface: the undo argument
        # crashes inside an area override, and whether the call is inside one
        # is asked as it is made, so an operator looked up before the override
        # and called inside it is asked too. Round 4's review of Loop Cut
        # measured the cost of wrapping only the ones looked up inside:
        # `op = bpy.ops.transform.translate` read outside
        # `temp_override_view3d`, then `op('EXEC_DEFAULT', 1, value=...)`
        # inside it, segfaulted desktop 5.2.1 (exit 139). Everything but the
        # call is still the operator's own (`_Guarded`). With an interface,
        # where the area has a type and the panel opens, Blender's object.
        if _without_interface():
            return _UndoInArea(operator, path)
        return operator

    # A mark, not the function it wraps: round 4's second fix-round review
    # found `bpy.ops._op_create_function._blenderkit_original` and its
    # `macro_define` twin handing a script the unguarded functions. The
    # closures hold them sealed (`_Sealed`).
    _op_create_function._blenderkit_guard = True
    ops._op_create_function = _op_create_function
    # And where `bpy.ops` reads it from: `_bpy.ops.create_function`, which a
    # reload of `bpy.ops` reads again (`importlib.reload(bpy.ops)` put the
    # unwrapped one back, round 4's review of group 4) and a script can call
    # itself (`_bpy.ops.create_function('uv', 'stitch')()`, round 4's review
    # of group 3). Measured in desktop 5.2.1: the C module takes the
    # attribute, and Blender's own C code never reads it from there.
    raw = getattr(sys.modules.get('_bpy'), 'ops', None)
    if raw is not None and getattr(raw, 'create_function', None) is raw_create:
        try:
            raw.create_function = _op_create_function
        except (AttributeError, TypeError):
            pass
    _guard_macro_define(raw)
    return True


def guard_library_write(bpy):
    """`bpy.data.libraries.write`, with every scene's view layers brought up
    to date first, once. Returns whether it is guarded.

    The partial write copies each data-block it is given, and their
    dependencies, into a file of their own (`PartialWriteContext::id_add_copy`).
    A Scene's copy copies its view layers (`BKE_view_layer_copy_data`), which
    expects their object bases in sync with the collections — Blender asserts
    it in a debug build and reads past it in a release one. A scene a script
    has just made, or one given a view layer since Blender last evaluated,
    is not. Measured in desktop 5.2.1 (round 4's fix round 2 review, and again
    this round, a Blender each): `bpy.data.libraries.write(path,
    {bpy.data.scenes.new('S2')})` exit 139 in BKE_view_layer_copy_data, with
    the app's context and bare; the same after reading the new view layer's
    `objects`; a scene given `view_layers.new('VL2')`, the same; a compositor
    node group whose Render Layers node names a new scene, the same (the
    scene comes in as a dependency). After `bpy.context.view_layer.update()`
    — which brings every view layer of every scene in sync before it
    evaluates (`BKE_main_view_layers_synced_ensure`, scene.cc) — each of them
    wrote its file. `scene.copy()` of an unsynced scene did not crash (it
    syncs first). So the write is preceded by that update, after the vertex
    budget's gate has priced what it would evaluate."""
    libraries = getattr(bpy.types, 'BlendDataLibraries', None)
    original = libraries.__dict__.get('write') if libraries is not None else None
    if original is None:
        return False
    if getattr(original, '_blenderkit_guard', False):
        return True

    def write(*args, **keywords):
        gate = _gate_module()
        if gate is not None:
            gate.settle('wm.libraries_write')
        layer = getattr(bpy.context, 'view_layer', None)
        if layer is None:
            raise RuntimeError(
                "bpy.data.libraries.write was not run: Blender copies every scene it writes with "
                "its view layers, which must be brought up to date first, and with no view layer "
                "in the context they cannot be. Call it outside any temp_override that clears "
                "the view layer.")
        layer.update()
        # Blender's own, bound as Blender binds it: `bpy.data.libraries` is a
        # collection, whose attribute lookup binds only a C method found on
        # its type (`pyrna_prop_collection_getattro`), to the collection of
        # the Main loaded now — a binding kept from before a file load would
        # write the freed one. So the original is put back on the type for
        # the lookup alone.
        libraries.write = original
        try:
            bound = bpy.data.libraries.write
        finally:
            libraries.write = write
        return bound(*args, **keywords)

    write.__doc__ = getattr(original, '__doc__', None)
    write.__name__ = 'write'
    write._blenderkit_guard = True
    libraries.write = write
    return True


_ASCII_LOWER = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')


def _ascii_lower(text):
    # Blender folds the module part of a name in ASCII only
    # (`BLI_str_toupper_ascii`); str.lower() would fold more than it does.
    return str.translate(text, _ASCII_LOWER)


def _exact(text):
    """`text` as a plain str with the characters Blender reads (C takes a str
    subclass's own data, whatever its methods say), so a subclass whose
    `partition` or `lower` lies cannot pick the key the guards look up —
    round 4's second fix-round review, found by reading. A non-str is
    returned as it is, for Blender to refuse."""
    return str.__str__(text) if isinstance(text, str) else text


def operator_path(idname):
    """'module.operator' for an operator named any way Blender takes one, as
    Blender resolves it (`WM_operator_bl_idname`): 'uv.stitch' (`bpy.ops`'s),
    'UV.stitch' or 'Uv.stitch' (the part before the first '.' upper-cased in
    ASCII), and 'UV_OT_stitch' (its RNA identifier, the part before '_OT_').
    The name part is left as it is: Blender looks it up as written, so
    'uv.STITCH' is no operator (measured, 5.2.1). An '_OT_' name whose module
    is not upper case is no operator either ('mesh_OT_primitive_cube_add':
    "not a valid operator id name"), and keyed the same way it is refused
    with the operator it names, which costs nothing."""
    idname = _exact(idname)
    if not isinstance(idname, str):
        return idname
    for separator in ('.', '_OT_'):
        module, sep, name = str.partition(idname, separator)
        if sep:
            return _ascii_lower(module) + '.' + name
    return idname


# The steps a macro may not have that the table does not name, each with why:
# a macro runs its steps inside Blender, past every guard of `bpy.ops`, and a
# step's settings are set after it is defined (`OperatorMacro.properties`),
# where nothing reads them. Measured in desktop 5.2.1 with every guard
# installed (round 4's second fix-round review): a step of Loop Cut with its
# edge set (`edge_index` 4, `object_index` 0) exited 139 in `loopcut_init`
# from `wm_macro_exec`, where its default edge (-1) is CANCELLED and the same
# call is refused in words; a step of Open (`WM_OT_open_mainfile`, a file
# saved in Sculpt Mode) then one of Mask Fill, from Sculpt Mode, exited 139 in
# Sculpt Mode's undo `push_begin_ex` — the step's load skips `_FileRead`,
# which makes Blender's undo again after a load, and the next step skips
# `require_undo_stack`; and a step of `WM_OT_read_homefile` on a script
# thread exited 139 in `ED_region_exit` from `ED_screen_exit`, the crash
# `_FileRead` refuses for a call.
_MACRO_STEP_REFUSALS = dict(
    [('wm.' + name, "It loads a file, which a step does where nothing makes Blender's undo again "
                    "after it (a sculpt step after the load crashed Blender) and, off the main "
                    "thread, where Blender crashes taking its screen down. Call bpy.ops.wm."
                    + name + " itself.") for name in FILE_READS]
    + [('mesh.' + name, "It cuts at an edge it is given, and a step runs with no 3D View, where "
                        "Blender crashes in it. Call bpy.ops.mesh." + name + " itself inside "
                        "`with _blenderkit_context.temp_override_view3d('Loop Cut'):`.")
       for name in NEEDS_VIEW]
    + [(module + '.' + name, "It can take the active object into Sculpt Mode, whose way in is asked "
                             "of the Multires level and of Blender's undo as it is called, and a "
                             "step's mode is set where nothing asks. Call bpy.ops." + module + "."
                             + name + " itself.") for module, name in SCULPT_ENTRIES])


def macro_refusal(path):
    """Why `path` (any name `operator_path` reads) cannot be a macro's step
    here, or None.

    One of UNSAFE_OPERATORS that applies, in its own words; an entry that
    gives its call what it needs (`brush.asset_activate`) as well, since
    nothing can be given to a step first. A step that loads a file, cuts a
    loop or enters Sculpt Mode (`_MACRO_STEP_REFUSALS`). And what the vertex
    budget prices (PRICED_ADDS, PRICED_OPERATORS, `transform.rotate`): a
    step's settings reach Blender with no count in front of them. Measured in
    desktop 5.2.1 with the app's context (round 4's fix round): the call
    `bpy.ops.mesh.primitive_uv_sphere_add(segments=1600, ring_count=1600)`
    (2,558,402 vertices) is refused by its price, and the same as a macro's
    step was still in `add_primitive_uvsphere_exec`, under `wm_macro_exec`,
    after 5 minutes at 100% CPU, when it was killed."""
    path = operator_path(path) if isinstance(path, str) else None
    if path is None:
        return None
    entry = UNSAFE_OPERATORS.get(path)
    if entry is not None and entry.applies():
        return ('' if entry.prepare is None else 'Nothing can be given to a step first. ') + entry.refusal
    if path in _MACRO_STEP_REFUSALS:
        return _MACRO_STEP_REFUSALS[path]
    module, _, name = path.partition('.')
    if (module == 'mesh' and name in PRICED_ADDS) or path in PRICED_OPERATORS or path == 'transform.rotate':
        return ("Its vertices are counted against the vertex budget from what it is called with, "
                "and a macro's step is given its settings where nothing counts them. Call "
                "bpy.ops." + path + " itself.")
    return None


def _guard_macro_define(raw):
    """Refuse a macro step the app guards as it is called, once
    (`macro_refusal`).

    A macro (`bpy.types.Macro`, a script's own class) runs its steps inside
    Blender (`macro_exec`), never through `bpy.ops`, so no wrapper of
    `_op_create_function` sees them: measured in desktop 5.2.1 with the app's
    context (round 4's fix round), a script's Macro with the one step
    `UV_OT_stitch`, run as a script line on an unwrapped cube in Edit Mode,
    exited 139 in `stitch_exit` (from `macro_exec`) with every other guard
    installed, and under the borrowed 3D View too; one with
    `UV_OT_select_edge_ring` had not returned after 25 s. `Macro.define` is
    `_bpy.ops.macro_define`, looked up on every call (`from _bpy import ops`
    in `_bpy_types.py`, 5.2.1's and the app's bundled 5.3's alike), so the
    step is refused there, named any way Blender takes it (`operator_path`:
    'UV_OT_stitch', 'uv.stitch', 'UV.stitch'), before any macro holds it.
    Loop Cut, a load and Sculpt Mode's way in are refused as steps too
    (`_MACRO_STEP_REFUSALS`): round 4's fix round had measured Loop Cut as a
    step with its default edge only (CANCELLED) and left it to Blender, and
    with an edge set it crashed. Every other step is Blender's; a macro of the
    Cube, for one, runs (FINISHED)."""
    define = getattr(raw, 'macro_define', None)
    if define is None or getattr(define, '_blenderkit_guard', False):
        return
    doc = define.__doc__
    define = _Sealed(define, '_bpy.ops.macro_define')

    def macro_define(cls, operator):
        path = operator_path(operator) if isinstance(operator, str) else None
        refused = macro_refusal(path)
        if refused is not None:
            raise RuntimeError(
                'Macro.define was not given ' + path + ': a macro runs its steps inside '
                "Blender, past the app's checks on bpy.ops." + path + '. ' + refused)
        # What was checked, not what the caller's str subclass may say later.
        return define(cls, _exact(operator))

    macro_define.__doc__ = doc
    macro_define._blenderkit_guard = True
    try:
        raw.macro_define = macro_define
    except (AttributeError, TypeError):
        pass


def _is_real_blender(bpy):
    """Blender's operators carry their RNA; the simulator's stand-in's are
    plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


class temp_override_view3d:
    """The startup screen's 3D View, for an operator whose poll asks for one.

    Measured in Blender 5.2.1 under `-b --factory-startup`, the bpy an iPad
    has: `object.hide_view_set` and `object.hide_view_clear` fail their poll
    ("context is incorrect"), because both check for a 3D View (`object_hide_poll`
    wants `ED_operator_view3d_active`). The window manager still holds the
    startup screen and its 3D View; under `temp_override(window, area, region)`
    with that view both poll True and act exactly as on a desktop — Hide
    deselects what it hides, Show Hidden Objects selects what it shows, and each
    returns CANCELLED when there is nothing to do.

    Named for `temp_override` on purpose: a script that mentions it runs on the
    main thread (`ScriptThread.needsMainThread`), which is the only thread
    Blender gives a window, area and region out on. Off it this refuses in
    words rather than letting the poll fail. In the simulator's stand-in, which
    has no screen and no poll, it does nothing.

    `what` names the command in the refusal.
    """

    def __init__(self, what):
        self.what = what
        self._override = None

    def __enter__(self):
        import bpy
        if not _is_real_blender(bpy):
            return self
        if not _is_main_thread():
            raise RuntimeError(
                self.what + " works through Blender's 3D View, which exists on the main "
                "thread only. To run it from a script, turn off Run Scripts Off the Main "
                "Thread in the Scripting tab's Options menu.")
        for window in bpy.context.window_manager.windows:
            screen = window.screen
            if screen is None:
                continue
            for area in screen.areas:
                if area.type != 'VIEW_3D':
                    continue
                for region in area.regions:
                    if region.type == 'WINDOW':
                        self._override = bpy.context.temp_override(
                            window=window, area=area, region=region)
                        self._override.__enter__()
                        return self
        raise RuntimeError(self.what + " works through Blender's 3D View, and Blender's "
                           "screen has none to borrow")

    def __exit__(self, *exc):
        if self._override is not None:
            return self._override.__exit__(*exc)
        return False


class needs_essentials:
    """Says why an operator that loads from Blender's Essentials asset library
    failed, when that library is not there.

    `object.shade_auto_smooth` adds the "Smooth by Angle" node group from
    `datafiles/assets/nodes/geometry_nodes_essentials.blend`. The bpy staged
    into the app has no `datafiles/assets` at all (its datafiles are
    colormanagement, fonts, icons and locale), and a desktop Blender with that
    folder removed answers `RuntimeError: Error: No asset found at path ""`
    and adds nothing (5.2.1, measured). That sentence names neither the
    library nor what to do instead, so it is replaced with one that does.
    Any other failure passes through unchanged.
    """

    def __init__(self, what, instead):
        self.what = what
        self.instead = instead

    def __enter__(self):
        return self

    def __exit__(self, kind, error, traceback):
        # The words stay for the case `essentials_available` cannot see: a
        # library that is there and does not hold the asset.
        if kind is not None and issubclass(kind, RuntimeError) and 'No asset found' in str(error):
            raise RuntimeError(
                self.what + " adds a node group from Blender's Essentials asset library, "
                "which this build of Blender does not include. " + self.instead) from None
        return False


# The file `object.shade_auto_smooth` takes "Smooth by Angle" from, relative to
# the Essentials library (`relative_asset_identifier` in object_edit.cc).
ESSENTIALS_NODES = ('nodes', 'geometry_nodes_essentials.blend')


def essentials_available():
    """Whether Blender's Essentials asset library is installed, with the node
    group Shade Auto Smooth adds.

    The interface asks once and greys the row out without it, rather than
    offer an operator that fails every time. Blender finds the library at
    `BKE_appdir_folder_id(BLENDER_SYSTEM_DATAFILES, "assets")`, which is what
    `bpy.utils.system_resource('DATAFILES', path='assets')` answers — an empty
    string when the folder is not there. Measured in 5.2.1: the desktop app
    answers its `datafiles/assets` and Auto Smooth adds its modifier; an APFS
    clone of it with that folder removed answers '' and Auto Smooth fails with
    'No asset found at path ""'. The bpy staged into the device app has
    colormanagement, fonts, icons and locale in its datafiles and no assets.
    The simulator's stand-in has no `bpy.utils.system_resource`, and no
    Auto Smooth either.
    """
    import os
    try:
        import bpy
        folder = bpy.utils.system_resource('DATAFILES', path='assets')
    except Exception:                               # noqa: BLE001 - no library is the answer
        return False
    return bool(folder) and os.path.isfile(os.path.join(folder, *ESSENTIALS_NODES))


# ---------------------------------------------------------------------------
# What a context member may hold
#
# `temp_override` keeps window, screen, area and region for itself and checks
# them (an Object, a RenderSettings or a list for any of them is Blender's own
# TypeError, measured), and hands every other member to Blender as it is.
# Blender's context then reads each one back without asking what it is
# (`BPY_context_member_get`, bpy_interface.cc): None as no pointer, any
# bpy_struct as a pointer of the member's own C type (`CTX_data_scene` takes
# an Object as a Scene), any other sequence, a str among them, as a list with
# no pointer in it, and an ID Python marked removed as no pointer. Measured in
# desktop 5.2.1 with the app's context (its modules, gpu.init(), its undo
# push), each a script line `with bpy.context.temp_override(<member>=<value>):
# bpy.ops.<operator>(...)` in a Blender of its own, exit -11 each time (round
# 4's fix round 2, October 21; the cases tests/unsafe/blender keeps are
# `CONTEXT_CASES`):
#   * scene None, an Object, a removed Scene, a RenderSettings, 'Cube' or
#     [scene]: every operator tried (select_all, translate, mode_set,
#     primitive_cube_add, undo_push, delete), in CTX_data_view_layer or past
#     it; another live scene beside the window's own view layer: select_all.
#   * view_layer None, a removed one or [view_layer]: select_all, translate,
#     mode_set, primitive_cube_add, undo_push; an Object: translate and
#     primitive_cube_add; a RenderSettings: every operator tried; another
#     scene's own view layer (the type is right, the scene is not): 13
#     operators of 14.
#   * blend_data None: every operator, and the override's own exit; an Object
#     or a RenderSettings: duplicate, transform_apply, primitive_cube_add,
#     delete. layer_collection None or [it]: the script's own read of
#     `context.layer_collection`. tool_settings None: translate.
#   * active_object a Mesh or a RenderSettings: translate, transform_apply,
#     mode_set's poll. collection a RenderSettings: the read of
#     `context.collection`.
#   * edit_object an object not in Edit Mode (the factory cube, one in no
#     scene, an evaluated copy): primitive_cube_add, which adds into an edited
#     mesh that is not there.
#   * selected_editable_objects [a Mesh], [cube, a Mesh], [a removed Object]
#     or [a RenderSettings]: shade_smooth, duplicate or transform_apply;
#     selected_objects [a removed Object]: delete.
#   * what a block takes away from under its own override: `with
#     temp_override(selected_objects=[cube, other], selected_editable_objects=
#     [cube, other]): bpy.ops.object.delete(); bpy.ops.object.shade_smooth()`
#     — and the same after bpy.data.objects.remove, after read_homefile, and
#     with the override made before the remove and entered after it —, a view
#     layer removed inside its own override then select_all, and edit_object's
#     object taken back to Object Mode inside it then primitive_cube_add.
# Under the borrowed 3D View (`temp_override_view3d`) the six values tried
# there crashed the same. With the guards as they were installed, 24 of the 25
# values tried again crashed the same or earlier, in a guard's own read of the
# context (`bpy.context.view_layer`), and the gate's read of [a Mesh] raised
# an AttributeError before Blender read it; every scenario crashed with them
# as without. Reading a
# member back in Python after its ID was removed gave None, no crash. The
# members Blender checks the type of itself (`object`, `material`:
# `CTX_data_pointer_get_type`), an int anywhere (Blender ignores it), another
# live scene on its own, a collection in no scene and an evaluated
# `active_object` crashed nothing measured.
#
# So `temp_override` gives a member only what Blender's own context holds
# there (`refuse_members`), and every operator `bpy.ops` hands out asks the
# overrides in force again as it is called (`refuse_stale_members`, from
# `_Guarded`), before any other guard reads the context. A member Blender's
# table does not name passes as it is: a script's own operator may read one.

# Blender's own table of the members its context gives out and the type of
# each (`context_type_map` in doc/python_api/sphinx_doc_gen.py, 5.3, the
# bundled bpy's source): any of the types named, and for `_MEMBER_LISTS` a
# list of them. `property` (any value, a str or an int) is left out. What
# `bpy.types.Context` defines in RNA is read from RNA instead
# (`_member_types`), which differs once: `collection` is a Collection in RNA
# and in `CTX_data_collection` (context.cc), a LayerCollection here.
_MEMBER_TYPES = {
    'active_action': 'Action', 'active_annotation_layer': 'AnnotationLayer',
    'active_bone': 'EditBone Bone', 'active_editable_fcurve': 'FCurve',
    'active_file': 'FileSelectEntry', 'active_nla_strip': 'NlaStrip',
    'active_nla_track': 'NlaTrack', 'active_node': 'Node', 'active_object': 'Object',
    'active_operator': 'Operator', 'active_pose_bone': 'PoseBone', 'active_strip': 'Strip',
    'annotation_data': 'GreasePencil', 'annotation_data_owner': 'ID', 'armature': 'Armature',
    'asset': 'AssetRepresentation', 'asset_library_reference': 'AssetLibraryReference',
    'bone': 'Bone', 'brush': 'Brush', 'camera': 'Camera', 'cloth': 'ClothModifier',
    'collection': 'LayerCollection', 'collision': 'CollisionModifier', 'curve': 'Curve',
    'curves': 'Curves', 'dynamic_paint': 'DynamicPaintModifier', 'edit_bone': 'EditBone',
    'edit_image': 'Image', 'edit_mask': 'Mask', 'edit_movieclip': 'MovieClip',
    'edit_object': 'Object', 'edit_text': 'Text', 'fluid': 'FluidModifier',
    'gpencil': 'GreasePencil', 'grease_pencil': 'GreasePencil', 'id': 'ID',
    'image_paint_object': 'Object', 'lattice': 'Lattice', 'light': 'Light',
    'lightprobe': 'LightProbe', 'line_style': 'FreestyleLineStyle', 'material': 'Material',
    'material_slot': 'MaterialSlot', 'mesh': 'Mesh', 'meta_ball': 'MetaBall', 'object': 'Object',
    'particle_edit_object': 'Object', 'particle_settings': 'ParticleSettings',
    'particle_system': 'ParticleSystem', 'particle_system_editable': 'ParticleSystem',
    'pointcloud': 'PointCloud', 'pose_bone': 'PoseBone', 'pose_object': 'Object', 'scene': 'Scene',
    'sculpt_object': 'Object', 'sequencer_scene': 'Scene', 'soft_body': 'SoftBodyModifier',
    'speaker': 'Speaker', 'strip': 'Strip', 'strip_modifier': 'StripModifier',
    'texture': 'Texture', 'texture_node': 'Node', 'texture_slot': 'TextureSlot',
    'texture_user': 'ID', 'texture_user_property': 'Property', 'tool_settings': 'ToolSettings',
    'ui_list': 'UIList', 'vertex_paint_object': 'Object', 'view_layer': 'ViewLayer',
    'volume': 'Volume', 'weight_paint_object': 'Object', 'world': 'World'}
_MEMBER_LISTS = {
    'editable_bones': 'EditBone', 'editable_fcurves': 'FCurve', 'editable_objects': 'Object',
    'objects_in_mode': 'Object', 'objects_in_mode_unique_data': 'Object',
    'selectable_objects': 'Object', 'selected_assets': 'AssetRepresentation',
    'selected_bones': 'EditBone', 'selected_editable_actions': 'Action',
    'selected_editable_bones': 'EditBone', 'selected_editable_fcurves': 'FCurve',
    'selected_editable_keyframes': 'Keyframe', 'selected_editable_objects': 'Object',
    'selected_editable_strips': 'Strip', 'selected_files': 'FileSelectEntry', 'selected_ids': 'ID',
    'selected_movieclip_tracks': 'MovieTrackingTrack', 'selected_nla_strips': 'NlaStrip',
    'selected_nodes': 'Node', 'selected_objects': 'Object', 'selected_pose_bones': 'PoseBone',
    'selected_pose_bones_from_active_object': 'PoseBone', 'selected_strips': 'Strip',
    'selected_visible_actions': 'Action', 'selected_visible_fcurves': 'FCurve', 'strips': 'Strip',
    'visible_bones': 'EditBone', 'visible_objects': 'Object', 'visible_pose_bones': 'PoseBone'}

# The members Blender's context always has one of and reads without asking
# whether it is there: each getter falls back to one when it is not given
# (`CTX_data_main`, `CTX_data_scene`, `CTX_data_view_layer`,
# `CTX_data_layer_collection`, `CTX_data_collection` and
# `CTX_data_tool_settings` in context.cc; the window manager, the
# preferences, and the window's workspace on the main thread). None crashed
# blend_data, scene, view_layer, layer_collection and tool_settings (the
# comment above); it is refused for each of them unless the context reads
# None there already, as `workspace` does on the script thread, where
# `temp_override(**bpy.context.copy())` passes it on.
_NEVER_NONE = ('blend_data', 'scene', 'view_layer', 'layer_collection', 'collection',
               'tool_settings', 'window_manager', 'preferences', 'workspace')

# The members Blender gives the active object in one mode only
# (`screen_context.cc`: `edit_object` is the object in Edit Mode,
# `sculpt_object` the one in Sculpt Mode, `pose_object` the armature in Pose
# Mode). Measured for edit_object (the comment above); the others are held to
# Blender's own definition.
_MODE_MEMBERS = {'edit_object': 'EDIT', 'sculpt_object': 'SCULPT', 'vertex_paint_object': 'VERTEX_PAINT',
                 'weight_paint_object': 'WEIGHT_PAINT', 'image_paint_object': 'TEXTURE_PAINT',
                 'particle_edit_object': 'PARTICLE_EDIT', 'pose_object': 'POSE'}

# The members others are looked for in, asked first: a view layer is the
# scene's, a layer collection the view layer's.
_ASKED_FIRST = ('blend_data', 'scene', 'view_layer')

# member -> (the classes it holds, whether it is a list), made once.
_types = None


def _member_types():
    global _types
    if _types is not None:
        return _types
    import bpy
    found = {}
    for table, many in ((_MEMBER_TYPES, False), (_MEMBER_LISTS, True)):
        for name, kinds in table.items():
            classes = tuple(c for c in (getattr(bpy.types, k, None) for k in kinds.split())
                            if isinstance(c, type))
            if classes:
                found[name] = (classes, many)
    for prop in getattr(getattr(bpy.types.Context, 'bl_rna', None), 'properties', ()):
        if prop.type == 'POINTER' and prop.identifier != 'rna_type':
            cls = getattr(bpy.types, prop.fixed_type.identifier, None)
            if isinstance(cls, type):
                found[prop.identifier] = ((cls,), False)
    for name in UI_MEMBERS:
        # `temp_override`'s own arguments, which Blender checks itself.
        found.pop(name, None)
    _types = found
    return found


def _a(name):
    return ('an ' if name[:1].upper() in 'AEIOU' else 'a ') + name


def _kinds(classes, many=False):
    if many:
        return 'a list of ' + ' and '.join(c.__name__ + 's' for c in classes)
    return ' or '.join(_a(c.__name__) for c in classes)


def _described(value):
    if value is None:
        return 'None'
    if isinstance(value, (list, tuple)):
        return _a(type(value).__name__) + ' of %d' % len(value)
    if isinstance(value, str):
        return 'the str %r' % value[:40]
    return _a(type(value).__name__)


def _is_list(value):
    # What Blender reads as a list (`PySequence_Check`), less a str or bytes:
    # Blender takes those as a list of characters, which holds no pointer.
    kind = type(value)
    return (not isinstance(value, (str, bytes, bytearray, dict))
            and hasattr(kind, '__getitem__') and hasattr(kind, '__len__'))


def _layer_collections(layer):
    stack = [layer]
    while stack:
        found = stack.pop()
        yield found
        stack.extend(found.children)


def _gone(value, asked):
    """Why the struct `value` is no longer what Blender holds, or None.

    An ID: Blender marks the Python object of a freed ID removed (measured in
    5.2.1 after `bpy.data.objects.remove`, `object.delete` and a file load:
    `as_pointer()` raises ReferenceError). The structs it does not mark — a
    removed scene's view layer and tool settings, a removed collection's
    layer collection (measured: each kept its address with its owner freed),
    an armature's bones (an EditBone kept past its armature's Edit Mode read
    back with an empty name) — are looked for by address where Blender holds them
    now: the view layer among the context's scene's, a layer collection under
    the context's view layer, the tool settings as the context's scene's, a
    bone among Blender's armatures and poses. `asked`: the members asked
    already, a scene or a view layer this override gives."""
    import bpy
    try:
        address = value.as_pointer()
    except ReferenceError:
        return 'has been removed'
    if isinstance(value, bpy.types.ID):
        return None
    if isinstance(value, (bpy.types.ViewLayer, bpy.types.ToolSettings)):
        scene = asked['scene'] if asked.get('scene') is not None else bpy.context.scene
        if isinstance(value, bpy.types.ViewLayer):
            held = scene.view_layers if scene is not None else ()
            where = "the scene's view layers"
        else:
            held = (scene.tool_settings,) if scene is not None else ()
            where = "the scene's tool settings"
    elif isinstance(value, bpy.types.LayerCollection):
        layer = asked['view_layer'] if asked.get('view_layer') is not None else bpy.context.view_layer
        held = _layer_collections(layer.layer_collection) if layer is not None else ()
        where = "the view layer's collections"
    elif isinstance(value, bpy.types.EditBone):
        held = (b for arm in bpy.data.armatures if arm.is_editmode for b in arm.edit_bones)
        where = "the bones of an armature in Edit Mode"
    elif isinstance(value, bpy.types.Bone):
        held = (b for arm in bpy.data.armatures for b in arm.bones)
        where = "Blender's armatures' bones"
    elif isinstance(value, bpy.types.PoseBone):
        held = (b for obj in bpy.data.objects if obj.pose is not None for b in obj.pose.bones)
        where = "Blender's poses' bones"
    else:
        return None
    if any(item.as_pointer() == address for item in held):
        return None
    return 'is not one of ' + where + ' (another\'s, or one that has been removed)'


def _not_held(value, classes, asked, mode=None, typed=True):
    """What the struct `value` is, as a clause, when the member cannot hold
    it, or None: its type (unless `typed` is False: what the context holds
    already), whether Blender still holds it (`_gone`), and what Blender's
    own context holds there: an original, never an evaluated copy, and for
    `_MODE_MEMBERS` an object in that mode."""
    import bpy
    if not isinstance(value, bpy.types.bpy_struct) or (typed and not isinstance(value, classes)):
        return _described(value)
    gone = _gone(value, asked)
    if gone is not None:
        return '%s that %s' % (_a(type(value).__name__), gone)
    if isinstance(value, bpy.types.ID) and value.is_evaluated:
        return ("the depsgraph's evaluated copy of %s, which Blender's context never holds (give "
                "its `.original`)" % _a(type(value).__name__))
    if mode is not None and value.mode != mode:
        try:
            items = bpy.types.Object.bl_rna.properties['mode'].enum_items
            now, wanted = items[value.mode].name, items[mode].name
        except (AttributeError, KeyError):
            now, wanted = value.mode, mode
        return "an object in %s, where Blender's context holds the one in %s" % (now, wanted)
    return None


def member_refusal(name, value, asked=None, again=False):
    """Why the context member `name` may not hold `value`, or None: a clause
    to follow the member's name. `asked`: the members of the same override
    asked already (`_ASKED_FIRST`). `again`: asked of an override in force, as
    an operator is called (`refuse_stale_members`), for what can have changed
    since it was made, which is what Blender still holds."""
    found = _member_types().get(name)
    if found is None:
        return None
    import bpy
    classes, many = found
    asked = {} if asked is None else asked
    if value is None:
        if again or many or name not in _NEVER_NONE or getattr(bpy.context, name, None) is None:
            return None
        return ("was given None, where Blender's context always holds %s; leave %s out to keep the one "
                "it has" % (_kinds(classes), name))
    mode = _MODE_MEMBERS.get(name)
    if many:
        if not _is_list(value):
            return 'holds %s, and was given %s' % (_kinds(classes, True), _described(value))
        for index, item in enumerate(value):
            if item is None and again:
                continue
            why = 'None' if item is None else _not_held(item, classes, asked, mode, typed=not again)
            if why is not None:
                return 'holds %s, and item %d of it is %s' % (_kinds(classes, True), index, why)
        return None
    if not isinstance(value, bpy.types.bpy_struct):
        return 'holds %s, and was given %s' % (_kinds(classes), _described(value))
    # Asked again, the type is not: it was asked as the override was made, and
    # a struct's type does not change.
    typed = not again
    if not again:
        # What the context holds already is of the member's type, as Blender's
        # own copy of it is (`temp_override(**bpy.context.copy())`), and is
        # still asked whether it belongs with the rest: the window's own view
        # layer given beside another scene is not the scene's.
        current = getattr(bpy.context, name, None)
        try:
            typed = not (current is value or (type(current) is type(value)
                                              and current.as_pointer() == value.as_pointer()))
        except (AttributeError, ReferenceError):
            pass
    why = _not_held(value, classes, asked, mode, typed)
    return None if why is None else 'holds %s, and was given %s' % (_kinds(classes), why)


def _first_refusal(members, again=False):
    """(name, clause) for the first member of `members` that may not hold
    what it was given, or None."""
    asked = {}
    for name in [n for n in _ASKED_FIRST if n in members] + [n for n in members if n not in _ASKED_FIRST]:
        why = member_refusal(name, members[name], asked, again)
        if why is not None:
            return name, why
        if again and name == 'scene':
            # In force, a view layer is held to the scene Blender's context
            # reads now (`bpy.context.scene`), not the one given: setting the
            # window's scene clears an override's `scene` and keeps its
            # `view_layer` (see the note above SCENE_SWITCHES) — the window's
            # scene set by a script line inside the block, then any operator.
            continue
        asked[name] = members[name]
    return None


def refuse_members(members):
    """Raises RuntimeError, in words, when a member of `members` (what a
    `temp_override` call was given) holds what Blender's own context would
    not hold there (`member_refusal`). Nothing for a member Blender's table
    does not name, nor for window, screen, area and region, which Blender's
    `temp_override` checks itself, nor where there is no real Blender (the
    simulator's stand-in)."""
    import bpy
    if not hasattr(bpy.types, 'bpy_struct') or not hasattr(bpy.types, 'Context'):
        return
    refused = _first_refusal(members)
    if refused is not None:
        name, why = refused
        raise RuntimeError(
            'temp_override was not entered: %s %s. Blender reads %s without asking what it holds, '
            'and crashed on values its own type would not hold.' % (name, why, name))


# The overrides entered and not yet left, on any thread: Blender's context is
# one, and an override entered on the script thread is in force for the main
# thread's operators too.
_in_force = []


def refuse_stale_members(operator):
    """Raises RuntimeError, in words, before `operator` runs (a wrapper, or
    its 'module.operator'), when an override in force holds what Blender has
    freed or changed since it was made (`member_refusal`, `again`). One look
    at an empty list when there is none."""
    for override in tuple(_in_force):
        refused = _first_refusal(override._members, again=True)
        if refused is not None:
            name, why = refused
            path = operator if isinstance(operator, str) else operator_path(operator.idname())
            refusal = ('bpy.ops.%s was not run: in the temp_override around it, %s %s, since the override '
                       'was made. Blender reads %s without asking what it holds, and crashed on that. Make '
                       'the override again from what is there now.' % (path, name, why, name))
            freed = _freed(override)
            if freed is not None:
                # A struct freed with its owner crashes the next call that
                # reads it, operator or not: the override is left (the
                # section after `_Override`), where `sys.monitoring` did not
                # stop this call first.
                _leave_from(override, freed)
            raise RuntimeError(refusal)


class _Override:
    # Blender's own override (`temp_override`'s), its members asked again as
    # it is entered — an ID removed between the call and the `with` crashed
    # Blender (the comment above `_MEMBER_TYPES`) — and in `_in_force` while
    # it is, for every operator to ask (`refuse_stale_members`). `__enter__`
    # hands out this, not Blender's object, which a later `with` would enter
    # unasked. One that holds a struct Blender frees with its owner is
    # watched while it is in force (`_watch`), and left at once when that is
    # freed (`_left`; the section below).
    __slots__ = ('_inner', '_members', '_watch', '_left', '_frame')

    def __init__(self, inner, members):
        self._inner = inner
        self._members = members
        self._watch = ()
        self._left = False
        self._frame = None

    def __enter__(self):
        refuse_members(self._members)
        self._inner.__enter__()
        self._left = False
        # The code its block is in: while that runs, a left override's block
        # is refused (`_broken`).
        self._frame = sys._getframe(1)
        _in_force.append(self)
        self._watch = _watchers(self._members)
        if self._watch:
            _watched.append(self)
            _monitor()
        return self

    def __exit__(self, *exc):
        self._frame = None
        if self._left:
            # Left already, when what it held was freed (`_refuse_freed`) or
            # the run ended (`leave_overrides`): Blender's context holds it no
            # longer, and its own exit was run then.
            self._left = False
            _broken[:] = [entry for entry in _broken if entry[0] is not self]
            _monitor()
            return False
        try:
            _in_force.remove(self)
        except ValueError:
            pass
        if self in _watched:
            _watched.remove(self)
            _monitor()
        return self._inner.__exit__(*exc)

    def __getattr__(self, name):
        # Blender's `logging_set`, and whatever else its object has.
        if name == '_inner':
            raise AttributeError(_SLOT_REFUSAL.format(what='This override'))
        return _unbound(getattr(self._inner, name))


# ---------------------------------------------------------------------------
# What a block frees from under its own override, past the operators
#
# `refuse_stale_members` asks before each operator. Calls that are not
# operators read the context in Blender's C too, and a struct that is not an
# ID reads back as whatever its pointer now points at: Python marks a freed
# ID's object removed (it reads as None), but not a view layer, a layer
# collection or a bone freed with its owner, and `ViewLayers.remove` sets the
# one it is given to null, as `view_layer=None` would be. Measured in desktop
# 5.2.1 with the app's context and the guards of the parallel entry, each in
# a Blender of its own, exit 139: inside `temp_override(view_layer=<a second
# view layer>)`, `scene.view_layers.remove(it)` then
# `bpy.context.evaluated_depsgraph_get()`, `cube.select_set(True)` or
# `cube.visible_get()`; inside `temp_override(scene=<another>,
# view_layer=<its own>)`, `bpy.data.scenes.remove(it)` then
# `evaluated_depsgraph_get()`; inside `temp_override(layer_collection=<a
# collection's>)`, `bpy.data.collections.remove(it)` then
# `bpy.context.layer_collection.name`. A bone member read after Edit Mode was
# left read back '' (freed memory). And an override a script entered and
# never left (`__enter__()` without its `with`) stays in force after the
# run: its scene removed, the app's own mirror pass after the run went down
# in `_blenderkit_collections._walk`.
#
# So an override in force that holds such a struct is watched (`_watched`):
# before every call from Python code (`sys.monitoring`'s CALL event, on only
# while one is watched: about 0.06 µs a call, measured, and nothing when
# none is) and every read of `bpy.context` (`_context_getattribute`), what it
# holds is looked for where Blender holds it now, from the owner it had when
# it was entered (`_watchers`). When it is gone, the override is left at once
# (Blender's own exit; newer ones above it first), the call is refused in
# words, and so is every call after it until its block ends (`_broken`).
# What a run leaves in force is left before the mirror reads anything
# (`leave_overrides`, from `_blenderkit_sync.sync`).

# Overrides in force that hold a struct `_watchers` can look for.
_watched = []
# (override, (member, why), the frame it was entered from) for each one left
# because what it held was freed, until its block ends: calls from that
# frame, or what it calls, are refused (`_between`, `_refusal`).
_broken = []
# (member, why) of the overrides left after their block had ended, for
# `leave_overrides` to say.
_quietly = []
# The `sys.monitoring` tool this module took, or None.
_tool = None
_THIS_FILE = __file__
# The app's own modules (`_blenderkit_*.py` beside this one): the gate's and
# the mirror's handlers run inside a script's operator call. For them a freed
# member's override is left and nothing is refused (`_between`): measured in
# desktop 5.2.1, an EditBone freed by Object Mode inside its override was
# first seen by the gate's depsgraph handler, which raised there before this.
_OWN_PREFIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_blenderkit_')


def _watchers(members):
    """(name, index, what it is, check) for each struct in `members` that is
    not an ID, of the kinds Blender frees with an owner it can be looked for
    in: `check()` is None while Blender holds it, else why not."""
    import bpy
    types = bpy.types
    out = []
    for name, value in members.items():
        if name in UI_MEMBERS:
            # Blender's own exit puts back and checks these.
            continue
        items = list(value) if _is_list(value) else [value]
        for index, item in enumerate(items):
            if not isinstance(item, types.bpy_struct) or isinstance(item, types.ID):
                continue
            try:
                address, owner = item.as_pointer(), item.id_data
            except (ReferenceError, AttributeError):
                continue
            if owner is None:
                continue
            kind = type(item).__name__
            if isinstance(item, types.ViewLayer):
                found = lambda o=owner: o.view_layers
            elif isinstance(item, types.ToolSettings):
                found = lambda o=owner: (o.tool_settings,)
            elif isinstance(item, types.LayerCollection):
                found = lambda o=owner: (c for layer in o.view_layers
                                         for c in _layer_collections(layer.layer_collection))
            elif isinstance(item, types.EditBone):
                found = lambda o=owner: o.edit_bones if o.is_editmode else ()
            elif isinstance(item, types.Bone):
                found = lambda o=owner: o.bones
            elif isinstance(item, types.PoseBone):
                found = lambda o=owner: o.pose.bones if o.pose is not None else ()
            else:
                # A MaterialSlot, a modifier, a Node, ...: not looked for.
                continue
            out.append((name, index if _is_list(value) else None, kind,
                        _held_by(item, address, owner, found, kind)))
            if name == 'view_layer' and isinstance(item, types.ViewLayer):
                out.append((name, None, kind, _held_to_scene(address, owner.as_pointer())))
    return tuple(out)


def _held_to_scene(address, owner):
    """A check that the view layer at `address`, entered as one of the scene
    at `owner`'s, is one of the scene's Blender's context reads now. Setting
    the window's scene inside the block clears the override's `scene` and
    keeps its `view_layer` (the note above SCENE_SWITCHES), and that view
    layer is not freed, so `_held_by` passes it. Measured in desktop 5.2.1 with the app's context, under MallocScribble,
    each in a Blender of its own (fix round 3's verification): inside
    `temp_override(scene=<the window's>, view_layer=<its own>)`, the script
    line `bpy.context.window.scene = <another>` and then
    `bpy.context.evaluated_depsgraph_get()` or `bpy.context.view_layer.update()`
    exited 139 in BKE_object_eval_eval_base_flags, which `refuse_stale_members`
    never saw: neither is an operator. Asked before every call and context
    read like what a block frees, the override is left and the call refused.
    The context's scene is read past `_context_getattribute` and compared by
    its address with the owner's (`_held_by` has asked that the owner still
    holds it). Measured in desktop 5.2.1, a Python call inside such an
    override: 1.5 µs with this check, 1.0 without it (load average about 30);
    reading `bpy.context.scene` and walking its view layers had made it 2.0."""
    import bpy

    def check():
        try:
            scene = _struct_getattribute(bpy.context, 'scene')
            if scene is None or scene.as_pointer() == owner:
                return None
            if any(v.as_pointer() == address for v in scene.view_layers):
                return None
        except (ReferenceError, AttributeError, TypeError):
            return None
        return ("a ViewLayer that is not one of the scene's view layers: the window was given another scene "
                "inside the override, and Blender's context reads that scene with this view layer")
    return check


def _held_by(item, address, owner, found, kind):
    def check():
        try:
            item.as_pointer()
        except ReferenceError:
            return _a(kind) + ' that has been removed'
        try:
            if any(x.as_pointer() == address for x in found()):
                return None
        except (ReferenceError, AttributeError, TypeError):
            return '%s whose %s has been removed' % (_a(kind), type(owner).__name__)
        return _a(kind) + " that is no longer Blender's (removed, or freed with what held it)"
    return check


def _freed(override):
    """(name, clause) for the first struct `override` holds that Blender has
    freed since it was entered, or None."""
    for name, index, kind, check in override._watch:
        why = check()
        if why is not None:
            if index is None:
                return name, 'holds %s, and was given %s' % (_a(kind), why)
            return name, 'holds a list, and item %d of it is %s' % (index, why)
    return None


def _leave_from(override, clause):
    """Leaves `override` and every override entered after it (Blender restores
    its context in the order it was set), each marked `_left` and kept in
    `_broken` with `clause` (member, why) until its block ends."""
    if override not in _in_force:
        return
    index = _in_force.index(override)
    while len(_in_force) > index:
        newest = _in_force.pop()
        newest._left = True
        if newest in _watched:
            _watched.remove(newest)
        _broken.append((newest, clause, newest._frame))
        try:
            newest._inner.__exit__(None, None, None)
        except Exception:                            # noqa: BLE001 - left either way
            pass
    _monitor()


def _called(target):
    if isinstance(target, str):
        return target
    if isinstance(target, _Guarded):
        try:
            return 'bpy.ops.' + operator_path(target.idname())
        except Exception:                            # noqa: BLE001 - a name only
            return 'the operator'
    name = getattr(target, '__qualname__', None) or getattr(target, '__name__', None)
    if name:
        return name
    text = (getattr(target, '__doc__', '') or '').strip().split('(', 1)[0].split()
    return text[-1] if text else 'the next call'


def _between(caller, entered):
    """Where the frame `caller` is, for the block entered from `entered`:
    'user' when `entered` is on its stack with none of the app's own code
    (`_OWN_PREFIX`) between them, 'own' when there is some (a handler the
    gate or the mirror runs inside the script's call), 'outside' when
    `entered` is not on it (the mirror after a run, another thread)."""
    own = False
    frame = caller
    while frame is not None:
        if frame is entered:
            return 'own' if own else 'user'
        if frame.f_code.co_filename.startswith(_OWN_PREFIX):
            own = True
        frame = frame.f_back
    return 'outside'


def _in_lookup(caller):
    """Whether `caller` is Blender's own `bpy.ops` lookup (bpy/ops.py: the
    module's `__getattr__` that `bpy.ops.object.select_all` goes through).
    A freed member seen there is left and not refused: the script's call of
    the operator it looks up comes next, and is the one refused, by name."""
    ops = sys.modules.get('bpy.ops')
    return ops is not None and caller.f_code.co_filename == getattr(ops, '__file__', None)


def _refuse_freed(caller, target=None):
    """Raises RuntimeError, in words, before a call or a read from the frame
    `caller`, when an override in force holds what Blender has freed since
    it was entered (leaving it first, `_leave_from`), or when the block of
    one left that way is still running (`_broken`). Not for the app's own
    code inside the block (`_between`): for it the override is left, and the
    script's next call is refused."""
    for _override, clause, entered in reversed(_broken):
        if entered is not None and _between(caller, entered) == 'user' and not _in_lookup(caller):
            raise RuntimeError(_refusal(target, clause))
    for override in tuple(_watched):
        clause = _freed(override)
        if clause is None:
            continue
        entered = override._frame
        _leave_from(override, clause)
        where = _between(caller, entered) if entered is not None else 'outside'
        if where == 'user' and not _in_lookup(caller):
            raise RuntimeError(_refusal(target, clause))
        if where == 'outside':
            # Its block is not running here: a run that entered it with no
            # `with` and ended, or another thread. The mirror after the run
            # says so (`leave_overrides`).
            _quietly.append(clause)


def _refusal(target, clause):
    name, why = clause
    what = _called(target) if target is not None else 'the next call'
    return ('%s was not run: in the temp_override around it, %s %s, since the override was made. '
            'Blender reads %s without asking what it holds, and crashed on that. The override was left, '
            'and nothing more runs in its block; make it again from what is there now.'
            % (what, name, why, name))


def _on_call(code, offset, target, arg0):
    # `sys.monitoring`'s CALL event: before every call from Python code,
    # while an override is watched or broken (`_monitor`). Not this module's
    # own calls, nor a call of one of its functions: the override's
    # `__exit__` as its block ends, and `leave_overrides` from the mirror.
    # Its operator wrappers are asked like any call.
    if code.co_filename == _THIS_FILE:
        return None
    try:
        module = getattr(target, '__module__', None)
    except Exception:                                # noqa: BLE001 - asked below
        module = None
    if module == __name__ and not isinstance(target, _Guarded):
        return None
    # The frame making the call: the one this callback runs on top of.
    _refuse_freed(sys._getframe(1), target)
    return None


def _monitor():
    """CALL events on while an override is watched or broken, off otherwise."""
    monitoring = getattr(sys, 'monitoring', None)
    if monitoring is None or _tool is None:
        return
    try:
        monitoring.set_events(_tool, monitoring.events.CALL if (_watched or _broken) else 0)
    except ValueError:
        pass


def _take_tool():
    """A `sys.monitoring` tool id of its own, once (3.12 and later)."""
    global _tool
    monitoring = getattr(sys, 'monitoring', None)
    if monitoring is None or _tool is not None:
        return
    for tool in (4, 3):
        if monitoring.get_tool(tool) is None:
            monitoring.use_tool_id(tool, 'Blender Local temp_override')
            monitoring.register_callback(tool, monitoring.events.CALL, _on_call)
            _tool = tool
            return


def _context_getattribute(self, name):
    # Every read of `bpy.context` (`install`): asked of the watched overrides
    # first, unless this module reads it (`member_refusal` reads the members
    # the context holds now).
    if (_watched or _broken) and name[:1] != '_':
        caller = sys._getframe(1)
        if caller.f_globals is not _GLOBALS:
            _refuse_freed(caller, 'bpy.context.' + name)
    if name == 'evaluated_depsgraph_get':
        # The vertex budget's gate first, for the view layer this context
        # evaluates (`_blenderkit_gate.before_evaluation`): a depsgraph
        # Blender builds fresh runs no handler.
        gate = sys.modules.get('_blenderkit_gate')
        if gate is not None and not gate._busy and hasattr(gate, '_wrap_entry'):
            return gate._wrap_entry(self, name, _struct_getattribute(self, name))
    return _struct_getattribute(self, name)


_struct_getattribute = None


def leave_overrides():
    """Leaves every override still in force, newest first, and forgets the
    ones left already: what a run leaves in force (`__enter__()` with no
    `with`) is the context the app's own work would read after it. Returns a
    sentence for the console when there was one, else ''."""
    left = 0
    while _in_force:
        newest = _in_force.pop()
        newest._left = True
        newest._frame = None
        left += 1
        try:
            newest._inner.__exit__(None, None, None)
        except Exception:                            # noqa: BLE001 - left either way
            pass
    _watched.clear()
    _broken.clear()
    quietly = list(_quietly)
    del _quietly[:]
    _monitor()
    said = []
    if left:
        said.append('[Blender Local] %d temp_override%s still in force when the run ended, and %s left as '
                    'its `with` block would have: what the run leaves in Blender\'s context is read by '
                    'everything after it.' % (left, ' was' if left == 1 else 's were',
                                              'it was' if left == 1 else 'they were'))
    for name, why in quietly:
        said.append('[Blender Local] A temp_override left in force by the run was left: its %s %s, and '
                    'Blender reads %s without asking what it holds.' % (name, why, name))
    return '\n'.join(said)


# ---------------------------------------------------------------------------
# The objects the guards hold, held from scripts
#
# Round 4's fix round 2 left `bpy.ops.uv.stitch._operator` open: the slot
# every wrapper keeps Blender's operator in, which called as it is runs past
# every guard (Stitch crashes Blender that way, as a script line does without
# the guard). And `.poll.__self__`, `.idname.__self__` and
# `.get_rna_type.__self__` handed out the same object, through the bound
# methods `__getattr__` passed on. Now the slot is read and written by this
# module only (`_module_only`), and a method of the held object is passed on
# as a plain function (`_unbound`): from a script, `._operator` (and
# `._operator._operator`, and an override's `._inner`) is refused in words,
# and `.__self__` is not there. Measured in desktop 5.2.1: every wrapper
# still calls, polls, names and describes its operator as Blender's (the
# context and unsafe checks, and the operator sweep). What Python's
# introspection reaches is not closed by this and cannot be from Python:
# `gc.get_referents(op)`, this slot's own descriptor in `_module_only`'s
# closure, frames, and ctypes (tests/unsafe/blender measures them still
# open). The wrappers' own closures held Blender's functions until fix round
# 3; they hold a `_Sealed` now (the note above it).

_GLOBALS = globals()
_SLOT_REFUSAL = ("{what} holds Blender's own object for the app's guards, which read it here only: "
                 "called as it is, it runs past them, and some calls crash Blender. Call the operator, "
                 "or enter the override, itself.")


def _unbound(found):
    """`found`, a bound method of an object the guards hold, as a plain
    function: its `__self__` would hand a script the object itself."""
    if getattr(found, '__self__', None) is None or not callable(found):
        return found

    def method(*args, **keywords):
        return found(*args, **keywords)
    method.__name__ = method.__qualname__ = getattr(found, '__name__', 'method')
    method.__doc__ = getattr(found, '__doc__', None)
    return method


def _module_only(cls, slot, what):
    """The slot `slot` of `cls`, read and written from this module only;
    anywhere else it raises AttributeError in words (`_SLOT_REFUSAL`). The
    slot's own descriptor stays in a closure, off the class."""
    held = cls.__dict__[slot]
    refusal = _SLOT_REFUSAL.format(what=what)

    def read(self):
        if sys._getframe(1).f_globals is not _GLOBALS:
            raise AttributeError(refusal)
        return held.__get__(self, type(self))

    def write(self, value):
        if sys._getframe(1).f_globals is not _GLOBALS:
            raise AttributeError(refusal)
        held.__set__(self, value)
    setattr(cls, slot, property(read, write, doc=refusal))


_module_only(_Guarded, '_operator', 'This operator')
_module_only(_Override, '_inner', 'This override')


# Fix round 3 (October 29): the functions of Blender's own that the guards
# wrap — `_bpy.ops.create_function`, `_bpy.ops.macro_define` and
# `Context.temp_override` — were still in the wrappers' closures:
# `bpy.ops._op_create_function.__closure__[0].cell_contents('uv', 'stitch')()`
# ran Stitch past every guard (fix round 2's final check: exit 139 in
# stitch_exit, in the run where `bpy.ops.uv.stitch()` was refused in words).
# A closure now holds a `_Sealed` instead: it calls the function only for
# this module (the caller's globals, read from its frame, as `_module_only`
# reads them), and its slot is this module's only. Measured in desktop 5.2.1:
# the cell's object called from a script raises TypeError in words, and its
# `_inner` raises AttributeError. What Python's introspection reaches past
# that is still open (the note above `_unbound`): `gc.get_referents` of the
# holder, the slot's own descriptor in `_module_only`'s closure, frames and
# ctypes.
_SEALED_REFUSAL = ("{what} is Blender's own, which the app's guards wrap and call from here only: called as "
                   "it is, it runs past them, and some calls crash Blender. Call the operator, or enter the "
                   "override, itself.")
_GUARD_REFUSAL = ("An operator's guard is made by the app, for Blender's own operator, and here only: one a script "
                  "makes calls what it is given past the guards, and some calls crash Blender. Call the operator "
                  "itself.")


class _Sealed:
    __slots__ = ('_inner', '_what')

    def __init__(self, inner, what):
        self._inner = inner
        self._what = what

    def __call__(self, *args, **keywords):
        if sys._getframe(1).f_globals is not _GLOBALS:
            raise TypeError(_SEALED_REFUSAL.format(what=self._what))
        return self._inner(*args, **keywords)

    def __repr__(self):
        return '<the guarded %s>' % self._what


_module_only(_Sealed, '_inner', 'This holder')
