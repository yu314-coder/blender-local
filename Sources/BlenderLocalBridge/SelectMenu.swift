import Foundation

/// Blender's Select menu: `VIEW3D_MT_select_object` in Object Mode and
/// `VIEW3D_MT_select_edit_mesh` while editing, read out of 5.2.1's
/// `space_view3d.py` with the same rows in the same order.
///
/// Every row is Blender's own operator, sent through `BpyBridge`, and what it
/// leaves selected is read back by the mirroring pass the command ends with —
/// the edit selection by `_report_edit_selection`, objects by the pass — so
/// the viewport shows Blender's selection, not a guess at it. Measured in
/// 5.2.1 without a window (docs/blender-local.md, 2026-09-22), each works
/// there, and the edit-mode ones that have a redo panel in Blender go through
/// `perform`, which gives them the Adjust Last Operation panel with Blender's
/// own arguments and defaults (`get_rna_type()`), labels included.
///
/// Every row of Blender's two menus is here (round 4, group 4). Next and
/// Previous Active and Side of Active were drawn disabled: they need Blender's
/// selection order, which a selection handed over from the viewport did not
/// carry (measured: Side of Active returned CANCELLED and Next Active changed
/// nothing). The order is the mirror's now (`EditSelection.history`) and the
/// push writes it, so each is Blender's operator. Select Grouped fails its
/// poll whenever Blender has no interface (`object_select_grouped_poll`
/// returns False for G.background, which a bpy module always is), so it is
/// that operator's exec, type for type (`_blenderkit_select.select_grouped`).
/// By Attribute is Blender's: with no active boolean attribute its poll says
/// why ("There must be an active attribute"), on the banner. The Object Mode
/// rows run through `perform` now too, with Blender's redo panel — before,
/// only the Edit Mode rows had one.
public enum SelectMenu {

    /// Where the 3D View looks, for the one row that asks: Side of Active
    /// with Axis Mode View, which reads the view's rotation. World space.
    public struct ViewDirection: Equatable, Sendable {
        public var forward: SIMD3<Float>
        public var up: SIMD3<Float>
        public init(forward: SIMD3<Float>, up: SIMD3<Float>) { self.forward = forward; self.up = up }
    }

    /// The undo step Select ▸ All, None and Invert push, and A, Alt+A and
    /// Ctrl+I: `select_all`'s name, which is what Blender's undo history
    /// shows for each of the three (measured in desktop 5.2.1 with the app's
    /// undo stack, objects, meshes, curves and lattices alike).
    public static let selectAllUndo = "(De)select All"

    /// What a row does.
    public enum Action: Equatable, Sendable {
        /// `BpyBridge.run(python, undo: undo)`.
        case run(python: String, undo: String)
        /// `BpyBridge.perform(op)`: with Blender's redo panel.
        case perform(LastOperator)
    }

    /// One row of either menu, as the menu and the DEBUG launch hook name it.
    public enum Command: Equatable, Sendable {
        case all, none, invert
        case mesh(MeshItem)
        case similar(SimilarType)
        /// Select Loops ▸ Edge Loops and Edge Rings: the operators the Mesh
        /// menu's Select Loops group has run since round 2, the same values.
        case loops(LastOperator.Mesh)
        case object(ObjectItem)
        case byType(String)
        case linked(String)
        case pattern(String)
        /// Select ▸ Select Grouped, by its type's identifier.
        case grouped(String)

        /// What the row sends. All, None and Invert are the rows the Select
        /// button's menu and the A / Alt+A / Ctrl+I keys already sent, with
        /// the same undo names. `view` is where the 3D View looks, which Side
        /// of Active's View axis reads; `selectMode` is Blender's select mode,
        /// which Select Linked ▸ Linked's first-press Delimit follows
        /// (`MeshItem.parameters(selectMode:)`).
        public func action(editing: Bool, view: ViewDirection? = nil,
                           selectMode: MeshSelectMode? = nil) -> Action {
            switch self {
            // One operator for all three, `select_all`, whose name is the
            // step Blender's undo history shows for each (measured in 5.2.1,
            // object and edit mode: "(De)select All").
            case .all:    return .run(python: Bpy.selectAll(editing: editing), undo: SelectMenu.selectAllUndo)
            case .none:   return .run(python: Bpy.deselectAll(editing: editing), undo: SelectMenu.selectAllUndo)
            case .invert: return .run(python: Bpy.invertSelection(editing: editing), undo: SelectMenu.selectAllUndo)
            case .mesh(let item):     return .perform(item.operation(view: view, selectMode: selectMode))
            case .similar(let type):  return .perform(type.operation)
            case .loops(let op):      return .perform(LastOperator.mesh(op))
            case .object(let item):   return item.action
            case .byType(let type):   return SelectMenu.selectByType(type)
            case .linked(let type):   return SelectMenu.selectLinked(type)
            case .pattern(let text):  return SelectMenu.selectPattern(text)
            case .grouped(let type):  return SelectMenu.selectGrouped(type)
            }
        }

