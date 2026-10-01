import Foundation

// Blender's Object menu rows that were reachable only by name through All
// Blender Tools — Duplicate Linked, Join, Parent, Clear Parent and Convert —
// and the Transform menu's Shear, as operators the redo panel can adjust.
//
// Every string here was run first in desktop Blender 5.2.1 with the app's
// context (an undo stack from `ed.undo_push` under a window and screen
// override, `gpu.init()`, the startup screen's 3D View for Shear), and each
// refusal below answers a case measured there where Blender either fails its
// poll with "context is incorrect" or returns FINISHED having done nothing.
// scripts/run-objectops-blender-check.sh holds them to it.

public extension LastOperator {

    /// Object ▸ Duplicate Linked, Blender's Alt+D: a copy of each selected
    /// object sharing its data, selected and active, where the original is.
    /// Measured: `A.001` holding mesh `A`; with nothing selected, CANCELLED and
    /// nothing said.
    static func duplicateLinked() -> LastOperator {
        var op = LastOperator(name: "Duplicate Linked", call: "bpy.ops.object.duplicate_move_linked",
                              parameters: [], restoration: .throughBlenderUndo)
        op.refusal = "Duplicate Linked copies the selected objects, and none is selected. Select one first."
        return op
    }

    /// The types `object.join` polls True for (5.2.1, measured two of each:
    /// text, metaballs, empties, cameras and lattices fail the poll). Hair
    /// curves and point clouds join too (measured with the app's context: two
    /// hair-curve objects became one of 6 points, two point clouds one of 16);
    /// the Add menu makes neither, so they come from a script or a file.
    static let joinableTypes = ["MESH", "CURVE", "SURFACE", "ARMATURE", "GREASEPENCIL", "CURVES", "POINTCLOUD"]

    /// Object ▸ Join, Blender's Ctrl+J: the other selected objects of the
    /// active object's type merged into it. Three cubes selected: one object
    /// of 24 vertices.
    ///
    /// Refused first when Blender would answer "context is incorrect" — no
    /// active object, or one of a type that does not join. A CANCELLED is
    /// Blender's "No mesh data to join" (nothing else of that type selected)
    /// or "Active object is not a selected mesh", both warnings a bpy module
    /// only prints.
    static func join() -> LastOperator {
        var op = LastOperator(name: "Join", call: "bpy.ops.object.join",
                              parameters: [], restoration: .throughBlenderUndo)
        let types = joinableTypes.map { "'\($0)'" }.joined(separator: ", ")
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None:
            raise RuntimeError('Join merges the selected objects into the active one, and no object '
                               'is active. Select the others, then the one to join into last.')
        if _bk_a.type not in (\(types)):
            raise RuntimeError('Join merges meshes, curves, surfaces, armatures, grease pencil, hair '
                               'curves and point clouds, and '
                               + _bk_a.name + ' is ' + \(Self.typeArticle)
                               + '. Blender cannot join it.')
        """
        op.refusal = "Join needs the active object and at least one other object of its type "
            + "selected: select them, then the one to join into last."
        return op
    }

    /// Object ▸ Parent ▸ Object, Blender's Ctrl+P: the active object becomes
    /// the parent of every other selected object. Keep Transform, its redo
    /// panel's switch, matters when a child already had a parent that has
    /// since moved: measured, re-parenting with it off moved such a child
    /// 2.0 m, with it on not at all. A first parent never moves a child
    /// either way (the parent inverse is set).
    ///
    /// With no active object, or only the active one selected, Blender returns
    /// FINISHED and parents nothing (measured), so both are refused first. A
    /// loop is Blender's own "Loop in parents".
    static func parent(keepTransform: Bool) -> LastOperator {
        var op = LastOperator(
            name: "Make Parent", call: "bpy.ops.object.parent_set",
            parameters: [Parameter(key: "keep_transform", label: "Keep Transform",
                                   kind: .literal([Parameter.Option("False", "Off"),
                                                   Parameter.Option("True", "On")]),
                                   value: keepTransform ? 1 : 0, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .throughBlenderUndo)
        op.fixedArguments = ["type='OBJECT'"]
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None:
            raise RuntimeError('Parent makes the active object the parent of the other selected '
                               'objects, and no object is active. Select the children, then the '
                               'parent last.')
        if not any(_bk_o != _bk_a for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Parent makes ' + _bk_a.name + ' the parent of the other selected '
                               'objects, and no other object is selected. Select the children, '
                               'then the parent last.')
        """
        return op
    }

