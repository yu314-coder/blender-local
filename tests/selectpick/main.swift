import Foundation
import simd
import CoreGraphics

// Blender's pick selections and the Select menu's new rows, the Swift half
// (SelectPick.swift, SelectMenu.swift, the selection order in EditMesh.swift,
// SceneModel.swift and BpyBridge.swift): which keys make which pick, which
// element a hit names in Blender's numbering, the element a loop makes
// active, the exact calls with Blender's redo panels, the selection order a
// tap leaves and the push writes, the mirror's reading of it, and the rows.
// What Blender makes of the calls is scripts/run-selectpick-blender-check.sh.
//
//     scripts/run-selectpick-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}

/// Two quads side by side, as the mirror hands them over: six vertices
/// (0 1 2 on y = 0, 3 4 5 on y = 1), two triangles a quad, and Blender's
/// seven edges in an order of its own.
func strip() -> (MeshData, EditTopology) {
    let p: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0),
                             SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(2, 1, 0)]
    let quads: [[UInt32]] = [[0, 1, 4, 3], [1, 2, 5, 4]]
    var indices: [UInt32] = [], polys: [UInt32] = []
    for (f, q) in quads.enumerated() {
        indices += [q[0], q[1], q[2], q[0], q[2], q[3]]
        polys += [UInt32(f), UInt32(f)]
    }
    let mesh = MeshData(vertices: p.map { MeshVertex($0, SIMD3(0, 0, 1)) }, indices: indices)
    let blender: [UInt32] = [3, 4, 0, 1, 4, 5, 1, 2, 0, 3, 1, 4, 2, 5]
    let sides = Set(quads.flatMap { q in (0..<4).map { k -> Set<UInt32> in [q[k], q[(k + 1) % 4]] } })
    var real = Set<Int>()
    for e in 0..<(mesh.edges.count / 2) where sides.contains([mesh.edges[2 * e], mesh.edges[2 * e + 1]]) {
        real.insert(e)
    }
    return (mesh, EditTopology(vertexCount: 6, polygonCount: 2, trianglePolygons: polys, realEdges: real,
                               blenderEdges: blender))
}

func drawnEdge(_ mesh: MeshData, _ a: UInt32, _ b: UInt32) -> Int? {
    (0..<(mesh.edges.count / 2)).first {
        Set([mesh.edges[2 * $0], mesh.edges[2 * $0 + 1]]) == Set([a, b])
    }
}

print("\n== the keys: Blender's keymap ==")
do {
    func keys(_ shift: Bool, _ control: Bool, _ option: Bool) -> String {
        guard let (pick, s) = SelectPick.fromKeys(shift: shift, control: control, option: option) else { return "-" }
        return pick.rawValue + (s ? "+shift" : "")
    }
    check("Alt+click is Loop Select", keys(false, false, true) == "loop")
    check("Shift+Alt+click is its Toggle Select", keys(true, false, true) == "loop+shift")
    check("Ctrl+Alt+click is Edge Ring Select", keys(false, true, true) == "ring")
    check("Shift+Ctrl+Alt+click its Toggle Select", keys(true, true, true) == "ring+shift")
    check("Ctrl+click is Pick Shortest Path", keys(false, true, false) == "path")
    check("Shift+Ctrl+click its Fill Region", keys(true, true, false) == "path+shift")
    check("a click, or a Shift-click, is no pick", keys(false, false, false) == "-" && keys(true, false, false) == "-")
    check("the names are the operators' (5.2.1)",
          SelectPick.allCases.map(\.operatorName) == ["Loop Select", "Edge Ring Select", "Pick Shortest Path", "Select Linked"])
    check("and what Shift adds, by Blender's property names",
          SelectPick.allCases.map(\.shiftLabel) == ["Toggle Select", "Toggle Select", "Fill Region", "Deselect"])
    check("Loop and Ring pick an edge in every mode; Path and Linked the mode's element",
          MeshSelectMode.allCases.allSatisfy {
              SelectPick.loop.pickMode($0) == .edge && SelectPick.ring.pickMode($0) == .edge
                  && SelectPick.path.pickMode($0) == $0 && SelectPick.linked.pickMode($0) == $0
          })
}

