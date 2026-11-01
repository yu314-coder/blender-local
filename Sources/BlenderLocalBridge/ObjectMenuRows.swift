import Foundation

// Object menu rows that were reachable only by name through the Operator
// Search (round 3's review, toolkit items 11 and 15): Mirror, Link/Transfer
// Data, Make Single User, Copy Modifiers to Selected Objects, Randomize
// Transform, Align Objects, and the Constraints menu — each where Blender's
// Object menu has it, by its row's label, through `perform` so its redo panel
// is Blender's (round 4, group 7).
//
// Measured in desktop Blender 5.2.1 with the app's context — its undo push,
// `gpu.init()`, a window and a screen and no area (tests/relations/blender):
// every operator below FINISHED there; their history steps, called with their
// undo on, were the operators' names (Link/Transfer Data, Make Single User,
// Copy Modifiers to Selected Objects, Randomize Transform, Align Objects).
// Where Blender answers FINISHED having done nothing, or fails its poll in
// its own words, the row refuses first in a sentence.

public extension LastOperator {

    // MARK: Mirror

    /// The orientations Mirror's panel offers here (`orient_type`'s items in
    /// 5.2.1, in its order). View is left out: it is the borrowed 3D View's
    /// rotation, which is not the app's view, so a mirror "in View" would be
    /// about axes the reader cannot see.
    static let mirrorOrientations: [Parameter.Option] = [
        Parameter.Option("GLOBAL", "Global"), Parameter.Option("LOCAL", "Local"),
        Parameter.Option("NORMAL", "Normal"), Parameter.Option("GIMBAL", "Gimbal"),
        Parameter.Option("CURSOR", "Cursor"), Parameter.Option("PARENT", "Parent"),
    ]

    /// Object ▸ Mirror ▸ X Global … Z Local (Ctrl+M then an axis in
    /// Blender): `transform.mirror` with one axis constrained, in Global or
    /// Local orientation. Measured on a cube turned 0.7 rad about Z: X Global
    /// left scale (-1, 1, 1) and rotation -0.7, X Local scale (-1, 1, 1) and
    /// rotation 0.7; with nothing selected, CANCELLED. Its panel is Blender's:
    /// Orientation and the Constraint Axis toggles (`transform_poll_property`
    /// shows that one for Mirror, which has no Move value).
    static func mirror(axis: Int, local: Bool) -> LastOperator {
        var on = [false, false, false]
        if on.indices.contains(axis) { on[axis] = true }
        let orientation = local ? 1 : 0
        var op = LastOperator(
            name: "Mirror", call: "bpy.ops.transform.mirror",
            parameters: [Parameter(key: "orient_type", label: "Orientation",
                                   kind: .choice(mirrorOrientations), value: Double(orientation),
                                   softMin: 0, softMax: Double(mirrorOrientations.count - 1), step: 0.02)]
                + Parameter.toggles("constraint_axis", "Constraint Axis", on),
            restoration: .throughBlenderUndo)
        op.refusal = "Mirror flips the selected objects: select one first."
        return op
    }

    /// The rows of Object ▸ Mirror after Interactive Mirror, in Blender's
    /// order: X, Y, Z Global, then X, Y, Z Local.
    static let mirrorRows: [(label: String, axis: Int, local: Bool)] = [
        ("X Global", 0, false), ("Y Global", 1, false), ("Z Global", 2, false),
        ("X Local", 0, true), ("Y Local", 1, true), ("Z Local", 2, true),
    ]

    // MARK: Link/Transfer Data

    /// `object.make_links_data`'s Type items in 5.2.1, as Object ▸
    /// Link/Transfer Data lists them (each its own row).
    static let makeLinksTypes: [Parameter.Option] = [
        Parameter.Option("OBDATA", "Link Object Data"), Parameter.Option("MATERIAL", "Link Materials"),
        Parameter.Option("ANIMATION", "Link Animation Data"), Parameter.Option("GROUPS", "Link Collections"),
        Parameter.Option("DUPLICOLLECTION", "Link Instance Collection"),
        Parameter.Option("FONTS", "Link Fonts to Text"), Parameter.Option("MODIFIERS", "Copy Modifiers"),
        Parameter.Option("CONSTRAINTS", "Copy Constraints"),
        Parameter.Option("EFFECTS", "Copy Grease Pencil Effects"),
        Parameter.Option("LIGHT_LINKING", "Copy Light Linking"),
        Parameter.Option("SHADOW_LINKING", "Copy Shadow Linking"),
    ]

