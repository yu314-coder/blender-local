import Foundation
import Observation

// Object constraints, as the Object Constraints tab shows and changes them
// (round 4, group 7). Read back from Blender every pass
// (`_blenderkit_constraints.record`), carried per object, and changed only
// through Blender's operators and properties (`ConstraintsBpy`). Round 3's
// review found Add Constraint reachable by name in the operator search and
// nothing at all to show, edit or remove one with (toolkit item 15).

/// One constraint on an object, as Blender holds it.
public struct ObjectConstraint: Equatable, Sendable, Identifiable {
    /// Blender's type: COPY_LOCATION, CHILD_OF, …
    public let kind: String
    public let name: String
    /// The type's name in Blender's words, read from its enum: "Copy Location".
    public let typeLabel: String
    public let enabled: Bool
    public let influence: Float
    public let active: Bool
    /// Blender's `is_valid`: false draws the panel red in Blender (no target,
    /// a target that cannot be used).
    public let valid: Bool
    /// The mirror could not read its settings: it gets the controls every
    /// constraint has and no rows of its own.
    public let unread: Bool
    /// The settings the record carried, by Blender's property names.
    public let fields: [String: String]

    public var id: String { name }

    public init(kind: String, name: String, typeLabel: String, enabled: Bool = true,
                influence: Float = 1, active: Bool = false, valid: Bool = true,
                unread: Bool = false, fields: [String: String] = [:]) {
        self.kind = kind; self.name = name; self.typeLabel = typeLabel
        self.enabled = enabled; self.influence = influence; self.active = active
        self.valid = valid; self.unread = unread; self.fields = fields
    }

    /// `kind=TYPE;name=…;…|…`, top first. An empty record is no constraints.
    public static func stack(from record: String) -> [ObjectConstraint] {
        record.split(separator: "|").compactMap { chunk in
            let f = Modifier.fields(chunk)
            guard let kind = f["kind"], !kind.isEmpty, let name = f["name"] else { return nil }
            var rest = f
            for key in ["kind", "name", "label", "enabled", "influence", "active", "valid",
                        "expanded", "unread"] { rest[key] = nil }
            return ObjectConstraint(kind: kind, name: name,
                                    typeLabel: f["label"] ?? Modifier.label(forType: kind),
                                    enabled: f["enabled"] != "0",
                                    influence: f["influence"].flatMap { Float($0) } ?? 1,
                                    active: f["active"] == "1", valid: f["valid"] != "0",
                                    unread: f["unread"] == "1", fields: rest)
        }
    }

    /// Whether the tab has rows for this one's settings.
    public var isModelled: Bool { !unread && ConstraintKind(rawValue: kind) != nil }

    public func bool(_ key: String) -> Bool? { fields[key].map { $0 == "1" } }
    public func float(_ key: String) -> Float? { fields[key].flatMap { Float($0) } }
    public func string(_ key: String) -> String? { fields[key] }
    /// The object it targets, or nil for none.
    public var target: String? { fields["target"].flatMap { $0.isEmpty ? nil : $0 } }

    /// An enum setting's choices as this Blender offers them: (identifier, name).
    public func options(_ key: String) -> [(id: String, label: String)] {
        guard let value = fields["options." + key], !value.isEmpty else { return [] }
        return value.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let id = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let label = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            return (id, label)
        }
    }

    /// The name an enum value is shown by, or the value itself.
    public func label(of key: String) -> String {
        let value = fields[key] ?? ""
        return options(key).first { $0.id == value }?.label ?? value
    }
}

/// The types the tab has rows for, with the panel Blender draws for each
/// (properties_constraint.py, 5.2.1). Every other type keeps the controls
/// every constraint has, and its settings are one tap away in the Data API.
public enum ConstraintKind: String, CaseIterable, Sendable {
    case copyLocation = "COPY_LOCATION", copyRotation = "COPY_ROTATION", copyScale = "COPY_SCALE"
    case copyTransforms = "COPY_TRANSFORMS", trackTo = "TRACK_TO", dampedTrack = "DAMPED_TRACK"
    case limitLocation = "LIMIT_LOCATION", limitRotation = "LIMIT_ROTATION", limitScale = "LIMIT_SCALE"
    case childOf = "CHILD_OF", followPath = "FOLLOW_PATH"

    public var hasTarget: Bool {
        switch self {
        case .limitLocation, .limitRotation, .limitScale: return false
        default: return true
        }
    }
}