    /// `object.parent_clear`'s three types, in Blender's order and words.
    enum ClearParentType: String, CaseIterable, Sendable {
        case clear = "CLEAR", keepTransform = "CLEAR_KEEP_TRANSFORM", inverse = "CLEAR_INVERSE"

        public var label: String {
            switch self {
            case .clear:         return "Clear Parent"
            case .keepTransform: return "Clear and Keep Transformation"
            case .inverse:       return "Clear Parent Inverse"
            }
        }
    }

    /// Object ▸ Parent's clearing rows, Blender's Alt+P. Measured on a child
    /// of a turned, moved parent: Clear Parent and Clear and Keep
    /// Transformation both left it where it was (a parent set by Blender
    /// carries its inverse); Clear Parent Inverse kept the parent and moved it
    /// 2.44 m. With nothing selected that has a parent it returns FINISHED
    /// having done nothing, so that is refused first. The type is its panel's
    /// one field, as in Blender's.
    static func clearParent(_ type: ClearParentType) -> LastOperator {
        var op = LastOperator(
            name: "Clear Parent", call: "bpy.ops.object.parent_clear",
            parameters: [Parameter(key: "type", label: "Type",
                                   kind: .choice(ClearParentType.allCases.map {
                                       Parameter.Option($0.rawValue, $0.label)
                                   }),
                                   value: Double(ClearParentType.allCases.firstIndex(of: type) ?? 0),
                                   softMin: 0, softMax: 2, step: 0.02)],
            restoration: .throughBlenderUndo)
        op.lead = """
        if not any(_bk_o.parent is not None for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Clear Parent: nothing selected has a parent')
        """
        return op
    }

    /// Object ▸ Convert's two targets that matter to a mesh modeller.
    enum ConvertTarget: String, CaseIterable, Sendable {
        case mesh = "MESH", curve = "CURVE"

        public var label: String { self == .mesh ? "Mesh" : "Curve" }

        /// What Blender turns into this target, measured in 5.2.1 one type at
        /// a time. To a mesh: meshes (their modifiers applied — a cube under a
        /// level-1 Subdivision came out 26 vertices with no modifier), curves,
        /// surfaces, text, metaballs, hair curves, point clouds and grease
        /// pencil; empties, lights, cameras and lattices answer "None of the
        /// objects are compatible" and FINISHED. To a curve: text, and a
        /// mesh's loose edges — see `Convert`'s lead.
        public var types: [String] {
            switch self {
            case .mesh:  return ["MESH", "CURVE", "SURFACE", "FONT", "META", "CURVES", "POINTCLOUD", "GREASEPENCIL"]
            case .curve: return ["FONT", "MESH"]
            }
        }
    }

