import Foundation

/// A mesh's vertex groups and shape keys, as Blender holds them: what the Data
/// tab's Vertex Groups and Shape Keys panels show.
///
/// Written only by the mirror (`_blenderkit_groups.record`, carried by
/// `SceneMirror.carryGroups`). Every control in those panels sends a
/// `GroupsBpy` command through the bridge and shows what comes back here —
/// nothing in the app holds a group or a key of its own. Nil for anything that
/// is not a mesh on the real backend; the simulator's stand-in has neither.
public struct MeshGroups: Equatable, Sendable {

    public struct Group: Equatable, Sendable {
        public var name: String
        /// Blender's `lock_weight`. Assign and Remove fail their poll on a
        /// locked group ("The active vertex group is locked", measured).
        public var locked: Bool
        /// How many vertices the group holds, counted for the active object
        /// on a mesh of up to `_blenderkit_groups.COUNT_LIMIT` vertices; nil
        /// when it was not counted.
        public var count: Int?

        public init(name: String, locked: Bool = false, count: Int? = nil) {
            self.name = name; self.locked = locked; self.count = count
        }
    }

    public struct Key: Equatable, Sendable {
        public var name: String
        public var value: Float
        /// The slider's range (`slider_min`, `slider_max`): Blender clamps
        /// `value` to it (1.5 set under a maximum of 1.0 read back 1.0).
        public var sliderMin: Float
        public var sliderMax: Float
        /// The key this one is relative to, by name.
        public var relativeKey: String
        public var mute: Bool
        /// `lock_shape`: Blender's Sculpt and Edit Mode leave a locked key's
        /// shape alone.
        public var locked: Bool
        /// The vertex group that weights the key's influence, or "".
        public var vertexGroup: String

        public init(name: String, value: Float = 0, sliderMin: Float = 0, sliderMax: Float = 1,
                    relativeKey: String = "", mute: Bool = false, locked: Bool = false,
                    vertexGroup: String = "") {
            self.name = name; self.value = value; self.sliderMin = sliderMin
            self.sliderMax = sliderMax; self.relativeKey = relativeKey; self.mute = mute
            self.locked = locked; self.vertexGroup = vertexGroup
        }

        /// What a value field may send: Blender's own clamp, so the draft
        /// shows what the commit leaves.
        public func clamped(_ v: Float) -> Float {
            guard v.isFinite else { return value }
            return min(max(v, sliderMin), max(sliderMin, sliderMax))
        }
    }

    public var groups: [Group] = []
    /// `vertex_groups.active_index`: -1 for none.
    public var activeGroup = -1
    /// `tool_settings.vertex_group_weight`: what Assign gives the selection.
    public var weight: Float = 1
    /// False when the object was past the count limit, so no group has a
    /// count for a reason the panel can say.
    public var counted = true

    public var keys: [Key] = []
    /// `active_shape_key_index`: the key Edit Mode edits; -1 with no keys.
    public var activeKey = -1
    /// `shape_keys.use_relative`.
    public var useRelative = true
    /// The reference key's name (`shape_keys.reference_key`, the Basis).
    public var reference = ""
    /// `show_only_shape_key` (Shape Key Lock) and `use_shape_key_edit_mode`.
    public var showOnlyShapeKey = false
    public var shapeKeyEditMode = false

    public init() {}

    public var activeGroupName: String? {
        groups.indices.contains(activeGroup) ? groups[activeGroup].name : nil
    }
    public var activeKeyBlock: Key? {
        keys.indices.contains(activeKey) ? keys[activeKey] : nil
    }
    /// Whether `key` is the reference key, which in a relative set has no
    /// value of its own: Blender draws no slider for it.
    public func isReference(_ key: Key) -> Bool { useRelative && key.name == reference }

