"""The UV Editor's UV menu, run the way Blender's own menu runs it.

Blender's UV operators act on the edited mesh's selected faces, and every one
the menu offers except Lightmap Pack refuses outside Edit Mode ("poll() failed,
context is incorrect", measured in 5.2.1). The app's UV Editor is open in object
mode too, where there is no selection on screen to honour, so from there the
whole mesh is unwrapped and each mesh's stored selection is put back after:
Edit Mode comes back exactly as it was left. In Edit Mode the operator acts on
the selection, as in Blender.

Two things Blender's menu gets from its window are supplied here:

- Blender's own menu does nothing, silently, with no face selected: every
  unwrap returned FINISHED having moved no UV, and Pack Islands CANCELLED. A
  control that visibly does nothing reads as broken, so that is refused in
  words.
- Follow Active Quads follows the active face, which a click in the viewport
  sets. The app's taps hand Blender a selection and no active element, so the
  operator answered "No active face" every time. With none, the lowest-numbered
  selected quad is made active — the face a desktop user would have had to
  click, chosen the same way each time.

- An unwrap that solves no island is refused, and the UVs are put back.
  Blender answers FINISHED and only warns "Unwrap failed to solve N of N
  island(s), edge seams may need to be added" — on the default cube and on a
  UV sphere with no seams, all three unwrap methods, the first thing a new
  user tries (5.2.1, measured). What it leaves is the old map packed back into
  the square (a sphere's scaled by 0.9998), not an unwrap. The warning is
  written to Python's stdout (`BPy_reports_write_stdout`), where it is read
  here. When some islands were solved the result stands and the warning goes
  on to the console, where the bridge shows it as a report.

In the simulator the stand-in's operators run as they are.
"""

import contextlib
import io
import re
import sys
from array import array

import bpy

# The rows that work on an existing map. On a mesh with none, three fail
# their poll ("context is incorrect", which names neither the map nor what to
# do) and Follow Active Quads says "No UV layers" (5.2.1, measured from
# Object and Edit Mode on a cube with its map removed); the projections and
# unwraps make one.
_NEEDS_MAP = {'follow_active_quads', 'pack_islands', 'average_islands_scale', 'seams_from_islands'}

# Blender's report, `uvedit_unwrap_exec`'s RPT_WARNING.
_UNSOLVED = re.compile(r"Unwrap failed to solve (\d+) of (\d+) island")
_UNWRAPS = {'unwrap'}

_LABELS = {
    'unwrap': 'Unwrap',
    'smart_project': 'Smart UV Project',
    'lightmap_pack': 'Lightmap Pack',
    'follow_active_quads': 'Follow Active Quads',
    'cube_project': 'Cube Projection',
    'cylinder_project': 'Cylinder Projection',
    'sphere_project': 'Sphere Projection',
    'pack_islands': 'Pack Islands',
    'average_islands_scale': 'Average Islands Scale',
    'seams_from_islands': 'Seams from Islands',
    'reset': 'Reset',
}


def _is_real_blender():
    """Blender's operators carry their RNA; the shim's are plain methods."""
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _selection(mesh):
    """A mesh's stored selection, read in object mode: vertices, edges, faces."""
    out = []
    for elements in (mesh.vertices, mesh.edges, mesh.polygons):
        flags = array('b', [0]) * len(elements)
        elements.foreach_get('select', flags)
        out.append(flags)
    return out


def _restore(mesh, saved):
    for elements, flags in zip((mesh.vertices, mesh.edges, mesh.polygons), saved):
        if len(elements) == len(flags):
            elements.foreach_set('select', flags)
    mesh.update()


def _edited(active):
    """The meshes Edit Mode will open: the active object and every selected
    mesh with it, as Blender's multi-object editing does."""
    layer = bpy.context.view_layer
    meshes = {active.data.name: active.data}
    for obj in layer.objects:
        if obj.type == 'MESH' and obj.select_get():
            meshes.setdefault(obj.data.name, obj.data)
    return list(meshes.values())


def _faces_selected():
    """Whether any mesh being edited has a face selected — Edit Mode spans
    every selected mesh, and the operators act on all of them."""
    return any(obj.data.total_face_sel for obj in bpy.context.view_layer.objects
               if obj.type == 'MESH' and obj.mode == 'EDIT')


def _make_quad_active(active):
    import bmesh
    bm = bmesh.from_edit_mesh(active.data)
    current = bm.faces.active
    if current is not None and current.select and len(current.verts) == 4:
        return
    quad = next((f for f in bm.faces if f.select and len(f.verts) == 4), None)
    if quad is None:
        raise RuntimeError("Follow Active Quads: no quad is selected on " + active.name)
    bm.faces.active = quad