    /// Object ▸ Convert ▸ Mesh or Curve, with Keep Original, its panel's
    /// switch (a converted copy beside the original, selected and active).
    ///
    /// Refused first when Blender would convert nothing and say so only in a
    /// report a bpy module prints: nothing selected ("No editable objects to
    /// convert", CANCELLED), or nothing of a type it converts (FINISHED).
    /// A mesh becomes a curve from its *loose* edges alone — edges in no face,
    /// of the mesh with its modifiers: measured, a cube stayed a mesh and a
    /// FINISHED came back; a cube with one loose edge became a curve of that
    /// one edge, its faces gone; a circle under Solidify two 32-point curves.
    /// So a mesh counts for Curve only when its evaluated mesh has one.
    static func convert(to target: ConvertTarget) -> LastOperator {
        var op = LastOperator(
            name: "Convert To", call: "bpy.ops.object.convert",
            parameters: [Parameter(key: "keep_original", label: "Keep Original",
                                   kind: .literal([Parameter.Option("False", "Off"),
                                                   Parameter.Option("True", "On")]),
                                   value: 0, softMin: 0, softMax: 1, step: 0.02)],
            restoration: .throughBlenderUndo)
        op.fixedArguments = ["target='\(target.rawValue)'"]
        let types = target.types.map { "'\($0)'" }.joined(separator: ", ")
        let what = "Convert to \(target.label)"
        var lead = """
        _bk_sel = list(bpy.context.selected_editable_objects)
        if not _bk_sel:
            raise RuntimeError('\(what) converts the selected objects, and none is selected. '
                               'Select one first.')

        """
        switch target {
        case .mesh:
            lead += """
            if not any(_bk_o.type in (\(types)) for _bk_o in _bk_sel):
                raise RuntimeError('\(what) converts curves, surfaces, text, metaballs and meshes, and '
                                   + _bk_sel[0].name + ' is ' + \(Self.typeArticle.replacingOccurrences(of: "_bk_a", with: "_bk_sel[0]"))
                                   + '. Blender converts nothing here.')
            """
        case .curve:
            lead += """
            import array as _bk_array
            _bk_dg = bpy.context.evaluated_depsgraph_get()

            def _bk_has_loose_edge(_bk_o):
                _bk_m = _bk_o.evaluated_get(_bk_dg).data
                _bk_used = _bk_array.array('i', bytes(4 * len(_bk_m.loops)))
                _bk_m.loops.foreach_get('edge_index', _bk_used)
                return len(set(_bk_used)) < len(_bk_m.edges)

            if not any(_bk_o.type == 'FONT' or (_bk_o.type == 'MESH' and _bk_has_loose_edge(_bk_o))
                       for _bk_o in _bk_sel):
                if _bk_sel[0].type == 'MESH':
                    raise RuntimeError('\(what) makes curves from text and from a mesh\\'s loose edges, '
                                       'and every edge of ' + _bk_sel[0].name + ' is part of a face. '
                                       'Blender converts nothing here.')
                raise RuntimeError('\(what) makes curves from text and from a mesh\\'s loose edges, and '
                                   + _bk_sel[0].name + ' is ' + \(Self.typeArticle.replacingOccurrences(of: "_bk_a", with: "_bk_sel[0]"))
                                   + '. Blender converts nothing here.')
            """
        }
        op.lead = lead
        // It answers CANCELLED only when nothing selected is editable, which
        // the lead has already refused; kept for a selection Python sees and
        // the operator does not.
        op.refusal = "\(what): Blender found nothing selected it could convert."
        return op
    }

    /// `_bk_a`'s type as a phrase — "a camera", "an empty" — for a refusal.
    /// The same table `Bpy.needsAMesh` reads out.
    private static let typeArticle = """
    {'MESH': 'a mesh', 'LIGHT': 'a light', 'CAMERA': 'a camera', 'EMPTY': 'an empty', \
    'CURVE': 'a curve', 'SURFACE': 'a surface', 'FONT': 'a text object', \
    'ARMATURE': 'an armature', 'LATTICE': 'a lattice', 'META': 'a metaball', \
    'VOLUME': 'a volume', 'SPEAKER': 'a speaker', 'POINTCLOUD': 'a point cloud', \
    'LIGHT_PROBE': 'a light probe', 'GREASEPENCIL': 'a grease pencil object', \
    'CURVES': 'a hair curves object'}.get(_bk_a.type, 'a ' + _bk_a.type.lower())
    """

    // MARK: Shear

    /// Blender's pairs of `orient_axis` and `orient_axis_ortho`, as one choice.
    ///
    /// The two are separate enums in Blender's panel, and the same axis in
    /// both collapses the selection to a point (measured: every vertex of a
    /// cube at the origin). One row of the six valid pairs cannot be set to
    /// that. Each is written as the Python of both keywords, which is what a
    /// `.literal` option is. A vertex moves along the ortho axis by
    /// −tan(angle) × its distance from the pivot along axis × ortho: with the
    /// default Z and X, measured at 0.5 rad, a cube's vertices at y = −1 moved
    /// +0.5463 in x and those at y = +1 moved −0.5463, whatever their z.
    static let shearAxes: [Parameter.Option] = [
        ("Z", "X", "Along X, by Y"), ("Z", "Y", "Along Y, by X"),
        ("X", "Y", "Along Y, by Z"), ("X", "Z", "Along Z, by Y"),
        ("Y", "Z", "Along Z, by X"), ("Y", "X", "Along X, by Z"),
    ].map { axis, ortho, label in
        Parameter.Option("'\(axis)', orient_axis_ortho='\(ortho)'", label)
    }