print("\n== a hit is named by Blender's index ==")
do {
    let (mesh, topology) = strip()
    let middle = drawnEdge(mesh, 1, 4)!
    check("the middle edge (1, 4) is Blender's edge 5",
          SelectPick.element(MeshPicker.Hit(edge: middle), mode: .edge, cage: mesh, topology: topology) == .edge(5))
    check("negative control: the viewport's own number for it is not Blender's", middle != 5, "\(middle)")
    let diagonal = drawnEdge(mesh, 0, 4)!
    check("a quad's diagonal names nothing",
          SelectPick.element(MeshPicker.Hit(edge: diagonal), mode: .edge, cage: mesh, topology: topology) == nil)
    check("a triangle names its polygon",
          SelectPick.element(MeshPicker.Hit(faces: [2, 3]), mode: .face, cage: mesh, topology: topology) == .face(1))
    check("a vertex is itself", SelectPick.element(MeshPicker.Hit(vertex: 4), mode: .vertex, cage: mesh,
                                                   topology: topology) == .vertex(4))
    check("a tap on nothing names nothing",
          SelectPick.element(MeshPicker.Hit(), mode: .vertex, cage: mesh, topology: topology) == nil)
    var stale = topology
    stale.vertexCount = 7
    check("a topology that no longer describes the cage names nothing",
          SelectPick.element(MeshPicker.Hit(vertex: 4), mode: .vertex, cage: mesh, topology: stale) == nil)
    let counts = SelectPick.counts(topology)
    check("counts are Blender's: 6 vertices, 7 edges, 2 faces", counts == (6, 7, 2))
    check("the any-index Blender's path and linked picks take: vertices, then edges, then faces",
          SelectPick.anyIndex(.vertex(4), counts: counts) == 4 && SelectPick.anyIndex(.edge(5), counts: counts) == 11
              && SelectPick.anyIndex(.face(1), counts: counts) == 14)
}

print("\n== the element Loop Select makes active, as its invoke chooses it ==")
do {
    let (mesh, topology) = strip()
    // A view from the top, one unit 100 points, y up the screen.
    func project(_ p: SIMD3<Float>) -> CGPoint? { CGPoint(x: CGFloat(p.x) * 100, y: 300 - CGFloat(p.y) * 100) }
    // Blender edge 5 is (1, 4): from (100, 300) to (100, 200).
    let nearOne = SelectPick.loopActive(edge: 5, at: CGPoint(x: 100, y: 290), mode: .vertex, cage: mesh,
                                        topology: topology, project: project)
    check("Vertex mode: the end nearer the pointer (vertex 1)", nearOne.vertex == 1 && nearOne.face == nil, "\(nearOne)")
    let nearFour = SelectPick.loopActive(edge: 5, at: CGPoint(x: 100, y: 215), mode: .vertex, cage: mesh,
                                         topology: topology, project: project)
    check("and from the other end, vertex 4", nearFour.vertex == 4, "\(nearFour)")
    let tie = SelectPick.loopActive(edge: 5, at: CGPoint(x: 100, y: 250), mode: .vertex, cage: mesh,
                                    topology: topology, project: project)
    check("exactly between: the edge's second end, as `length_1 < length_2 ? v1 : v2` gives", tie.vertex == 4,
          "\(tie)")
    let left = SelectPick.loopActive(edge: 5, at: CGPoint(x: 90, y: 250), mode: .face, cage: mesh,
                                     topology: topology, project: project)
    check("Face mode: the face whose middle is nearer (the left, 0)", left.face == 0 && left.vertex == nil, "\(left)")
    let right = SelectPick.loopActive(edge: 5, at: CGPoint(x: 120, y: 250), mode: .face, cage: mesh,
                                      topology: topology, project: project)
    check("and from the right, face 1", right.face == 1, "\(right)")
    let between = SelectPick.loopActive(edge: 5, at: CGPoint(x: 100, y: 250), mode: .face, cage: mesh,
                                        topology: topology, project: project)
    check("exactly between: the face added last, first in BM_FACES_OF_EDGE", between.face == 1, "\(between)")
    let edgeMode = SelectPick.loopActive(edge: 5, at: CGPoint(x: 100, y: 290), mode: .edge, cage: mesh,
                                         topology: topology, project: project)
    check("Edge mode: the exec makes the edge active itself", edgeMode.vertex == nil && edgeMode.face == nil)
    let past = SelectPick.loopActive(edge: 99, at: .zero, mode: .vertex, cage: mesh, topology: topology, project: project)
    check("an edge past Blender's list gives nothing", past.vertex == nil && past.face == nil)
}