        /// `all`, `more`, `linked`, `similar:VERT_NORMAL`, `loops:selectEdgeLoops`,
        /// `object:mirror`, `type:MESH`, `objlinked:OBDATA`, `pattern:Wheel*` —
        /// how `-select-menu` names a row.
        public init?(token: String) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let head = parts[0], tail = parts.count > 1 ? parts[1] : ""
            switch head {
            case "all":    self = .all
            case "none":   self = .none
            case "invert": self = .invert
            case "similar":
                guard let type = SimilarType(rawValue: tail) else { return nil }
                self = .similar(type)
            case "loops":
                guard let op = LastOperator.Mesh(rawValue: tail) else { return nil }
                self = .loops(op)
            case "object":
                guard let item = ObjectItem(rawValue: tail) else { return nil }
                self = .object(item)
            case "type":    self = .byType(tail)
            case "objlinked": self = .linked(tail)
            case "pattern": self = .pattern(tail)
            case "grouped":
                guard SelectMenu.groupedTypes.contains(where: { $0.identifier == tail }) else { return nil }
                self = .grouped(tail)
            default:
                guard let item = MeshItem(rawValue: head) else { return nil }
                self = .mesh(item)
            }
        }
    }

    // MARK: edit mode

    /// The edit-mode rows beyond All / None / Invert and the tools.
    public enum MeshItem: String, CaseIterable, Sendable {
        case mirror, random, checkerDeselect
        case more, less, nextActive, previousActive
        case similarRegion
        case nonManifold, loose, interiorFaces, facesBySides, polesByCount, ungrouped
        case linked, shortestPath, linkedFlat
        case boundaryLoops, loopInnerRegion, boundaryOfSelected
        case sharpEdges, sideOfActive, byAttribute

        /// The row, as Blender's menu labels it.
        public var title: String {
            switch self {
            case .mirror:             return "Select Mirror"
            case .random:             return "Select Random"
            case .checkerDeselect:    return "Checker Deselect"
            case .more:               return "More"
            case .less:               return "Less"
            case .nextActive:         return "Next Active"
            case .previousActive:     return "Previous Active"
            case .similarRegion:      return "Face Regions"
            case .nonManifold:        return "Non Manifold"
            case .loose:              return "Loose Geometry"
            case .interiorFaces:      return "Interior Faces"
            case .facesBySides:       return "Faces by Sides"
            case .polesByCount:       return "Poles by Count"
            case .ungrouped:          return "Ungrouped Vertices"
            case .linked:             return "Linked"
            case .shortestPath:       return "Shortest Path"
            case .linkedFlat:         return "Linked Flat Faces"
            case .boundaryLoops:      return "Boundary Loops"
            case .loopInnerRegion:    return "Loop Inner-Region"
            case .boundaryOfSelected: return "Boundary of Selected"
            case .sharpEdges:         return "Sharp Edges"
            case .sideOfActive:       return "Side of Active"
            case .byAttribute:        return "By Attribute"
            }
        }

        /// The operator's own name — its `bl_label`, read from `get_rna_type()`
        /// in 5.2.1 — which is what Blender calls the undo step and titles the
        /// redo panel with.
        public var operatorName: String {
            switch self {
            case .mirror:             return "Select Mirror"
            case .random:             return "Select Random"
            case .checkerDeselect:    return "Checker Deselect"
            case .more:               return "Select More"
            case .less:               return "Select Less"
            case .nextActive:         return "Select Next Element"
            case .previousActive:     return "Select Previous Element"
            case .similarRegion:      return "Select Similar Regions"
            case .nonManifold:        return "Select Non-Manifold"
            case .loose:              return "Select Loose Geometry"
            case .interiorFaces:      return "Select Interior Faces"
            case .facesBySides:       return "Select Faces by Sides"
            case .polesByCount:       return "Select By Pole Count"
            case .ungrouped:          return "Select Ungrouped"
            case .linked:             return "Select Linked All"
            case .shortestPath:       return "Select Shortest Path"
            case .linkedFlat:         return "Select Linked Flat Faces"
            case .boundaryLoops:      return "Multi Select Boundary Loops"
            case .loopInnerRegion:    return "Select Loop Inner-Region"
            case .boundaryOfSelected: return "Select Boundary of Selected"
            case .sharpEdges:         return "Select Sharp Edges"
            case .sideOfActive:       return "Select Axis"
            case .byAttribute:        return "Select by Attribute"
            }
        }

        public var call: String {
            switch self {
            case .mirror:             return "bpy.ops.mesh.select_mirror"
            case .random:             return "bpy.ops.mesh.select_random"
            case .checkerDeselect:    return "bpy.ops.mesh.select_nth"
            case .more:               return "bpy.ops.mesh.select_more"
            case .less:               return "bpy.ops.mesh.select_less"
            case .nextActive:         return "bpy.ops.mesh.select_next_item"
            case .previousActive:     return "bpy.ops.mesh.select_prev_item"
            case .similarRegion:      return "bpy.ops.mesh.select_similar_region"
            case .nonManifold:        return "bpy.ops.mesh.select_non_manifold"
            case .loose:              return "bpy.ops.mesh.select_loose"
            case .interiorFaces:      return "bpy.ops.mesh.select_interior_faces"
            case .facesBySides:       return "bpy.ops.mesh.select_face_by_sides"
            case .polesByCount:       return "bpy.ops.mesh.select_by_pole_count"
            case .ungrouped:          return "bpy.ops.mesh.select_ungrouped"
            case .linked:             return "bpy.ops.mesh.select_linked"
            case .shortestPath:       return "bpy.ops.mesh.shortest_path_select"
            case .linkedFlat:         return "bpy.ops.mesh.faces_select_linked_flat"
            case .boundaryLoops:      return "bpy.ops.mesh.select_boundary_loop_multi"
            case .loopInnerRegion:    return "bpy.ops.mesh.loop_to_region"
            case .boundaryOfSelected: return "bpy.ops.mesh.region_to_loop"
            case .sharpEdges:         return "bpy.ops.mesh.edges_select_sharp"
            case .sideOfActive:       return "bpy.ops.mesh.select_axis"
            case .byAttribute:        return "bpy.ops.mesh.select_by_attribute"
            }
        }

        /// Whether the row applies in a select mode. Blender's menu leaves Non
        /// Manifold out in face mode (`VIEW3D_MT_edit_mesh_select_by_trait`),
        /// and the operator refuses there.
        public func isOffered(in mode: MeshSelectMode) -> Bool {
            self != .nonManifold || mode != .face
        }

        /// Whether Blender's poll would let the row run, for the rows the menu
        /// draws greyed rather than leaves out, as Blender's menu does with an
        /// operator whose poll fails. Ungrouped Vertices, measured in 5.2.1:
        /// in edge or face mode "Must be in vertex selection mode", and in
        /// vertex mode on a cube with no group — or with a group holding no
        /// weight — "No weights/vertex groups on object"; with 2 of 8 weighted
        /// it finished and selected the other 6. `vertexGroups` is how many
        /// groups the mirror reported, nil when it reported none (the
        /// simulator). A group with no weights still gets Blender's words.
        public func isEnabled(in mode: MeshSelectMode, vertexGroups: Int?) -> Bool {
            guard self == .ungrouped else { return true }
            return mode == .vertex && (vertexGroups ?? 1) > 0
        }

        /// Blender's redo-panel fields, with its defaults and soft ranges
        /// (`get_rna_type()` in 5.2.1). Only the ones that change what is
        /// selected; the ones that tag edges instead (Shortest Path's Edge
        /// Tag) are left at Blender's default. `selectMode` is Blender's select
        /// mode, which Linked's Delimit starts from.
        func parameters(selectMode: MeshSelectMode?) -> [LastOperator.Parameter] {
            typealias P = LastOperator.Parameter
            let offOn = [P.Option("False", "Off"), P.Option("True", "On")]
            func toggle(_ key: String, _ label: String, _ on: Bool) -> P {
                P(key: key, label: label, kind: .literal(offOn), value: on ? 1 : 0,
                  softMin: 0, softMax: 1, step: 0.02)
            }
            let comparison = [P.Option("LESS", "Less Than"), P.Option("EQUAL", "Equal To"),
                              P.Option("GREATER", "Greater Than"), P.Option("NOTEQUAL", "Not Equal To")]
            switch self {
            case .mirror:
                return [P(key: "axis", label: "Axis",
                          kind: .literal([P.Option("{'X'}", "X"), P.Option("{'Y'}", "Y"),
                                          P.Option("{'Z'}", "Z")]),
                          value: 0, softMin: 0, softMax: 2, step: 0.02),
                        toggle("extend", "Extend", false)]
            case .random:
                // A factor (subtype FACTOR, measured in 5.2.1), which Blender
                // shows as 0.500, not as a percentage.
                return [P(key: "ratio", label: "Ratio", kind: .float, value: 0.5,
                          softMin: 0, softMax: 1, step: 0.004, unit: .none),
                        P(key: "seed", label: "Random Seed", kind: .integer, value: 0,
                          softMin: 0, softMax: 255, step: 0.05),
                        P(key: "action", label: "Action",
                          kind: .choice([P.Option("SELECT", "Select"), P.Option("DESELECT", "Deselect")]),
                          value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .checkerDeselect:
                return [P(key: "skip", label: "Deselected", kind: .integer, value: 1,
                          softMin: 1, softMax: 100, step: 0.05),
                        P(key: "nth", label: "Selected", kind: .integer, value: 1,
                          softMin: 1, softMax: 100, step: 0.05),
                        P(key: "offset", label: "Offset", kind: .integer, value: 0,
                          softMin: -100, softMax: 100, step: 0.05)]
            case .more, .less:
                return [toggle("use_face_step", "Face Step", true)]
            case .nonManifold:
                return [toggle("extend", "Extend", true), toggle("use_wire", "Wire", true),
                        toggle("use_boundary", "Boundaries", true),
                        toggle("use_multi_face", "Multiple Faces", true),
                        toggle("use_non_contiguous", "Non Contiguous", true),
                        toggle("use_verts", "Vertices", true)]
            case .loose, .ungrouped:
                return [toggle("extend", "Extend", false)]
            case .facesBySides:
                return [P(key: "number", label: "Number of Vertices", kind: .integer, value: 4,
                          softMin: 3, softMax: 100, step: 0.05),
                        P(key: "type", label: "Type", kind: .choice(comparison), value: 1,
                          softMin: 0, softMax: 3, step: 0.02),
                        toggle("extend", "Extend", true)]
            case .polesByCount:
                return [P(key: "pole_count", label: "Pole Count", kind: .integer, value: 4,
                          softMin: 0, softMax: 100, step: 0.05),
                        P(key: "type", label: "Type", kind: .choice(comparison), value: 3,
                          softMin: 0, softMax: 3, step: 0.02),
                        toggle("extend", "Extend", false),
                        toggle("exclude_nonmanifold", "Exclude Non Manifold", true)]
            case .linked:
                // Blender's Ctrl+L and its Select Linked ▸ Linked row call
                // `select_linked` with no Delimit, and its exec then picks one
                // by the scene's select mode (USE_LINKED_SELECT_DEFAULT_HACK,
                // `select_linked_delimit_default_from_op`, editmesh_select.cc):
                // on a first press none while vertices or edges are selectable,
                // Seam in Face mode alone. This row sent Seam in every mode, and
                // round 4's review measured the difference in 5.2.1 on a 4 × 4
                // grid with a seam down its middle: Blender's Ctrl+L 25
                // vertices in Vertex and in Edge mode, this row 15. The panel
                // draws the enum flag as Blender's does, one toggle per item
                // under its heading, with 5.2.1's items and labels
                // (`get_rna_type()`, measured). Without the select mode the
                // row leaves Delimit to Blender's own rule and has no panel
                // row for it, rather than show a value Blender may not use.
                guard let selectMode else { return [] }
                return P.flags("delimit", "Delimit",
                               [("NORMAL", "Normal"), ("MATERIAL", "Material"), ("SEAM", "Seam"),
                                ("SHARP", "Sharp"), ("UV", "UVs")],
                               on: selectMode == .face ? ["SEAM"] : [])
            case .shortestPath:
                return [toggle("use_face_step", "Face Stepping", false),
                        toggle("use_topology_distance", "Topology Distance", false),
                        toggle("use_fill", "Fill Region", false)]
            case .linkedFlat:
                return [P(key: "sharpness", label: "Sharpness", kind: .float, value: 1 * .pi / 180,
                          softMin: 1 * .pi / 180, softMax: .pi, step: 0.002, unit: .degrees)]
            case .sharpEdges:
                return [P(key: "sharpness", label: "Sharpness", kind: .float, value: 30 * .pi / 180,
                          softMin: 1 * .pi / 180, softMax: .pi, step: 0.002, unit: .degrees)]
            case .boundaryLoops:
                return [toggle("extend", "Extend", true)]
            case .loopInnerRegion:
                return [toggle("select_bigger", "Select Bigger", false)]
            case .sideOfActive:
                // `select_axis` (5.2.1): Axis Mode from Local, the sign, the
                // axis, and Threshold 0.0001 within 0.00001 … 10.
                return [P(key: "orientation", label: "Axis Mode",
                          kind: .choice([P.Option("GLOBAL", "Global"), P.Option("LOCAL", "Local"),
                                         P.Option("NORMAL", "Normal"), P.Option("GIMBAL", "Gimbal"),
                                         P.Option("VIEW", "View"), P.Option("CURSOR", "Cursor"),
                                         P.Option("PARENT", "Parent")]),
                          value: 1, softMin: 0, softMax: 6, step: 0.02),
                        P(key: "sign", label: "Axis Sign",
                          kind: .choice([P.Option("POS", "Positive Axis"), P.Option("NEG", "Negative Axis"),
                                         P.Option("ALIGN", "Aligned Axis")]),
                          value: 0, softMin: 0, softMax: 2, step: 0.02),
                        P(key: "axis", label: "Axis",
                          kind: .choice([P.Option("X", "X"), P.Option("Y", "Y"), P.Option("Z", "Z")]),
                          value: 0, softMin: 0, softMax: 2, step: 0.02),
                        P(key: "threshold", label: "Threshold", kind: .float, value: 0.0001,
                          softMin: 0.00001, softMax: 10, step: 0.0004, unit: .meters)]
            case .similarRegion, .interiorFaces, .boundaryOfSelected, .nextActive, .previousActive, .byAttribute:
                return []
            }
        }

        /// The words for a CANCELLED Blender says nothing about. Measured in
        /// 5.2.1: Shortest Path with one element selected returns CANCELLED,
        /// raises nothing and changes nothing (`edbm_shortest_path_select_exec`
        /// wants two of the same kind).
        var refusal: String? {
            switch self {
            case .shortestPath:
                return "It selects the path between two selected elements: select two first"
            case .sideOfActive:
                // Measured in 5.2.1: CANCELLED with no active vertex, and with
                // an active edge or face.
                return "It selects the vertices on one side of the active vertex — the one selected "
                    + "last — and there is none: tap a vertex first"
            default:
                return nil
            }
        }

        /// The words for a FINISHED that changed no selection and not the
        /// order: measured in 5.2.1, Select Next Element with fewer than two
        /// elements in the order and Select Previous Element with none both
        /// return FINISHED, saying only "Selection pair not found" or "Last
        /// selected not found" in a report a bpy module cannot read.
        var unchangedSelection: String? {
            switch self {
            case .nextActive:
                return "Next Active walks on from the last two elements selected, in the order they "
                    + "were selected, and there are not two to walk from. Tap one, then another next to it."
            case .previousActive:
                return "Previous Active takes back the element selected last, and nothing has been "
                    + "selected one at a time. Tap an element first."
            default:
                return nil
            }
        }

        public var operation: LastOperator { operation(view: nil) }

        /// The row's operator. Side of Active runs in the borrowed 3D View
        /// aimed as `view` looks, when given: its View axis reads the view's
        /// rotation, and without a view it reads the world's (measured in
        /// 5.2.1, both ways: with no view View selected what Global does).
        /// `selectMode` is Blender's, for Linked's Delimit.
        public func operation(view: ViewDirection?, selectMode: MeshSelectMode? = nil) -> LastOperator {
            var op = LastOperator(name: operatorName, call: call, parameters: parameters(selectMode: selectMode),
                                  restoration: .restoreMesh, needsEditMode: true)
            op.refusal = refusal
            op.unchangedSelection = unchangedSelection
            if self == .sideOfActive, let view {
                func v(_ p: SIMD3<Float>) -> String { "(\(p.x), \(p.y), \(p.z))" }
                op.lead = "import _blenderkit_select"
                op.within = "_blenderkit_select.aimed_view('Side of Active', forward=\(v(view.forward)), "
                    + "up=\(v(view.up)))"
            }
            return op
        }
    }

    /// Select ▸ Select Similar's types. Blender lists the ones for the select
    /// mode in use (`select_similar_type_itemf`); asked for another mode's,
    /// the call fails ("enum "EDGE_LENGTH" not found in ('VERT_NORMAL', …)",
    /// measured in 5.2.1), so the menu offers exactly that mode's.
    public enum SimilarType: String, CaseIterable, Sendable {
        case vertNormal = "VERT_NORMAL", vertFaces = "VERT_FACES", vertGroups = "VERT_GROUPS"
        case vertEdges = "VERT_EDGES", vertCrease = "VERT_CREASE"
        case edgeLength = "EDGE_LENGTH", edgeDirection = "EDGE_DIR", edgeFaces = "EDGE_FACES"
        case edgeFaceAngle = "EDGE_FACE_ANGLE", edgeCrease = "EDGE_CREASE", edgeBevel = "EDGE_BEVEL"
        case edgeSeam = "EDGE_SEAM", edgeSharp = "EDGE_SHARP", edgeFreestyle = "EDGE_FREESTYLE"
        case faceMaterial = "FACE_MATERIAL", faceArea = "FACE_AREA", faceSides = "FACE_SIDES"
        case facePerimeter = "FACE_PERIMETER", faceNormal = "FACE_NORMAL"
        case faceCoplanar = "FACE_COPLANAR", faceSmooth = "FACE_SMOOTH", faceFreestyle = "FACE_FREESTYLE"

        /// Blender's label for it.
        public var label: String {
            switch self {
            case .vertNormal:    return "Normal"
            case .vertFaces:     return "Amount of Adjacent Faces"
            case .vertGroups:    return "Vertex Groups"
            case .vertEdges:     return "Amount of Connecting Edges"
            case .vertCrease:    return "Vertex Crease"
            case .edgeLength:    return "Length"
            case .edgeDirection: return "Direction"
            case .edgeFaces:     return "Amount of Faces Around an Edge"
            case .edgeFaceAngle: return "Face Angles"
            case .edgeCrease:    return "Crease"
            case .edgeBevel:     return "Bevel"
            case .edgeSeam:      return "Seam"
            case .edgeSharp:     return "Sharpness"
            case .edgeFreestyle: return "Freestyle Edge Marks"
            case .faceMaterial:  return "Material"
            case .faceArea:      return "Area"
            case .faceSides:     return "Polygon Sides"
            case .facePerimeter: return "Perimeter"
            case .faceNormal:    return "Normal"
            case .faceCoplanar:  return "Coplanar"
            case .faceSmooth:    return "Flat/Smooth"
            case .faceFreestyle: return "Freestyle Face Marks"
            }
        }

        public var mode: MeshSelectMode {
            if rawValue.hasPrefix("VERT_") { return .vertex }
            if rawValue.hasPrefix("EDGE_") { return .edge }
            return .face
        }

        public static func offered(in mode: MeshSelectMode) -> [SimilarType] {
            allCases.filter { $0.mode == mode }
        }

        /// The operator, with Blender's panel: the type among its mode's,
        /// then Compare and Threshold.
        public var operation: LastOperator {
            typealias P = LastOperator.Parameter
            let types = Self.offered(in: mode)
            let index = types.firstIndex(of: self) ?? 0
            return LastOperator(
                name: "Select Similar", call: "bpy.ops.mesh.select_similar",
                parameters: [
                    P(key: "type", label: "Type",
                      kind: .choice(types.map { P.Option($0.rawValue, $0.label) }),
                      value: Double(index), softMin: 0, softMax: Double(types.count - 1), step: 0.02),
                    P(key: "compare", label: "Compare",
                      kind: .choice([P.Option("EQUAL", "Equal"), P.Option("GREATER", "Greater"),
                                     P.Option("LESS", "Less")]),
                      value: 0, softMin: 0, softMax: 2, step: 0.02),
                    P(key: "threshold", label: "Threshold", kind: .float, value: 0,
                      softMin: 0, softMax: 1, step: 0.004, unit: .none)],
                restoration: .restoreMesh, needsEditMode: true)
        }
    }

    // MARK: object mode

    /// The Object Mode rows beyond All / None / Invert and the tools.
    public enum ObjectItem: String, CaseIterable, Sendable {
        case activeCamera, mirror, random
        case more, less, parent, child, extendParent, extendChild

        public var title: String {
            switch self {
            case .activeCamera: return "Select Active Camera"
            case .mirror:       return "Select Mirror"
            case .random:       return "Select Random"
            case .more:         return "More"
            case .less:         return "Less"
            case .parent:       return "Parent"
            case .child:        return "Child"
            case .extendParent: return "Extend Parent"
            case .extendChild:  return "Extend Child"
            }
        }

        /// The operator's `bl_label`, which names the undo step.
        public var operatorName: String {
            switch self {
            case .activeCamera: return "Select Camera"
            case .mirror:       return "Select Mirror"
            case .random:       return "Select Random"
            case .more:         return "Select More"
            case .less:         return "Select Less"
            case .parent, .child, .extendParent, .extendChild: return "Select Hierarchy"
            }
        }

        /// The operator, bare: its arguments are the redo panel's.
        public var call: String {
            switch self {
            case .activeCamera: return "bpy.ops.object.select_camera"
            case .mirror:       return "bpy.ops.object.select_mirror"
            case .random:       return "bpy.ops.object.select_random"
            case .more:         return "bpy.ops.object.select_more"
            case .less:         return "bpy.ops.object.select_less"
            case .parent, .child, .extendParent, .extendChild: return "bpy.ops.object.select_hierarchy"
            }
        }

        /// What Blender's CANCELLED means for each, in words. The banner puts
        /// the operator's name in front, so these do not repeat it. Measured
        /// in 5.2.1: More, Less, Parent and Child return CANCELLED, changing
        /// nothing, when there is nothing to add or take away, and Select
        /// Active Camera when the scene has no camera; Mirror and Random
        /// always finish.
        var refusal: String {
            switch self {
            case .activeCamera:
                return "The scene has no camera."
            case .mirror, .random:
                return "Blender changed nothing."
            case .more:
                return "Nothing selected has a parent or a child to add."
            case .less:
                return "Nothing selected is at the end of a parent–child chain to take away."
            case .parent, .extendParent:
                return "Nothing selected has a parent."
            case .child, .extendChild:
                return "Nothing selected has a child."
            }
        }

        /// Whether the row needs an active object. Select Hierarchy's poll
        /// fails without one ("context is incorrect", measured in 5.2.1 —
        /// and after a Deselect All there often is none), so the row is
        /// refused in words first, and greyed out in the menu.
        public var needsActive: Bool {
            switch self {
            case .parent, .child, .extendParent, .extendChild: return true
            default: return false
            }
        }

        /// Blender's redo-panel fields (5.2.1, `get_rna_type()`).
        var parameters: [LastOperator.Parameter] {
            typealias P = LastOperator.Parameter
            switch self {
            case .activeCamera, .mirror:
                return [SelectMenu.toggle("extend", "Extend", false)]
            case .random:
                // A factor (subtype FACTOR), which Blender shows as 0.500.
                return [P(key: "ratio", label: "Ratio", kind: .float, value: 0.5,
                          softMin: 0, softMax: 1, step: 0.004, unit: .none),
                        P(key: "seed", label: "Random Seed", kind: .integer, value: 0,
                          softMin: 0, softMax: 255, step: 0.05),
                        P(key: "action", label: "Action",
                          kind: .choice([P.Option("SELECT", "Select"), P.Option("DESELECT", "Deselect")]),
                          value: 0, softMin: 0, softMax: 1, step: 0.02)]
            case .more, .less:
                return []
            case .parent, .child, .extendParent, .extendChild:
                return [P(key: "direction", label: "Direction",
                          kind: .choice([P.Option("PARENT", "Parent"), P.Option("CHILD", "Child")]),
                          value: self == .parent || self == .extendParent ? 0 : 1,
                          softMin: 0, softMax: 1, step: 0.02),
                        SelectMenu.toggle("extend", "Extend", self == .extendParent || self == .extendChild)]
            }
        }

        public var operation: LastOperator {
            SelectMenu.objectOperation(name: operatorName, call: call, parameters: parameters,
                                       refusal: refusal, needsActive: needsActive ? title : nil,
                                       refuseUnchanged: self == .mirror || self == .random)
        }

        public var action: Action { .perform(operation) }
    }

    /// An Off/On row of a redo panel.
    static func toggle(_ key: String, _ label: String, _ on: Bool) -> LastOperator.Parameter {
        LastOperator.Parameter(key: key, label: label,
                               kind: .literal([LastOperator.Parameter.Option("False", "Off"),
                                               LastOperator.Parameter.Option("True", "On")]),
                               value: on ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)
    }

    /// An Object Mode row as an adjustable operator: Blender's call with its
    /// redo panel, inside `_blenderkit_select.object_select`, which refuses
    /// first what needs an active object, puts back what a CANCELLED or an
    /// error changed on the way, and — for the operators that always finish —
    /// refuses a run that left the selection and the active object as they
    /// were (`refuseUnchanged`), so no step is recorded for it. Blender's own
    /// undo puts the selection back for a re-run (`.throughBlenderUndo`).
    static func objectOperation(name: String, call: String, parameters: [LastOperator.Parameter],
                                fixed: [String] = [], refusal: String, needsActive row: String? = nil,
                                refuseUnchanged: Bool = false) -> LastOperator {
        var op = LastOperator(name: name, call: call, parameters: parameters,
                              restoration: .throughBlenderUndo, needsEditMode: false)
        op.fixedArguments = fixed
        op.guardWithin = "object_select(\(Bpy.quote(refusal)), unchanged="
            + (refuseUnchanged ? "True" : "False")
            + (row.map { ", needs_active=\(Bpy.quote($0))" } ?? "") + ")"
        op.refusal = refusal
        // Select Grouped is the exec's port, which the log names as it runs.
        if call.hasPrefix("_blenderkit_select.") { op.lead = "import _blenderkit_select" }
        return op
    }

    /// Select ▸ Select All by Type: Blender's `object.select_by_type` types.
    public static let objectTypes: [(identifier: String, label: String)] = [
        ("MESH", "Mesh"), ("CURVE", "Curve"), ("SURFACE", "Surface"), ("META", "Metaball"),
        ("FONT", "Text"), ("CURVES", "Hair Curves"), ("POINTCLOUD", "Point Cloud"),
        ("VOLUME", "Volume"), ("GREASEPENCIL", "Grease Pencil"), ("ARMATURE", "Armature"),
        ("LATTICE", "Lattice"), ("EMPTY", "Empty"), ("LIGHT", "Light"),
        ("LIGHT_PROBE", "Light Probe"), ("CAMERA", "Camera"), ("SPEAKER", "Speaker")]

    /// Select ▸ Select Linked: Blender's `object.select_linked` types.
    public static let linkedTypes: [(identifier: String, label: String)] = [
        ("OBDATA", "Object Data"), ("MATERIAL", "Material"), ("DUPGROUP", "Instanced Collection"),
        ("PARTICLE", "Particle System"), ("LIBRARY", "Library"),
        ("LIBRARY_OBDATA", "Library (Object Data)")]

    /// Select ▸ Select Grouped: Blender's `object.select_grouped` types
    /// (prop_select_grouped_types, 5.2.1), as its menu lists them.
    public static let groupedTypes: [(identifier: String, label: String)] = [
        ("CHILDREN_RECURSIVE", "Children"), ("CHILDREN", "Immediate Children"), ("PARENT", "Parent"),
        ("SIBLINGS", "Siblings"), ("TYPE", "Type"), ("COLLECTION", "Collection"), ("HOOK", "Hook"),
        ("PASS", "Pass"), ("COLOR", "Color"), ("KEYINGSET", "Keying Set"), ("LIGHT_TYPE", "Light Type")]

    /// A choice row of `items`, starting at `identifier`.
    private static func typeRow(_ items: [(identifier: String, label: String)],
                                _ identifier: String) -> LastOperator.Parameter {
        LastOperator.Parameter(key: "type", label: "Type",
                               kind: .choice(items.map { LastOperator.Parameter.Option($0.identifier, $0.label) }),
                               value: Double(items.firstIndex { $0.identifier == identifier } ?? 0),
                               softMin: 0, softMax: Double(items.count - 1), step: 0.02)
    }

    /// Measured in 5.2.1: with none of the type it finishes, having
    /// deselected everything (Extend is off), as Blender's menu does.
    public static func selectByType(_ identifier: String) -> Action {
        .perform(objectOperation(name: "Select by Type", call: "bpy.ops.object.select_by_type",
                                 parameters: [toggle("extend", "Extend", false), typeRow(objectTypes, identifier)],
                                 refusal: "Blender changed nothing.", refuseUnchanged: true))
    }

    /// Measured in 5.2.1: by Material, Instanced Collection or Particle System
    /// on an object with none returns CANCELLED — having deselected
    /// everything first — and with no active object it raises "No active
    /// object", again after deselecting. `object_select` puts the selection
    /// back either way, so a refused row changes nothing and leaves no step
    /// nobody can undo.
    public static func selectLinked(_ identifier: String) -> Action {
        let label = linkedTypes.first { $0.identifier == identifier }?.label ?? identifier
        return .perform(objectOperation(name: "Select Linked", call: "bpy.ops.object.select_linked",
                                        parameters: [toggle("extend", "Extend", false),
                                                     typeRow(linkedTypes, identifier)],
                                        refusal: "The active object has no " + label.lowercased()
                                            + " for others to share.",
                                        needsActive: "Select Linked"))
    }

    /// Select ▸ Select Pattern…, Blender's defaults: not case sensitive, and
    /// added to the selection. The pattern is what was typed; the panel has
    /// Blender's Case Sensitive and Extend.
    public static func selectPattern(_ pattern: String) -> Action {
        .perform(objectOperation(name: "Select Pattern", call: "bpy.ops.object.select_pattern",
                                 parameters: [toggle("case_sensitive", "Case Sensitive", false),
                                              toggle("extend", "Extend", true)],
                                 fixed: ["pattern=\(Bpy.quote(pattern))"],
                                 refusal: "No unselected object's name matches \(Bpy.quote(pattern)).",
                                 refuseUnchanged: true))
    }

    /// Select ▸ Select Grouped, as `object_select_grouped_exec` does it
    /// (`_blenderkit_select.select_grouped`: Blender's own operator fails its
    /// poll without an interface). Its CANCELLED is a run that changed no
    /// selection; the active object is what every type starts from.
    public static func selectGrouped(_ identifier: String) -> Action {
        .perform(objectOperation(name: "Select Grouped", call: "_blenderkit_select.select_grouped",
                                 parameters: [toggle("extend", "Extend", false), typeRow(groupedTypes, identifier)],
                                 refusal: "Nothing else is grouped with the active object that way.",
                                 needsActive: "Select Grouped"))
    }

    // MARK: region selects on objects

    /// What a Box, Circle or Lasso gesture over objects sends: `names` are the
    /// objects the region covers (`RegionSelect.objects`), combined with the
    /// selection as `action` says (Blender's `sel_op_result`).
    ///
    /// Blender leaves the active object alone. The app's box select has made
    /// the first object it caught active since it was built, because the
    /// Properties panel shows the active one; that stays, but only when
    /// the active object is no longer selected — otherwise a box that also
    /// caught the object being edited would take its panel away.
    public static func objectRegion(_ names: [String], action: SelectAction) -> String {
        let list = names.map { Bpy.quote($0) }.joined(separator: ", ")
        var lines: [String] = []
        switch action {
        case .set:
            lines.append(Bpy.deselectAll)
            lines += names.map { "bpy.data.objects[\(Bpy.quote($0))].select_set(True)" }
        case .extend:
            lines += names.map { "bpy.data.objects[\(Bpy.quote($0))].select_set(True)" }
        case .subtract:
            lines += names.map { "bpy.data.objects[\(Bpy.quote($0))].select_set(False)" }
        case .difference:
            lines += names.map {
                "_o = bpy.data.objects[\(Bpy.quote($0))]\n_o.select_set(not _o.select_get())"
            }
        case .intersect:
            lines.append(names.isEmpty ? "_bk_hit = set()" : "_bk_hit = {\(list)}")
            lines.append("""
                for _o in list(bpy.data.objects):
                    if _o.name not in _bk_hit and _o.select_get():
                        _o.select_set(False)
                """)
        }
        if let first = names.first, action == .set || action == .extend || action == .difference {
            lines.append("""
                _a = bpy.context.view_layer.objects.active
                if (_a is None or not _a.select_get()) and bpy.data.objects[\(Bpy.quote(first))].select_get():
                    bpy.context.view_layer.objects.active = bpy.data.objects[\(Bpy.quote(first))]
                """)
        }
        if lines.isEmpty { lines.append("pass") }
        return lines.joined(separator: "\n")
    }
}
