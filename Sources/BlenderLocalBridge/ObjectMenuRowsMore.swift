import Foundation

// Object menu rows Blender 5.2.1 has and the app did not (the misses audit of
// November 14, Blender's VIEW3D_MT_object held to the app's Object menu):
// Clear ▸ Origin; Apply's deltas rows, Visual Transform, Visual Geometry to
// Objects, Make Instances Real and Parent Inverse; Relations ▸ Make Instance
// Face; Modifiers ▸ Clear Object Modifiers; and Track. Each is Blender's
// operator through `perform`, so its redo panel and its undo step are
// Blender's own (`get_rna_type().name`).
//
// Measured in desktop Blender 5.2.1 in the app's kind of context (no 3D View
// area): every operator below FINISHED on a selected cube. Where Blender
// answers FINISHED having done nothing (Clear Origin, Apply Parent Inverse and
// Make Instances Real with nothing selected or nothing to act on, Track with
// no other object selected), CANCELLED with a warning only a status bar would
// show (the deltas rows, Visual Transform with nothing selected), or fails its
// poll (Clear Object Modifiers with no active object), the row refuses first
// in a sentence, as the rows beside them do.

public extension LastOperator {

    // MARK: Clear ▸ Origin

    /// Object ▸ Clear ▸ Origin: `object.origin_clear`. It clears the offset a
    /// parented object keeps from its parent (the translation of
    /// `matrix_parent_inverse`), so the child moves onto its parent's origin.
    /// Measured: a cube parented to a light at (4, 0, 0) with the usual
    /// inverse sat at the world origin, and after Clear Origin at (4, 0, 0),
    /// its parent inverse's translation (0, 0, 0). On an object without a
    /// parent it does nothing, FINISHED — refused first.
    static func clearOrigin() -> LastOperator {
        var op = LastOperator(name: "Clear Origin", call: "bpy.ops.object.origin_clear",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_sel = list(bpy.context.selected_editable_objects)
        if not _bk_sel:
            raise RuntimeError('Clear Origin acts on the selected objects, and none is selected.')
        if not any(_bk_o.parent is not None for _bk_o in _bk_sel):
            raise RuntimeError('Clear Origin clears the offset a child keeps from its parent, and none of '
                               'the selected objects has a parent.')
        """
        return op
    }

    // MARK: Apply ▸ … to Deltas

    /// `object.transforms_to_deltas`'s Mode items in 5.2.1.
    static let deltaModes: [Parameter.Option] = [
        Parameter.Option("ALL", "All Transforms"), Parameter.Option("LOC", "Location"),
        Parameter.Option("ROT", "Rotation"), Parameter.Option("SCALE", "Scale"),
    ]

    /// Apply ▸ Location / Rotation / Scale / All Transforms to Deltas, in
    /// Blender's order, by the Mode each row sets.
    static let deltaRows: [(label: String, mode: String)] = [
        ("Location to Deltas", "LOC"), ("Rotation to Deltas", "ROT"),
        ("Scale to Deltas", "SCALE"), ("All Transforms to Deltas", "ALL"),
    ]

    /// `object.transforms_to_deltas`, with its panel: Mode and Reset Values
    /// (on, Blender's default). Measured: a cube at (1, 2, 3) came back at
    /// location (0, 0, 0) and delta location (1, 2, 3), drawn where it was.
    /// With nothing selected Blender CANCELLED with a warning — refused first.
    static func transformsToDeltas(mode: String) -> LastOperator {
        let index = deltaModes.firstIndex { $0.identifier == mode } ?? 0
        var op = LastOperator(
            name: "Transforms to Deltas", call: "bpy.ops.object.transforms_to_deltas",
            parameters: [
                Parameter(key: "mode", label: "Mode", kind: .choice(deltaModes), value: Double(index),
                          softMin: 0, softMax: Double(deltaModes.count - 1), step: 0.02),
                Parameter(key: "reset_values", label: "Reset Values",
                          kind: .literal([Parameter.Option("False", "Off"), Parameter.Option("True", "On")]),
                          value: 1, softMin: 0, softMax: 1, step: 0.02),
            ],
            restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_editable_objects:
            raise RuntimeError('Transforms to Deltas moves the selected objects\\' transforms into their '
                               'deltas, and none is selected.')
        """
        return op
    }

    /// Apply ▸ Animated Transforms to Deltas: the selected objects' transform
    /// F-curves moved onto their delta channels. Measured: with no animation
    /// Blender warned "No animation data to convert" and FINISHED having done
    /// nothing — refused first.
    static func animatedTransformsToDeltas() -> LastOperator {
        var op = LastOperator(name: "Animated Transforms to Deltas",
                              call: "bpy.ops.object.anim_transforms_to_deltas",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_sel = list(bpy.context.selected_editable_objects)
        if not _bk_sel:
            raise RuntimeError('Animated Transforms to Deltas acts on the selected objects, and none is '
                               'selected.')
        if not any(_bk_o.animation_data is not None and _bk_o.animation_data.action is not None
                   for _bk_o in _bk_sel):
            raise RuntimeError('Animated Transforms to Deltas moves keyframed transforms onto the deltas, '
                               'and none of the selected objects is animated.')
        """
        return op
    }

    // MARK: Apply ▸ Visual …

    /// Apply ▸ Visual Transform: what constraints and parents make of each
    /// selected object, written into its own transform. With nothing selected
    /// Blender CANCELLED — refused first.
    static func visualTransformApply() -> LastOperator {
        var op = LastOperator(name: "Apply Visual Transform", call: "bpy.ops.object.visual_transform_apply",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_editable_objects:
            raise RuntimeError('Visual Transform acts on the selected objects, and none is selected.')
        """
        return op
    }

    /// Apply ▸ Visual Geometry to Objects (new in Blender 5): each instance
    /// and each geometry type the active object's evaluation makes becomes an
    /// object of its own. With nothing selected its poll failed — refused
    /// first in a sentence.
    static func visualGeometryToObjects() -> LastOperator {
        var op = LastOperator(name: "Visual Geometry to Objects",
                              call: "bpy.ops.object.visual_geometry_to_objects",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_editable_objects:
            raise RuntimeError('Visual Geometry to Objects acts on the selected objects, and none is '
                               'selected.')
        """
        return op
    }

    /// The most objects Make Instances Real may make in one go. Each instance
    /// becomes a data-block in Blender's main database and an object in the
    /// mirror; a particle system or an Instance on Points can make hundreds of
    /// thousands, which the viewport draws as instances but would not survive
    /// as objects on an iPad.
    static let instancesRealLimit = 5000

    /// Apply ▸ Make Instances Real, with Blender's panel: Parent and Keep
    /// Hierarchy (both off). Measured: a cube instancing a light on its 8
    /// vertices went from 3 objects to 11. With nothing to instance it
    /// FINISHED having done nothing — refused first, and so is a count over
    /// `instancesRealLimit`, counted from the evaluated depsgraph before
    /// anything is made.
    static func makeInstancesReal() -> LastOperator {
        let off = Parameter.Option("False", "Off"), on = Parameter.Option("True", "On")
        var op = LastOperator(
            name: "Make Instances Real", call: "bpy.ops.object.duplicates_make_real",
            parameters: [
                Parameter(key: "use_base_parent", label: "Parent", kind: .literal([off, on]),
                          value: 0, softMin: 0, softMax: 1, step: 0.02),
                Parameter(key: "use_hierarchy", label: "Keep Hierarchy", kind: .literal([off, on]),
                          value: 0, softMin: 0, softMax: 1, step: 0.02),
            ],
            restoration: .throughBlenderUndo)
        op.lead = """
        _bk_sel = set(_bk_o.name for _bk_o in bpy.context.selected_editable_objects)
        if not _bk_sel:
            raise RuntimeError('Make Instances Real acts on the selected objects, and none is selected.')
        _bk_n = 0
        for _bk_i in bpy.context.evaluated_depsgraph_get().object_instances:
            if _bk_i.is_instance and _bk_i.parent is not None and _bk_i.parent.original.name in _bk_sel:
                _bk_n += 1
                if _bk_n > \(instancesRealLimit):
                    break
        if _bk_n == 0:
            raise RuntimeError('Make Instances Real makes objects of the instances the selected objects '
                               'show, and they show none.')
        if _bk_n > \(instancesRealLimit):
            raise RuntimeError('Make Instances Real would make more than \(instancesRealLimit) objects, '
                               'more than this device keeps. Lower the instance count first.')
        """
        return op
    }

    /// Apply ▸ Parent Inverse: the parent inverse matrix folded into each
    /// selected child's own transform. Without a parent it does nothing,
    /// FINISHED — refused first.
    static func parentInverseApply() -> LastOperator {
        var op = LastOperator(name: "Apply Parent Inverse", call: "bpy.ops.object.parent_inverse_apply",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        _bk_sel = list(bpy.context.selected_editable_objects)
        if not _bk_sel:
            raise RuntimeError('Parent Inverse acts on the selected objects, and none is selected.')
        if not any(_bk_o.parent is not None for _bk_o in _bk_sel):
            raise RuntimeError('Parent Inverse folds a child\\'s parent inverse into its transform, and none '
                               'of the selected objects has a parent.')
        """
        return op
    }

    // MARK: Relations ▸ Make Instance Face, Modifiers ▸ Clear

    /// Relations ▸ Make Instance Face: the selected objects become one quad
    /// each on a new mesh that instances them on its faces. Measured: a cube
    /// gave Cube_dupli (Instancing Faces) and Cube.001. With nothing selected
    /// FINISHED having done nothing — refused first.
    static func makeInstanceFace() -> LastOperator {
        var op = LastOperator(name: "Make Instance Face", call: "bpy.ops.object.make_dupli_face",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        if not bpy.context.selected_editable_objects:
            raise RuntimeError('Make Instance Face acts on the selected objects, and none is selected.')
        """
        return op
    }

    /// Modifiers ▸ Clear Object Modifiers: every modifier of the selected
    /// objects removed. With no active object its poll fails ("Context missing
    /// active object"); with no modifiers it FINISHED having done nothing —
    /// each refused first.
    static func clearObjectModifiers() -> LastOperator {
        var op = LastOperator(name: "Clear Object Modifiers", call: "bpy.ops.object.modifiers_clear",
                              parameters: [], restoration: .throughBlenderUndo)
        op.lead = """
        if bpy.context.view_layer.objects.active is None:
            raise RuntimeError('Clear Object Modifiers needs an active object, and none is active.')
        if not any(len(getattr(_bk_o, 'modifiers', ())) for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Clear Object Modifiers clears the selected objects\\' modifiers, and none of '
                               'them has one.')
        """
        return op
    }

    // MARK: Track

    /// `object.track_set`'s Type items (5.2.1), each a row of Object ▸ Track.
    static let trackTypes: [Parameter.Option] = [
        Parameter.Option("DAMPTRACK", "Damped Track Constraint"),
        Parameter.Option("TRACKTO", "Track to Constraint"),
        Parameter.Option("LOCKTRACK", "Lock Track Constraint"),
    ]

    /// `object.track_clear`'s Type items, the rows after the separator.
    static let trackClearTypes: [Parameter.Option] = [
        Parameter.Option("CLEAR", "Clear Track"),
        Parameter.Option("CLEAR_KEEP_TRANSFORM", "Clear and Keep Transformation (Clear Track)"),
    ]

    /// Object ▸ Track ▸ … Constraint (Make Track): each selected object other
    /// than the active one gets a tracking constraint aimed at the active
    /// object. With only the active selected, or nothing, Blender FINISHED
    /// having done nothing — refused first.
    static func makeTrack(_ type: String) -> LastOperator {
        let index = trackTypes.firstIndex { $0.identifier == type } ?? 0
        var op = LastOperator(
            name: "Make Track", call: "bpy.ops.object.track_set",
            parameters: [Parameter(key: "type", label: "Type", kind: .choice(trackTypes),
                                   value: Double(index), softMin: 0,
                                   softMax: Double(trackTypes.count - 1), step: 0.02)],
            restoration: .throughBlenderUndo)
        op.lead = """
        _bk_a = bpy.context.view_layer.objects.active
        if _bk_a is None:
            raise RuntimeError('Track aims the selected objects at the active one, and no object is active.')
        if not any(_bk_o != _bk_a for _bk_o in bpy.context.selected_editable_objects):
            raise RuntimeError('Track aims the other selected objects at ' + _bk_a.name
                               + ', and no other object is selected. Select the trackers, then the target last.')
        """
        return op
    }

    /// Object ▸ Track ▸ Clear Track, or Clear and Keep Transformation:
    /// `object.track_clear`. It removes the selected objects' tracking
    /// constraints (Track To, Damped Track, Lock Track). With none it FINISHED
    /// having done nothing — refused first.
    static func clearTrack(_ type: String) -> LastOperator {
        let index = trackClearTypes.firstIndex { $0.identifier == type } ?? 0
        var op = LastOperator(
            name: "Clear Track", call: "bpy.ops.object.track_clear",
            parameters: [Parameter(key: "type", label: "Type", kind: .choice(trackClearTypes),
                                   value: Double(index), softMin: 0,
                                   softMax: Double(trackClearTypes.count - 1), step: 0.02)],
            restoration: .throughBlenderUndo)
        op.lead = """
        if not any(_bk_c.type in ('TRACK_TO', 'DAMPED_TRACK', 'LOCKED_TRACK')
                   for _bk_o in bpy.context.selected_editable_objects for _bk_c in _bk_o.constraints):
            raise RuntimeError('Clear Track removes the selected objects\\' tracking constraints, and none of '
                               'them has one.')
        """
        return op
    }
}
