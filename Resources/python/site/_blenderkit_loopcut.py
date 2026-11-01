"""Blender's Loop Cut (Ctrl+R), from the app's own picking.

Blender's tool previews the ring of edges the cut will cross as the pointer
moves over an edge, and a click runs

    bpy.ops.mesh.loopcut_slide(MESH_OT_loopcut={"number_cuts": n, ...,
        "edge_index": e, "object_index": 0}, TRANSFORM_OT_edge_slide={"value": v})

The call needs a 3D View region in the context: without one it segfaults
Blender in `loopcut_init` (round 3's review; `_blenderkit_context.NEEDS_VIEW`
refuses it there), and under `_blenderkit_context.temp_override_view3d` it
cuts — the factory cube in Edit Mode went from 8/12/6 to 12/20/10. The
pointer-driven half (`loopcut_slide` invoked, `view3d.edgering_select`)
returns CANCELLED or PASS_THROUGH headless, so the app picks the edge itself
and asks this module for the ring.

`ring` is Blender's own ring, not an approximation of it: the code below is
`bmw_EdgeringWalker_begin/step` (bmesh_walkers_impl.cc) with the flags
`edgering_select` gives it in editmesh_loopcut.cc — BMW_FLAG_TEST_HIDDEN and
BMW_DELIMIT_EDGE_RING_NGONS, so the ring crosses quads only and stops at a
triangle or an n-gon — and the preview's ordering is
`view3d_preselect_mesh_edgering_update_edges_from_edge` and
`edgering_find_order` (editmesh_preselect_edgering.cc), the lines Blender
draws while the pointer hovers. scripts/run-cuttools-blender-check.sh holds
every edge of a cube, a grid, a UV sphere, a cylinder with n-gon caps and a
mesh of quads, triangles and n-gons, hidden faces included, to the cut
Blender makes, and the app's DEBUG hook `-cut-ops` does the same on the
app's own Blender.
"""

import json

import bpy

# How many cuts the preview and the commit start from: Blender's default.
DEFAULT_CUTS = 1


def _is_real_blender():
    # The simulator's stand-in has no RNA behind its operators.
    return hasattr(bpy.ops.mesh.primitive_cube_add, 'get_rna_type')


def _edited_mesh(what="Loop Cut"):
    """The active object, when it is a mesh in Edit Mode; a refusal in words
    otherwise."""
    obj = bpy.context.view_layer.objects.active
    if obj is None:
        raise RuntimeError(what + " cuts the mesh being edited, and no object is active.")
    if obj.type != 'MESH':
        raise RuntimeError(what + " cuts a mesh, and %s is a %s." % (obj.name, obj.type.lower()))
    if obj.mode != 'EDIT':
        raise RuntimeError(what + " cuts the mesh being edited. Go into Edit Mode first.")
    return obj


# --------------------------------------------------------------------------
# Blender's edge-ring walker, as editmesh_loopcut.cc's `edgering_select` runs
# it. Element wrappers are cached per element by bmesh (CD_BM_ELEM_PYPTR), so
# `is` compares them as the C compares pointers.

def _manifold(e):
    loops = e.link_loops
    return len(loops) == 2


def _boundary(e):
    return len(e.link_loops) == 1


def _edge_ok(e):
    # EDGE_CHECK: bmw_mask_check_edge (not hidden) and boundary or manifold.
    return (not e.hide) and (_boundary(e) or _manifold(e))


def _quad(face):
    return len(face.loops) == 4


class _State:
    __slots__ = ('l', 'wire', 'no_calc')

    def __init__(self, l=None, wire=None, no_calc=False):
        self.l, self.wire, self.no_calc = l, wire, no_calc

    def copy(self):
        return _State(self.l, self.wire, self.no_calc)


def _step(states, visit):
    """bmw_EdgeringWalker_step with BMW_DELIMIT_EDGE_RING_NGONS. The walker is
    depth first: a new state goes to the head of the list."""
    owalk = states.pop(0)
    l = owalk.l
    if l is None:
        return owalk.wire
    e = l.edge
    # `no_calc` is set only by a seam, sharp or material delimit, which a
    # loop cut does not ask for; kept so the code reads as Blender's.
    if not _edge_ok(e) or owalk.no_calc:
        return e
    # Only quads: across the face on the other side first, then this one.
    l = l.link_loop_radial_next.link_loop_next.link_loop_next
    if (not _quad(l.face)) or (not _edge_ok(l.edge)) or l.face.hide:
        l = owalk.l.link_loop_next.link_loop_next
    if _quad(l.face) and _edge_ok(l.edge) and l.edge not in visit:
        states.insert(0, _State(l))
        visit.add(l.edge)
    return e


