"""Mirrors `bpy.data` into Blender Local's Metal viewport.

With the real Blender backend, bpy owns the scene — so after anything runs, the
evaluated depsgraph is walked here and every mesh is handed to the renderer.
Extraction uses `foreach_get`, which copies a whole attribute array in one call
rather than iterating in Python; on a subdivided mesh that is the difference
between a frame and a stall.

The same code runs against the shim in the simulator, because the shim
implements the small slice of the API this file touches. That is deliberate:
the real backend is arm64-only and cannot be simulator-tested, so this path has
to be exercised somewhere.
"""

from array import array
import math

import bpy
import _blenderkit

# Guard peak mobile memory use; the renderer uses 32-bit indices.
_MAX_VERTS = 10_000_000


def _matrix_bytes(matrix):
    """Blender's matrix_world, flattened row-major as 16 doubles."""
    return array("d", [c for row in matrix for c in row]).tobytes()


def visibility(obj):
    """(drawn, hidden, disabled): whether the viewport draws the object, and
    the two separate reasons Blender has for not drawing it.

    `hide_get()` is what H, Alt+H and the Outliner's eye change — the view
    layer's flag. `hide_viewport` is Disable in Viewports, the Outliner's
    monitor. Measured in 5.2.1: `object.hide_view_clear` brings back the first
    and leaves the second alone (it returned CANCELLED with only a disabled
    object in the scene), so an eye that wrote `hide_viewport`, as the
    Outliner's did, could not show an object H had hidden. A hidden collection
    hides an object with neither flag set, which is why `visible_get()` decides
    what is drawn. `hide_get()` raises for an object outside the view layer.
    """
    disabled = bool(getattr(obj, 'hide_viewport', False))
    try:
        hidden = bool(obj.hide_get())
    except (AttributeError, RuntimeError, TypeError):
        hidden = False
    try:
        drawn = bool(obj.visible_get())
    except (AttributeError, RuntimeError, TypeError):
        drawn = not hidden
    return drawn and not disabled, hidden, disabled


def _kind(obj):
    """The object's type, with the flags the viewport and the Outliner read.

    `|hidden` is not drawn, for whatever reason; `|layerhidden` and
    `|disabled` are the two reasons the Outliner shows and changes (see
    `visibility`). `|norender` carries `hide_render`, which the Outliner's
    camera column shows. Without it the column could turn rendering off and
    never show it as off.
    """
    drawn, hidden, disabled = visibility(obj)
    flags = '' if drawn else '|hidden'
    if hidden:
        flags += '|layerhidden'
    if disabled:
        flags += '|disabled'
    if getattr(obj, 'hide_render', False):
        flags += '|norender'
    # Display As Bounds, which Blender's snapping skips (`snap_obj_fn`:
    # `ob_eval->dt == OB_BOUNDBOX` snaps to nothing).
    if getattr(obj, 'display_type', '') == 'BOUNDS':
        flags += '|boundbox'
    symmetry = _symmetry(obj)
    if symmetry:
        flags += '|mirror=' + symmetry
    return obj.type + flags


def _symmetry(obj):
    """The mesh's X / Y / Z symmetry and Topology Mirror, one letter each
    (`xyzt`), or '' — what the header's mirror toggles show and what an
    edit-mode drag mirrors (SymmetricEdit.swift). They are the mesh
    datablock's, readable in edit mode as in object mode, and the edit-mode
    flags Blender's own header reads (`Mesh.symmetry`, ME_EDIT_MIRROR_TOPO)."""
    if obj.type != 'MESH':
        return ''
    data = getattr(obj, 'data', None)
    letters = ''
    for letter, name in (('x', 'use_mirror_x'), ('y', 'use_mirror_y'),
                         ('z', 'use_mirror_z'), ('t', 'use_mirror_topology')):
        if getattr(data, name, False):
            letters += letter
    return letters


def _push_placeholder(obj, active_name):
    # Non-mesh objects still belong in the outliner and can be transformed.
    # One origin point and no triangles gives them bounds without fake geometry.
    _blenderkit.sync_push(obj.name, _kind(obj),
        _matrix_bytes(obj.matrix_world), array('f', [0, 0, 0]).tobytes(),
        array('f', [0, 0, 1]).tobytes(), b'',
        int(obj.select_get()), int(obj.name == active_name),
        array('f', list(obj.color)).tobytes())
    _push_display(obj)
    _push_modifiers(obj)
    _push_relations(obj)
    push_local(obj)
    _push_points(obj)
    _push_groups(obj)


def _push_groups(obj, with_counts=False, during_pass=True):
    """A mesh's vertex groups and shape keys for the Data tab
    (`_blenderkit_groups`). Counted only for the active object, which is the
    one the tab shows: counting walks every vertex. A failure costs the Data
    tab this object's groups and keys, not the pass."""
    if obj is None or obj.type != 'MESH' or not _is_real_blender():
        return
    try:
        import _blenderkit_groups
    except ImportError:
        # As for the points: a check that loads this file by itself may not
        # have the module beside it.
        return
    try:
        _blenderkit_groups.push(obj, during_pass=during_pass, with_counts=with_counts)
    except (AttributeError, TypeError, ValueError, RuntimeError, KeyError) as error:
        print(f"[Blender Local] {obj.name}: its vertex groups and shape keys could not be read: {error}")


def _push_points(obj):
    """A curve's or a lattice's settings for the Data tab, and while it is
    edited its control points (`_blenderkit_points`). A failure costs the
    Data tab and Edit Mode's points this object, not the pass."""
    if obj.type not in ('CURVE', 'LATTICE') or not _is_real_blender():
        return
    try:
        import _blenderkit_points
    except ImportError:
        # The app has it beside this file; a check that loads this file by
        # itself may not, and its pass must go on without the points.
        return
    try:
        _blenderkit_points.push(obj)
    except (AttributeError, TypeError, ValueError, RuntimeError) as error:
        print(f"[Blender Local] {obj.name}: its control points could not be read: {error}")


def _push_lattice(obj, active_name, depsgraph):
    """A lattice, drawn as Blender draws it: its grid of points and lines.

    `to_mesh()` refuses a lattice (measured in 5.2.1: "Object does not have
    geometry data"), so the pass used to send one as its origin alone, and
    Add ▸ Lattice put nothing on screen. Its points go as an edge mesh, as a
    wire curve's do; the normals are zero, which the outline shader leaves
    unextruded."""
    try:
        import _blenderkit_points
        wire = _blenderkit_points.lattice_wire(obj, depsgraph)
    except (AttributeError, TypeError, ValueError, RuntimeError, ImportError) as error:
        print(f"[Blender Local] {obj.name}: the lattice could not be read: {error}")
        wire = None
    if wire is None:
        _push_placeholder(obj, active_name)
        return
    positions, lines = wire
    _blenderkit.sync_push(obj.name, _kind(obj), _matrix_bytes(obj.matrix_world),
        positions.tobytes(), (array('f', [0.0]) * len(positions)).tobytes(), b'',
        int(obj.select_get()), int(obj.name == active_name),
        array('f', list(obj.color)).tobytes())
    _push_edges(obj, lines)
    _push_modifiers(obj)
    _push_relations(obj)
    push_local(obj)
    _push_points(obj)


# The twelve edges of a box, by corner. Blender numbers `bound_box`'s corners
# with x changing slowest: 0-3 at min x, 4-7 at max x, and within each the
# loop (y, z) = (min, min), (min, max), (max, max), (max, min).
_BOX_EDGES = (0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7)


def _push_edges(obj, edges):
    """Hand over the edges of the mesh just pushed, for a mesh with no faces.

    A wire circle, an unfilled curve or an edge-only mesh has no triangle to
    draw, and the mirror used to drop every such object outright — so the
    app's own Add ▸ Circle (fill type Nothing: 32 vertices, 32 edges, no face,
    measured in 5.2.1) never reached the viewport, the Outliner or Knife
    Project's list of cutters. The renderer draws lines, so these are drawn as
    what they are.
    """
    push = getattr(_blenderkit, 'sync_edges', None)
    # An empty list is sent too: it is how a wire that lost its last edge
    # says so. Skipping it left the old edges on screen, because the vertices
    # came back identical and the mirror reuses a mesh whose positions,
    # normals and triangles all match (measured in 5.2.1: Add ▸ Circle, then
    # Delete ▸ Only Edges & Faces keeps all 32 vertices where they were).
    if push is not None and edges is not None:
        push(obj.name, edges.tobytes())


def _push_knots(obj, evaluated):
    """Hand over a curve's control points, for a curve with no surface.

    Blender snaps such a curve by its control points and nothing else: its
    evaluated geometry holds no mesh (measured in 5.2.1: None for a Bezier
    circle and a NURBS path, whose `to_mesh()` is a wire of 48 and 13
    vertices), so `data_for_snap` hands `snapCurve` the curve itself, which
    offers each Bezier point's knot and each NURBS or poly point, as points,
    and no edge or face (transform_snap_object_curve.cc). The wire pushed
    above is what is drawn; this is what a drag may land on. A curve with a
    bevel, an extrusion or a fill evaluates to a mesh (measured: 156, 26 and
    48 vertices), which Blender snaps like any mesh, and is left alone.
    """
    push = getattr(_blenderkit, 'sync_knots', None)
    if push is None or obj.type != 'CURVE' or not _is_real_blender():
        return
    try:
        if evaluated.evaluated_geometry().mesh is not None:
            return
        points = array('f')
        for spline in obj.data.splines:
            if spline.type == 'BEZIER':
                for point in spline.bezier_points:
                    points.extend(point.co)
            else:
                for point in spline.points:
                    points.extend(point.co[:3])
    except (AttributeError, TypeError, ValueError, RuntimeError) as error:
        # Without them the curve is snapped as the wire it is drawn with.
        print(f"[Blender Local] {obj.name} control points could not be read: {error}")
        return
    push(obj.name, points.tobytes())


def _push_uvs(obj, mesh, editing):
    """Hand over the active UV map and the seams of the mesh just pushed.

    `sync_push` carries positions, normals and triangles, so the UV Editor
    read "No UVs on this mesh" on the real backend straight after an unwrap.
    The map goes as Blender holds it: the loop behind each triangle corner and
    a UV per loop, two `foreach_get` calls and no loop in Python — the Swift
    side picks out each corner's UV (`SceneMirror.installUVs`). Measured in
    5.2.1 on the app's saved car, bike and dinosaur scene: both reads took
    0.6 ms for all 80 meshes, where gathering the corners here took 13.5 ms.
    It is not free: the dinosaur's 23 meshes push 385,392 bytes of geometry
    and 444,400 more of UV map (+115%; +109% for the whole scene), and this
    function cost about 1 ms of each pass on a Mac. The Swift side compares an
    unchanged map in place, 0.10 ms for the dinosaur, and installs nothing.

    Seams are an edge flag, and only the marked edges go, as vertex pairs:
    none is the usual case. They carry through the evaluated mesh — a cube's
    4 marked edges came out as 8 through a level-1 Subdivision, 8 through a
    Bevel and 8 through a Mirror — so they line up with the triangles pushed.
    A mesh with no UV map still sends its seams, since seams are marked before
    the unwrap that uses them.
    """
    push = getattr(_blenderkit, 'sync_uvs', None)
    if push is None:
        return
    try:
        layers = mesh.uv_layers
        loops = array('I', [0]) * (3 * len(mesh.loop_triangles))
        mesh.loop_triangles.foreach_get('loops', loops)
    except AttributeError:
        # The simulator's stand-in: its projections already put the UVs on
        # the Swift mesh, and it has no loops to send.
        return
    if editing:
        # The same triangles `sync_push` sent: hidden faces are left out.
        loops = _unhidden_triangles(mesh, loops)
    layer = layers.active
    if layer is None:
        name, loops, uvs = '', array('I'), array('f')
    else:
        name = layer.name
        uvs = array('f', [0.0]) * (2 * len(mesh.loops))
        layer.uv.foreach_get('vector', uvs)
    try:
        push(obj.name, name, loops.tobytes(), uvs.tobytes(), _seams(mesh, editing).tobytes())
    except ValueError as error:
        # A malformed map costs the UV Editor this object, not the whole pass.
        print(f"[Blender Local] {obj.name}: UVs not mirrored: {error}")
        return
    _push_uv_layout(obj, mesh, name, uvs, editing)