    /// Object ▸ Link/Transfer Data (Ctrl+L): the active object's data,
    /// materials, modifiers … onto every other selected object. Measured: two
    /// selected, each type FINISHED (Other took the cube's mesh, its Bevel and
    /// its Copy Location); with only the active selected it answered FINISHED
    /// having done nothing, and with no active object its poll failed
    /// ("context is incorrect") — both refused first.
    static func makeLinksData(_ type: String) -> LastOperator {
        let index = makeLinksTypes.firstIndex { $0.identifier == type } ?? 0
        var op = LastOperator(
            name: "Link/Transfer Data", call: "bpy.ops.object.make_links_data",
            parameters: [Parameter(key: "type", label: "Type", kind: .choice(makeLinksTypes),
                                   value: Double(index), softMin: 0,
                                   softMax: Double(makeLinksTypes.count - 1), step: 0.02)],
            restoration: .throughBlenderUndo)
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None or not _bk_a.select_get():
            raise RuntimeError('Link/Transfer Data copies from the active object to the other selected '
                               'objects, and no selected object is active. Select the others, then the '
                               'one to copy from last.')
        if not any(_bk_o != _bk_a for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Link/Transfer Data copies from ' + _bk_a.name + ' to the other selected '
                               'objects, and no other object is selected.')
        """
        op.refusal = "Link/Transfer Data: Blender found nothing selected to copy onto."
        return op
    }

    /// Object ▸ Link/Transfer Data ▸ Copy UV Maps (`object.join_uvs`, named
    /// Transfer UV Maps): the active mesh's UV map onto the other selected
    /// meshes with the same face count. No panel fields.
    static func copyUVMaps() -> LastOperator {
        var op = LastOperator(name: "Transfer UV Maps", call: "bpy.ops.object.join_uvs",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None or _bk_a.type != 'MESH':
            raise RuntimeError('Copy UV Maps copies the active mesh\\'s UV map, and the active object is '
                               'not a mesh.')
        if not getattr(_bk_a.data, 'uv_layers', None) or len(_bk_a.data.uv_layers) == 0:
            raise RuntimeError('Copy UV Maps copies ' + _bk_a.name + '\\'s UV map, and it has none.')
        if not any(_bk_o != _bk_a and _bk_o.type == 'MESH' for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Copy UV Maps copies onto the other selected meshes, and none is selected.')
        """
        op.refusal = "Copy UV Maps: Blender copied nothing."
        return op
    }

    // MARK: Make Single User

    /// Object ▸ Relations ▸ Make Single User's rows (VIEW3D_MT_make_single_user,
    /// 5.2.1): each turns on its own switches and the others off.
    enum SingleUser: String, CaseIterable, Sendable {
        case object, objectData, objectDataMaterials, materials, objectAnimation, objectDataAnimation

        public var label: String {
            switch self {
            case .object: return "Object"
            case .objectData: return "Object & Data"
            case .objectDataMaterials: return "Object & Data & Materials"
            case .materials: return "Materials"
            case .objectAnimation: return "Object Animation"
            case .objectDataAnimation: return "Object Data Animation"
            }
        }

        /// object, obdata, material, animation, obdata_animation.
        var switches: [Bool] {
            switch self {
            case .object: return [true, false, false, false, false]
            case .objectData: return [true, true, false, false, false]
            case .objectDataMaterials: return [true, true, true, false, false]
            case .materials: return [false, false, true, false, false]
            case .objectAnimation: return [false, false, false, true, false]
            case .objectDataAnimation: return [false, false, false, false, true]
            }
        }
    }

