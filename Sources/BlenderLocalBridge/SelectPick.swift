import Foundation
import CoreGraphics
import simd

// Blender's four pick selections in a mesh's Edit Mode — Loop Select
// (Alt+click), Edge Ring Select (Ctrl+Alt+click), Pick Shortest Path
// (Ctrl+click) and Select Linked (L under the pointer) — driven by the app's
// own picking.
//
// Each of Blender's operators finds the element under the mouse in its
// invoke and hands the element's index to its exec, which does the
// selecting; the index is a hidden property "for redo". Round 3's review
// measured all four returning CANCELLED under the borrowed 3D View, called
// without one. Given the index, the exec is the whole operator: measured in
// desktop 5.2.1 with the app's context, on every edge of four meshes in all
// three select modes (`_blenderkit_select`'s docstring has the numbers). So
// the app picks the element on the cage in Swift (`MeshPicker`, the tap's
// own picking), names it by Blender's index, and runs Blender's own operator
// with it — the same call Blender's invoke makes, its redo panel Blender's.
// What is selected afterwards is what the mirror reads back.
//
// The task first proposed pushing the picked element as the selection and
// running Select Loops' multi-select from it. Measured, that is the same
// loop in Vertex and Edge mode and a different one in every case in Face
// mode (Alt+click there walks a face loop; 0 of 252 edges agreed), it loses
// Blender's loop-to-boundary cycling on a second click, and it leaves no
// active element: scripts/run-selectpick-blender-check.sh keeps it as the
// negative control.

/// One of Blender's pick selections.
public enum SelectPick: String, CaseIterable, Sendable {
    case loop, ring, path, linked

    /// The operator's name (`get_rna_type().name`, 5.2.1): the redo panel's
    /// title and the undo step's name.
    public var operatorName: String {
        switch self {
        case .loop:   return "Loop Select"
        case .ring:   return "Edge Ring Select"
        case .path:   return "Pick Shortest Path"
        case .linked: return "Select Linked"
        }
    }

    public var call: String {
        switch self {
        case .loop:   return "bpy.ops.mesh.loop_select"
        case .ring:   return "bpy.ops.mesh.edgering_select"
        case .path:   return "bpy.ops.mesh.shortest_path_pick"
        case .linked: return "bpy.ops.mesh.select_linked_pick"
        }
    }

    /// Blender's keys for it (blender_default.py, "Mesh" keymap).
    public var keys: String {
        switch self {
        case .loop:   return "Alt+click"
        case .ring:   return "Ctrl+Alt+click"
        case .path:   return "Ctrl+click"
        case .linked: return "L"
        }
    }

    /// What Shift adds to its keys in Blender's keymap, by the name of the
    /// property it sets (5.2.1): Shift+Alt+click and Shift+Ctrl+Alt+click
    /// toggle the loop or ring (`toggle`, "Toggle Select"), Shift+Ctrl+click
    /// fills the region between (`use_fill`, "Fill Region"), Shift+L takes the
    /// linked elements away (`deselect`, "Deselect").
    public var shiftLabel: String {
        switch self {
        case .loop, .ring: return "Toggle Select"
        case .path:        return "Fill Region"
        case .linked:      return "Deselect"
        }
    }

    /// What Shift does to an ordinary click, by the name of the property it
    /// sets: `view3d.select(toggle=True)`, "Toggle Selection" (5.2.1).
    public static let toggleLabel = "Toggle Selection"

    public var icon: String {
        switch self {
        case .loop:   return "circle.dotted"
        case .ring:   return "circle.grid.cross"
        case .path:   return "point.topleft.down.to.point.bottomright.curvepath"
        case .linked: return "link"
        }
    }

    /// What a tap picks for it. Loop Select and Edge Ring Select pick the
    /// nearest edge whatever the select mode (`edbm_select_loop_or_ring_pick`
    /// sets the edit mesh's select mode to edges for the pick); the other two
    /// pick an element of the select mode in use.
    public func pickMode(_ mode: MeshSelectMode) -> MeshSelectMode {
        switch self {
        case .loop, .ring:   return .edge
        case .path, .linked: return mode
        }
    }