def _push_uv_layout(obj, evaluated, evaluated_map, evaluated_uvs, editing):
    """Hand the UV Editor the map Blender's UV Editor draws, when the mesh
    just pushed carries another one.

    The pushed mesh is the evaluated one, and its map is what the viewport
    textures it with. Blender's UV Editor draws the object's own mesh, before
    its modifiers (the modified map only in the opt-in Modified Edges
    overlay). Drawn from the evaluated mesh, a cube's 24 corners came out as
    96 through a level-1 Subdivision, and a Mirror with Mirror U added a
    flipped copy of every island (round 2's review, 5.2.1). Only an object
    with a modifier on in the viewport can differ, and only one whose map did
    differ is sent. Measured on a copy of the app's Scene.blend in desktop
    5.2.1: its 11 subdivided meshes (of 80) are sent, 152,808 bytes, and this
    cost 0.39-0.58 ms of a 6.1 ms pass.

    In Edit Mode the mesh's own arrays read empty (5.2.1: a UV map of 0
    corners after `update_from_editmode`), so it is read through the original
    object's `to_mesh()`, a temporary mesh outside bpy.data (96 corners after
    an edit-mode Subdivide, as the edit mesh holds). A scratch datablock
    written from the BMesh worked too, but adding and removing one tags the
    depsgraph's relations, which the next pass rebuilt: 3.8 ms more a pass on
    a copy of Scene.blend with one subdivided cube in Edit Mode."""
    push = getattr(_blenderkit, 'sync_uv_layout', None)
    if push is None or obj.type != 'MESH' or not any(m.show_viewport for m in obj.modifiers):
        return
    scratch = None
    try:
        base = obj.data
        if editing:
            # `sync` has already called update_from_editmode.
            scratch = obj.to_mesh()
            base = scratch
        layer = base.uv_layers.active
        name = layer.name if layer is not None else ''
        uvs = array('f', [0.0]) * (2 * len(base.loops) if layer is not None else 0)
        if layer is not None:
            layer.uv.foreach_get('vector', uvs)
        if (name == evaluated_map and len(base.loops) == len(evaluated.loops)
                and len(base.polygons) == len(evaluated.polygons) and uvs == evaluated_uvs):
            return
        base.calc_loop_triangles()
        count = len(base.vertices)
        co = array('f', [0.0]) * (3 * count)
        base.vertices.foreach_get('co', co)
        triangles = array('I', [0]) * (3 * len(base.loop_triangles))
        base.loop_triangles.foreach_get('vertices', triangles)
        loops = array('I', [0]) * (3 * len(base.loop_triangles))
        base.loop_triangles.foreach_get('loops', loops)
        if editing:
            triangles = _unhidden_triangles(base, triangles)
            loops = _unhidden_triangles(base, loops)
        if layer is None:
            loops = array('I')
        push(obj.name, name, co.tobytes(), triangles.tobytes(), loops.tobytes(), uvs.tobytes(),
             _seams(base, editing).tobytes())
    except (ValueError, AttributeError, RuntimeError) as error:
        # Without it the UV Editor draws the pushed mesh's map, as before.
        print(f"[Blender Local] {obj.name}: the UV Editor's map was not mirrored: {error}")
    finally:
        if scratch is not None:
            obj.to_mesh_clear()


def _seams(mesh, editing):
    """The vertex pairs of the mesh's seam edges; hidden ones left out while
    editing, as their faces are."""
    try:
        flags = array('b', [0]) * len(mesh.edges)
        mesh.edges.foreach_get('use_seam', flags)
    except (AttributeError, TypeError, RuntimeError):
        return array('I')
    if 1 not in flags.tobytes():
        return array('I')
    ends = array('I', [0]) * (2 * len(mesh.edges))
    mesh.edges.foreach_get('vertices', ends)
    hidden = _hidden_flags(mesh.edges) if editing else None
    seams = array('I')
    for e, flag in enumerate(flags):
        if flag and not (hidden and hidden[e]):
            seams.extend(ends[2 * e:2 * e + 2])
    return seams


def _push_bounds(obj, evaluated, active_name, vertex_count):
    """Stand in for a mesh too big to mirror with its bounding box, drawn as
    twelve lines, rather than leave it out: an object that vanishes from the
    viewport and the Outliner reads as deleted, not as too big. `|bounds=N`
    tells the interface how many vertices it is not showing."""
    corners = array('f', [c for corner in evaluated.bound_box for c in corner])
    _blenderkit.sync_push(obj.name, _kind(obj) + '|bounds=%d' % vertex_count,
        _matrix_bytes(obj.matrix_world), corners.tobytes(),
        (array('f', [0.0, 0.0, 1.0]) * 8).tobytes(), b'',
        int(obj.select_get()), int(obj.name == active_name),
        array('f', list(obj.color)).tobytes())
    _push_edges(obj, array('I', _BOX_EDGES))
    _push_modifiers(obj)
    _push_relations(obj)
    push_local(obj)