    /// `object.make_single_user`, with its panel: Type (Selected Objects,
    /// All) and the five switches. Measured: a mesh shared by two objects,
    /// Object Data on the selected one, gave it Cube.001; with nothing
    /// selected (Type Selected Objects) FINISHED having done nothing, refused
    /// first.
    static func makeSingleUser(_ row: SingleUser) -> LastOperator {
        let off = Parameter.Option("False", "Off"), on = Parameter.Option("True", "On")
        let keys = [("object", "Object"), ("obdata", "Object Data"), ("material", "Materials"),
                    ("animation", "Object Animation"), ("obdata_animation", "Object Data Animation")]
        var parameters = [Parameter(key: "type", label: "Type",
                                    kind: .choice([Parameter.Option("SELECTED_OBJECTS", "Selected Objects"),
                                                   Parameter.Option("ALL", "All")]),
                                    value: 0, softMin: 0, softMax: 1, step: 0.02)]
        for (i, key) in keys.enumerated() {
            parameters.append(Parameter(key: key.0, label: key.1, kind: .literal([off, on]),
                                        value: row.switches[i] ? 1 : 0, softMin: 0, softMax: 1, step: 0.02))
        }
        var op = LastOperator(name: "Make Single User", call: "bpy.ops.object.make_single_user",
                              parameters: parameters, restoration: .throughBlenderUndo)
        op.lead = """
        if @arg:type@ == 'SELECTED_OBJECTS' and not bpy.context.selected_editable_objects:
            raise RuntimeError('Make Single User acts on the selected objects, and none is selected.')
        """
        return op
    }

    // MARK: Modifiers, Transform