    /// Mesh ▸ Transform ▸ Shear: the selected vertices slanted, through the
    /// startup screen's 3D View, whose poll it wants (measured: "context is
    /// incorrect" without it, FINISHED inside `temp_override(window, area,
    /// region)`, with or without `gpu.init()` — it reads no view matrix
    /// that needs the GPU). Orientation is pinned to Global so the result
    /// does not depend on the borrowed view; the pivot is the scene's
    /// (measured: Pivot at the 3D cursor moved the same vertex to −1.5463
    /// where Median Point gave −0.4537).
    ///
    /// This is the Edit Mode row; Object Mode's is `shearObjects`. With
    /// nothing selected it returns CANCELLED.
    ///
    /// The angle's range stops short of ±90°: tan(90°) threw a cube's
    /// vertices to 13 million metres. Blender's soft range is ±360°.
    static func shear() -> LastOperator {
        var op = LastOperator(
            name: "Shear", call: "bpy.ops.transform.shear",
            parameters: [
                Parameter(key: "angle", label: "Angle", kind: .float,
                          value: 20 * .pi / 180, softMin: -80 * .pi / 180, softMax: 80 * .pi / 180,
                          step: 0.004, unit: .degrees),
                Parameter(key: "orient_axis", label: "Axes", kind: .literal(shearAxes),
                          value: 0, softMin: 0, softMax: Double(shearAxes.count - 1), step: 0.02)],
            restoration: .restoreMesh, needsEditMode: true)
        op.fixedArguments = ["orient_type='GLOBAL'"]
        op.lead = "import _blenderkit_context"
        op.within = "_blenderkit_context.temp_override_view3d('Shear')"
        op.refusal = "Shear slants the selected vertices: select some first"
        return op
    }

    /// Object ▸ Transform ▸ Shear: the same call in Object Mode, where it
    /// slides each selected object's origin along one axis by its distance
    /// from the pivot along the other, and leaves its rotation and scale
    /// alone. Measured in 5.2.1 with the app's context (undo stack,
    /// `gpu.init()`, the borrowed 3D View), at 20°, Along X by Y: cubes at
    /// y = −2 and y = +2 went to x = +0.728 and −0.728, rotation and scale
    /// unchanged; with nothing selected, CANCELLED.
    ///
    /// It used to be withheld on a measurement that could not fail: the check
    /// sheared Along X by Y two cubes that both had y = 0, which nothing
    /// moves. Undone through Blender's undo, as the other Object rows are —
    /// there is no mesh to back up.
    static func shearObjects() -> LastOperator {
        let edit = shear()
        var op = LastOperator(name: "Shear", call: edit.call, parameters: edit.parameters,
                              restoration: .throughBlenderUndo)
        op.fixedArguments = edit.fixedArguments
        op.lead = edit.lead
        op.within = edit.within
        op.refusal = "Shear moves the selected objects: select some first"
        return op
    }
}

/// What the Object menu's Duplicate Linked, Join, Parent and Convert rows
/// may do, read from the mirror — so a greyed row is one Blender would refuse.
/// Shared by the Mac menu bar and the 3D View's More menu, as
/// `ObjectTransformState` is for Set Origin and Apply.
public struct ObjectRelationState: Equatable, Sendable {
    /// Object Mode and nothing running: Blender's Object menu is not there
    /// while editing, and these operators are object-mode ones.
    public let available: Bool
    public let selected: Int
    public let hasActive: Bool
    /// Something selected has a parent, which Clear Parent needs.
    public let selectionHasParent: Bool

    public init(available: Bool, selected: Int, hasActive: Bool, selectionHasParent: Bool) {
        self.available = available
        self.selected = selected
        self.hasActive = hasActive
        self.selectionHasParent = selectionHasParent
    }

    public init(scene: BKScene, editing: Bool, isRunning: Bool) {
        let chosen = scene.objects.filter { scene.selection.contains($0.id) }
        self.init(available: !editing && !isRunning, selected: chosen.count,
                  hasActive: scene.active != nil,
                  selectionHasParent: chosen.contains { $0.parentName != nil })
    }

    public var canDuplicate: Bool { available && selected > 0 }
    public var canJoin: Bool { available && hasActive && selected > 1 }
    /// The active object is the parent; something else has to be selected.
    public var canParent: Bool { available && hasActive && selected > 1 }
    public var canClearParent: Bool { available && selectionHasParent }
    public var canConvert: Bool { available && selected > 0 }
}