    /// The pick a pointer click with these keys held makes, and whether Shift
    /// is among them: Blender's keymap, with ⌘ standing in for Ctrl as the
    /// region selects take it. Nil for a click with none of them, an
    /// ordinary select.
    public static func fromKeys(shift: Bool, control: Bool, option: Bool) -> (pick: SelectPick, shift: Bool)? {
        switch (control, option) {
        case (true, true):  return (.ring, shift)
        case (false, true): return (.loop, shift)
        case (true, false): return (.path, shift)
        default:            return nil
        }
    }

    /// Why picking cannot work on `object`, in words, or nil when it can.
    /// The index handed to Blender is an index into Blender's edit mesh, so
    /// the drawn cage has to be Blender's: under a modifier that rebuilds the
    /// mesh it is refused in Box, Circle and Lasso's words
    /// (`BKObject.editRegionRefusal`).
    public func refusal(object: BKObject?, usesRealBlender: Bool) -> String? {
        guard usesRealBlender else {
            return "\(operatorName) selects through Blender's own operator, which the simulator's "
                + "stand-in for Blender does not have."
        }
        guard let object else { return "\(operatorName) selects on the mesh being edited, and no object is active." }
        guard object.hasEditMode, !object.editsPoints else {
            return "\(operatorName) selects on a mesh, and \(object.name) is not one."
        }
        return object.editRegionRefusal(picking: "an element picked on them", toDo: "pick here")
    }

    /// The element the viewport's hit names, in Blender's numbering, or nil
    /// when it names none of Blender's: a quad's diagonal, a tap on nothing,
    /// a topology that no longer describes the cage.
    public static func element(_ hit: MeshPicker.Hit, mode: MeshSelectMode, cage: MeshData,
                               topology: EditTopology) -> EditElement? {
        guard topology.describes(cage) else { return nil }
        switch mode {
        case .vertex:
            guard let v = hit.vertex, v < topology.vertexCount else { return nil }
            return .vertex(v)
        case .edge:
            guard let drawn = hit.edge,
                  let e = LoopCut.blenderEdge(drawn: drawn, cage: cage, topology: topology) else { return nil }
            return .edge(e)
        case .face:
            guard let t = hit.faces.min(), t < topology.trianglePolygons.count else { return nil }
            return .face(Int(topology.trianglePolygons[t]))
        }
    }

    /// Blender's counts for the mesh the topology was read from: vertices,
    /// edges, faces. The pick refuses when Blender's mesh no longer has them.
    public static func counts(_ topology: EditTopology) -> (vertices: Int, edges: Int, faces: Int) {
        (topology.vertexCount, topology.blenderEdges.count / 2, topology.polygonCount)
    }

    /// Blender's index for `element` among every vertex, edge and face, which
    /// Pick Shortest Path and Select Linked take (`EDBM_elem_to_index_any`):
    /// vertices first, then edges, then faces.
    public static func anyIndex(_ element: EditElement, counts: (vertices: Int, edges: Int, faces: Int)) -> Int {
        switch element {
        case .vertex(let v): return v
        case .edge(let e):   return counts.vertices + e
        case .face(let f):   return counts.vertices + counts.edges + f
        }
    }