print("\n== the calls: Blender's operators with the index their invoke hands their exec ==")
do {
    let counts = (vertices: 49, edges: 84, faces: 36)
    let loop = LastOperator.pick(.loop, element: .edge(10), shift: false, mode: .edge, counts: counts)
    check("Loop Select, Edge mode: Blender's call with its Delimit's defaults",
          loop.python.hasSuffix("    bpy.ops.mesh.loop_select(delimit_edge_loop={'NGONS', 'OUTER_CORNERS'}, "
                                + "object_index=0, edge_index=10)"), loop.python)
    check("inside the borrowed 3D View its poll asks for, after the check",
          loop.python.hasPrefix("import _blenderkit_context, _blenderkit_select\n"
                                + "_blenderkit_select.check_pick(\"Loop Select\", 1, 10, (49, 84, 36))\n"
                                + "with _blenderkit_context.temp_override_view3d(\"Loop Select\"):\n"),
          loop.python)
    check("its redo panel is Blender's Delimit, five toggles, N-gons and Outer Corners on",
          loop.parameters.map(\.label) == ["Seam", "Sharp", "N-gons", "Inner Corners", "Outer Corners"]
              && loop.parameters.map(\.value) == [0, 0, 1, 0, 1] && loop.name == "Loop Select")
    var none = loop
    for p in none.parameters { none[p.key] = 0 }
    check("with none on, Python's empty set", none.python.contains("delimit_edge_loop=set()"), none.python)
    var seam = loop
    seam["delimit_edge_loop.SEAM"] = 1
    check("Seam added to the set", seam.python.contains("delimit_edge_loop={'SEAM', 'NGONS', 'OUTER_CORNERS'}"),
          seam.python)
    let vertex = LastOperator.pick(.loop, element: .edge(10), shift: false, mode: .vertex, counts: counts,
                                   activeVertex: 7, activeFace: 3)
    check("Vertex mode carries the active vertex, not the face",
          vertex.python.contains("edge_index=10, vert_index=7)") && !vertex.python.contains("face_index"), vertex.python)
    let face = LastOperator.pick(.loop, element: .edge(10), shift: false, mode: .face, counts: counts,
                                 activeVertex: 7, activeFace: 3)
    check("Face mode: Face Loop Delimit and the active face",
          face.python.contains("bpy.ops.mesh.loop_select(delimit_face_loop=set(), object_index=0, edge_index=10, "
                               + "face_index=3)"), face.python)
    let toggle = LastOperator.pick(.loop, element: .edge(10), shift: true, mode: .vertex, counts: counts,
                                   activeVertex: 7)
    check("Shift: Toggle Select, and no active vertex (Blender's invoke leaves it unset then)",
          toggle.python.contains("edge_index=10, toggle=True)") && !toggle.python.contains("vert_index"), toggle.python)
    let ring = LastOperator.pick(.ring, element: .edge(10), shift: false, mode: .edge, counts: counts)
    check("Edge Ring Select with Edge Ring Delimit, N-gons on",
          ring.python.contains("bpy.ops.mesh.edgering_select(delimit_edge_ring={'NGONS'}, object_index=0, edge_index=10)")
              && ring.name == "Edge Ring Select", ring.python)
    let path = LastOperator.pick(.path, element: .edge(10), shift: false, mode: .edge, counts: counts)
    check("Pick Shortest Path in Edge mode: Edge Tag, its four switches and checker, the any-index",
          path.python.contains("bpy.ops.mesh.shortest_path_pick(edge_mode='SELECT', use_face_step=False, "
                               + "use_topology_distance=False, use_fill=False, skip=0, nth=1, offset=0, index=59)")
              && path.python.contains("_blenderkit_select.check_path(1, 10, (49, 84, 36))"), path.python)
    let fill = LastOperator.pick(.path, element: .vertex(48), shift: true, mode: .vertex, counts: counts)
    check("in Vertex mode no Edge Tag (Blender's poll_property hides it), Shift is Fill Region",
          fill.python.contains("shortest_path_pick(use_face_step=False, use_topology_distance=False, use_fill=True, "
                               + "skip=0, nth=1, offset=0, index=48)"), fill.python)
    let linked = LastOperator.pick(.linked, element: .vertex(3), shift: false, mode: .vertex, counts: counts)
    check("Select Linked in Vertex mode: no Delimit, as L's first press; no 3D View needed",
          linked.python == "import _blenderkit_select\n_blenderkit_select.check_pick(\"Select Linked\", 0, 3, (49, 84, 36))\n"
              + "bpy.ops.mesh.select_linked_pick(deselect=False, delimit=set(), object_index=0, index=3)",
          linked.python)
    let linkedFace = LastOperator.pick(.linked, element: .face(2), shift: true, mode: .face, counts: counts)
    check("in Face mode Seam, and Shift is Deselect",
          linkedFace.python.contains("select_linked_pick(deselect=True, delimit={'SEAM'}, object_index=0, index=135)"),
          linkedFace.python)
    check("the CANCELLED refusal runs, and stays out of the Info log",
          loop.executedPython.contains("if 'CANCELLED' in bpy.ops.mesh.loop_select(")
              && !loop.python.contains("CANCELLED"), loop.executedPython)
}