def _active_uvs(meshes):
    """Each mesh's maps by name and its active one's UVs, read in object
    mode, to put back."""
    out = []
    for mesh in meshes:
        names = [layer.name for layer in mesh.uv_layers]
        layer = mesh.uv_layers.active
        values = None
        if layer is not None:
            values = array('f', [0.0]) * (2 * len(mesh.loops))
            layer.uv.foreach_get('vector', values)
        out.append((mesh, names, layer.name if layer is not None else None, values))
    return out


def _put_back(saved):
    for mesh, names, name, values in saved:
        # An unwrap makes a map on a mesh that had none (5.2.1, measured):
        # "left as they were" has to take it away again.
        for layer in [l for l in mesh.uv_layers if l.name not in names]:
            mesh.uv_layers.remove(layer)
        layer = mesh.uv_layers.get(name) if name is not None else None
        if layer is not None and values is not None and len(layer.uv) * 2 == len(values):
            layer.uv.foreach_set('vector', values)
        mesh.update()


def _unsolved(text):
    """(failed, total) from Blender's unwrap warning, or None."""
    found = _UNSOLVED.search(text)
    return (int(found.group(1)), int(found.group(2))) if found else None


def run(name, **props):
    """Run `bpy.ops.uv.<name>(**props)` for the UV Editor's UV menu."""
    label = _LABELS.get(name)
    if label is None:
        raise ValueError("not a UV menu operator: " + name)
    operator = getattr(bpy.ops.uv, name)
    if not _is_real_blender():
        return operator(**props)

    active = bpy.context.view_layer.objects.active
    if active is None or active.type != 'MESH':
        raise RuntimeError(label + ": the active object is not a mesh")
    if name in _NEEDS_MAP and len(active.data.uv_layers) == 0:
        raise RuntimeError(label + ": " + active.name + " has no UV map to work on. Unwrap it first "
                           "(UV ▸ Unwrap, or Smart UV Project).")
    before = active.mode
    whole = before != 'EDIT'
    saved = []
    # The maps as they were, for an unwrap that solves nothing. From object
    # mode they are read off the meshes; in Edit Mode a mesh's arrays read
    # empty (foreach_get: "needed 0", measured in 5.2.1), so each edited
    # BMesh is copied instead, in C, and written back whole if nothing was
    # unwrapped — the unwrap changes nothing else.
    uvs, copies = [], []
    if name in _UNWRAPS:
        if before == 'EDIT':
            import bmesh
            seen = set()
            for obj in bpy.context.objects_in_mode:
                if obj.type == 'MESH' and obj.data.name not in seen:
                    seen.add(obj.data.name)
                    copies.append((obj.data, bmesh.from_edit_mesh(obj.data).copy()))
        else:
            uvs = _active_uvs(_edited(active))
    if whole:
        if before != 'OBJECT':
            bpy.ops.object.mode_set(mode='OBJECT')
        saved = [(mesh, _selection(mesh)) for mesh in _edited(active)]
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
    unsolved = None
    try:
        if not whole and not _faces_selected():
            raise RuntimeError(label + ": no faces are selected. Select faces, or leave "
                               "Edit Mode to work on the whole mesh.")
        if name == 'follow_active_quads':
            _make_quad_active(active)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            result = operator(**props)
        # Blender's own words still reach the console.
        sys.stdout.write(said.getvalue())
        unsolved = _unsolved(said.getvalue()) if name in _UNWRAPS else None
        if unsolved is not None and unsolved[0] >= unsolved[1]:
            # Nothing was unwrapped: put the maps back before leaving Edit
            # Mode writes Blender's repack of them over the mesh.
            bpy.ops.object.mode_set(mode='OBJECT')
            _put_back(uvs)
            for mesh, copy in copies:
                copy.to_mesh(mesh)
                mesh.update()
            bpy.ops.object.mode_set(mode='EDIT')
    finally:
        for _, copy in copies:
            copy.free()
        if whole:
            bpy.ops.object.mode_set(mode='OBJECT')
            for mesh, flags in saved:
                _restore(mesh, flags)
            if before != 'OBJECT':
                bpy.ops.object.mode_set(mode=before)
    if 'FINISHED' not in result:
        raise RuntimeError(label + " did not run (" + ", ".join(sorted(result)) + ")")
    if unsolved is not None and unsolved[0] >= unsolved[1]:
        raise RuntimeError(
            label + ": Blender could not unwrap " + ("the island" if unsolved[1] == 1 else
            "any of the " + str(unsolved[1]) + " islands") + ": a closed surface needs seams "
            "to open it along. Mark some (Edge ▸ Mark Seam in Edit Mode), or use Smart UV "
            "Project, which needs none. The UVs were left as they were.")
    return result