    /// The element Loop Select and Edge Ring Select make active, as Blender's
    /// invoke chooses it (`edbm_select_loop_or_ring_invoke_impl`): in Vertex
    /// mode the end of the edge nearer the pointer (the second end on a
    /// tie), in Face mode the face of the edge whose middle
    /// (`BM_face_calc_center_median`) is nearer it, in Edge mode the edge
    /// itself (its exec does that). `project` takes a point of the edit mesh
    /// — Blender's own coordinates, which its invoke projects — to the view.
    public static func loopActive(edge: Int, at point: CGPoint, mode: MeshSelectMode,
                                  cage: MeshData, topology: EditTopology,
                                  project: (SIMD3<Float>) -> CGPoint?) -> (vertex: Int?, face: Int?) {
        let ends = topology.blenderEdges
        guard 2 * edge + 1 < ends.count else { return (nil, nil) }
        let a = Int(ends[2 * edge]), b = Int(ends[2 * edge + 1])
        let positions = topology.blenderPositions.count == cage.vertices.count && !topology.blenderPositions.isEmpty
            ? topology.blenderPositions : cage.vertices.map(\.position)
        guard a < positions.count, b < positions.count else { return (nil, nil) }
        func distance(_ p: SIMD3<Float>) -> CGFloat {
            guard let s = project(p) else { return .greatestFiniteMagnitude }
            return hypot(s.x - point.x, s.y - point.y)
        }
        switch mode {
        case .edge:
            return (nil, nil)
        case .vertex:
            return (distance(positions[a]) < distance(positions[b]) ? a : b, nil)
        case .face:
            // The edge's faces: the polygons with a triangle side on it.
            var corners: [Int: Set<Int>] = [:]
            let triangles = cage.indices.count / 3
            guard topology.trianglePolygons.count == triangles else { return (nil, nil) }
            var faces = Set<Int>()
            for t in 0..<triangles {
                let c = (0..<3).map { Int(cage.indices[3 * t + $0]) }
                let p = Int(topology.trianglePolygons[t])
                corners[p, default: []].formUnion(c)
                for k in 0..<3 {
                    let x = c[k], y = c[(k + 1) % 3]
                    if (x == a && y == b) || (x == b && y == a) { faces.insert(p) }
                }
            }
            var best: (face: Int, d: CGFloat)?
            // Blender keeps the first strictly nearer face in the order
            // BM_FACES_OF_EDGE walks the edge's faces, which on an edit mesh
            // made from a mesh starts at the face added last
            // (`bmesh_radial_loop_append` makes each new loop the edge's
            // first): the higher polygon index. That only decides a pointer
            // exactly between two faces' middles — a grid seen from the top,
            // tapped on an edge — where the check measured it.
            for f in faces.sorted(by: >) {
                guard let members = corners[f], !members.isEmpty else { continue }
                let centre = members.reduce(SIMD3<Float>.zero) { $0 + positions[$1] } / Float(members.count)
                let d = distance(centre)
                if best == nil || d < best!.d { best = (f, d) }
            }
            return (nil, best?.face)
        }
    }
}