/// Blender's Add Object Constraint menu (`object.constraint_add`'s Type enum,
/// 5.2.1), in its four columns and its order.
public enum ConstraintMenu {
    public struct Group: Sendable {
        public let title: String
        public let types: [(id: String, label: String)]
    }

    public static let groups: [Group] = [
        Group(title: "Motion Tracking", types: [("CAMERA_SOLVER", "Camera Solver"),
                                                ("FOLLOW_TRACK", "Follow Track"),
                                                ("OBJECT_SOLVER", "Object Solver")]),
        Group(title: "Transform", types: [("COPY_LOCATION", "Copy Location"),
                                          ("COPY_ROTATION", "Copy Rotation"),
                                          ("COPY_SCALE", "Copy Scale"),
                                          ("COPY_TRANSFORMS", "Copy Transforms"),
                                          ("LIMIT_DISTANCE", "Limit Distance"),
                                          ("LIMIT_LOCATION", "Limit Location"),
                                          ("LIMIT_ROTATION", "Limit Rotation"),
                                          ("LIMIT_SCALE", "Limit Scale"),
                                          ("MAINTAIN_VOLUME", "Maintain Volume"),
                                          ("TRANSFORM", "Transformation"),
                                          ("TRANSFORM_CACHE", "Transform Cache")]),
        // Inverse Kinematics and Spline IK are a bone's: the object
        // operator's Type has neither (measured, 'enum "IK" not found').
        Group(title: "Tracking", types: [("CLAMP_TO", "Clamp To"), ("DAMPED_TRACK", "Damped Track"),
                                         ("LOCKED_TRACK", "Locked Track"), ("STRETCH_TO", "Stretch To"),
                                         ("TRACK_TO", "Track To")]),
        Group(title: "Relationship", types: [("ACTION", "Action"), ("ARMATURE", "Armature"),
                                             ("CHILD_OF", "Child Of"), ("FLOOR", "Floor"),
                                             ("FOLLOW_PATH", "Follow Path"),
                                             ("GEOMETRY_ATTRIBUTE", "Geometry Attribute"),
                                             ("PIVOT", "Pivot"), ("SHRINKWRAP", "Shrinkwrap")]),
    ]

    /// Every type the menu offers, in its order: what `object.constraint_add`
    /// takes on an object (all 27 FINISHED on a cube, measured).
    public static var types: [(id: String, label: String)] { groups.flatMap(\.types) }
}

/// The tab's controls, each as Blender's own operator or property write on
/// the active object (`_blenderkit_constraints`).
public enum ConstraintsBpy {
    static let module = "import _blenderkit_constraints"

    private static func command(_ call: String, _ guarded: String, undo: String?) -> BlenderCommand {
        BlenderCommand(call: call, body: module + "\n_blenderkit_constraints." + guarded, undo: undo)
    }

    private static func path(_ object: String, _ constraint: String) -> String {
        "bpy.data.objects[\(Bpy.quote(object))].constraints[\(Bpy.quote(constraint))]"
    }

    public static func add(_ type: String, to object: String) -> BlenderCommand {
        command("bpy.ops.object.constraint_add(type='\(type)')",
                "add(\(Bpy.quote(object)), '\(type)')", undo: "Add Constraint")
    }

    public static func remove(_ constraint: String, of object: String) -> BlenderCommand {
        command("bpy.ops.constraint.delete(constraint=\(Bpy.quote(constraint)), owner='OBJECT')",
                "remove(\(Bpy.quote(object)), \(Bpy.quote(constraint)))", undo: "Delete Constraint")
    }

    /// Move Constraint Up (-1) or Down (+1).
    public static func move(_ constraint: String, of object: String, by direction: Int) -> BlenderCommand {
        let op = direction < 0 ? "move_up" : "move_down"
        return command("bpy.ops.constraint.\(op)(constraint=\(Bpy.quote(constraint)), owner='OBJECT')",
                       "move(\(Bpy.quote(object)), \(Bpy.quote(constraint)), \(direction < 0 ? -1 : 1))",
                       undo: direction < 0 ? "Move Constraint Up" : "Move Constraint Down")
    }

    /// The header menu's Move to First and Move to Last.
    public static func move(_ constraint: String, of object: String, to index: Int) -> BlenderCommand {
        command("bpy.ops.constraint.move_to_index(constraint=\(Bpy.quote(constraint)), owner='OBJECT', index=\(index))",
                "move_to(\(Bpy.quote(object)), \(Bpy.quote(constraint)), \(index))",
                undo: "Move Constraint to Index")
    }