def _walk(states, visit):
    # BMW_walk: step until a step yields something.
    while states:
        current = _step(states, visit)
        if current is not None:
            return current
    return None


def walk(edge):
    """Every edge Blender's loop cut crosses from `edge`, in the walker's
    order (bmw_EdgeringWalker_begin, then BMW_step until it is done)."""
    states, visit = [], set()
    loops = edge.link_loops
    if not loops:
        # A wire edge: the walker yields it alone.
        states.insert(0, _State(wire=edge))
    else:
        states.insert(0, _State(loops[0]))
        visit.add(edge)
        # Rewind: walk one way to the end, and start again from there.
        owalk = None
        while states:
            owalk = states[0].copy()
            _walk(states, visit)
        lwalk = owalk.copy()
        states.insert(0, lwalk)
        if not _quad(lwalk.l.face):
            lwalk.l = lwalk.l.link_loop_radial_next
        visit.clear()
        visit.add(lwalk.l.edge)
        if lwalk.l.link_loop_radial_next is not lwalk.l:
            if lwalk.no_calc or not _quad(lwalk.l.face):
                states.insert(0, _State(lwalk.l.link_loop_radial_next))
    out = []
    # BMW_begin: the first step, then BMW_step until nothing is left.
    current = _step(states, visit) if states else None
    while current is not None:
        out.append(current)
        current = _walk(states, visit)
    return out


# --------------------------------------------------------------------------
# The preview Blender draws while the pointer hovers (editmesh_preselect_edgering.cc).

def _edge_in_face(e, face):
    return any(l.edge is e for l in face.loops)


def _find_order(eed_last, eed, eve_last):
    """edgering_find_order: `eed`'s two vertices, the one beside `eve_last`
    first, so the preview's lines do not cross."""
    first = eed.link_loops[0] if eed.link_loops else None
    found = None
    if first is not None:
        if _edge_in_face(eed, first.face) and _edge_in_face(eed_last, first.face):
            found = first
        else:
            # BM_LOOPS_OF_LOOP: the other loops round the same edge.
            l = first.link_loop_radial_next
            while l is not first:
                if _edge_in_face(eed, l.face) and _edge_in_face(eed_last, l.face):
                    found = l
                    break
                l = l.link_loop_radial_next
    v1, v2 = eed.verts[0], eed.verts[1]
    if found is None:
        # "this should never happen"
        return (v1, v2), (eed_last.verts[0], eed_last.verts[1])
    l = found
    # BM_loop_other_edge_loop(l, eed->v1)
    l_other = l.link_loop_prev if l.vert is v1 else l.link_loop_next
    rev = l_other is l.link_loop_prev
    last_verts = (eed_last.verts[0], eed_last.verts[1])
    guard = len(l.face.loops) + 1
    while l_other.vert is not last_verts[0] and l_other.vert is not last_verts[1] and guard > 0:
        l_other = l_other.link_loop_prev if rev else l_other.link_loop_next
        guard -= 1
    if l_other.vert is eve_last:
        return (v1, v2), None
    return (v2, v1), None


def _share_quad(e1, e2):
    # BM_edge_share_quad_check
    return any(_quad(l.face) and _edge_in_face(e2, l.face) for l in e1.link_loops)


def _any_quad(e):
    # BM_edge_is_any_face_len_test(e, 4): hidden faces count.
    return any(_quad(l.face) for l in e.link_loops)