    /// Reads `_blenderkit_groups.record`; nil for a record with no head.
    public static func parse(_ record: String) -> MeshGroups? {
        var groups = MeshGroups()
        var sawHead = false
        for entry in record.split(separator: "|") {
            let f = Modifier.fields(entry)
            func float(_ k: String) -> Float? {
                f[k].flatMap(Float.init).flatMap { $0.isFinite ? $0 : nil }
            }
            func int(_ k: String) -> Int? {
                guard let v = float(k), v > -1e9, v < 1e9 else { return nil }
                return Int(v.rounded())
            }
            func bool(_ k: String) -> Bool? { f[k].map { $0 == "1" || $0 == "True" } }
            switch f["kind"] {
            case "head":
                sawHead = true
                groups.activeGroup = int("active_group") ?? -1
                groups.weight = float("weight") ?? 1
                groups.activeKey = int("active_key") ?? -1
                groups.useRelative = bool("use_relative") ?? true
                groups.reference = f["reference"] ?? ""
                groups.showOnlyShapeKey = bool("show_only") ?? false
                groups.shapeKeyEditMode = bool("key_edit_mode") ?? false
                groups.counted = bool("counted") ?? true
            case "group":
                guard let name = f["name"] else { continue }
                groups.groups.append(Group(name: name, locked: bool("lock") ?? false, count: int("count")))
            case "key":
                guard let name = f["name"] else { continue }
                groups.keys.append(Key(name: name, value: float("value") ?? 0,
                                       sliderMin: float("min") ?? 0, sliderMax: float("max") ?? 1,
                                       relativeKey: f["relative"] ?? "", mute: bool("mute") ?? false,
                                       locked: bool("lock") ?? false, vertexGroup: f["vertex_group"] ?? ""))
            default:
                continue
            }
        }
        return sawHead ? groups : nil
    }

    /// This record, keeping the counts `old` had for groups of the same name
    /// where this one has none. A frame change sends the record without
    /// counting (values move with the playhead; group members do not), and a
    /// count should not blink out for a frame.
    public func keepingCounts(from old: MeshGroups?) -> MeshGroups {
        guard let old, groups.contains(where: { $0.count == nil }) else { return self }
        var byName: [String: Int] = [:]
        for g in old.groups { if let c = g.count { byName[g.name] = c } }
        var kept = self
        for i in kept.groups.indices where kept.groups[i].count == nil {
            kept.groups[i].count = byName[kept.groups[i].name]
        }
        return kept
    }
}

public extension SceneMirror {
    /// A mesh's vertex groups and shape keys onto the object of that name:
    /// the one the pass just pushed during a pass, the one on screen outside
    /// one (a tap, a frame change). False when there is no such object or the
    /// record has no head.
    @discardableResult
    static func carryGroups(record: String, named name: String,
                            pass: [BKObject]?, screen: [BKObject]) -> Bool {
        let target: BKObject?
        if let pass {
            target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        } else {
            target = screen.first { $0.name == name }
        }
        guard let target, let parsed = MeshGroups.parse(record) else { return false }
        let groups = pass == nil ? parsed.keepingCounts(from: target.meshGroups) : parsed
        if target.meshGroups != groups { target.meshGroups = groups }
        return true
    }
}

/// What the Vertex Groups and Shape Keys panels send.
///
/// Each control is one `Command`: the Python Blender's Info log would show for
/// it (`call`), the undo step's name (nil where Blender's undo would take
/// nothing back — measured, see `_blenderkit_groups`), and what runs: the
/// module function that holds the call to the conditions Blender's own button
/// is held to and says in words what Blender would do silently.
public enum GroupsBpy {

    public struct Command: Equatable, Sendable {
        public let call: String
        public let undo: String?
        public let executed: String
    }

    static let module = "import _blenderkit_groups as _bk_grp"

    private static func command(_ call: String, undo: String?, _ function: String, _ arguments: [String]) -> Command {
        Command(call: call, undo: undo,
                executed: module + "\n_bk_grp.\(function)(\(arguments.joined(separator: ", ")))")
    }