print("\n== the selection order a tap leaves ==")
do {
    let (mesh, topology) = strip()
    var s = EditSelection()
    s = s.tapped(MeshPicker.Hit(vertex: 1), action: .set, mode: .vertex, cage: mesh, topology: topology)
    check("a tap makes the vertex the order", s.history == [.vertex(1)] && s.vertices == [1], "\(s.history)")
    s = s.tapped(MeshPicker.Hit(vertex: 4), action: .extend, mode: .vertex, cage: mesh, topology: topology)
    check("Extend adds it at the end: the active one", s.history == [.vertex(1), .vertex(4)] && s.active == .vertex(4))
    s = s.tapped(MeshPicker.Hit(vertex: 1), action: .extend, mode: .vertex, cage: mesh, topology: topology)
    check("Extend on one already there moves it to the end", s.history == [.vertex(4), .vertex(1)])
    s = s.tapped(MeshPicker.Hit(vertex: 1), action: .difference, mode: .vertex, cage: mesh, topology: topology)
    check("Difference that deselects takes it out", s.history == [.vertex(4)] && !s.vertices.contains(1))
    s = s.tapped(MeshPicker.Hit(vertex: 4), action: .subtract, mode: .vertex, cage: mesh, topology: topology)
    check("Subtract takes it out", s.history.isEmpty)
    s = s.tapped(MeshPicker.Hit(vertex: 2), action: .set, mode: .vertex, cage: mesh, topology: topology)
    s = s.tapped(MeshPicker.Hit(), action: .set, mode: .vertex, cage: mesh, topology: topology)
    check("a Set tap on nothing clears it, as Deselect On Nothing does", s.history.isEmpty && s.vertices.isEmpty)
    let middle = drawnEdge(mesh, 1, 4)!
    let e = EditSelection().tapped(MeshPicker.Hit(edge: middle), action: .set, mode: .edge, cage: mesh, topology: topology)
    check("an edge goes into the order by Blender's index", e.history == [.edge(5)] && e.vertices == [1, 4])
    let f = EditSelection().tapped(MeshPicker.Hit(faces: [2, 3]), action: .set, mode: .face, cage: mesh, topology: topology)
    check("a face by its polygon", f.history == [.face(1)] && f.faces == [2, 3])
    let none = EditSelection().tapped(MeshPicker.Hit(vertex: 1), action: .set, mode: .vertex, cage: mesh, topology: nil)
    check("with no topology (the stand-in) there is no order to keep", none.history.isEmpty && none.vertices == [1])
}