def preview(edge, edges=None):
    """The preview's segments: for each, the two edges it joins, each as its
    two vertex indices in the order Blender interpolates them — a cut's
    point is at i / (cuts + 1) from the first to the second. Empty for an
    edge with no quad, which Blender previews as points on it alone."""
    edges = walk(edge) if edges is None else edges
    if not _any_quad(edge) or not edges:
        return []
    stack = list(edges)
    eed_start = stack[-1]
    segments = []
    eed_last = None
    eve_last = None
    v_prev = None
    while stack:
        eed = stack.pop()
        if eed_last is not None:
            if eve_last is not None:
                v_prev = v_cur
            else:
                v_prev = (eed_last.verts[0], eed_last.verts[1])
                eve_last = eed_last.verts[0]
            v_cur, fallback = _find_order(eed_last, eed, eve_last)
            if fallback is not None:
                v_prev = fallback
            eve_last = v_cur[0]
            segments.append((v_prev, v_cur))
        eed_last = eed
    if eed_last is not eed_start and _share_quad(eed_last, eed_start) and eve_last is not None:
        v_prev = v_cur
        v_cur, fallback = _find_order(eed_last, eed_start, eve_last)
        if fallback is not None:
            v_prev = fallback
        segments.append((v_prev, v_cur))
    return [[a[0].index, a[1].index, b[0].index, b[1].index] for a, b in segments]


def _bmesh(obj):
    import bmesh
    bm = bmesh.from_edit_mesh(obj.data)
    bm.verts.index_update()
    bm.edges.index_update()
    bm.edges.ensure_lookup_table()
    return bm


def _edge(bm, edge_index, what="Loop Cut"):
    if not isinstance(edge_index, int) or not 0 <= edge_index < len(bm.edges):
        raise RuntimeError("%s: the mesh has %d edges, and there is no edge %r."
                           % (what, len(bm.edges), edge_index))
    edge = bm.edges[edge_index]
    if edge.hide:
        raise RuntimeError("%s: edge %d is hidden. Reveal it (Alt+H) to cut across it." % (what, edge_index))
    return edge


def ring(edge_index, obj=None):
    """The ring Blender's loop cut through Blender edge `edge_index` crosses,
    on the mesh being edited: {"edges": [Blender edge indices, the walker's
    order], "ends": [[v1, v2] of each], "segments": `preview`'s,
    "single": the edge has no quad, so Blender previews points on it alone}."""
    if not _is_real_blender():
        raise NotImplementedError("Loop Cut needs Blender's 3D View, which the simulator's "
                                  "stand-in for Blender does not have")
    obj = obj or _edited_mesh()
    bm = _bmesh(obj)
    edge = _edge(bm, edge_index)
    edges = walk(edge)
    # The walker yields its start twice when the edge has no quad either side.
    ordered, seen = [], set()
    for e in edges:
        if e.index not in seen:
            seen.add(e.index)
            ordered.append(e)
    return {"edge": edge_index,
            "edges": [e.index for e in ordered],
            "ends": [[e.verts[0].index, e.verts[1].index] for e in ordered],
            "segments": preview(edge, edges),
            "single": not _any_quad(edge),
            "vertices": len(bm.verts)}


def ring_json(edge_index):
    """`ring` as one line of JSON, or {"refused": the reason}, for the viewport
    to draw from (the app's `bridge.capture`)."""
    try:
        print(json.dumps(ring(edge_index), separators=(',', ':')))
    except (RuntimeError, NotImplementedError) as error:
        print(json.dumps({"refused": str(error)}))


def object_index(obj):
    """What `loopcut`'s `object_index` names `obj` by: its place among the
    objects in Edit Mode that the 3D View shows, active first
    (`loopcut_init`: BKE_view_layer_array_from_bases_in_edit_mode with the
    view, which leaves out what is hidden in it). -1 for one it does not show."""
    in_mode = list(getattr(bpy.context, 'objects_in_mode', None) or [obj])
    shown = [other for other in in_mode if _shown(other)]
    for i, other in enumerate(shown):
        if other == obj:
            return i
    return -1


def _shown(obj):
    try:
        return bool(obj.visible_get())
    except (AttributeError, RuntimeError, TypeError):
        return True


def priced(obj, ring_edges, cuts):
    """The vertices Blender's viewport will evaluate after `cuts` cuts across a
    ring of `ring_edges` edges, through the whole modifier stack — an upper
    bound: each ring edge gains `cuts` vertices, each quad it crosses is split
    into `cuts + 1` (at most one quad per ring edge), and a face at an end of
    the ring gains `cuts` corners per ring edge it has."""
    import _blenderkit_multires as multires
    me = obj.data
    obj.update_from_editmode()
    v, e, f, c = len(me.vertices), len(me.edges), len(me.polygons), len(me.loops)
    r, n = ring_edges, cuts
    base = (v + n * r, e + 2 * n * r, f + n * r, c + 4 * n * r + 2 * n * r)
    return multires.stack_vertices(obj, base=base)