def sync(report=False):
    """Replace the mirrored scene with the current contents of bpy.data.

    `report` prints how many objects were mirrored. A script can build a
    perfectly good scene inside bpy and have none of it reach the viewport —
    that is what a broken backend check looked like for nine builds — and a
    count is the difference between seeing that at once and not at all.
    """
    _blenderkit.sync_begin()
    _shown.clear()
    pushed = 0
    material_values = []
    active = None
    try:
        active = getattr(bpy.context, "active_object", None)
        # Sculpt Mode leaves the evaluated mesh stale (after a Redo of a
        # stroke, the mesh from before it): refreshed before it is read.
        _sculpt_refresh(active)
        depsgraph = bpy.context.evaluated_depsgraph_get()
        active_name = active.name if active else None
        skipped = []
        # Sculpt Mode on a Multires level: Blender draws the level from grids
        # of its own, and the evaluated mesh read below would be the base
        # mesh. The level comes from `_blenderkit_sculpt.multires_display`,
        # read before the walk, since it adds and removes a temporary object.
        sculpt_display = _sculpt_display(active)
        if sculpt_display is not None:
            depsgraph = bpy.context.evaluated_depsgraph_get()

        for obj in bpy.context.scene.objects:
            if obj.type == 'LATTICE' and visibility(obj)[0] and _is_real_blender():
                _push_lattice(obj, active_name, depsgraph)
                continue
            if not visibility(obj)[0] or obj.type not in {"MESH", "CURVE", "SURFACE", "FONT", "META"}:
                _push_placeholder(obj, active_name)
                continue
            editing = obj.type == 'MESH' and getattr(obj, 'mode', '') == 'EDIT'
            if editing:
                obj.update_from_editmode()
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            if mesh is None:
                # A curve with no splines left (measured: `to_mesh()` answers
                # None for one). It is still an object in the scene.
                _push_placeholder(obj, active_name)
                continue
            try:
                mesh.calc_loop_triangles()

                nverts = len(mesh.vertices)
                ntris = len(mesh.loop_triangles)
                # Every object reaches the interface, whatever its geometry.
                # These three used to be skipped, and a skipped object is not
                # in the Outliner, cannot be selected and is in no menu.
                if nverts == 0:
                    # Everything deleted in edit mode, or text with no
                    # characters: an origin, as for an empty.
                    _push_placeholder(obj, active_name)
                    continue
                if nverts > _MAX_VERTS:
                    skipped.append((obj.name, nverts))
                    _push_bounds(obj, evaluated, active_name, nverts)
                    # Counted: it reached the viewport, as its bounds. Left
                    # out, a scene whose only mesh was this one printed both
                    # "drawn as its bounds" and "none reached the viewport".
                    pushed += 1
                    continue

                co = array("f", [0.0]) * (nverts * 3)
                mesh.vertices.foreach_get("co", co)
                normals = array("f", [0.0]) * (nverts * 3)
                mesh.vertices.foreach_get("normal", normals)
                tris = array("I", [0]) * (ntris * 3)
                mesh.loop_triangles.foreach_get("vertices", tris)
                if editing:
                    tris = _unhidden_triangles(mesh, tris)
                    ntris = len(tris) // 3
                drawn_level = sculpt_display is not None and obj.name == active_name
                if drawn_level:
                    co, normals, tris = sculpt_display
                    nverts, ntris = len(co) // 3, len(tris) // 3
                # No faces: a wire circle, an unfilled curve, an edge-only
                # mesh. Its edges are what there is to draw and to pick; a
                # mesh of loose vertices alone still arrives, with its bounds.
                edges = None
                if ntris == 0:
                    try:
                        edges = array("I", [0]) * (len(mesh.edges) * 2)
                        mesh.edges.foreach_get("vertices", edges)
                        if editing:
                            edges = _unhidden_edges(mesh, edges)
                    except AttributeError:
                        # The simulator's stand-in mesh has no edge list.
                        edges = None

                colour = array("f", list(obj.color)[:4] or [0.8, 0.8, 0.8, 1.0])
                while len(colour) < 4:
                    colour.append(1.0)

                # The simulator's material proxies already write directly to
                # the native preview and do not implement RNA node iteration.
                if (hasattr(_blenderkit, 'material_set') and
                        hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')):
                    values = {'Base Color': (0.8, 0.8, 0.8), 'Metallic': (0.0,),
                              'Roughness': (0.5,), 'IOR': (1.45,),
                              'Emission Color': (0.0, 0.0, 0.0), 'Emission Strength': (0.0,)}
                    material = getattr(obj, 'active_material', None)
                    tree = getattr(material, 'node_tree', None)
                    if tree:
                        shader = next((n for n in tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
                        if shader:
                            for key in values:
                                socket = shader.inputs.get(key)
                                if socket is not None:
                                    v = socket.default_value
                                    values[key] = tuple(v)[:3] if hasattr(v, '__len__') else (float(v),)
                    material_values.append((obj.name, values))
                pushed += 1
                _shown[obj.name] = (nverts, ntris)
                _blenderkit.sync_push(
                    obj.name,
                    _kind(obj),
                    _matrix_bytes(obj.matrix_world),
                    co.tobytes(),
                    normals.tobytes(),
                    tris.tobytes(),
                    1 if obj.select_get() else 0,
                    1 if obj.name == active_name else 0,
                    colour.tobytes(),
                )
                if edges is not None:
                    _push_edges(obj, edges)
                    _push_knots(obj, evaluated)
                elif not drawn_level:
                    # The level's UVs are not the base mesh's, and Sculpt Mode
                    # shows none.
                    _push_uvs(obj, mesh, editing)
                # The mesh pushed above is already evaluated, so the stack
                # that produced it has to travel separately for the panel to
                # be able to change it.
                _push_modifiers(obj)
                _push_relations(obj)
                push_local(obj)
                _push_points(obj)
                # After `update_from_editmode` above, so an edited mesh's
                # groups are counted as Edit Mode has them.
                _push_groups(obj, with_counts=obj.name == active_name)
            finally:
                # to_mesh() allocates; without this the depsgraph leaks a mesh
                # per object per sync.
                try:
                    evaluated.to_mesh_clear()
                except Exception:
                    pass

        if skipped:
            for name, n in skipped:
                print(f"[Blender Local] {name} has {n} vertices and exceeds the "
                      f"{_MAX_VERTS}-vertex viewport limit; drawn as its bounds.")
        meshes = sum(1 for o in bpy.data.objects if o.type == "MESH")
        if report:
            print(f"[Blender Local] viewport mirrored {pushed} of {meshes} "
                  f"mesh objects from bpy.data.")
        elif pushed == 0 and meshes:
            # bpy holds geometry and none of it reached the screen. Saying so
            # is the whole difference between a diagnosable problem and
            # "the showcase doesn't change".
            print(f"[Blender Local] {meshes} mesh objects in bpy.data but none "
                  f"reached the viewport.")
    finally:
        _blenderkit.sync_end()
    _report_mode(active)
    _report_sculpt_mask(active)
    _report_edit_selection(active)
    _report_paint()
    for name, values in material_values:
        for key, value in values.items():
            _blenderkit.material_set(name, key, *value)
    if hasattr(_blenderkit, 'set_timeline'):
        scene = bpy.context.scene
        _blenderkit.set_timeline(getattr(scene, 'frame_start', 1),
                                getattr(scene, 'frame_end', 250), scene.frame_current)
    _report_animation()
    _report_tools()
    return pushed


# What the last full pass pushed for each mesh object: (vertices, triangles).
# The edit-selection report can only name elements by index when the viewport's
# mesh is Blender's mesh, and these counts are how it knows.
_shown = {}


def _hidden_flags(elements):
    """Each element's `hide`, or None when nothing is hidden or the mesh has no
    such flag (the simulator's stand-in)."""
    try:
        flags = array('b', [0]) * len(elements)
        elements.foreach_get('hide', flags)
    except (AttributeError, TypeError, RuntimeError):
        return None
    return flags if any(flags) else None


def _unhidden_triangles(mesh, tris):
    """The triangles of the faces edit mode shows: Blender draws no hidden face.

    Measured in 5.2.1: after `mesh.hide` the evaluated mesh still carries every
    face — 16 of a 4 x 4 grid with 9 hidden, and 64 of 64 through a
    Subdivision with 16 of them hidden — and says which by the face's `hide`.
    The mirror drew them all, so Hide Selected looked like it had done
    nothing. Only while editing: in object mode Blender draws hidden faces.
    """
    hidden = _hidden_flags(mesh.polygons)
    if hidden is None:
        return tris
    ntris = len(tris) // 3
    faces = array('I', [0]) * ntris
    mesh.loop_triangles.foreach_get('polygon_index', faces)
    kept = array('I')
    for t in range(ntris):
        if not hidden[faces[t]]:
            kept.extend(tris[3 * t:3 * t + 3])
    return kept


def _unhidden_edges(mesh, edges):
    """A wire mesh's edges less the hidden ones, while editing."""
    hidden = _hidden_flags(mesh.edges)
    if hidden is None:
        return edges
    kept = array('I')
    for e in range(len(edges) // 2):
        if not hidden[e]:
            kept.extend(edges[2 * e:2 * e + 2])
    return kept

# Modes the interface keeps for itself on top of Blender's object mode.
# Painting here is Swift working on the display cache, so Blender stays in
# object mode underneath it — and reporting that back must not end it.
# Sculpt Mode is Blender's own with the real Blender (`_blenderkit_sculpt`):
# its brushes work on the mesh in Blender's Sculpt Mode, so an Undo that takes
# Blender back to object mode takes the interface with it. On the simulator's
# stand-in the Swift brushes still sculpt the display cache.
_APP_MODES = {'SCULPT', 'TEXTURE_PAINT', 'VERTEX_PAINT', 'WEIGHT_PAINT'}
_REAL_APP_MODES = _APP_MODES - {'SCULPT'}


def _is_real_blender():
    """Blender's operators carry their RNA; the shim's are plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _report_mode(active):
    """Tell the interface which mode Blender is really in.

    The interface's mode decides whether the 3D View shows mesh editing at
    all, and nothing used to report Blender's: Edit Mesh put Blender into edit
    mode while the interface went on showing object mode, with no Done button
    and no way back out.
    """
    set_mode = getattr(_blenderkit, 'set_mode', None)
    shown_mode = getattr(_blenderkit, 'mode', None)
    if set_mode is None or shown_mode is None:
        return
    real = getattr(active, 'mode', 'OBJECT') if active is not None else 'OBJECT'
    shown = shown_mode()
    app_modes = _REAL_APP_MODES if _is_real_blender() else _APP_MODES
    if real == shown or (real == 'OBJECT' and shown in app_modes):
        return
    try:
        set_mode(real)
    except ValueError:
        # Pose, particle edit and the grease-pencil modes have no interface
        # here, and object mode is the honest stand-in for them.
        if shown != 'OBJECT' and shown not in app_modes:
            set_mode('OBJECT')


def _drawn_in_sculpt_mode(active):
    """Whether the mirror may read `active`'s sculpt session: it is in Sculpt
    Mode, on the real Blender, and drawn. An object Blender does not draw it
    does not evaluate either, and its sculpt session keeps pointing at the
    last evaluation. Measured in the app: a Multires cube in Sculpt Mode,
    then Disable in Viewports, crashed the next pass in `ed.flush_edits`
    (`multires_flush_sculpt_updates`, a null Subdiv). Not drawn, nothing here
    needs it."""
    return (active is not None and getattr(active, 'mode', '') == 'SCULPT'
            and _is_real_blender() and visibility(active)[0])


def _sculpt_refresh(active):
    if not _drawn_in_sculpt_mode(active):
        return
    try:
        import _blenderkit_sculpt
        _blenderkit_sculpt.refresh_evaluated(active)
    except Exception as error:                      # noqa: BLE001 - the mirror goes on
        print(f"[Blender Local] the sculpted mesh of {active.name} could not be refreshed: {error}")


def _sculpt_display(active):
    """The Multires level Sculpt Mode draws for the active object, as
    (positions, normals, triangles), or None when it is not sculpted on one."""
    if not _drawn_in_sculpt_mode(active):
        return None
    try:
        import _blenderkit_sculpt
        return _blenderkit_sculpt.multires_display(active)
    except Exception as error:                      # noqa: BLE001 - the mirror goes on
        print(f"[Blender Local] the Multires level of {active.name} could not be read: {error}")
        return None


def _report_sculpt_mask(active):
    """The mask on the object Blender is sculpting, for Sculpt Mode's viewport
    to darken (`_blenderkit_sculpt.push_mask`): after an Undo or a script, as
    after a stroke."""
    if not _drawn_in_sculpt_mode(active):
        return
    try:
        import _blenderkit_sculpt
        _blenderkit_sculpt.push_mask(active)
    except Exception as error:                      # noqa: BLE001 - the mirror goes on
        print(f"[Blender Local] the sculpt mask of {active.name} could not be shown: {error}")


def _report_edit_selection(active):
    """Hand the interface Blender's selection on the mesh being edited.

    Without this the viewport showed only what was tapped in it, never what an
    operator selected — the faces an inset leaves selected, a Select All from
    the keyboard — and the next Bevel acted on a selection nobody could see.
    """
    report = getattr(_blenderkit, 'sync_edit_selection', None)
    if report is None or active is None or getattr(active, 'type', '') != 'MESH':
        return
    if getattr(active, 'mode', '') != 'EDIT' or not _is_real_blender():
        return
    active.update_from_editmode()
    me = active.data
    tool = bpy.context.scene.tool_settings.mesh_select_mode
    bits = (1 if tool[0] else 0) | (2 if tool[1] else 0) | (4 if tool[2] else 0)
    me.calc_loop_triangles()
    nv, ne, nf, nt = len(me.vertices), len(me.edges), len(me.polygons), len(me.loop_triangles)
    try:
        tri_poly = array('I', [0]) * nt
        me.loop_triangles.foreach_get('polygon_index', tri_poly)
        # The triangles the pass drew: hidden faces are left out of it
        # (`_unhidden_triangles`), so they are left out here too, or triangle
        # t would name a different face on each side.
        hidden_faces = _hidden_flags(me.polygons)
        if hidden_faces is not None:
            tri_poly = array('I', [p for p in tri_poly if not hidden_faces[p]])
        if _shown.get(active.name) != (nv, len(tri_poly)):
            # The viewport draws a mesh a modifier has rebuilt, so its elements
            # are not Blender's and there is no index to report a selection by.
            report(active.name, bits, b'', b'', b'', b'', b'', b'')
            return
        vsel = array('b', [0]) * nv
        me.vertices.foreach_get('select', vsel)
        psel = array('b', [0]) * nf
        me.polygons.foreach_get('select', psel)
        ends = array('I', [0]) * (2 * ne)
        me.edges.foreach_get('vertices', ends)
        esel = array('b', [0]) * ne
        me.edges.foreach_get('select', esel)
        # Hidden vertices keep their place in the vertex list and are given no
        # dot and no tap. Hidden edges need nothing: every face on one is
        # hidden too, so the viewport has no line for it.
        vhide = _hidden_flags(me.vertices)
        args = (active.name, bits, vsel.tobytes(), tri_poly.tobytes(), psel.tobytes(),
                ends.tobytes(), esel.tobytes(), vhide.tobytes() if vhide is not None else b'')
        coords = _edit_coordinates(active, me, nv)
        report(*(args + (coords,) if coords else args))
    except (ValueError, KeyError):
        # The object is not on screen under that name; the next pass will be.
        pass


def _edit_coordinates(active, me, nv):
    """Blender's own coordinates for the mesh being edited, as float bytes,
    when a modifier shown in edit mode may have moved the vertices the
    viewport drew off them; b'' otherwise.

    The viewport draws the evaluated mesh, and a modifier that keeps the
    vertex count moves its vertices without renumbering them, so the report
    above still names them by index. SimpleDeform and Shrinkwrap are shown in
    edit mode by default (measured in 5.2.1; Displace, Lattice, Armature,
    Smooth and Cast are not, until turned on). But a transform's X / Y / Z
    mirror pairs vertices on the edit mesh's coordinates
    (EDBM_verts_mirror_cache_begin_ex reads BMVert co), not on what is drawn.
    Measured in 5.2.1: a 10 x 10 grid with a SimpleDeform Twist, X on, the
    vertex at (0.6, 0.4) selected — paired on the evaluated positions it has
    no mirror image, and `translate(mirror=True)` moved it and vertex 79, its
    image on the edit mesh. SymmetricEdit pairs on these instead. Sent only
    when some modifier is on in edit mode, so a plain mesh's report costs no
    more than it did; the Swift side drops them if they equal what it drew."""
    if not any(getattr(m, 'show_viewport', False) and getattr(m, 'show_in_editmode', False)
               for m in getattr(active, 'modifiers', ())):
        return b''
    co = array('f', [0.0]) * (3 * nv)
    # With a shape key other than Basis active, `update_from_editmode` fills
    # the mesh's vertices from the Basis (update_vertex_coords_from_refkey,
    # bmesh_mesh_convert.cc) while the edit mesh, which Blender pairs on and
    # the viewport draws, holds the active key; the key's own block holds it
    # too. Measured in 5.2.1 (round 3's review): grid vertex 85 with Key 1
    # (x + 0.1) active read (0.6, 0.4, 0) from the mesh, where the edit mesh
    # and the drawing had (0.7, 0.4, 0).
    keys = getattr(me, 'shape_keys', None)
    blocks = getattr(keys, 'key_blocks', None) or ()
    index = getattr(active, 'active_shape_key_index', 0)
    block = blocks[index] if 0 <= index < len(blocks) else None
    if block is not None and block != keys.reference_key and len(block.data) == nv:
        block.data.foreach_get('co', co)
    else:
        me.vertices.foreach_get('co', co)
    return co.tobytes()


def _report_paint():
    """Hand the viewport what Texture Paint paints through: every textured
    object's UVs and images, and the pixels of an image that changed. See
    _blenderkit_texpaint.report.

    A failure here must not take the rest of the pass with it — the materials
    and the timeline after it would silently stop reaching the interface.
    """
    try:
        import _blenderkit_texpaint
        _blenderkit_texpaint.report(_shown)
    except Exception as error:
        print(f"[Blender Local] Texture Paint could not read the scene: {error}")


def sync_selection():
    """Mirror what a click changes, without re-reading every mesh.

    A full pass walks the evaluated depsgraph and copies every object's
    geometry — the right price after an operator, and far too high for a tap
    that changed a few selection flags.
    """
    active = getattr(bpy.context, 'active_object', None)
    _blenderkit.select_all(False)
    for obj in bpy.context.scene.objects:
        try:
            if obj.select_get():
                _blenderkit.select(obj.name, True)
        except (KeyError, RuntimeError):
            # Not on screen yet, or not in this view layer.
            pass
    try:
        _blenderkit.set_active(active.name if active is not None else '')
    except KeyError:
        pass
    _report_mode(active)
    _report_edit_selection(active)
    # A tap that made another mesh active in Object Mode: its groups,
    # counted, since the Data tab now shows it. Not in Edit Mode, where a
    # tap changes the selection and never a group.
    if active is not None and getattr(active, 'mode', '') != 'EDIT':
        _push_groups(active, with_counts=True, during_pass=False)
    # A tap on a curve's or a lattice's point: its points, read back.
    if active is not None and active.type in ('CURVE', 'LATTICE') and _is_real_blender():
        try:
            import _blenderkit_points
            _blenderkit_points.push(active, during_pass=False)
        except ImportError:
            pass
        except (AttributeError, TypeError, ValueError, RuntimeError) as error:
            print(f"[Blender Local] {active.name}: its control points could not be read: {error}")


# Cameras, lights and empties have no surface to mirror: Blender draws them in
# its overlay engine from their settings (draw/engines/overlay/overlay_camera.hh,
# overlay_light.hh and overlay_empty.hh), so those settings are what the viewport
# is handed, straight after the object. The record is `key=value` pairs joined by
# `;` and keyed by Blender's property names; ObjectDisplay.swift reads it, and
# the simulator's shim keeps the same one.
_DISPLAY_TYPES = {'CAMERA', 'LIGHT', 'EMPTY'}


def _record_value(value):
    if isinstance(value, bool):
        return '1' if value else '0'
    if isinstance(value, (int, float)):
        return repr(float(value))
    if isinstance(value, str):
        return value
    return ','.join(repr(float(c)) for c in value)


def _focus_distance(obj, camera):
    """`BKE_camera_object_dof_distance`: how far along the camera's view its
    focus object is, or the focus distance when it has none."""
    target = camera.dof.focus_object
    if target is None:
        return camera.dof.focus_distance
    view = obj.matrix_world.col[2].to_3d().normalized()
    offset = obj.matrix_world.translation - target.matrix_world.translation
    return max(abs(view.dot(offset)), 1e-5)


def _image_aspect(image):
    """`calc_image_aspect` in overlay_empty.hh: an image empty's frame is 1
    along the image's longer side."""
    if image is None:
        return (1.0, 1.0)
    width, height = (max(1, int(c)) for c in image.size)
    aspect_x, aspect_y = image.display_aspect
    scale_x = scale_y = 1.0
    if aspect_x > aspect_y:
        scale_y = aspect_y / aspect_x
    elif aspect_x < aspect_y:
        scale_x = aspect_x / aspect_y
    x, y = width * scale_x, height * scale_y
    return (1.0, y / x) if x > y else (x / y, 1.0)


def _display_record(obj):
    """What the viewport draws a camera, light or empty from: (data-block name,
    record).

    None for an object drawn from its mesh. The evaluated object is read, so an
    animated setting is drawn as it is on the current frame.
    """
    kind = obj.type
    if kind not in _DISPLAY_TYPES:
        return None
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    if kind == 'EMPTY':
        # Set Origin moves an empty that instances a collection and no other
        # (Bpy.originReach has the measurements), so the menu has to know.
        # getattr: the simulator's shim has no instancing, and an error here
        # would leave the empty undrawn.
        values = [('empty_display_type', evaluated.empty_display_type),
                  ('empty_display_size', evaluated.empty_display_size),
                  ('instances_collection', getattr(obj, 'instance_type', 'NONE') == 'COLLECTION'
                   and getattr(obj, 'instance_collection', None) is not None)]
        if evaluated.empty_display_type == 'IMAGE':
            values += [('empty_image_offset', tuple(evaluated.empty_image_offset)),
                       ('image_aspect', _image_aspect(evaluated.data))]
        return '', ';'.join(k + '=' + _record_value(v) for k, v in values)
    data = evaluated.data
    if data is None:
        return None
    if kind == 'CAMERA':
        scene = bpy.context.scene
        render = scene.render
        values = [('type', data.type), ('lens', data.lens), ('sensor_fit', data.sensor_fit),
                  ('sensor_width', data.sensor_width), ('sensor_height', data.sensor_height),
                  ('ortho_scale', data.ortho_scale), ('clip_start', data.clip_start),
                  ('clip_end', data.clip_end), ('shift_x', data.shift_x),
                  ('shift_y', data.shift_y), ('display_size', data.display_size),
                  ('show_limits', data.show_limits),
                  ('focus_distance', _focus_distance(obj, data)),
                  ('aspect_x', render.resolution_x * render.pixel_aspect_x),
                  ('aspect_y', render.resolution_y * render.pixel_aspect_y),
                  ('scene_camera', scene.camera is not None and scene.camera.name == obj.name)]
    else:
        values = [('type', data.type), ('color', tuple(data.color)), ('energy', data.energy),
                  ('shadow_soft_size', data.shadow_soft_size),
                  ('cutoff_distance', data.cutoff_distance),
                  ('shadow_buffer_clip_start', data.shadow_buffer_clip_start)]
        if data.type == 'SPOT':
            values += [('spot_size', data.spot_size), ('spot_blend', data.spot_blend),
                       ('show_cone', data.show_cone)]
        elif data.type == 'AREA':
            values += [('shape', data.shape), ('size', data.size), ('size_y', data.size_y)]
    return data.name, ';'.join(k + '=' + _record_value(v) for k, v in values)


_MODIFIER_FIELDS = {
    'SUBSURF':      ('levels',),
    'ARRAY':        ('count',),
    # Clipping, Merge and its distance. The three per-axis triples (axis,
    # bisect, flip) are unpacked below. Blender clips an edit-mode transform
    # only for a Mirror enabled in the viewport (measured), which the drag's
    # preview reads from `show_viewport` — sent for every kind (_COMMON_FIELDS).
    'MIRROR':       ('use_clip', 'use_mirror_merge', 'merge_threshold'),
    'SOLIDIFY':     ('thickness',),
    'SMOOTH':       ('factor', 'iterations'),
    'CAST':         ('factor',),
    'SIMPLE_DEFORM': ('deform_method', 'angle', 'deform_axis'),
    'DISPLACE':     ('strength',),
    # Wave's Motion X and Y: which way the ripple travels. Both on (Blender's
    # default) is a ring, one alone a line of crests, neither lifts the whole
    # mesh by one amount (measured on a 21 x 21 grid in 5.2.1).
    'WAVE':         ('height', 'use_x', 'use_y'),
    'BEVEL':        ('width', 'segments'),
    'BOOLEAN':      ('operation',),
    'WELD':         (),
    'TRIANGULATE':  (),
    # Shrinkwrap's `target` is a pointer, so it is special-cased below beside
    # Boolean's `object`.
    'SHRINKWRAP':   ('wrap_method', 'offset'),
    'SCREW':        ('angle', 'steps', 'axis', 'screw_offset'),
    # face_count is read-only in RNA and read-only in the panel: it is what
    # Blender's collapse actually produced, which is the only thing that tells
    # a low-poly mesh apart from a broken control.
    'DECIMATE':     ('ratio', 'decimate_type', 'face_count'),
    'REMESH':       ('mode', 'voxel_size', 'octree_depth'),
    # A Geometry Nodes modifier: its node group, and for Blender's own Smooth
    # by Angle — what Shade Auto Smooth adds — the two inputs its panel has.
    # Special-cased below: they are node-group inputs, not modifier settings.
    'NODES':        (),
    # Weighted Normal's weighting (`mode`, which is also Remesh's name for its
    # algorithm: the Swift reads the two per kind), its 1-100 weight, the
    # threshold, Keep Sharp and Face Influence.
    'WEIGHTED_NORMAL': ('mode', 'weight', 'thresh', 'keep_sharp', 'use_face_influence'),
    # The three levels and what Subdivide has made, which clamps them and is
    # read-only in RNA.
    'MULTIRES':     ('levels', 'sculpt_levels', 'render_levels', 'total_levels'),
    'EDGE_SPLIT':   ('split_angle', 'use_edge_angle', 'use_edge_sharp'),
    # `use_x` / `use_y` are Wave's Motion names too; read per kind.
    'LAPLACIANSMOOTH': ('iterations', 'lambda_factor', 'lambda_border', 'use_x', 'use_y',
                        'use_z', 'use_volume_preserve', 'use_normalized'),
    # `rest_source` and `is_bind` are shown and never written: binding is an
    # operator the panel does not offer.
    'CORRECTIVE_SMOOTH': ('factor', 'iterations', 'scale', 'smooth_type', 'use_only_smooth',
                          'use_pin_boundary', 'rest_source', 'is_bind'),
    # Its `object` is a pointer, special-cased below beside Boolean's.
    'LATTICE':      ('strength',),
}

# What every modifier's record carries, whatever its kind: the two switches
# every row has.
_COMMON_FIELDS = ('show_viewport', 'show_render')

# The kinds whose Vertex Group field the panel offers, and the field with its
# Invert (`ModifierKind.takesVertexGroup`). Each was measured in 5.2.1 to
# change what it makes with a group set, and again inverted; Bevel's is read
# only under a Vertex Group limit, which the panel does not offer.
_VERTEX_GROUP_KINDS = {'SOLIDIFY', 'SMOOTH', 'CAST', 'SIMPLE_DEFORM', 'DISPLACE', 'WAVE',
                       'SHRINKWRAP', 'WEIGHTED_NORMAL', 'LAPLACIANSMOOTH', 'CORRECTIVE_SMOOTH',
                       'LATTICE', 'WELD', 'DECIMATE'}
_VERTEX_GROUP_FIELDS = ('vertex_group', 'invert_vertex_group')

# Blender's name for each modifier type — "Surface Deform" for
# SURFACE_DEFORM — which a row for a kind the panel has no settings for shows.
# Read from RNA once per type: the pass runs after every operation.
_TYPE_LABELS = {}


def _type_label(modifier):
    label = _TYPE_LABELS.get(modifier.type)
    if label is None:
        try:
            label = modifier.bl_rna.properties['type'].enum_items[modifier.type].name
        except (AttributeError, KeyError, TypeError):
            label = modifier.type.replace('_', ' ').title()
        _TYPE_LABELS[modifier.type] = label
    return label

# The group Shade Auto Smooth adds, and the inputs Blender's panel draws for it
# (5.2.1: "Angle", Input_1, a float in radians from 0 to pi, default 30
# degrees; "Ignore Sharpness", Socket_1, a bool). Read and written by name,
# since an identifier is the group's own business.
SMOOTH_BY_ANGLE = 'Smooth by Angle'
_SMOOTH_BY_ANGLE_INPUTS = (('Angle', 'angle'), ('Ignore Sharpness', 'ignore_sharpness'))


def _node_input_identifier(group, name):
    for item in getattr(getattr(group, 'interface', None), 'items_tree', ()):
        if (getattr(item, 'item_type', '') == 'SOCKET' and getattr(item, 'in_out', '') == 'INPUT'
                and item.name == name):
            return item.identifier
    return None


def _node_input_slot(modifier, name):
    """(owner, key) for a Geometry Nodes input: how this Blender stores it.

    5.2.1 keeps the value at `modifier.properties.inputs.<identifier>.value`
    and refuses `modifier["Input_1"]` ("this type doesn't support
    IDProperties", measured); Blender before it kept an ID property on the
    modifier. Both are tried, so the app's bpy need not be the desktop's.
    """
    group = getattr(modifier, 'node_group', None)
    identifier = _node_input_identifier(group, name) if group is not None else None
    if identifier is None:
        raise KeyError('%s has no input called %r' % (modifier.name, name))
    inputs = getattr(getattr(modifier, 'properties', None), 'inputs', None)
    if inputs is not None and hasattr(inputs, identifier):
        return getattr(inputs, identifier), 'value'
    return modifier, identifier


def node_input(modifier, name):
    owner, key = _node_input_slot(modifier, name)
    return owner[key] if owner is modifier else getattr(owner, key)


def set_node_input(obj, modifier_name, name, value):
    """Sets a Geometry Nodes input on one of `obj`'s modifiers, and has the
    object evaluated again.

    The second half is not optional: measured in 5.2.1, a Smooth by Angle set
    from 30 to 100 degrees on a cube still evaluated with all 12 edges sharp
    until `update_tag()`, and then with none.
    """
    modifier = obj.modifiers[modifier_name]
    owner, key = _node_input_slot(modifier, name)
    if owner is modifier:
        owner[key] = value
    else:
        setattr(owner, key, value)
    obj.update_tag()


# The record's separators, escaped where they occur inside a value. Blender
# lets a modifier (or the object a Boolean or Lattice points at) be called
# anything: measured in 5.2.1, a modifier renamed 'a;b|c=d%e' keeps that name.
# Unescaped, the `|` split its entry in two and the `;` cut its name short, so
# the row showed the wrong name and every edit it sent raised KeyError.
# `%` goes first so a name that already holds one comes back as itself.
_RECORD_ESCAPES = (('%', '%25'), (';', '%3B'), ('|', '%7C'), ('=', '%3D'), ('\n', '%0A'))


def _modifier_value(value):
    text = _record_value(value)
    if isinstance(value, str):
        for raw, escaped in _RECORD_ESCAPES:
            text = text.replace(raw, escaped)
    return text


def _modifier_entry(obj, m, first):
    """One modifier's `kind=…;name=…;key=value` entry."""
    fields = _MODIFIER_FIELDS.get(m.type)
    values = [('kind', m.type), ('name', m.name)]
    if fields is None:
        fields = ()
        values.append(('type_label', _type_label(m)))
    if m.type in _VERTEX_GROUP_KINDS:
        fields = tuple(fields) + _VERTEX_GROUP_FIELDS
    for key in _COMMON_FIELDS + fields:
        try:
            values.append((key, getattr(m, key)))
        except AttributeError:
            pass
    if m.type == 'MIRROR':
        for key, default in (('use_axis', (True, False, False)),
                             ('use_bisect_axis', (False, False, False)),
                             ('use_bisect_flip_axis', (False, False, False))):
            flags = tuple(getattr(m, key, default))
            values += [(key + '_x', flags[0]), (key + '_y', flags[1]), (key + '_z', flags[2])]
    if m.type == 'REMESH' and first:
        size = _own_mesh_size(obj)
        if size is not None:
            values.append(('input_size', size))
    if m.type in ('BOOLEAN', 'LATTICE'):
        other = getattr(m, 'object', None)
        values.append(('object', other.name if other is not None else ''))
    if m.type == 'SHRINKWRAP':
        # Shrinkwrap spells its pointer `target`; `object` does not exist
        # on it at all. With no target set the evaluated mesh is unchanged
        # and nothing is raised, so the panel has to be able to see that
        # the field is empty.
        other = getattr(m, 'target', None)
        values.append(('target', other.name if other is not None else ''))
    if m.type == 'NODES':
        # The row names the group whatever it is — a modifier the panel
        # dropped read as no modifier at all — and gives Smooth by Angle
        # its two settings.
        group = getattr(m, 'node_group', None)
        values.append(('group', group.name if group is not None else ''))
        if group is not None and group.name.startswith(SMOOTH_BY_ANGLE):
            for name, key in _SMOOTH_BY_ANGLE_INPUTS:
                try:
                    values.append((key, node_input(m, name)))
                except (KeyError, AttributeError, TypeError):
                    pass
    return ';'.join(k + '=' + _modifier_value(v) for k, v in values)


def _modifier_record(obj):
    """The object's modifier stack, as `kind=…;name=…;key=value` per entry.

    Every modifier Blender has on the object, in stack order. A kind the
    interface has no settings rows for is sent with its type, Blender's name
    for that type and the two switches, and gets a row with the controls
    every modifier has. It used to be skipped: measured on a cube with
    Multires, Weighted Normal, Edge Split, Laplacian Smooth and Subdivision,
    only the Subdivision reached the panel.

    Mirror's axis, bisect and flip triples, Boolean's and Lattice's other
    object and a Geometry Nodes modifier's group and inputs are special-cased
    because they are not plain scalars.

    One modifier whose settings cannot be read still gets its row, by kind
    and name: an error reading it used to drop the object's whole stack.
    """
    entries = []
    # Whether a modifier enabled in the viewport comes before this one, any
    # kind: while none does, a modifier's input is the object's own mesh.
    enabled_before = False
    for m in getattr(obj, 'modifiers', ()):
        first = not enabled_before
        enabled_before = enabled_before or bool(getattr(m, 'show_viewport', True))
        try:
            entries.append(_modifier_entry(obj, m, first))
        except (AttributeError, TypeError, ValueError, KeyError) as error:
            # `unread`: the Swift gives it the header's controls and no
            # settings, since a settings row here would show defaults
            # Blender does not hold. The header's two switches are read on
            # their own: without them the Swift's defaults lit both whatever
            # Blender held, and a tap sent the opposite of what it showed.
            print(f"[Blender Local] {obj.name}: modifier {m.name} could not be read: {error}")
            values = [('kind', m.type), ('name', m.name), ('type_label', _type_label(m)),
                      ('unread', True)]
            for key in _COMMON_FIELDS:
                try:
                    values.append((key, bool(getattr(m, key))))
                except (AttributeError, TypeError, ValueError):
                    pass
            entries.append(';'.join(k + '=' + _modifier_value(v) for k, v in values))
    return '|'.join(entries)


def _own_mesh_size(obj):
    """The largest dimension of the object's own mesh, which is what a Remesh
    with nothing enabled above it remeshes; None when that is not it.

    The Voxel Size row's floor is this over 256. It used to be taken from the
    mesh on screen, which is Blender's evaluated one — what the Remesh made:
    measured in 5.2.1, a 2 m cube at Voxel Size 2.0 evaluates to a 0.667 m
    cube, the floor fell to 0.0026, and committing it gave 3,548,168 vertices
    where 2/256 gives 396,296. Shape keys change the Remesh's input without
    changing these coordinates, so a keyed mesh has no answer here; nor does
    the simulator's stand-in, whose mesh already carries its stack.
    """
    data = getattr(obj, 'data', None)
    if (obj.type != 'MESH' or data is None or not _is_real_blender()
            or getattr(data, 'shape_keys', None) is not None):
        return None
    count = len(data.vertices)
    if count == 0:
        return None
    co = array('f', [0.0]) * (3 * count)
    data.vertices.foreach_get('co', co)
    return max(max(co[axis::3]) - min(co[axis::3]) for axis in range(3))


def _push_modifiers(obj):
    """Hand the interface the modifier stack Blender has for this object.

    Without this the Modifiers panel is blind on the real backend: it can add
    a modifier, and then never see it again.
    """
    push = getattr(_blenderkit, 'sync_modifiers', None)
    if push is None:
        return
    try:
        record = _modifier_record(obj)
    except (AttributeError, TypeError, ValueError) as error:
        print(f"[Blender Local] {obj.name} modifiers could not be read: {error}")
        return
    push(obj.name, record)


# ---------------------------------------------------------------------------
# What moves with what
#
# A drag leaves out of its snap targets every object that moves with what it
# moves, as Blender does (BA_SNAP_FIX_DEPS_FIASCO, transform_convert_object.cc),
# and its preview carries children along. Both need what each object depends
# on. Blender asks its depsgraph; Python has no view of the depsgraph's
# relations, so they are read from the pointers that make them: the parent,
# every Object or Collection pointer on a constraint, a modifier or the
# object's data (and one level into their collections, for a UV Project's
# projectors or an Armature constraint's targets), a Geometry Nodes modifier's
# inputs and the Object and Collection sockets of its node trees, drivers, and
# a collection instance. Held against Blender's own answer — what
# `depsgraph_update_post` reports updated when one object moves — for 28
# objects covering each of those in scripts/run-tools-blender-check.sh. It
# costs 2.8 µs an object, 5.6 with two modifiers, a constraint and a parent
# (1000 objects, desktop 5.2.1 on this Mac), in a pass that runs after every
# command.

# Per RNA struct: its Object pointers, its Collection pointers, and its
# collections whose items hold an Object pointer. Read once per type from
# bl_rna, so a pass costs attribute reads rather than a walk of RNA.
_POINTER_FIELDS = {}


def _pointer_fields(struct):
    rna = struct.bl_rna
    found = _POINTER_FIELDS.get(rna.identifier)
    if found is None:
        objects, collections, nested = [], [], []
        for prop in rna.properties:
            fixed = getattr(getattr(prop, 'fixed_type', None), 'identifier', '')
            if prop.type == 'POINTER':
                if fixed == 'Object':
                    objects.append(prop.identifier)
                elif fixed == 'Collection':
                    collections.append(prop.identifier)
            elif prop.type == 'COLLECTION' and prop.identifier != 'rna_type':
                item = getattr(prop, 'fixed_type', None)
                if item is not None and any(
                        p.type == 'POINTER'
                        and getattr(getattr(p, 'fixed_type', None), 'identifier', '') == 'Object'
                        for p in item.properties):
                    nested.append(prop.identifier)
        found = (tuple(objects), tuple(collections), tuple(nested))
        _POINTER_FIELDS[rna.identifier] = found
    return found


def _add_value(value, out):
    if isinstance(value, bpy.types.Object):
        out.add(value)
    elif isinstance(value, bpy.types.Collection):
        out.update(value.all_objects)


def _add_pointers(struct, out, depth=0):
    objects, collections, nested = _pointer_fields(struct)
    for name in objects + collections:
        _add_value(getattr(struct, name, None), out)
    if depth < 2:
        for name in nested:
            for item in getattr(struct, name, ()):
                _add_pointers(item, out, depth + 1)


def _add_node_tree(tree, out, seen):
    if tree is None or tree.name in seen:
        return
    seen.add(tree.name)
    for node in tree.nodes:
        for socket in node.inputs:
            if getattr(socket, 'type', '') in ('OBJECT', 'COLLECTION') and not socket.is_linked:
                _add_value(getattr(socket, 'default_value', None), out)
        _add_node_tree(getattr(node, 'node_tree', None), out, seen)


def _add_node_inputs(modifier, out):
    """A Geometry Nodes modifier's inputs. 5.2.1 keeps them on
    `modifier.properties.inputs`, whose RNA is built per node group (see
    `_node_input_slot`); Blender before it kept ID properties."""
    inputs = getattr(getattr(modifier, 'properties', None), 'inputs', None)
    if inputs is not None:
        for prop in inputs.bl_rna.properties:
            if prop.type == 'POINTER' and prop.identifier != 'rna_type':
                _add_value(getattr(getattr(inputs, prop.identifier, None), 'value', None), out)
        return
    try:
        keys = modifier.keys()
    except TypeError:
        return
    for key in keys:
        _add_value(modifier[key], out)


def _add_drivers(owner, out):
    for curve in getattr(getattr(owner, 'animation_data', None), 'drivers', None) or ():
        for variable in curve.driver.variables:
            for target in variable.targets:
                _add_value(target.id, out)


def _relations(obj):
    """(parent name or '', sorted names of the objects `obj` depends on)."""
    found = set()
    if obj.parent is not None:
        found.add(obj.parent)
    for constraint in getattr(obj, 'constraints', ()):
        _add_pointers(constraint, found)
    for modifier in getattr(obj, 'modifiers', ()):
        _add_pointers(modifier, found)
        if modifier.type == 'NODES':
            _add_node_inputs(modifier, found)
            _add_node_tree(getattr(modifier, 'node_group', None), found, set())
    _add_drivers(obj, found)
    data = getattr(obj, 'data', None)
    if data is not None:
        _add_pointers(data, found)
        _add_drivers(data, found)
        _add_drivers(getattr(data, 'shape_keys', None), found)
    if getattr(obj, 'instance_type', '') == 'COLLECTION':
        _add_value(getattr(obj, 'instance_collection', None), found)
    found.discard(obj)
    return (obj.parent.name if obj.parent is not None else '',
            sorted(o.name for o in found))


def _push_relations(obj):
    """Hand the interface what `obj` moves with. Only for an object that has
    something: one that is not described has no parent and depends on nothing,
    which is what the interface assumes."""
    push = getattr(_blenderkit, 'sync_relations', None)
    if push is None or not _is_real_blender():
        return
    try:
        parent, names = _relations(obj)
    except (AttributeError, TypeError, ValueError, RuntimeError) as error:
        # Leaving it out makes the object a snap target that may move with the
        # drag; taking the pass down with it would leave the viewport stale.
        print(f"[Blender Local] {obj.name} relations could not be read: {error}")
        return
    if parent or names:
        push(obj.name, parent, names)


# ---------------------------------------------------------------------------
# The object's own channels, for Object ▸ Apply
#
# `matrix_world` is pushed with every object, but Apply bakes the *local*
# channels, and the two part ways under a parent, a negative scale, a delta or
# a rotation mode other than Euler (LocalTransform in ObjectTransformState.swift
# has the measurements). These are read from RNA the way `BKE_object_to_mat4`
# composes `matrix_basis`, in plain Python so the simulator's shim — whose
# mathutils has no quaternion product — runs the same code.


def _quaternion_product(a, b):
    """a @ b: turn by b, then by a."""
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw)


def _euler_quaternion(angles, order):
    """`eulO_to_quat`: the first axis the order names turns first."""
    q = (1.0, 0.0, 0.0, 0.0)
    for axis in order:
        i = 'XYZ'.index(axis)
        half = float(angles[i]) * 0.5
        turn = [math.cos(half), 0.0, 0.0, 0.0]
        turn[1 + i] = math.sin(half)
        q = _quaternion_product(tuple(turn), q)
    return q


def _unit_quaternion(q):
    """`normalize_qt`, which Blender applies before building the matrix.

    A zero quaternion comes out as a half turn about X, not as no turn:
    measured in 5.2.1, rotation_quaternion (0,0,0,0) gave a matrix_basis of
    diag(1,-1,-1)."""
    q = tuple(float(c) for c in q)
    length = math.sqrt(sum(c * c for c in q))
    if length == 0.0:
        return (0.0, 1.0, 0.0, 0.0)
    return tuple(c / length for c in q)


def local_transform(obj):
    """What `transform_apply` bakes: location, rotation as (w, x, y, z), scale.

    Each with its delta folded in, because Apply bakes the delta and resets it
    (measured: delta_scale (2,1,1) under a scale of 1 doubled every vertex's X
    and came back as 1). The rotation is the delta's turn after the object's
    own — `BKE_object_rot_to_mat3` multiplies dmat @ rmat. AXIS_ANGLE has a
    delta in DNA that RNA does not expose, so there is none to read."""
    location = [float(a) + float(b) for a, b in
                zip(obj.location, getattr(obj, 'delta_location', (0.0, 0.0, 0.0)))]
    scale = [float(a) * float(b) for a, b in
             zip(obj.scale, getattr(obj, 'delta_scale', (1.0, 1.0, 1.0)))]
    mode = getattr(obj, 'rotation_mode', 'XYZ')
    if mode == 'QUATERNION':
        rotation = _quaternion_product(
            _unit_quaternion(getattr(obj, 'delta_rotation_quaternion', (1.0, 0.0, 0.0, 0.0))),
            _unit_quaternion(obj.rotation_quaternion))
    elif mode == 'AXIS_ANGLE':
        angle, x, y, z = (float(c) for c in obj.rotation_axis_angle)
        length = math.sqrt(x * x + y * y + z * z)
        if length == 0.0:
            # `axis_angle_to_mat3` gives the identity for a zero axis (measured).
            rotation = (1.0, 0.0, 0.0, 0.0)
        else:
            s = math.sin(angle * 0.5) / length
            rotation = (math.cos(angle * 0.5), x * s, y * s, z * s)
    else:
        rotation = _quaternion_product(
            _euler_quaternion(tuple(getattr(obj, 'delta_rotation_euler', (0.0, 0.0, 0.0))), mode),
            _euler_quaternion(tuple(obj.rotation_euler), mode))
    return location + list(rotation) + scale


# The rotation modes in the order `sync_channels` numbers them: the six Euler
# orders, then QUATERNION (6) and AXIS_ANGLE (7).
_ROTATION_MODES = ('XYZ', 'XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX', 'QUATERNION', 'AXIS_ANGLE')


def field_channels(obj):
    """What Blender's Transform fields show: `location`, the rotation mode,
    the rotation in that mode's own property, `scale` — each without its
    delta, eleven numbers.

    Not `local_transform`, which folds the deltas in for Apply, and not
    `matrix_world`, which the fields used to show: measured in 5.2.1, a cube
    parented to another that was then moved 2 in X and turned 90° about Z sits
    at world (-1, 0, 0) while its `location` is (0, 3, 0) — and the field
    writes `location`, so a nudge of 0.01 in Z sent it 3.16 m away.

    The simulator's stand-in stores every rotation as XYZ Euler whatever mode
    a script named, and only `rotation_euler` takes a component write there,
    so that is what its fields show and write."""
    mode = getattr(obj, 'rotation_mode', 'XYZ') if _is_real_blender() else 'XYZ'
    if mode == 'QUATERNION':
        rotation = [float(c) for c in obj.rotation_quaternion]
    elif mode == 'AXIS_ANGLE':
        rotation = [float(c) for c in obj.rotation_axis_angle]
    else:
        rotation = [float(c) for c in obj.rotation_euler] + [0.0]
    return ([float(c) for c in obj.location] + [float(_ROTATION_MODES.index(mode))]
            + rotation + [float(c) for c in obj.scale])


def _push_fields(obj):
    """Hand the Transform fields the channels they show and write. Like
    `push_local`, a failure leaves those fields saying they cannot show the
    object rather than take the pass or the frame down with it."""
    push = getattr(_blenderkit, 'sync_channels', None)
    if push is None:
        return
    try:
        values = field_channels(obj)
    except (AttributeError, TypeError, ValueError) as error:
        print(f"[Blender Local] {obj.name} transform fields could not be read: {error}")
        return
    try:
        push(obj.name, array('d', values).tobytes())
    except ValueError as error:
        print(f"[Blender Local] {obj.name} transform fields were not taken: {error}")


def push_local(obj):
    """Hand the interface the channels Apply would bake, and the ones the
    Transform fields show (`field_channels`).

    From a mirroring pass it describes the object just pushed; from a frame
    change (`_blenderkit_anim.push_frame`) it updates the one on screen,
    because a keyed channel moves with the playhead. Reading the channels cost
    3.6 µs an object in desktop Blender 5.2.1 on this Mac (1000 empties);
    `field_channels` adds 2.4 µs (measured the same way, 2026-10-01)."""
    _push_fields(obj)
    push = getattr(_blenderkit, 'sync_local', None)
    if push is None:
        return
    try:
        values = local_transform(obj)
    except (AttributeError, TypeError, ValueError) as error:
        # Without it the interface cannot tell what Apply would bake, and
        # offers every row rather than grey one out on a guess.
        print(f"[Blender Local] {obj.name} transform channels could not be read: {error}")
        return
    try:
        push(obj.name, array('d', values).tobytes())
    except ValueError as error:
        # The channels only inform the Apply menu, which offers every row for
        # an object that arrives without them. Raised out of a frame change
        # this cost the frame — `push_frame` never reached `anim_frame`, so the
        # timeline stopped a frame behind Blender (measured in 5.2.1) — and
        # out of a pass it would cost the whole pass.
        print(f"[Blender Local] {obj.name} transform channels were not taken: {error}")


def _push_display(obj):
    """Hand the viewport what a camera, light or empty is drawn from.

    Called for every object pushed without a surface, and a no-op for the ones
    that are not these three. A setting that cannot be read leaves that object
    undrawn and says why, rather than taking the whole pass down with it.
    """
    push = getattr(_blenderkit, 'sync_display', None)
    if push is None:
        return
    try:
        found = _display_record(obj)
    except (AttributeError, TypeError, ValueError) as error:
        print(f"[Blender Local] {obj.name} cannot be drawn: {error}")
        return
    if found is not None:
        push(obj.name, obj.type, found[0], found[1])

# The native UI reads RNA from the running build, so new backend features do
# not need a second hand-maintained catalogue in Swift.
import ast
import json
import inspect


def resolve(path):
    """Resolve a bpy data path without evaluating calls or arbitrary code."""
    def visit(node):
        if isinstance(node, ast.Name) and node.id == 'bpy':
            return bpy
        if isinstance(node, ast.Attribute) and not node.attr.startswith('_'):
            return getattr(visit(node.value), node.attr)
        if isinstance(node, ast.Subscript):
            key = ast.literal_eval(node.slice)
            if not isinstance(key, (str, int)):
                raise ValueError('Use a name or index in brackets')
            return visit(node.value)[key]
        raise ValueError('Use a bpy path with attributes and named or numeric indices')
    return visit(ast.parse(path, mode='eval').body)


def property_info(prop, owner=None):
    kind = prop.type
    value = getattr(owner, prop.identifier) if owner is not None else getattr(prop, 'default', None)
    if getattr(prop, 'is_array', False):
        value = list(value) if owner is not None else list(prop.default_array)
    elif isinstance(value, set):
        value = sorted(value)
    pointer_value = value
    if kind not in {'BOOLEAN', 'INT', 'FLOAT', 'STRING', 'ENUM'}:
        value = None
    options = []
    if kind == 'ENUM':
        try:
            options = [{'id': i.identifier, 'name': i.name} for i in prop.enum_items if i.identifier]
        except Exception:
            pass
    if kind == 'POINTER' and not prop.is_readonly:
        # Choices are actual datablocks; labels remain human-readable.
        for collection_prop in bpy.data.bl_rna.properties:
            if collection_prop.type != 'COLLECTION':
                continue
            if collection_prop.fixed_type.identifier != prop.fixed_type.identifier:
                continue
            collection_path = 'bpy.data.' + collection_prop.identifier
            for item in getattr(bpy.data, collection_prop.identifier):
                item_path = collection_path + '[' + repr(item.name) + ']'
                options.append(dict(id=item_path, name=item.name))
                if item == pointer_value:
                    value = item_path
            break
    return dict(id=prop.identifier, name=prop.name, description=prop.description,
                kind=kind, value=json.dumps(value), options=options,
                editable=not prop.is_readonly and kind in {'BOOLEAN', 'INT', 'FLOAT', 'STRING', 'ENUM', 'POINTER'},
                array=bool(getattr(prop, 'is_array', False)),
                enumFlag=bool(getattr(prop, 'is_enum_flag', False)))


def operator_info(path):
    op = resolve('bpy.ops.' + path)
    rna = op.get_rna_type()
    # Asked in the mode run_operator will run it in. When that is not the
    # mode Blender is in, the poll cannot be asked without switching, and a
    # read must not switch modes (each switch is an undo step and a mesh
    # conversion), so the form says where it will run and Blender's poll is
    # asked there when Run is pressed.
    target, current = _operator_target(path)
    try:
        available = True if target is not None else bool(op.poll())
    except Exception:
        available = False
    refused = _UNSAFE_OPERATORS.get(path)
    if refused is not None:
        available, target = False, None
    props = []
    for p in rna.properties:
        if p.identifier == 'rna_type' or p.is_hidden:
            continue
        try:
            props.append(property_info(p))
        except Exception:
            continue
    return dict(title=rna.name, description=rna.description, available=available,
                properties=props, children=[],
                mode=_MODE_NAMES.get(target) if target is not None else None,
                currentMode=_MODE_NAMES.get(current, current.title()),
                refused=refused)


# The operator search runs any operator by name, and its code starts with an
# import, so BpyModeGuard (which brackets a bare `bpy.ops.` line) never saw
# it: the operator ran in whatever mode Blender was left in, checked by its
# poll alone. Measured in the app and in desktop 5.2.1, poll is not enough:
# object.multires_base_apply and object.multires_unsubdivide pass it in Edit
# Mode and there both segfault (multires_reshape_create_subdiv). Apply Base
# passes it in Sculpt Mode too, where it runs (FINISHED) with an undo stack and
# segfaults without one, in sculpt_paint::undo::push_begin_ex (desktop 5.2.1,
# a cube at one Multires level, gpu.init; round 3's review measured the first
# half). The app makes its undo stack at start, but a file load drops it until
# the next push. So the search takes the menus' rule —
# object.* in Object Mode, mesh.* and uv.* in Edit Mode, adds in Object Mode —
# and puts the mode back.
#
# Left alone: the object.* operators that set the mode themselves (all five
# with "mode" in their name in 5.2.1), which the rule would undo.
_MODE_CHANGERS = frozenset(('object.mode_set', 'object.mode_set_with_submode',
                            'object.editmode_toggle', 'object.posemode_toggle',
                            'object.transfer_mode'))
# object.* operators that only work on the mesh being edited: in desktop
# 5.2.1 each fails its poll in Object Mode and passes it in Edit Mode, on a
# cube and on a cube with a vertex group, hooks and a Skin modifier. From Edit
# Mode they run there. Each was run from Edit Mode with its defaults through
# run_operator on those fixtures without a crash (run-opsearch-blender-check.sh).
# Any other operator that the rule's mode refuses is refused, not tried in
# the mode the user was in, because that is where the crashes above are.
_EDIT_MODE_OBJECT_OPS = frozenset((
    'object.hook_add_newob', 'object.hook_add_selob', 'object.hook_assign',
    'object.hook_recenter', 'object.hook_remove', 'object.hook_reset',
    'object.hook_select', 'object.skin_loose_mark_clear',
    'object.skin_radii_equalize', 'object.skin_root_mark',
    'object.vertex_group_assign', 'object.vertex_group_assign_new',
    'object.vertex_group_deselect', 'object.vertex_group_remove_from',
    'object.vertex_group_select', 'object.vertex_group_smooth',
    'object.vertex_parent_set', 'object.vertex_weight_copy',
    'object.vertex_weight_delete', 'object.vertex_weight_normalize_active_vertex',
    'object.vertex_weight_paste', 'object.vertex_weight_set_active'))
# Operators that pass their poll in the app's context and then take Blender
# down, so the search refuses them by name. Found by run-opsearch-blender-
# check.sh, which runs every operator the search lists with its defaults
# through run_operator in desktop 5.2.1 with the app's context (undo stack,
# gpu.init, no editor override): object.*, mesh.* and uv.* on three fixtures
# from Object, Edit, Sculpt and Texture Paint, every other module on a cube
# from the same four — 13,852 runs. These two were the only ones to crash or
# hang, from every mode and fixture (in Edit Mode, where the rule runs them).
_UNSAFE_OPERATORS = {
    'uv.stitch': ("uv.stitch works inside Blender's UV Editor, which this app does not "
                  "have; without one Blender crashes as the operator finishes "
                  "(a segfault in stitch_exit, measured in Blender 5.2.1)."),
    'uv.select_edge_ring': ("uv.select_edge_ring picks the ring under the mouse in Blender's "
                            "UV Editor, which this app does not have; without one Blender "
                            "never returns from it (measured in Blender 5.2.1). Use Select "
                            "▸ Select Edge Rings in the 3D View."),
}
_MODE_NAMES = {'OBJECT': 'Object Mode', 'EDIT': 'Edit Mode', 'SCULPT': 'Sculpt Mode',
               'TEXTURE_PAINT': 'Texture Paint', 'VERTEX_PAINT': 'Vertex Paint',
               'WEIGHT_PAINT': 'Weight Paint', 'POSE': 'Pose Mode'}


def operator_mode(path):
    """The Blender mode the operator search runs `path` in, or None to run it
    where Blender is. The same rule as `BpyModeGuard.requiredMode`."""
    if path in _MODE_CHANGERS:
        return None
    if path.startswith('mesh.primitive_'):
        return 'OBJECT'
    if path.startswith('mesh.') or path.startswith('uv.'):
        return 'EDIT'
    if path.startswith('object.'):
        return 'OBJECT'
    return None


def _current_mode():
    active = bpy.context.view_layer.objects.active
    return getattr(active, 'mode', 'OBJECT') if active is not None else 'OBJECT'


def _operator_target(path):
    """(the mode run_operator switches to or None, the mode Blender is in)."""
    current = _current_mode()
    mode = operator_mode(path)
    if mode == current:
        mode = None
    elif mode == 'OBJECT' and current == 'EDIT' and path in _EDIT_MODE_OBJECT_OPS:
        mode = None
    return mode, current


def _set_mode(mode):
    """mode_set, reporting whether Blender is in `mode` afterwards."""
    try:
        bpy.ops.object.mode_set(mode=mode)
    except Exception as error:
        return str(error).strip()
    if _current_mode() != mode:
        return 'Blender stayed in ' + _MODE_NAMES.get(_current_mode(), _current_mode())
    return None


def run_operator(path, values):
    if path in _UNSAFE_OPERATORS:
        raise RuntimeError(_UNSAFE_OPERATORS[path])
    op = resolve('bpy.ops.' + path)
    target, previous = _operator_target(path)
    where = _MODE_NAMES.get(target or previous, target or previous)
    if target is not None:
        why = _set_mode(target)
        if why is not None:
            # Never run it where Blender was instead: that is the mode the
            # rule exists to keep it out of.
            if _current_mode() != previous:
                _set_mode(previous)
            raise RuntimeError(path + ' was not run: it runs in ' + where
                               + ', and Blender could not switch to it (' + why + ').')
    try:
        if not op.poll():
            raise RuntimeError(path + ' needs a different selection or Blender editor context'
                               + (' in ' + where if target is not None else '')
                               + '. Blender checked and refused it.')
        properties = op.get_rna_type().properties
        for key, value in values.items():
            if properties[key].type == 'ENUM' and properties[key].is_enum_flag:
                values[key] = set(value)
        if path == 'object.multires_subdivide':
            # The Modifiers panel's budget, whichever way Subdivide is reached:
            # each one is four times the mesh (_blenderkit_multires).
            _multires_budget(values.get('modifier', ''))
        elif path == 'object.subdivision_set':
            # Blender's Subdivision Set calls Multires Subdivide once per
            # missing level, inside one operator, so the check above never
            # saw it: level 7 from the search went to 196 times the budget
            # (round 3's review). Priced the way the operator decides.
            import _blenderkit_multires
            _blenderkit_multires.refuse_subdivision_set(**values)
        elif path == 'object.voxel_remesh':
            # The Sculpt header's Remesh had the budget and this had none:
            # OpenVDB is asked for the whole surface at once.
            import _blenderkit_sculpt
            _blenderkit_sculpt.refuse_voxel_remesh(bpy.context.view_layer.objects.active)
        if path == 'object.shade_auto_smooth':
            # The 3D View's row says why it fails without Blender's Essentials
            # library, which the device's bpy does not ship; the search used
            # to pass Blender's 'No asset found at path ""' on bare (round 2's
            # review).
            try:
                import _blenderkit_context
                guard = _blenderkit_context.needs_essentials(
                    'Shade Auto Smooth', 'Shade Smooth by Angle does the same once, without a modifier.')
            except ImportError:
                guard = None
            if guard is not None:
                with guard:
                    result = op('EXEC_DEFAULT', **values)
            else:
                result = op('EXEC_DEFAULT', **values)
        else:
            result = op('EXEC_DEFAULT', **values)
        if 'FINISHED' not in result:
            raise RuntimeError(path + ' returned ' + repr(result) + '; no completed operation')
        return sorted(result)
    finally:
        # Back to the mode it found, as BpyModeGuard does — on the object that
        # is active now (Duplicate makes its copy active). An operator that
        # deleted the object leaves no mode to go back to.
        if target is not None and _current_mode() != previous:
            if bpy.context.view_layer.objects.active is not None:
                why = _set_mode(previous)
                if why is not None:
                    print('[Blender Local] ' + path + ' left Blender in '
                          + _MODE_NAMES.get(_current_mode(), _current_mode())
                          + ': ' + why)


def _multires_budget(name):
    """Refuses, in words, a Multires Subdivide whose new level would pass
    `_blenderkit_multires.BUDGET` or the memory left."""
    obj = bpy.context.view_layer.objects.active
    if obj is None or obj.type != 'MESH':
        return
    modifier = obj.modifiers.get(name) if name else None
    if modifier is None:
        modifier = next((m for m in obj.modifiers if m.type == 'MULTIRES'), None)
    if modifier is None or modifier.type != 'MULTIRES':
        return
    import _blenderkit_multires
    _blenderkit_multires.refuse_over_budget(obj, modifier.total_levels, 'Multires Subdivide')


def inspect_data(path):
    obj = resolve(path)
    props, children = [], []
    if hasattr(obj, 'bl_rna') and not type(obj).__name__.startswith('bpy_prop_collection'):
        for p in obj.bl_rna.properties:
            if p.identifier == 'rna_type' or p.is_hidden:
                continue
            try:
                if p.type in {'POINTER', 'COLLECTION'}:
                    value = getattr(obj, p.identifier)
                    if p.type == 'POINTER' and not p.is_readonly:
                        props.append(property_info(p, obj))
                    if value is not None:
                        children.append(dict(name=p.name, path=path + '.' + p.identifier))
                else:
                    props.append(property_info(p, obj))
            except Exception:
                continue
    elif hasattr(obj, '__iter__'):
        for index, item in enumerate(obj):
            if index >= 500:
                break
            name = getattr(item, 'name', str(index))
            # Numeric keys also work for collections whose items have duplicate names.
            children.append(dict(name=name, path=path + '[' + str(index) + ']'))
    return dict(title=getattr(obj, 'name', path), description=path,
                available=True, properties=props, children=children)


def set_property(path, key, value):
    obj = resolve(path)
    prop = obj.bl_rna.properties[key]
    if prop.is_readonly:
        raise ValueError(key + ' is read-only')
    if prop.type == 'ENUM' and prop.is_enum_flag:
        value = set(value)
    if prop.type == 'POINTER' and value is not None:
        value = resolve(value)
    if isinstance(obj, bpy.types.Modifier) and isinstance(obj.id_data, bpy.types.Object):
        # A Subdivision or Multires level, or an Array count, typed here would
        # skip the budget the modifier rows keep (_blenderkit_multires).
        import _blenderkit_multires
        _blenderkit_multires.check_setting(obj.name, key, value, obj.id_data)
    setattr(obj, key, value)
    bpy.context.view_layer.update()


def assist(source, path=''):
    """Parse, never execute, the draft. Documentation is from installed bpy."""
    messages = []
    try:
        compile(source, '<editor>', 'exec', ast.PyCF_ONLY_AST)
        messages.append('Syntax is valid. The draft has not been executed.')
    except SyntaxError as error:
        messages.append(f'Line {error.lineno}, column {error.offset}: {error.msg}')
    if path:
        try:
            obj = resolve(path)
            if path.startswith('bpy.ops.'):
                info = operator_info(path[len('bpy.ops.'):])
                messages.append(info['title'] + '\n' + info['description'])
                messages.append('Available in current context: ' + str(info['available']))
                for prop in info['properties']:
                    messages.append(prop['id'] + ' = ' + prop['value'] + '\n' + prop['description'])
            else:
                try:
                    messages.append(str(inspect.signature(obj)))
                except (ValueError, TypeError):
                    pass
                messages.append((inspect.getdoc(obj) or 'No documentation available.')[:16000])
        except Exception as error:
            messages.append(str(error))
    return '\n\n'.join(messages)

# Full .blend checkpoints preserve data that a viewport snapshot cannot carry:
# node graphs, animation, collections, simulation settings and custom meshes.
_history = []
_history_index = -1
_history_root = None


def history_state():
    return dict(undo=_history_index > 0, redo=_history_index + 1 < len(_history))


def checkpoint(root, label, replace=False):
    import os
    import uuid
    import shutil
    global _history_index, _history_root
    os.makedirs(root, exist_ok=True)
    _history_root = root
    for obj in bpy.context.objects_in_mode:
        if obj.type == 'MESH':
            obj.update_from_editmode()
    target = os.path.join(root, str(uuid.uuid4()) + '.blend')
    result = bpy.ops.wm.save_as_mainfile(filepath=target, copy=True, compress=False, check_existing=False)
    if 'FINISHED' not in result or not os.path.isfile(target):
        raise RuntimeError('Blender could not write the undo checkpoint')
    cut = _history_index if replace and _history_index >= 0 else _history_index + 1
    removed = _history[cut:]
    del _history[cut:]
    _history.append((label, target))
    while len(_history) > 2 and (len(_history) > 12 or
            sum(os.path.getsize(item[1]) for item in _history) > 512 * 1024 * 1024):
        removed.append(_history.pop(0))
    _history_index = len(_history) - 1
    for _, old in removed:
        if os.path.isfile(old):
            os.remove(old)
    # Replace only after a complete write, so interrupted saves retain recovery.
    _publish_autosave(target, os.path.join(os.path.dirname(root), 'autosave.blend'))
    return history_state()


def _publish_autosave(source, autosave):
    """Make `source` the file the app recovers from on launch.

    A hard link, not a copy: every undo step used to write the whole scene
    twice — the checkpoint, then a byte-for-byte copy of it — and on a heavy
    scene that second write was as slow as the first. The checkpoint is never
    written again once saved, and removing it from the history leaves a linked
    autosave intact. Where links are not supported the copy still happens.
    """
    import os
    import shutil
    partial = autosave + '.partial'
    try:
        if os.path.lexists(partial):
            os.remove(partial)
        os.link(source, partial)
    except OSError:
        shutil.copyfile(source, partial)
    os.replace(partial, autosave)


def history_step(direction):
    global _history_index
    target = _history_index + direction
    if not 0 <= target < len(_history):
        return history_state()
    result = bpy.ops.wm.open_mainfile(filepath=_history[target][1], load_ui=False)
    if 'FINISHED' not in result:
        raise RuntimeError('Blender could not restore the checkpoint')
    _history_index = target
    # Existing Python variables pointing at old datablocks must be reacquired.
    import os
    _publish_autosave(_history[target][1],
                      os.path.join(os.path.dirname(_history_root), 'autosave.blend'))
    return history_state()


def complete_source(source, path):
    """Infer bpy aliases from assignments/imports without executing the draft."""
    aliases = {'bpy': 'bpy', 'C': 'bpy.context', 'D': 'bpy.data'}
    # Incomplete current lines are normal while typing. Keep the valid prefix.
    lines = source.splitlines()
    tree = None
    for _ in range(min(len(lines) + 1, 20)):
        try:
            tree = ast.parse('\n'.join(lines))
            break
        except SyntaxError as error:
            lines = lines[:max(0, (error.lineno or len(lines)) - 1)]
    def expand(node):
        if isinstance(node, ast.Name):
            return aliases.get(node.id)
        if isinstance(node, ast.Attribute):
            base = expand(node.value)
            return base + '.' + node.attr if base and not node.attr.startswith('_') else None
        if isinstance(node, ast.Subscript):
            base = expand(node.value)
            try:
                key = ast.literal_eval(node.slice)
                if base and isinstance(key, (str, int)):
                    return base + '[' + repr(key) + ']'
            except (ValueError, TypeError):
                pass
        return None
    if tree:
        # Only straight-line module assignments: never guess the outcome of
        # an unexecuted branch, function, loop, or factory call.
        for node in tree.body:
            if isinstance(node, ast.Import):
                for item in node.names:
                    if item.name == 'bpy':
                        aliases[item.asname or 'bpy'] = 'bpy'
            elif isinstance(node, ast.ImportFrom) and node.module == 'bpy':
                for item in node.names:
                    if item.name != '*':
                        aliases[item.asname or item.name] = 'bpy.' + item.name
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                value = expand(node.value)
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Name):
                        aliases.pop(target.id, None)
                        if value:
                            aliases[target.id] = value
    if not path:
        return [{'name': name, 'callable': False} for name in sorted(aliases)]
    try:
        expanded = expand(ast.parse(path, mode='eval').body)
        if not expanded:
            return []
        obj = resolve(expanded)
        return [{'name': name, 'callable': callable(getattr(obj, name, None))}
                for name in dir(obj) if not name.startswith('_')]
    except Exception:
        return []


def editor_metadata():
    """One snapshot for Monaco; editing never invokes the interpreter."""
    result = {'members': {}, 'operators': {}}
    for path in ('bpy', 'bpy.context', 'bpy.context.scene', 'bpy.context.object',
                 'bpy.data', 'bpy.types', 'bpy.context.scene.render'):
        try:
            obj = resolve(path)
            result['members'][path] = [n for n in dir(obj) if not n.startswith('_')]
        except (AttributeError, ValueError):
            pass
    for module in dir(bpy.ops):
        if module.startswith('_'):
            continue
        namespace = getattr(bpy.ops, module)
        for name in dir(namespace):
            if name.startswith('_'):
                continue
            op = getattr(namespace, name)
            if not callable(op):
                continue
            info = {'description': '', 'parameters': []}
            if hasattr(op, 'get_rna_type'):
                try:
                    rna = op.get_rna_type()
                    info['description'] = rna.description
                    info['parameters'] = [p.identifier for p in rna.properties
                                          if p.identifier != 'rna_type']
                except (AttributeError, RuntimeError):
                    pass
            result['operators']['bpy.ops.' + module + '.' + name] = info
    return result


def _report_animation():
    """Blender's frame range, rate, keying settings and keys, for the timeline.
    See _blenderkit_anim.report; a bridge without the animation calls — an
    older build, or a test's stand-in — gets nothing."""
    if hasattr(_blenderkit, 'anim_state'):
        import _blenderkit_anim
        _blenderkit_anim.report()


def _report_tools():
    """Snapping, the pivot point, proportional editing and the 3D cursor, for
    the header and the N-panel. See _blenderkit_tools.report.

    Only from the full pass. `sync_selection`, the tap path, deliberately skips
    it: a tap cannot change a tool setting, and not doing the full pass is what
    that path exists for."""
    if hasattr(_blenderkit, 'tool_state'):
        import _blenderkit_tools
        _blenderkit_tools.report()