print("\n== the push writes it, the mirror reads it ==")
do {
    let (mesh, topology) = strip()
    let object = BKObject(name: "Strip", kind: .plane)
    object.setMirroredMesh(mesh)
    object.editTopology = topology
    var s = EditSelection()
    s.vertices = [1, 4]
    s.edges = [drawnEdge(mesh, 1, 4)!]
    s.history = [.vertex(1), .edge(5), .vertex(4)]
    let push = Bpy.pushEditSelection(s, mode: .vertex, of: object)
    check("the push clears Blender's order and writes it afresh, each entry only if selected",
          push.contains("_bk_bm.select_history.clear()")
              && push.contains("for _bk_k, _bk_a, _bk_b in [(0, 1, -1), (1, 1, 4), (0, 4, -1)]:")
              && push.contains("    if _bk_x is not None and _bk_x.select:"), push)
    check("an edge goes over by its two vertices, as selected edges do",
          push.contains("_bk_bm.edges.get((_bk_bm.verts[_bk_a], _bk_bm.verts[_bk_b]))"))
    s.history = [.face(1)]
    s.faces = [2, 3]
    let facePush = Bpy.pushEditSelection(s, mode: .face, of: object)
    check("a face last in the order is made the active face, as Blender's click makes it",
          facePush.contains("if _bk_bm.faces[1].select:\n    _bk_bm.faces.active = _bk_bm.faces[1]"), facePush)
    s.history = [.vertex(99), .face(7), .edge(42)]
    let filtered = Bpy.pushEditSelection(s, mode: .vertex, of: object)
    check("entries past the mesh are left out", !filtered.contains("for _bk_k"), filtered)

    // The mirror's report: (kind, index) pairs, a trailing (3, f) for an
    // active face kept apart, and entries past the counts dropped.
    let report = BlenderEditReport(selectMode: 1, vertexSelected: [0, 1, 0, 0, 1, 0],
                                   trianglePolygons: topology.trianglePolygons, polygonSelected: [0, 1],
                                   edgeVertices: topology.blenderEdges, edgeSelected: [0, 0, 0, 0, 0, 1, 0],
                                   history: [0, 1, 1, 5, 0, 99, 2, 1, 3, 0])
    if let mirrored = EditSelection.mirrored(report, display: mesh) {
        check("the mirror reads Blender's order, oldest first", mirrored.selection.history == [.vertex(1), .edge(5), .face(1)],
              "\(mirrored.selection.history)")
        check("and the active face kept apart", mirrored.selection.activeFace == 0)
        check("the active element is the last", mirrored.selection.active == .face(1))
    } else { check("the report is read", false) }
    var a = EditSelection(), b = EditSelection()
    a.vertices = [1]; b.vertices = [1]
    b.history = [.vertex(1)]
    check("a change of order alone is a change the viewport takes", !a.matches(b))
}

print("\n== a region keeps the order unless it sets ==")
do {
    let (mesh, topology) = strip()
    let object = BKObject(name: "Strip", kind: .plane)
    object.setMirroredMesh(mesh)
    object.editTopology = topology
    var current = EditSelection()
    current.vertices = [0]
    current.history = [.vertex(0)]
    current.activeFace = 1
    let vp = matrix_identity_float4x4
    let box = SelectionRegion.box(CGRect(x: 0, y: 0, width: 10, height: 10))
    let extend = object.regionSelection(box, mode: .vertex, action: .extend, current: current,
                                        viewProjection: vp, size: CGSize(width: 100, height: 100), seeThrough: true)
    check("Extend keeps it", extend.history == [.vertex(0)] && extend.activeFace == 1)
    let set = object.regionSelection(box, mode: .vertex, action: .set, current: current,
                                     viewProjection: vp, size: CGSize(width: 100, height: 100), seeThrough: true)
    check("Set clears it (Blender's deselect-all does), the active face kept", set.history.isEmpty && set.activeFace == 1)
}