def check(edge_index, cuts, object_index_=0):
    """Everything `loopcut_slide` needs that Blender does not check before it
    runs, refused in words: a mesh in Edit Mode, an edge that is there and
    not hidden, `object_index` naming the active object, and a result inside
    the vertex budget (`_blenderkit_multires.refuse_count`)."""
    if not _is_real_blender():
        raise NotImplementedError("Loop Cut needs Blender's 3D View, which the simulator's "
                                  "stand-in for Blender does not have")
    obj = _edited_mesh()
    if not isinstance(cuts, int) or cuts < 1:
        raise RuntimeError("Loop Cut makes at least one cut, and was asked for %r." % (cuts,))
    # Hidden, it is not one of the objects the borrowed view hands Loop Cut,
    # and Blender answers CANCELLED: measured in 5.2.1 with the active cube
    # hidden (hide_set(True)) in Edit Mode, `loopcut_slide(edge_index=4)` cut
    # nothing, and the banner said there was no edge 4 (round 4's review).
    if not _shown(obj):
        raise RuntimeError("Loop Cut cuts what the 3D View shows, and %s is hidden there. Show it "
                           "(its eye in the Outliner) to cut it." % obj.name)
    bm = _bmesh(obj)
    edge = _edge(bm, edge_index)
    if object_index(obj) != object_index_:
        raise RuntimeError("Loop Cut: %s is not the first of the objects in Edit Mode, so Blender "
                           "would cut another one. Leave Edit Mode on the others first." % obj.name)
    count = len({e.index for e in walk(edge)})
    refuse_slow(obj.name, count, cuts)
    import _blenderkit_multires as multires
    multires.refuse_count(obj, priced(obj, count, cuts), "%d cut%s across %d edges"
                          % (cuts, "" if cuts == 1 else "s", count),
                          "Use fewer cuts, or start from a lighter mesh.")
    return count


# How long Blender's Loop Cut may take, in seconds on a desktop Mac, and its
# time's model. Its time grows faster than the vertices it makes: measured in
# desktop 5.2.1 (load average about 4, `loopcut_slide` under the borrowed 3D
# View), a cube's ring of 4 edges took 0.037 s at 1,000 cuts, 0.20 s at
# 2,000 and 1.0 s at 4,000; a 64-sided cylinder's 0.99 s at 1,000 and 5.3 s
# at 2,000; a 33 × 33 grid's 0.15 and 1.1 s. Round 4's fix round 2 review
# measured the cube at 8,000 cuts 4.65 s and at 32,000 342 s (load about
# 14), for 128,008 vertices, far inside the budget — one script line froze
# Blender for minutes, and 600,000 cuts was stopped at 200 s. The model is
# the ring's edges times the cuts squared, at the largest rate measured up
# to 5 s (2.1e-8 s), rounded up; past the review's 8,000 cuts the time grows
# faster still, which only makes the refusal earlier than needed.
LOOPCUT_SECONDS = 2.0
LOOPCUT_SECONDS_PER_EDGE_CUT2 = 2.5e-8


def loopcut_seconds(ring_edges, cuts):
    return LOOPCUT_SECONDS_PER_EDGE_CUT2 * max(1, int(ring_edges)) * float(cuts) ** 2


def refuse_slow(name, ring_edges, cuts):
    """Refuses, in words, a Loop Cut that would freeze Blender (`loopcut_seconds`)."""
    seconds = loopcut_seconds(ring_edges, cuts)
    if seconds > LOOPCUT_SECONDS:
        raise RuntimeError(
            "%d cuts across %s's ring of %d edges would take Blender about %d s, with the app frozen "
            "meanwhile: Loop Cut's time grows with the square of its cuts (measured on a desktop Mac: "
            "a cube at 4,000 cuts 1.0 s, at 32,000 more than five minutes). Use fewer cuts, at most "
            "%s here." % (cuts, name, ring_edges, max(1, round(seconds)),
                          format(int((LOOPCUT_SECONDS / (LOOPCUT_SECONDS_PER_EDGE_CUT2 * max(1, ring_edges)))
                                     ** 0.5), ',')))