    /// The panel's buttons and its header menu's rows, by the operator each
    /// runs and that operator's name (its undo step).
    public enum Operation: String, CaseIterable, Sendable {
        case apply, copy, copyToSelected = "copy_to_selected"
        case setInverse = "childof_set_inverse", clearInverse = "childof_clear_inverse"
        case animatePath = "followpath_path_animate"

        /// What Blender's button or menu row says.
        public var label: String {
            switch self {
            case .apply: return "Apply"
            case .copy: return "Duplicate"
            case .copyToSelected: return "Copy to Selected"
            case .setInverse: return "Set Inverse"
            case .clearInverse: return "Clear Inverse"
            case .animatePath: return "Animate Path"
            }
        }

        /// The operator's name: Blender's undo step for it.
        public var undo: String {
            switch self {
            case .apply: return "Apply Constraint"
            case .copy: return "Duplicate Constraint"
            case .copyToSelected: return "Copy Constraint To Selected"
            case .setInverse: return "Set Inverse"
            case .clearInverse: return "Clear Inverse"
            case .animatePath: return "Auto Animate Path"
            }
        }
    }

    public static func operate(_ operation: Operation, on constraint: String, of object: String) -> BlenderCommand {
        command("bpy.ops.constraint.\(operation.rawValue)(constraint=\(Bpy.quote(constraint)), owner='OBJECT')",
                "operate(\(Bpy.quote(object)), \(Bpy.quote(constraint)), '\(operation.rawValue)')",
                undo: operation.undo)
    }

    /// One setting written as Blender's panel writes it: `literal` is the
    /// Python value (`True`, `0.5`, `'TRACK_Z'`); `undo` the field's text.
    public static func set(_ property: String, of constraint: String, on object: String,
                           to literal: String, undo: String) -> BlenderCommand {
        command("\(path(object, constraint)).\(property) = \(literal)",
                "set_value(\(Bpy.quote(object)), \(Bpy.quote(constraint)), '\(property)', \(literal))",
                undo: undo)
    }

    /// The Target field: an object's name, or nil for none.
    public static func setTarget(_ target: String?, of constraint: String, on object: String) -> BlenderCommand {
        let value = target.map { "bpy.data.objects[\(Bpy.quote($0))]" } ?? "None"
        return command("\(path(object, constraint)).target = \(value)",
                       "set_target(\(Bpy.quote(object)), \(Bpy.quote(constraint)), \(Bpy.quote(target ?? "")))",
                       undo: "Target")
    }

    /// The Data API path of one constraint, for its settings this tab has no
    /// rows for.
    public static func dataPath(_ constraint: String) -> String {
        "bpy.context.object.constraints[\(Bpy.quote(constraint))]"
    }

    /// `True` / `False` and numbers as the panel's writes carry them.
    public static func literal(_ value: Bool) -> String { value ? "True" : "False" }
    public static func literal(_ value: Float) -> String {
        LastOperator.number(Double(value), places: 6)
    }
}

// MARK: - Drags that constraints move

public extension BKScene {
    /// Whether an object-mode drag of `moving` moves anything a constraint
    /// decides: one of them, or anything that depends on one (a child, an
    /// object whose constraint targets it), has a constraint. Then the
    /// viewport's own preview — the channels moved — would not be where
    /// Blender puts it, and Blender previews the drag instead
    /// (`BpyBridge.beginConstrainedDrag`).
    func dragNeedsBlender(moving: Set<UUID>) -> Bool {
        guard !moving.isEmpty else { return false }
        let reached = dependents(of: moving)
        return objects.contains { reached.contains($0.id) && !$0.constraints.isEmpty }
    }
}

public extension BpyBridge {
    /// Starts a drag Blender previews (`_blenderkit_constraints.drag_begin`).
    /// False when it could not, and the viewport previews it alone. From
    /// here until `endConstrainedDrag` nothing else runs, undoes or redoes
    /// (`BpySession.constrainedDragOpen`); the drag's own frames and its end
    /// are reads (`capture`), which the hold does not stop.
    func beginConstrainedDrag() -> Bool {
        guard usesRealBlender else { return false }
        #if DEBUG
        // `-relations-ops constrained-preview:off`: the viewport previews the
        // channels alone, as before round 4 group 7 — the negative control,
        // read here so that it switches the path the gizmo and the fields run.
        if Self.debugSkipConstrainedPreview { return false }
        #endif
        // A drag whose end never came — its view went away mid-gesture, a
        // scrub the system cancelled — is ended first, so its hold and its
        // preview cannot outlive it (drag_begin does the same in Blender).
        if constrainedDragOpen { endConstrainedDrag() }
        guard capture("import _blenderkit_constraints\nprint(_blenderkit_constraints.drag_begin())") != nil
        else { return false }
        constrainedDragOpen = true
        return true
    }