    /// Object ▸ Modifiers ▸ Copy Modifiers to Selected Objects: the active
    /// object's whole stack appended to every other selected one. Measured: a
    /// Bevel copied as Bevel.001 onto an object that had a Bevel; with nothing
    /// selected FINISHED having done nothing. No panel fields (Blender's has
    /// none).
    static func copyModifiersToSelected() -> LastOperator {
        var op = LastOperator(name: "Copy Modifiers to Selected Objects",
                              call: "bpy.ops.object.modifiers_copy_to_selected",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None:
            raise RuntimeError('Copy Modifiers to Selected Objects copies the active object\\'s modifiers, '
                               'and no object is active.')
        if len(_bk_a.modifiers) == 0:
            raise RuntimeError('Copy Modifiers to Selected Objects copies ' + _bk_a.name
                               + '\\'s modifiers, and it has none.')
        if not any(_bk_o != _bk_a for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Copy Modifiers to Selected Objects copies onto the other selected '
                               'objects, and no other object is selected.')
        """
        return op
    }

    /// Object ▸ Transform ▸ Randomize Transform, with Blender's panel in its
    /// order (object_randomize_transform.py, 5.2.1): Random Seed, Transform
    /// Delta, Randomize Location and its Location, Randomize Rotation and its
    /// Rotation, Randomize Scale, Scale Even, Scale. Its defaults move nothing
    /// (Location and Rotation 0, Scale 1 — measured: the cube kept every
    /// channel), so the row opens the panel to set them, as Blender's does.
    /// With nothing selected it answers FINISHED having done nothing, refused
    /// first.
    static func randomizeTransform() -> LastOperator {
        let off = Parameter.Option("False", "Off"), on = Parameter.Option("True", "On")
        func flag(_ key: String, _ label: String, _ value: Bool) -> Parameter {
            Parameter(key: key, label: label, kind: .literal([off, on]), value: value ? 1 : 0,
                      softMin: 0, softMax: 1, step: 0.02)
        }
        let parameters: [Parameter] = [
            Parameter(key: "random_seed", label: "Random Seed", kind: .integer, value: 0,
                      softMin: 0, softMax: 10000, step: 0.2),
            flag("use_delta", "Transform Delta", false),
            flag("use_loc", "Randomize Location", true),
        ] + Parameter.vector("loc", "Location", .zero, softMin: -100, softMax: 100, step: 0.01) + [
            flag("use_rot", "Randomize Rotation", true),
        ] + Parameter.vector("rot", "Rotation", .zero, softMin: -3.141592, softMax: 3.141592,
                             step: 0.004, unit: .degrees) + [
            flag("use_scale", "Randomize Scale", true),
            flag("scale_even", "Scale Even", false),
        ] + Parameter.vector("scale", "Scale", SIMD3(1, 1, 1), softMin: -100, softMax: 100, step: 0.01,
                             unit: .none)
        var op = LastOperator(name: "Randomize Transform", call: "bpy.ops.object.randomize_transform",
                              parameters: parameters, restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_objects:
            raise RuntimeError('Randomize Transform moves the selected objects, and none is selected.')
        """
        return op
    }

    /// Object ▸ Transform ▸ Align Objects, with Blender's panel: High
    /// Quality, Align Mode, Relative To, and Align's X, Y, Z (none on by
    /// default, so the row moves nothing until one is — measured: FINISHED
    /// and nothing moved; with X, Other went from x = 5 to the active cube's
    /// 0). With nothing selected Blender answers CANCELLED ("No objects with
    /// bound-box selected"), refused first.
    static func alignObjects() -> LastOperator {
        let off = Parameter.Option("False", "Off"), on = Parameter.Option("True", "On")
        var op = LastOperator(
            name: "Align Objects", call: "bpy.ops.object.align",
            parameters: [
                Parameter(key: "bb_quality", label: "High Quality", kind: .literal([off, on]), value: 1,
                          softMin: 0, softMax: 1, step: 0.02),
                Parameter(key: "align_mode", label: "Align Mode",
                          kind: .choice([Parameter.Option("OPT_1", "Negative Sides"),
                                         Parameter.Option("OPT_2", "Centers"),
                                         Parameter.Option("OPT_3", "Positive Sides")]),
                          value: 1, softMin: 0, softMax: 2, step: 0.02),
                Parameter(key: "relative_to", label: "Relative To",
                          kind: .choice([Parameter.Option("OPT_1", "Scene Origin"),
                                         Parameter.Option("OPT_2", "3D Cursor"),
                                         Parameter.Option("OPT_3", "Selection"),
                                         Parameter.Option("OPT_4", "Active")]),
                          value: 3, softMin: 0, softMax: 3, step: 0.02),
            ] + Parameter.flags("align_axis", "Align", [("X", "X"), ("Y", "Y"), ("Z", "Z")], on: []),
            restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_objects:
            raise RuntimeError('Align Objects aligns the selected objects, and none is selected.')
        if @arg:relative_to@ == 'OPT_4' and bpy.context.view_layer.objects.active is None:
            raise RuntimeError('Align Objects is set to align to the active object, and no object is '
                               'active.')
        """
        op.refusal = "Align Objects: Blender found no selected object with a bounding box."
        return op
    }

    // MARK: Constraints

    /// Object ▸ Constraints ▸ Add Constraint (with Targets): a constraint on
    /// the active object aimed at the other selected one, Blender's
    /// `constraint_add_with_targets` (measured: Copy Rotation on the cube with
    /// the sphere selected targeted the sphere). Its panel is its Type.
    static func addConstraintWithTargets(_ type: String) -> LastOperator {
        let all = ConstraintMenu.groups.flatMap(\.types).map { Parameter.Option($0.id, $0.label) }
        var op = LastOperator(
            name: "Add Constraint (with Targets)", call: "bpy.ops.object.constraint_add_with_targets",
            parameters: [Parameter(key: "type", label: "Type", kind: .choice(all),
                                   value: Double(all.firstIndex { $0.identifier == type } ?? 0),
                                   softMin: 0, softMax: Double(all.count - 1), step: 0.02)],
            restoration: .throughBlenderUndo)
        op.lead = """
        if bpy.context.view_layer.objects.active is None:
            raise RuntimeError('Add Constraint (with Targets) adds a constraint to the active object, and '
                               'no object is active.')
        """
        op.refusal = "Add Constraint (with Targets): Blender added nothing."
        return op
    }

    /// Object ▸ Constraints ▸ Copy Constraints to Selected Objects. No panel
    /// fields.
    static func copyConstraintsToSelected() -> LastOperator {
        var op = LastOperator(name: "Copy Constraints to Selected Objects",
                              call: "bpy.ops.object.constraints_copy",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None or len(_bk_a.constraints) == 0:
            raise RuntimeError('Copy Constraints to Selected Objects copies the active object\\'s '
                               'constraints, and it has none.')
        if not any(_bk_o != _bk_a for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Copy Constraints to Selected Objects copies onto the other selected '
                               'objects, and no other object is selected.')
        """
        return op
    }

    /// Object ▸ Constraints ▸ Clear Object Constraints: every constraint off
    /// every selected object.
    static func clearObjectConstraints() -> LastOperator {
        var op = LastOperator(name: "Clear Object Constraints", call: "bpy.ops.object.constraints_clear",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        if not any(len(_bk_o.constraints) for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Clear Object Constraints clears the selected objects\\' constraints, and '
                               'none of them has one.')
        """
        return op
    }
}