    private static func q(_ s: String) -> String { Bpy.quote(s) }
    private static func f(_ v: Float) -> String { String(format: "%.6g", Double(v)) }
    private static func py(_ b: Bool) -> String { b ? "True" : "False" }
    private static func object(_ name: String) -> String { "bpy.data.objects[\(q(name))]" }

    // MARK: vertex groups

    public static func addGroup(object name: String) -> Command {
        command("bpy.ops.object.vertex_group_add()", undo: "Add Vertex Group", "add_group", [q(name)])
    }

    public static func removeGroup(_ group: String, object name: String) -> Command {
        command("bpy.ops.object.vertex_group_remove(all=False)", undo: "Remove Vertex Group",
                "remove_group", [q(name), q(group)])
    }

    public static func removeAllGroups(object name: String) -> Command {
        command("bpy.ops.object.vertex_group_remove(all=True)", undo: "Remove Vertex Group",
                "remove_all_groups", [q(name)])
    }

    public static func renameGroup(_ group: String, to wanted: String, object name: String) -> Command {
        command("\(object(name)).vertex_groups[\(q(group))].name = \(q(wanted))", undo: "Name",
                "rename_group", [q(name), q(group), q(wanted)])
    }

    public static func setActiveGroup(_ group: String, object name: String) -> Command {
        command("\(object(name)).vertex_groups.active_index = \(object(name)).vertex_groups[\(q(group))].index",
                undo: "Active Vertex Group", "set_active_group", [q(name), q(group)])
    }

    public static func lockGroup(_ group: String, _ locked: Bool, object name: String) -> Command {
        command("\(object(name)).vertex_groups[\(q(group))].lock_weight = \(py(locked))", undo: "Lock Weight",
                "lock_group", [q(name), q(group), py(locked)])
    }

    /// Assign: the selected vertices into `group` at `weight`. The weight is
    /// what the Weight field shows; it rides along so the two cannot differ.
    public static func assign(_ group: String, weight: Float, object name: String) -> Command {
        command("bpy.ops.object.vertex_group_assign()", undo: "Assign to Vertex Group",
                "assign", [q(name), q(group), f(min(max(weight, 0), 1))])
    }

    public static func removeFromGroup(_ group: String, object name: String) -> Command {
        command("bpy.ops.object.vertex_group_remove_from()", undo: "Remove from Vertex Group",
                "remove_from", [q(name), q(group)])
    }

    public static func selectGroup(_ group: String, select: Bool, object name: String) -> Command {
        command("bpy.ops.object.vertex_group_\(select ? "select" : "deselect")()",
                undo: select ? "Select Vertex Group" : "Deselect Vertex Group",
                "select_group", [q(name), q(group), py(select)])
    }

    /// The Weight field: `tool_settings.vertex_group_weight`. No undo step —
    /// measured, Blender's undo does not take a tool setting back.
    public static func setWeight(_ weight: Float) -> String {
        "bpy.context.scene.tool_settings.vertex_group_weight = \(f(min(max(weight, 0), 1)))"
    }

    // MARK: shape keys

    public static func addKey(fromMix: Bool, object name: String) -> Command {
        command("bpy.ops.object.shape_key_add(from_mix=\(py(fromMix)))",
                undo: fromMix ? "New Shape from Mix" : "Add Shape Key",
                "add_key", [q(name), py(fromMix)])
    }

    public static func removeKey(_ key: String, object name: String) -> Command {
        command("bpy.ops.object.shape_key_remove(all=False)", undo: "Remove Shape Key",
                "remove_key", [q(name), q(key)])
    }

    public static func removeAllKeys(apply: Bool, object name: String) -> Command {
        command("bpy.ops.object.shape_key_remove(all=True, apply_mix=\(py(apply)))",
                undo: apply ? "Apply All Shape Keys" : "Delete All Shape Keys",
                "remove_all_keys", [q(name), py(apply)])
    }