    /// One frame: Blender puts the channels back, runs `call` — the call the
    /// release commits — and sends its evaluated matrices. False when Blender
    /// raised; the drag then goes on with the viewport's own preview.
    func previewConstrainedDrag(_ call: String) -> Bool {
        capture("import _blenderkit_constraints\n_blenderkit_constraints.drag_frame(\(Bpy.quote(call)))\nprint('ok')")?
            .contains("ok") == true
    }

    /// The drag over: Blender's channels as the drag found them, before the
    /// commit runs once as its step, or for a drag that ends without one.
    /// The hold ends first: the commit is a command like any other.
    func endConstrainedDrag() {
        constrainedDragOpen = false
        _ = capture("import _blenderkit_constraints\n_blenderkit_constraints.drag_end()")
    }

    #if DEBUG
    /// `-relations-ops constrained-preview:off` (see `beginConstrainedDrag`).
    nonisolated(unsafe) static var debugSkipConstrainedPreview = false
    #endif
}

/// A Transform field's edit as the Properties editor's Object tab and the
/// Sidebar's Item tab make it (`ObjectTransformFields`), from its first change
/// to its commit: the channels' preview (`TransformFieldEdit`), and Blender's
/// preview when a constraint decides where the object goes. The fields are a
/// view over this; the `-object-ops field:` DEBUG hook drives this same type,
/// so what it measures is what the fields run (round 4's review of group 7
/// found the hook re-implementing the sequence, and its numbers were the
/// copy's).
@Observable
public final class TransformFieldDrag {
    /// The edit in progress, or nil between edits.
    public private(set) var edit: TransformFieldEdit?
    /// The edit moves something a constraint decides, and Blender previews it
    /// (`BpyBridge.beginConstrainedDrag`).
    public private(set) var constrainedPreview = false

    public init() {}

    /// What the fields show for `object`: the edit's values while it is
    /// being edited, Blender's channels otherwise.
    public func shown(for object: BKObject) -> TransformChannels? {
        edit.flatMap { $0.object === object ? $0.edited : nil } ?? object.shownChannels
    }

    /// One field's new value: a scrub's sample or a typed number.
    public func change(_ group: TransformChannels.Group, axis: Int, to value: Float,
                       of object: BKObject, in scene: BKScene, bridge: BpyBridge?) {
        if edit?.object !== object {
            // The object changed under an edit with no commit: its drawing
            // and Blender's preview go back before the new one starts.
            edit?.rollBackDrawing()
            endConstrainedPreview(bridge)
            edit = TransformFieldEdit(object: object, scene: scene)
            // A field of an object a constraint decides — or one something
            // constrained follows: the channels' preview is not where Blender
            // puts it (a cube on Copy Location stays on its target whatever
            // its location), so Blender previews the write, by the very
            // assignments the commit sends.
            if let bridge, scene.dragNeedsBlender(moving: [object.id]) {
                constrainedPreview = bridge.beginConstrainedDrag()
            }
        }
        edit?.change(group, axis: axis, to: value)
        if constrainedPreview, let bridge, let python = edit?.previewPython,
           !bridge.previewConstrainedDrag(python) {
            endConstrainedPreview(bridge)
        }
    }

    /// The finger lifted, the number was typed, or the scrub was cancelled:
    /// Blender's channels back as the edit found them, then the write once,
    /// as its undo step. Nil when there was nothing to commit.
    @discardableResult
    public func commit(_ group: TransformChannels.Group, bridge: BpyBridge?) -> BpyBridge.Outcome? {
        guard let pending = edit else { return nil }
        edit = nil
        endConstrainedPreview(bridge)
        guard let bridge else {
            pending.rollBackDrawing()
            return nil
        }
        return bridge.commitTransformField(pending, group: group)
    }

    /// Blender's channels back as the edit found them, before the commit
    /// writes them once as its step, or with no commit.
    private func endConstrainedPreview(_ bridge: BpyBridge?) {
        guard constrainedPreview else { return }
        constrainedPreview = false
        bridge?.endConstrainedDrag()
    }
}