def check_call(path, keywords):
    """`mesh.loopcut` or `mesh.loopcut_slide` as a script calls it
    (`_blenderkit_context._NeedsView`): its time refused in words before it
    runs (`refuse_slow`), from the edge it is given and the ring that edge
    starts. Its vertices are priced by the gate's Edit Mode transaction."""
    settings = keywords.get('MESH_OT_loopcut') if path.endswith('loopcut_slide') else keywords
    settings = dict(settings or {})
    try:
        cuts = int(settings.get('number_cuts', 1))
        edge_index = int(settings.get('edge_index', -1))
    except (TypeError, ValueError):
        return
    if cuts < 2 or not _is_real_blender():
        return
    import bpy
    obj = bpy.context.edit_object
    if obj is None or obj.type != 'MESH':
        return
    bm = _bmesh(obj)
    bm.edges.ensure_lookup_table()
    if not 0 <= edge_index < len(bm.edges):
        return
    refuse_slow(obj.name, len({e.index for e in walk(bm.edges[edge_index])}), cuts)


def check_edgering(cuts):
    """Subdivide Edge-Ring's price against the vertex budget
    (`_blenderkit_multires.refuse_count`), before it runs: each selected edge
    gains `cuts` vertices at most, as a Loop Cut's ring edge does (`priced`).
    Blender's default is ten cuts, and its field takes up to a thousand. The
    simulator's stand-in has no budget to keep and passes."""
    if not _is_real_blender():
        return 0
    obj = _edited_mesh("Subdivide Edge-Ring")
    if not isinstance(cuts, int) or cuts < 0:
        raise RuntimeError("Subdivide Edge-Ring was asked for %r cuts." % (cuts,))
    selected = sum(1 for e in _bmesh(obj).edges if e.select and not e.hide)
    import _blenderkit_multires as multires
    multires.refuse_count(obj, priced(obj, selected, cuts), "Subdivide Edge-Ring with %d cut%s across %d "
                          "selected edges" % (cuts, "" if cuts == 1 else "s", selected),
                          "Use fewer cuts, or select fewer edges.")
    return selected


def edit_counts():
    """(vertices, edges, faces) of each mesh in Edit Mode, to tell a run that
    changed the mesh from one that did not. Blender's Subdivide Edge-Ring
    answers FINISHED either way (measured in 5.2.1: one edge of a cube
    selected, nothing cut), and Blender says nothing a bpy module can read."""
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or [bpy.context.object])
    counts = []
    for obj in objects:
        if obj is None or getattr(obj, 'type', '') != 'MESH':
            continue
        try:
            import bmesh
            bm = bmesh.from_edit_mesh(obj.data)
            counts.append((len(bm.verts), len(bm.edges), len(bm.faces)))
        except (ImportError, AttributeError, TypeError, ValueError):
            # The simulator's stand-in has no bmesh; its meshes are current.
            mesh = obj.data
            counts.append(tuple(len(getattr(mesh, name, ())) for name in ('vertices', 'edges', 'polygons')))
    return counts


def edit_state():
    """`edit_counts`, with each mesh's vertex positions and edges: what
    `LastOperator.unchanged` compares before and after a row, so a row that
    moves vertices or turns edges and adds none reads as having changed the
    mesh. Measured in desktop 5.2.1 with the rows' own calls on a cube: Merge
    ▸ Collapse on two unjoined corners and Smooth Vertices (Laplacian) on one
    corner (or the whole cube) answer FINISHED with nothing changed; Merge ▸
    At Cursor on one vertex moves it with the counts the same, which
    `edit_counts` alone would have read as nothing done (round 4's review).
    Read through the mesh (`update_from_editmode`, two `foreach_get` calls),
    not vertex by vertex in Python."""
    from array import array
    objects = list(getattr(bpy.context, 'objects_in_mode_unique_data', None) or [bpy.context.object])
    state = []
    for obj, counts in zip([o for o in objects if o is not None and getattr(o, 'type', '') == 'MESH'],
                           edit_counts()):
        try:
            obj.update_from_editmode()
            mesh = obj.data
            co = array('f', [0.0]) * (3 * len(mesh.vertices))
            mesh.vertices.foreach_get('co', co)
            edges = array('i', [0]) * (2 * len(mesh.edges))
            mesh.edges.foreach_get('vertices', edges)
            state.append((counts, co.tobytes(), edges.tobytes()))
        except (AttributeError, TypeError, RuntimeError):
            # The simulator's stand-in: its counts are what it can say.
            state.append((counts,))
    return state