    public static func setActiveKey(_ key: String, object name: String) -> Command {
        command("\(object(name)).active_shape_key_index = "
                + "\(object(name)).data.shape_keys.key_blocks.find(\(q(key)))",
                undo: "Active Shape Key", "set_active_key", [q(name), q(key)])
    }

    /// A key's own settings, by Blender's property names.
    public enum KeySetting: String, CaseIterable, Sendable {
        case value, sliderMin = "slider_min", sliderMax = "slider_max", mute, locked = "lock_shape",
             name, relativeKey = "relative_key", vertexGroup = "vertex_group"

        /// The undo step, named as Blender names a property change.
        public var label: String {
            switch self {
            case .value:       return "Value"
            case .sliderMin:   return "Range Min"
            case .sliderMax:   return "Range Max"
            case .mute:        return "Mute"
            case .locked:      return "Lock Shape"
            case .name:        return "Name"
            case .relativeKey: return "Relative Key"
            case .vertexGroup: return "Vertex Group"
            }
        }
    }

    /// One of a key's settings; `value` is already Python. `editing`:
    /// Blender's Edit Mode, where no undo step is pushed — measured in 5.2.1,
    /// the edit-mesh undo step holds the mesh and none of the Key's settings:
    /// value, range, mute, lock, relative key, vertex group and name each
    /// stayed changed after Undo (each was taken back in Object Mode). A step
    /// there would undo nothing, as the mirror row found for the symmetry
    /// flags.
    public static func setKey(_ key: String, _ setting: KeySetting, _ value: String,
                              editing: Bool, object name: String) -> Command {
        let target = "\(object(name)).data.shape_keys.key_blocks[\(q(key))]"
        let shown: String
        switch setting {
        case .relativeKey: shown = "\(object(name)).data.shape_keys.key_blocks[\(value)]"
        default:           shown = value
        }
        return command("\(target).\(setting.rawValue) = \(shown)",
                       undo: editing ? nil : setting.label,
                       "set_key", [q(name), q(key), q(setting.rawValue), value])
    }

    public static func setKeyValue(_ key: String, _ v: Float, editing: Bool, object name: String) -> Command {
        setKey(key, .value, f(v), editing: editing, object: name)
    }

    /// The panel's switches: Relative, Shape Key Lock and Edit Mode.
    public enum Switch: String, CaseIterable, Sendable {
        case useRelative = "use_relative", showOnly = "show_only_shape_key",
             editMode = "use_shape_key_edit_mode"

        public var label: String {
            switch self {
            case .useRelative: return "Relative"
            case .showOnly:    return "Shape Key Lock"
            case .editMode:    return "Shape Key Edit Mode"
            }
        }
    }

    /// The panel's switches. No undo step in Edit Mode, for the same reason
    /// as `setKey`: measured, Undo there left all three as they were set.
    public static func set(_ toggle: Switch, _ on: Bool, editing: Bool, object name: String) -> Command {
        let owner = toggle == .useRelative ? "\(object(name)).data.shape_keys" : object(name)
        return command("\(owner).\(toggle.rawValue) = \(py(on))", undo: editing ? nil : toggle.label,
                       "set_keys", [q(name), q(toggle.rawValue), py(on)])
    }
}

public extension ModifierKind {
    /// The kinds this app models whose `vertex_group` changes what they do
    /// (each measured in desktop 5.2.1 on a grid or a sphere with a group of
    /// the vertices at x < 0: the evaluated mesh differed with the group, and
    /// again with Invert). Bevel has the field too, but it is read only with
    /// Limit Method set to Vertex Group, which the row does not offer:
    /// measured, with the default Angle limit the group changed nothing, so
    /// a picker there would be a control that does nothing.
    var takesVertexGroup: Bool {
        switch self {
        case .solidify, .smooth, .cast, .simpleDeform, .displace, .wave, .shrinkwrap,
             .weightedNormal, .laplacianSmooth, .correctiveSmooth, .lattice, .weld, .decimate:
            return true
        default:
            return false
        }
    }
}