public extension LastOperator {
    /// Blender's pick operator for `element`, as its invoke hands it to its
    /// exec: Loop Select and Edge Ring Select an edge (`edge_index`, and the
    /// element they make active, `vert_index` / `face_index`, only when they
    /// select — their invoke leaves them out for Toggle); Pick Shortest Path
    /// and Select Linked any element (`index`). `shift` is what Shift adds in
    /// Blender's keymap (`SelectPick.shiftLabel`). `counts` is the mesh the
    /// element was picked on, which `_blenderkit_select.check_pick` holds
    /// Blender's to before anything runs.
    ///
    /// The redo panel is Blender's: Loop Select's Delimit (or Face Loop
    /// Delimit in Face mode, as its `poll_property` shows one or the other),
    /// Edge Ring Select's Edge Ring Delimit, Pick Shortest Path's Edge Tag (in
    /// Edge mode), Face Stepping, Topology Distance, Fill Region and its
    /// checker fields, Select Linked's Deselect and Delimit — each with
    /// Blender's default (5.2.1, `get_rna_type()`). Select Linked's Delimit
    /// starts as Blender's L leaves it on a first press: none in Vertex and
    /// Edge mode, Seam in Face mode (`select_linked_delimit_default_from_op`).
    /// Like the app's other operators, nothing is remembered from one press
    /// to the next.
    static func pick(_ pick: SelectPick, element: EditElement, shift: Bool, mode: MeshSelectMode,
                     counts: (vertices: Int, edges: Int, faces: Int),
                     activeVertex: Int? = nil, activeFace: Int? = nil) -> LastOperator {
        typealias P = Parameter
        let offOn = [P.Option("False", "Off"), P.Option("True", "On")]
        func toggle(_ key: String, _ label: String, _ on: Bool) -> P {
            P(key: key, label: label, kind: .literal(offOn), value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
        }
        let countList = "(\(counts.vertices), \(counts.edges), \(counts.faces))"
        var parameters: [P] = []
        var fixed: [String] = []
        let lead: String
        var within: String? = "_blenderkit_context.temp_override_view3d(\(Bpy.quote(pick.operatorName)))"
        switch pick {
        case .loop, .ring:
            if pick == .loop {
                parameters = mode == .face
                    ? P.flags("delimit_face_loop", "Face Loop Delimit",
                              [("SEAM", "Seam"), ("SHARP", "Sharp"), ("MATERIAL", "Material")], on: [])
                    : P.flags("delimit_edge_loop", "Delimit",
                              [("SEAM", "Seam"), ("SHARP", "Sharp"), ("NGONS", "N-gons"),
                               ("INNER_CORNERS", "Inner Corners"), ("OUTER_CORNERS", "Outer Corners")],
                              on: ["NGONS", "OUTER_CORNERS"])
            } else {
                parameters = P.flags("delimit_edge_ring", "Edge Ring Delimit",
                                     [("SEAM", "Seam"), ("SHARP", "Sharp"), ("MATERIAL", "Material"),
                                      ("NGONS", "N-gons")], on: ["NGONS"])
            }
            fixed = ["object_index=0", "edge_index=\(element.index)"]
            if shift { fixed.append("toggle=True") }
            if !shift, mode == .vertex, let v = activeVertex { fixed.append("vert_index=\(v)") }
            if !shift, mode == .face, let f = activeFace { fixed.append("face_index=\(f)") }
            lead = "import _blenderkit_context, _blenderkit_select\n"
                + "_blenderkit_select.check_pick(\(Bpy.quote(pick.operatorName)), 1, \(element.index), \(countList))"
        case .path:
            if mode == .edge {
                parameters.append(P(key: "edge_mode", label: "Edge Tag",
                                    kind: .choice([P.Option("SELECT", "Select"), P.Option("SEAM", "Tag Seam"),
                                                   P.Option("SHARP", "Tag Sharp"), P.Option("CREASE", "Tag Crease"),
                                                   P.Option("BEVEL", "Tag Bevel"),
                                                   P.Option("FREESTYLE", "Tag Freestyle Edge Mark")]),
                                    value: 0, softMin: 0, softMax: 5, step: 0.02))
            }
            parameters += [toggle("use_face_step", "Face Stepping", false),
                           toggle("use_topology_distance", "Topology Distance", false),
                           toggle("use_fill", "Fill Region", shift),
                           P(key: "skip", label: "Deselected", kind: .integer, value: 0,
                             softMin: 0, softMax: 100, step: 0.05),
                           P(key: "nth", label: "Selected", kind: .integer, value: 1,
                             softMin: 1, softMax: 100, step: 0.05),
                           P(key: "offset", label: "Offset", kind: .integer, value: 0,
                             softMin: -100, softMax: 100, step: 0.05)]
            fixed = ["index=\(SelectPick.anyIndex(element, counts: counts))"]
            lead = "import _blenderkit_context, _blenderkit_select\n"
                + "_blenderkit_select.check_path(\(element.kind), \(element.index), \(countList))"
        case .linked:
            parameters = [toggle("deselect", "Deselect", shift)]
                + P.flags("delimit", "Delimit",
                          [("NORMAL", "Normal"), ("MATERIAL", "Material"), ("SEAM", "Seam"),
                           ("SHARP", "Sharp"), ("UV", "UVs")],
                          on: mode == .face ? ["SEAM"] : [])
            fixed = ["object_index=0", "index=\(SelectPick.anyIndex(element, counts: counts))"]
            lead = "import _blenderkit_select\n"
                + "_blenderkit_select.check_pick(\(Bpy.quote(pick.operatorName)), \(element.kind), "
                + "\(element.index), \(countList))"
            // Its poll asks for an edit mesh, not a 3D View (measured: it
            // runs with none).
            within = nil
        }
        var op = LastOperator(name: pick.operatorName, call: pick.call, parameters: parameters,
                              restoration: .restoreMesh, needsEditMode: true)
        op.fixedArguments = fixed
        op.lead = lead
        op.within = within
        // What is left for Blender's CANCELLED once the checks have run: the
        // exec found nothing to start from (measured for an index past the
        // mesh and for an element of another kind than the active one).
        op.refusal = "\(pick.operatorName) found nothing to select from there"
        return op
    }
}

public extension EditSelection {
    /// The edit selection a tap that picked `hit` (on `cage`, the mesh the
    /// viewport picks on) leaves, with `action` — what the 3D View's tap does
    /// (`MetalViewportView.Coordinator.editTapSelection`). Each component set
    /// is combined separately, so Extend on a face selection grows the faces
    /// and the vertices they imply. With the mirror's topology, Blender's
    /// selection order follows as Blender's click leaves it (`picked`).
    func tapped(_ hit: MeshPicker.Hit, action: SelectAction, mode: MeshSelectMode,
                cage: MeshData?, topology: EditTopology?) -> EditSelection {
        var selection = self
        var hitVerts: Set<Int> = []
        if !hit.faces.isEmpty, let cage {
            hitVerts = MeshEditor.vertices(of: hit.faces, in: cage)
        }
        if let v = hit.vertex { hitVerts = [v] }
        var hitEdges: Set<Int> = []
        if let e = hit.edge, let cage {
            hitEdges = [e]
            let base = e * 2
            if base + 1 < cage.edges.count {
                hitVerts = [Int(cage.edges[base]), Int(cage.edges[base + 1])]
            }
        }
        selection.faces = action.apply(selection.faces, hit: hit.faces)
        selection.vertices = action.apply(selection.vertices, hit: hitVerts)
        selection.edges = action.apply(selection.edges, hit: hitEdges)
        if let cage, let topology {
            let element = SelectPick.element(hit, mode: mode, cage: cage, topology: topology)
            let nowSelected: Bool
            switch mode {
            case .vertex: nowSelected = hit.vertex.map(selection.vertices.contains) ?? false
            case .edge:   nowSelected = hit.edge.map(selection.edges.contains) ?? false
            case .face:   nowSelected = !hit.faces.isEmpty && hit.faces.isSubset(of: selection.faces)
            }
            selection.picked(element, action: action, nowSelected: nowSelected)
        }
        return selection
    }

    /// The selection order after a tap that picked `element` (Blender's
    /// index; nil for a tap on nothing) with `action`, as Blender's click
    /// leaves it (`EDBM_select_pick`): Set makes it the whole order (a click
    /// on nothing clears it, as Deselect On Nothing does), Extend moves it to
    /// the end, Subtract takes it out, Difference does one or the other by
    /// whether it ends up selected, Intersect leaves the order to the push,
    /// which keeps only what is still selected. A face tapped becomes the
    /// active face.
    mutating func picked(_ element: EditElement?, action: SelectAction, nowSelected: Bool) {
        switch action {
        case .set:
            history = element.map { [$0] } ?? []
        case .extend:
            if let element { history.removeAll { $0 == element }; history.append(element) }
        case .subtract:
            if let element { history.removeAll { $0 == element } }
        case .difference:
            if let element {
                history.removeAll { $0 == element }
                if nowSelected { history.append(element) }
            }
        case .intersect:
            break
        }
        if case .face = element, history.last == element { activeFace = nil }
    }
}