print("\n== the Select menu's rows ==")
do {
    let rows: [(SelectMenu.MeshItem, String, String)] = [
        (.nextActive, "Next Active", "bpy.ops.mesh.select_next_item"),
        (.previousActive, "Previous Active", "bpy.ops.mesh.select_prev_item"),
        (.sideOfActive, "Side of Active", "bpy.ops.mesh.select_axis"),
        (.byAttribute, "By Attribute", "bpy.ops.mesh.select_by_attribute")]
    for (item, title, call) in rows {
        check("\(title) is a row, Blender's \(call)", item.title == title && item.call == call)
    }
    let next = SelectMenu.MeshItem.nextActive.operation
    check("Next Active refuses a FINISHED that changed nothing, kept out of the log",
          next.executedPython.contains("with _bk_select.refuse_unchanged_selection(")
              && next.python == "bpy.ops.mesh.select_next_item()", next.executedPython)
    let side = SelectMenu.MeshItem.sideOfActive.operation
    check("Side of Active's panel: Axis Mode (Local), Axis Sign, Axis, Threshold 0.0001",
          side.python == "bpy.ops.mesh.select_axis(orientation='LOCAL', sign='POS', axis='X', threshold=0.0001)",
          side.python)
    let aimed = SelectMenu.MeshItem.sideOfActive.operation(view: SelectMenu.ViewDirection(forward: SIMD3(0, 1, 0),
                                                                                         up: SIMD3(0, 0, 1)))
    check("with the view, run in the borrowed 3D View aimed as the app looks",
          aimed.python.contains("with _blenderkit_select.aimed_view('Side of Active', forward=(0.0, 1.0, 0.0), "
                                + "up=(0.0, 0.0, 1.0)):"), aimed.python)
    check("Select Grouped's eleven types, Blender's", SelectMenu.groupedTypes.map(\.label) == [
        "Children", "Immediate Children", "Parent", "Siblings", "Type", "Collection", "Hook", "Pass", "Color",
        "Keying Set", "Light Type"])
    check("and its row token", SelectMenu.Command(token: "grouped:SIBLINGS") == .grouped("SIBLINGS")
              && SelectMenu.Command(token: "grouped:NOPE") == nil)
    if case .perform(let op) = SelectMenu.selectGrouped("SIBLINGS") {
        check("Select Grouped: the exec's port with Blender's Extend and Type, its step Select Grouped",
              op.python == "import _blenderkit_select\n_blenderkit_select.select_grouped(extend=False, type='SIBLINGS')"
                  && op.name == "Select Grouped" && op.executedPython.contains("needs_active=\"Select Grouped\""),
              op.python)
    } else { check("Select Grouped is adjustable", false) }
    if case .perform(let op) = SelectMenu.ObjectItem.random.action {
        check("Object Select Random has Blender's panel now: Ratio, Random Seed, Action",
              op.parameters.map(\.label) == ["Ratio", "Random Seed", "Action"]
                  && op.python == "bpy.ops.object.select_random(ratio=0.5, seed=0, action='SELECT')", op.python)
        check("its guard stays out of the log and refuses an unchanged run",
              op.executedPython.contains("object_select(\"Blender changed nothing.\", unchanged=True)"), op.executedPython)
    } else { check("Object Select Random is adjustable", false) }
    if case .perform(let op) = SelectMenu.ObjectItem.extendParent.action {
        check("Extend Parent is Select Hierarchy with Direction Parent and Extend on",
              op.python == "bpy.ops.object.select_hierarchy(direction='PARENT', extend=True)", op.python)
    }
}

print("\n== Select ▸ Select Linked ▸ Linked and Ctrl+L: Blender's first-press Delimit ==")
do {
    func row(_ mode: MeshSelectMode?) -> LastOperator? {
        if case .perform(let op) = SelectMenu.Command.mesh(.linked).action(editing: true, selectMode: mode) {
            return op
        }
        return nil
    }
    // USE_LINKED_SELECT_DEFAULT_HACK: none while vertices or edges are
    // selectable, Seam in Face mode alone. The row sent Seam in every mode
    // (round 4's review measured 15 vertices where Blender's Ctrl+L took 25).
    check("Vertex mode: no Delimit", row(.vertex)?.python == "bpy.ops.mesh.select_linked(delimit=set())",
          row(.vertex)?.python ?? "nil")
    check("Edge mode: no Delimit", row(.edge)?.python == "bpy.ops.mesh.select_linked(delimit=set())",
          row(.edge)?.python ?? "nil")
    check("Face mode: Seam", row(.face)?.python == "bpy.ops.mesh.select_linked(delimit={'SEAM'})",
          row(.face)?.python ?? "nil")
    // The negative control: what the row sent before, which these refuse.
    check("(the old row's Seam in Vertex mode would fail the first)",
          "bpy.ops.mesh.select_linked(delimit={'SEAM'})" != row(.vertex)?.python)
    let panel = row(.face)?.parameters ?? []
    check("its panel is Blender's: one toggle per Delimit item, under the heading, 5.2.1's labels",
          panel.map(\.label) == ["Normal", "Material", "Seam", "Sharp", "UVs"]
              && panel.allSatisfy { if case .flag(let k, let h, _) = $0.kind { return k == "delimit" && h == "Delimit" }
                                    return false }
              && panel.map(\.display) == ["Off", "Off", "On", "Off", "Off"], "\(panel.map(\.label))")
    if var op = row(.vertex) {
        op["delimit.SEAM"] = 1
        op["delimit.UV"] = 1
        check("two toggles on make one set", op.python == "bpy.ops.mesh.select_linked(delimit={'SEAM', 'UV'})",
              op.python)
    }
    check("without Blender's select mode the row leaves Delimit to Blender, and shows no value for it",
          row(nil)?.python == "bpy.ops.mesh.select_linked()" && row(nil)?.parameters.isEmpty == true,
          row(nil)?.python ?? "nil")
    check("the redo panel's title and the undo step stay Select Linked All",
          row(.face)?.name == "Select Linked All")
}

print("\n== which element near the tap wins: Blender's Manhattan distance ==")
do {
    // Two vertices 2.83 and 3.5 points from the tap, straight; 4.0 and 3.5
    // the Manhattan way, which is how Blender ranks them.
    let screen: [SIMD2<Float>?] = [SIMD2(2, 2), SIMD2(3.5, 0)]
    let v = MeshPicker.nearestVertex([0, 1], screen: screen, visible: nil, to: .zero, within: 22)
    check("the vertex Blender's click takes (Manhattan 3.5, not the straight 2.83)", v == 1, "\(v.map(String.init) ?? "nil")")
    check("(the straight distance alone would take the other)", simd_distance(screen[0]!, .zero) < simd_distance(screen[1]!, .zero))
    check("the reach is still a finger's circle: 22 points straight, not 22 the Manhattan way",
          MeshPicker.nearestVertex([0], screen: [SIMD2(15, 15)], visible: nil, to: .zero, within: 22) == 0)
    // An edge: the foot of the perpendicular, then Manhattan to it.
    check("an edge is measured at its nearest point, the Manhattan way",
          abs(MeshPicker.manhattanToSegment(SIMD2(1, 1), SIMD2(0, 0), SIMD2(4, 0)) - 1) < 1e-6
              && abs(MeshPicker.manhattanToSegment(SIMD2(3, 3), SIMD2(0, 0), SIMD2(4, 4)) - 0) < 1e-6
              && abs(MeshPicker.manhattanToSegment(SIMD2(-1, 1), SIMD2(0, 0), SIMD2(4, 0)) - 2) < 1e-6)
}

print("\n== Box, Circle and Lasso Set over what is selected: Blender's pre-deselect ==")
do {
    var one = EditSelection()
    one.vertices = [4]
    one.history = [.vertex(4)]
    var same = one
    same.history = []          // what `regionSelection` leaves for a Set
    check("a Set over exactly the selected vertex changes Blender (its order goes): pushed",
          BKObject.regionChanges(same, from: one, mode: .vertex, action: .set))
    var unordered = one
    unordered.history = []
    check("and with no order too (Blender's box finishes whenever anything was selected)",
          BKObject.regionChanges(unordered, from: unordered, mode: .vertex, action: .set))
    check("a Set over nothing with nothing selected changes nothing: no step",
          !BKObject.regionChanges(EditSelection(), from: EditSelection(), mode: .vertex, action: .set))
    check("Extend over the selected vertex changes nothing: no step, the order kept",
          !BKObject.regionChanges(one, from: one, mode: .vertex, action: .extend))
    var two = one
    two.vertices = [4, 5]
    check("Extend that adds one: pushed", BKObject.regionChanges(two, from: one, mode: .vertex, action: .extend))
    // The negative control: the rule as it was, the mode's elements alone,
    // reads the first case as unchanged.
    check("(the old rule, the elements alone, reads the first case as unchanged)", same.vertices == one.vertices)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
