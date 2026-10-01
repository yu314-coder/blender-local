import Foundation
import simd

/// One object's own transform channels, as `bpy.ops.object.transform_apply`
/// reads them: `location + delta_location`, the rotation in whatever
/// `rotation_mode` the object uses composed with its delta, and
/// `scale * delta_scale` — sign included.
///
/// `BKObject.location`, `rotation` and `scale` cannot answer the question
/// "what would Apply bake?" on the real backend. They are a decomposition of
/// `matrix_world`, and Apply bakes the *local* channels. Measured in 5.2.1:
///
/// - A cube mirrored with scale (-1,1,1) decomposes to scale 1 and a half turn
///   about Z, so Apply Scale read as nothing to do — where Blender's Apply Scale
///   flips the normals (the face normal went from -X to +X) — and Apply
///   Rotation read as something to do for a rotation of zero.
/// - A cube parented to an empty scaled 0.01 decomposes to 0.01, but its own
///   scale is 1: Apply Scale returned FINISHED, left every vertex where it was
///   and still pushed an undo step. The same cube at scale 100 under that
///   parent decomposes to 1, and Apply Scale multiplied its vertices by 100.
/// - A unit cube turned 45° or 10° about Z decomposes, in Float32, to a scale
///   of 0.99999994 — enough to offer Apply Scale with a "1 × 1 × 1" subtitle.
/// - Deltas are baked and reset too (a `delta_scale` of (2,1,1) under a scale
///   of 1 doubled the vertices' X), and in QUATERNION or AXIS_ANGLE mode
///   `rotation_euler` stays at zero while Apply Rotation turns the vertices.
///
/// `_blenderkit_sync.local_transform` produces these ten numbers, and the
/// 3D View's Blender check holds every greyed row against what Blender's
/// operator then does.
public struct LocalTransform: Equatable, Sendable {
    public var location: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public init(location: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        self.location = location
        self.rotation = rotation
        self.scale = scale
    }

    /// Location, rotation as (w, x, y, z), scale: the mirror's order.
    public init?(_ values: [Double]) {
        guard values.count == 10, values.allSatisfy(\.isFinite) else { return nil }
        let f = values.map { Float($0) }
        location = SIMD3(f[0], f[1], f[2])
        rotation = simd_quatf(ix: f[4], iy: f[5], iz: f[6], r: f[3])
        scale = SIMD3(f[7], f[8], f[9])
    }

    /// XYZ Euler, the only rotation the simulator's shim keeps. Blender turns
    /// about X first, so X is the rightmost factor.
    public init(location: SIMD3<Float>, eulerXYZ e: SIMD3<Float>, scale: SIMD3<Float>) {
        self.location = location
        rotation = simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0))
        self.scale = scale
    }

    /// Below this a channel is float noise, not a transform. Float32's step at
    /// 1.0 is 1.2e-7 and the noise measured above was 6e-8; baking 1e-5 moves
    /// a vertex one hundred-thousandth of the object's own size, which no
    /// modifier measured in metres can tell from nothing.
    public static let tolerance: Float = 1e-5

    /// How far Apply Rotation would turn the geometry, in radians. Read from
    /// the vector part so a turn near zero is not lost to `acos` near 1, and
    /// `abs(real)` so q and -q, the same rotation, agree.
    public var rotationAngle: Float {
        2 * atan2(length(rotation.imag), abs(rotation.real))
    }

    public var bakesLocation: Bool { any(abs(location) .> Self.tolerance) }
    public var bakesRotation: Bool { rotationAngle > Self.tolerance }
    public var bakesScale: Bool { any(abs(scale - 1) .> Self.tolerance) }
}

extension BKObject {
    /// What Apply would bake: Blender's channels when mirrored, the display
    /// cache's own when not — in the simulator those *are* the channels, with
    /// no parent and no delta to tell them apart.
    ///
    /// Nil for an object that came from Blender without its channels. Then
    /// `location`, `rotation` and `scale` are a decomposition of
    /// `matrix_world`, which is exactly the value that lies, and nothing may
    /// be greyed out on it.
    public var appliedTransform: LocalTransform? {
        if let localTransform { return localTransform }
        if mirroredTransform != nil { return nil }
        return LocalTransform(location: location, eulerXYZ: rotation, scale: scale)
    }

    /// A light's kind (`POINT`, `SUN`, `SPOT`, `AREA`), from what the mirror
    /// said it is drawn from; nil for anything else or when that is not known.
    public var lightKind: String? {
        if case .light(let light) = display { return light.kind.rawValue }
        return nil
    }

    /// Whether an empty instances a collection, from what the mirror said it
    /// is drawn from; nil for anything else or when that is not known.
    public var instancesCollection: Bool? {
        if case .empty(let empty) = display { return empty.instancesCollection }
        return nil
    }
}

extension Bpy.ObjectReach {
    public func acts(on object: BKObject) -> Bool {
        acts(onType: object.blenderType, lightKind: object.lightKind,
             instancesCollection: object.instancesCollection)
    }
}

/// What the selection offers Object ▸ Set Origin and Object ▸ Apply.
///
/// Every field is read back from Blender through the mirror rather than from
/// what the interface meant to do: the channels are `LocalTransform`, the type
/// is `obj.type`, a light's kind is its data's, the selection is
/// `select_get()`. A row is greyed out only when Blender's operator would
/// change nothing — never on a value that can lie, and never where Blender
/// would refuse in a sentence of its own: that sentence reaches the banner.
struct ObjectTransformState {
    var isRunning = false
    var editing = false
    /// Whether anything selected is something `origin_set` moves at all.
    var canSetOrigin = false
    /// Whether anything selected is something `transform_apply` bakes at all.
    var canApply = false
    /// Whether an object Apply acts on has something to bake in that channel.
    /// Applying an identity channel returns `{'FINISHED'}` and pushes an undo
    /// step for a scene that did not change.
    var hasLocation = false
    var hasRotation = false
    var hasScale = false
    /// The active object's scale when Apply Scale would bake it, shown under
    /// the row. An unapplied non-uniform scale is invisible until a modifier
    /// measured in metres comes out lopsided, so the number belongs where the
    /// fix is — signed, because a mirroring -1 is the case that most needs
    /// saying — and nil when there is nothing to warn about.
    var activeScale: SIMD3<Float>?

    /// The subtitle, to the digit the tolerance needs, so a scale the row is
    /// offered for never reads "1 × 1 × 1". `%.3g` read so for anything within
    /// 0.0005 of 1 — a 1.0002 from a small drag — while 1e-5 is offered.
    var activeScaleText: String? {
        activeScale.map { String(format: "%.6g × %.6g × %.6g", $0.x, $0.y, $0.z) }
    }

    /// Not gated on an active object: both operators act on the selection,
    /// and with `view_layer.objects.active` None — after deleting the active
    /// object and selecting all, say — a selected cube still had its scale
    /// baked and its origin moved to the cursor (measured in 5.2.1).
    var enabled: Bool { !editing && !isRunning }

    init() {}

    init(scene: BKScene, editing: Bool, isRunning: Bool) {
        self.isRunning = isRunning
        self.editing = editing
        let selected = scene.objects.filter { scene.selection.contains($0.id) }
        canSetOrigin = selected.contains { Bpy.originReach.acts(on: $0) }
        // Only what Apply acts on counts: a camera's scale of 2 beside a mesh
        // with none bakes nothing (measured: CANCELLED for the camera alone).
        let baked = selected.filter { Bpy.applyReach.acts(on: $0) }.map(\.appliedTransform)
        canApply = !baked.isEmpty
        // An object whose channels are unknown counts as having all three.
        hasLocation = baked.contains { $0?.bakesLocation ?? true }
        hasRotation = baked.contains { $0?.bakesRotation ?? true }
        hasScale = baked.contains { $0?.bakesScale ?? true }
        activeScale = scene.active.flatMap { active in
            guard scene.selection.contains(active.id), Bpy.applyReach.acts(on: active),
                  let channels = active.appliedTransform, channels.bakesScale
            else { return nil }
            return channels.scale
        }
    }

    func has(_ what: Bpy.AppliedTransform) -> Bool {
        switch what {
        case .all:      return hasLocation || hasRotation || hasScale
        case .location: return hasLocation
        case .rotation: return hasRotation
        case .scale:    return hasScale
        }
    }

    /// Whether a row can be chosen at all — the menu and the row together.
    func offers(_ what: Bpy.AppliedTransform) -> Bool {
        enabled && canApply && has(what)
    }
}

extension BpyBridge {
    /// Object ▸ Set Origin, as both menus send it. The refusal goes in
    /// `setup:`, which runs first in the same evaluation and is not logged —
    /// the log is the action, and the scaffolding an operator needs is not it.
    @discardableResult
    public func setOrigin(_ choice: Bpy.OriginChoice) -> Outcome {
        run(Bpy.originSet(choice.type, center: choice.center),
            undo: Bpy.originReach.undoName, setup: Bpy.originReach.guardPython)
    }

    /// Object ▸ Apply, Blender's Ctrl+A menu.
    @discardableResult
    public func applyTransform(_ what: Bpy.AppliedTransform) -> Outcome {
        run(Bpy.applyTransform(what), undo: what.undoName, setup: Bpy.applyReach.guardPython)
    }
}

// MARK: the simulator's shim

public extension BKScene {
    /// `transform_apply` in the simulator: the chosen channels baked into each
    /// selected mesh's base. Returns how many objects it baked.
    ///
    /// The base, not `mesh`: `mesh` is the modifier stack's output, and
    /// `setMirroredMesh` runs the stack over what it is given — so baking
    /// `mesh` applied every modifier twice, a Subdivision at level 1 coming
    /// back at level 2. Blender bakes `object.data` and evaluates the stack on
    /// top. Meshes only: a camera or a point light beside a mesh is left alone,
    /// as Blender leaves it; the shim's Python refuses an empty or an area
    /// light, which Blender does bake, before this is reached.
    ///
    /// What is baked is `apply_objects_internal`'s matrix, which corrects for
    /// the channels that stay: Location alone moves the geometry by
    /// (RS)⁻¹·loc, Rotation alone turns it by S⁻¹·R·S. Baking the chosen
    /// channel's own matrix moved the world vertices of a cube at (1,2,3),
    /// turned (0.3, 0, 0.5) and scaled (1,2,3) by 6.83 for Location and 1.09
    /// for Rotation; Blender moved them 0 for every row (measured in 5.2.1).
    /// The inverses are `invert_m3_m3`'s, so a zero scale does what it does
    /// in Blender: Rotation without Scale skips the object ("has a
    /// non-invertible transformation matrix, not applying transform"), and
    /// Location still bakes, through the bare adjugate — which moves it
    /// (measured: 3.74 for a zero X scale at (1,2,3)).
    @discardableResult
    func bakeSelectedTransforms(location: Bool, rotation: Bool, scale: Bool) -> Int {
        var baked = 0
        for obj in objects where selection.contains(obj.id) && obj.blenderType == "MESH" {
            let turn = simd_float4x4(eulerXYZ: obj.rotation)
            let r = simd_float3x3(turn.columns.0.xyz, turn.columns.1.xyz, turn.columns.2.xyz)
            let s = simd_float3x3(diagonal: obj.scale)
            let linear: simd_float3x3
            if rotation && scale {
                linear = r * s
            } else if scale {
                linear = s
            } else if rotation {
                let unscale = blenderInverse(s)
                guard unscale.invertible else { continue }
                linear = unscale.inverse * r * s
            } else {
                linear = matrix_identity_float3x3
            }
            var offset = SIMD3<Float>.zero
            if location {
                offset = rotation && scale ? obj.location
                    : linear * blenderInverse(r * s).inverse * obj.location
            }
            let normalMatrix = linear.inverse.transpose
            var base = obj.evaluatedBase
            for i in base.vertices.indices {
                base.vertices[i].position = linear * base.vertices[i].position + offset
                base.vertices[i].normal = normalize(normalMatrix * base.vertices[i].normal)
            }
            if location { obj.location = .zero }
            if rotation { obj.rotation = .zero }
            if scale { obj.scale = SIMD3(repeating: 1) }
            obj.setMirroredMesh(base)
            baked += 1
        }
        return baked
    }

    /// `origin_set(type='ORIGIN_GEOMETRY', center='MEDIAN')` in the simulator:
    /// the median of each selected mesh's base moved to its origin, and the
    /// object moved by as much, so nothing appears to jump. The base for the
    /// reason `bakeSelectedTransforms` gives, and because Blender takes the
    /// median of `object.data`, not of what the stack makes of it.
    @discardableResult
    func moveSelectedOriginsToMedian() -> Int {
        var moved = 0
        for obj in objects where selection.contains(obj.id) && obj.blenderType == "MESH" {
            var base = obj.evaluatedBase
            guard !base.vertices.isEmpty else { continue }
            let median = base.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                / Float(base.vertices.count)
            for i in base.vertices.indices { base.vertices[i].position -= median }
            obj.location += (simd_float4x4(eulerXYZ: obj.rotation) * SIMD4(median * obj.scale, 0)).xyz
            obj.setMirroredMesh(base)
            moved += 1
        }
        return moved
    }
}

/// `invert_m3_m3`: the adjugate, divided by the determinant when there is
/// one. Blender carries on with the bare adjugate when there is not, and
/// `bakeSelectedTransforms` has to do the same to land where Blender does.
private func blenderInverse(_ m: simd_float3x3) -> (inverse: simd_float3x3, invertible: Bool) {
    let (c0, c1, c2) = (m.columns.0, m.columns.1, m.columns.2)
    let adjugate = simd_float3x3(rows: [cross(c1, c2), cross(c2, c0), cross(c0, c1)])
    let determinant = dot(c0, cross(c1, c2))
    return determinant != 0 ? (adjugate * (1 / determinant), true) : (adjugate, false)
}

// MARK: - The Transform fields

/// What Blender's Transform fields — the N panel's Item tab and Properties ▸
/// Object — show and write: `location`, the rotation in the property its
/// `rotation_mode` uses, and `scale`, each without its delta, as Blender's own
/// fields show them. `_blenderkit_sync.field_channels` sends them.
///
/// Neither transform the mirror already carried can stand in for them:
///
/// - `BKObject.location`, `rotation` and `scale` decompose `matrix_world`, and
///   the fields used to show them while writing `location`, `rotation_euler`
///   and `scale`. Measured in 5.2.1 with the app's Object ▸ Parent
///   (`parent_set(keep_transform=False, type='OBJECT')`): B parented to A, A
///   then moved 2 in X and turned 90° about Z. The field showed B at
///   (-1, 0, 0) while Blender held `B.location` (0, 3, 0), so a nudge of Z by
///   0.01 wrote (-1, 0, 0.01) and B jumped to world (2, -1, 0.01), 3.16 m
///   away. A delta, an Euler order other than XYZ or a quaternion part them
///   the same way without any parent.
/// - `LocalTransform` folds the deltas in, which is what Apply bakes and not
///   what the fields show.
public struct TransformChannels: Equatable, Sendable {
    public enum RotationMode: Equatable, Sendable {
        /// One of Blender's six Euler orders, the first axis named turning first.
        case euler(String)
        case quaternion
        case axisAngle

        static let eulerOrders = ["XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX"]

        /// `_blenderkit_sync._ROTATION_MODES`' numbering.
        init?(code: Double) {
            guard code.isFinite, code >= 0, code.rounded() == code, code < 8 else { return nil }
            switch Int(code) {
            case 6:  self = .quaternion
            case 7:  self = .axisAngle
            case let i: self = .euler(Self.eulerOrders[i])
            }
        }

        /// The property the rotation fields write.
        public var property: String {
            switch self {
            case .euler:      return "rotation_euler"
            case .quaternion: return "rotation_quaternion"
            case .axisAngle:  return "rotation_axis_angle"
            }
        }

        /// As Blender's Mode menu names it.
        public var label: String {
            switch self {
            case .euler(let order): return order + " Euler"
            case .quaternion:       return "Quaternion (WXYZ)"
            case .axisAngle:        return "Axis Angle"
            }
        }
    }

    /// The three rows of fields.
    public enum Group: Int, CaseIterable, Sendable {
        case location, rotation, scale

        public var title: String { ["Location", "Rotation", "Scale"][rawValue] }
        /// The undo step a change makes, as the panels have always named it.
        public var undoName: String { ["Move", "Rotate", "Resize"][rawValue] }
    }

    public var location: SIMD3<Float>
    public var rotationMode: RotationMode
    /// As the mode's property holds it: an Euler's (x, y, z) in radians and a
    /// 0; a quaternion's (w, x, y, z), not normalised; an axis-angle's
    /// (angle, x, y, z).
    public var rotation: SIMD4<Float>
    public var scale: SIMD3<Float>

    public init(location: SIMD3<Float>, rotationMode: RotationMode, rotation: SIMD4<Float>,
                scale: SIMD3<Float>) {
        self.location = location
        self.rotationMode = rotationMode
        self.rotation = rotation
        self.scale = scale
    }

    /// Location, mode number, rotation, scale: the mirror's eleven numbers.
    /// Nil for a mode number Blender does not have. A channel Blender holds as
    /// NaN (a script can set one) is kept: the field shows it, and typing a
    /// number there is how it is mended.
    public init?(_ values: [Double]) {
        guard values.count == 11, let mode = RotationMode(code: values[3]) else { return nil }
        let f = values.map { Float($0) }
        location = SIMD3(f[0], f[1], f[2])
        rotationMode = mode
        rotation = SIMD4(f[4], f[5], f[6], f[7])
        scale = SIMD3(f[8], f[9], f[10])
    }

    /// XYZ Euler: the simulator's own channels before the mirror has sent any,
    /// and an object nothing mirrors.
    public init(location: SIMD3<Float>, eulerXYZ e: SIMD3<Float>, scale: SIMD3<Float>) {
        self.init(location: location, rotationMode: .euler("XYZ"), rotation: SIMD4(e, 0), scale: scale)
    }

    /// The labels of a row: X Y Z, or W X Y Z for a quaternion or an axis
    /// angle, whose W is the angle.
    public func axes(_ group: Group) -> [String] {
        switch (group, rotationMode) {
        case (.rotation, .quaternion), (.rotation, .axisAngle): return ["W", "X", "Y", "Z"]
        default: return ["X", "Y", "Z"]
        }
    }

    public func values(_ group: Group) -> [Float] {
        switch group {
        case .location: return [location.x, location.y, location.z]
        case .scale:    return [scale.x, scale.y, scale.z]
        case .rotation:
            let all = [rotation.x, rotation.y, rotation.z, rotation.w]
            if case .euler = rotationMode { return Array(all.prefix(3)) }
            return all
        }
    }

    /// Whether a field is an angle, shown in degrees: every Euler field, and
    /// an axis angle's W.
    public func isAngle(_ group: Group, axis: Int) -> Bool {
        guard group == .rotation else { return false }
        switch rotationMode {
        case .euler:      return true
        case .quaternion: return false
        case .axisAngle:  return axis == 0
        }
    }

    /// These channels with one field changed.
    public func setting(_ group: Group, axis: Int, to value: Float) -> TransformChannels {
        var next = self
        switch group {
        case .location: if axis < 3 { next.location[axis] = value }
        case .scale:    if axis < 3 { next.scale[axis] = value }
        case .rotation:
            let width = axes(.rotation).count
            if axis < width { next.rotation[axis] = value }
        }
        return next
    }

    /// The turn the rotation makes before its delta, as `BKE_object_rot_to_mat3`
    /// builds it: an Euler turned axis by axis in its order, a quaternion
    /// normalised — a zero one is a half turn about X (`_blenderkit_sync.
    /// _unit_quaternion` has the measurement) — and an axis angle about its
    /// normalised axis, no turn at all for a zero axis.
    public var turn: simd_quatf {
        switch rotationMode {
        case .euler(let order):
            var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
            for axis in order {
                let i = axis == "X" ? 0 : axis == "Y" ? 1 : 2
                var unit = SIMD3<Float>(0, 0, 0)
                unit[i] = 1
                q = simd_quatf(angle: rotation[i], axis: unit) * q
            }
            return q
        case .quaternion:
            let q = SIMD4(rotation.x, rotation.y, rotation.z, rotation.w)   // w, x, y, z
            let n = length(q)
            guard n > 0 else { return simd_quatf(ix: 1, iy: 0, iz: 0, r: 0) }
            return simd_quatf(ix: q.y / n, iy: q.z / n, iz: q.w / n, r: q.x / n)
        case .axisAngle:
            let axis = SIMD3(rotation.y, rotation.z, rotation.w)
            guard length(axis) > 0 else { return simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
            return simd_quatf(angle: rotation.x, axis: normalize(axis))
        }
    }

    /// The Python that writes every field of `edited` that differs from
    /// these: one assignment per changed field, to that one component, so
    /// the fields left alone keep Blender's own values to the last bit — the
    /// three-component write at four places this replaced turned an X of 90°
    /// into 90.0002° when Z was edited. The number is the field's own Float,
    /// written to its shortest exact form. Nil when nothing changed, when a
    /// value is not a number Python can read, or when the mode changed under
    /// the edit.
    public func python(writing edited: TransformChannels, to name: String) -> String? {
        guard edited.rotationMode == rotationMode else { return nil }
        var lines: [String] = []
        let target = "bpy.data.objects[\(Bpy.quote(name))]"
        for group in Group.allCases {
            let property = group == .rotation ? rotationMode.property : group == .location ? "location" : "scale"
            for (axis, (old, new)) in zip(values(group), edited.values(group)).enumerated()
            where old.bitPattern != new.bitPattern {
                guard new.isFinite else { return nil }
                lines.append("\(target).\(property)[\(axis)] = \(new)")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `matrix_basis` for these channels with the deltas `local` folds in
    /// over `base` — the channels `local` was read with. Nil when a delta
    /// cannot be recovered: a zero scale hides its delta scale.
    func basis(deltasFrom local: LocalTransform?, over base: TransformChannels) -> simd_float4x4? {
        var deltaLocation = SIMD3<Float>(repeating: 0)
        var deltaTurn = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        var deltaScale = SIMD3<Float>(repeating: 1)
        if let local {
            guard base.scale.x != 0, base.scale.y != 0, base.scale.z != 0 else { return nil }
            deltaLocation = local.location - base.location
            deltaTurn = local.rotation * base.turn.inverse
            deltaScale = local.scale / base.scale
        }
        return simd_float4x4(translation: location + deltaLocation)
            * simd_float4x4(deltaTurn * turn)
            * simd_float4x4(scale: scale * deltaScale)
    }

    /// Where `matrix_world` goes once `edited` is written over these channels:
    /// `world` · basis⁻¹ · basis′. What the parent, its inverse and any
    /// constraint contribute is `world` · basis⁻¹, and writing a channel
    /// leaves it as it was. Nil when that part cannot be recovered — a basis
    /// with no inverse — or the result is not finite; the fields then preview
    /// nothing, and the viewport moves when Blender has the value.
    public func world(after edited: TransformChannels, from world: simd_float4x4,
                      local: LocalTransform?) -> simd_float4x4? {
        guard let before = basis(deltasFrom: local, over: self),
              let after = edited.basis(deltasFrom: local, over: self),
              abs(before.determinant) > 1e-12 else { return nil }
        let moved = world * before.inverse * after
        // Component by component rather than simd's `all`: a host suite's
        // own top-level `all` shadows it (tests/boxselect).
        let finite = [moved.columns.0, moved.columns.1, moved.columns.2, moved.columns.3]
            .allSatisfy { column in (0..<4).allSatisfy { column[$0].isFinite } }
        return finite ? moved : nil
    }
}

extension BKObject {
    /// What the Transform fields show: Blender's channels when mirrored, the
    /// display cache's own when nothing mirrors this object — then
    /// `location`, `rotation` and `scale` are the channels, XYZ Euler with no
    /// parent and no delta.
    ///
    /// Nil for an object that came from Blender without them: `location`,
    /// `rotation` and `scale` are then a decomposition of `matrix_world`,
    /// which is exactly the value that lies, and the fields say so instead.
    /// During a gizmo drag, whose preview drops the mirrored matrix, they
    /// show what Blender holds until the drag commits.
    public var shownChannels: TransformChannels? {
        if let channels { return channels }
        if mirroredTransform != nil { return nil }
        return TransformChannels(location: location, eulerXYZ: rotation, scale: scale)
    }
}

/// One edit of a Transform field, from its first change — the first sample
/// of a drag, a typed number — to the finger lifting, where `BpyBridge.
/// commitTransformField` writes it.
///
/// While it lasts the viewport previews the write: the object moves to the
/// `matrix_world` Blender will give it (`TransformChannels.world`), and its
/// children with it, each by its parent's change, as the gizmo's preview
/// carries them (`BKScene.carried`). `rollBack` puts everything back, and
/// the commit's mirroring pass then draws what Blender did.
public struct TransformFieldEdit {
    public let object: BKObject
    public let start: TransformChannels
    public private(set) var edited: TransformChannels
    private let local: LocalTransform?
    private let startWorld: simd_float4x4?
    /// True for an object nothing mirrors, whose own channels are what is
    /// drawn: the preview sets them. An object with Blender's channels and
    /// no matrix — mid gizmo drag, whose preview drops it — previews nothing,
    /// since its channels are not where it is drawn.
    private let drawsChannels: Bool
    private let startPose: ObjectPose
    private let followers: [(object: BKObject, parent: BKObject, matrix: simd_float4x4?)]

    /// Nil when the fields have nothing to show for the object.
    public init?(object: BKObject, scene: BKScene) {
        guard let start = object.shownChannels else { return nil }
        self.object = object
        self.start = start
        edited = start
        local = object.channels == nil ? nil : object.localTransform
        startWorld = object.mirroredTransform
        drawsChannels = object.mirroredTransform == nil && object.channels == nil
        startPose = ObjectPose(object)
        followers = scene.carried(by: [object.id]).map { child, parent in
            (child, parent, child.mirroredTransform)
        }
    }

    /// The object as the commit will leave it, if it can be worked out: nil
    /// when the fields have nothing to preview it with (see `world`).
    public var previewedWorld: simd_float4x4? {
        guard let startWorld else {
            return drawsChannels ? simd_float4x4(translation: edited.location)
                * simd_float4x4(edited.turn) * simd_float4x4(scale: edited.scale) : nil
        }
        // Mirrored channels without the deltas they were read with preview
        // nothing rather than guess at them.
        if object.channels != nil, local == nil { return nil }
        return start.world(after: edited, from: startWorld, local: local)
    }

    /// One field's new value, previewed.
    public mutating func change(_ group: TransformChannels.Group, axis: Int, to value: Float) {
        edited = edited.setting(group, axis: axis, to: value)
        guard let startWorld else {
            // Nothing mirrors it: its own channels are what is drawn, and
            // Euler XYZ is all they hold.
            guard drawsChannels else { return }
            object.location = edited.location
            if case .euler = edited.rotationMode {
                object.rotation = SIMD3(edited.rotation.x, edited.rotation.y, edited.rotation.z)
            }
            object.scale = edited.scale
            return
        }
        guard let moved = previewedWorld else {
            rollBackDrawing()
            return
        }
        object.setMirroredTransform(moved)
        var before: [UUID: simd_float4x4] = [object.id: startWorld]
        var after: [UUID: simd_float4x4] = [object.id: moved]
        for follower in followers {
            guard let own = follower.matrix, let parentBefore = before[follower.parent.id],
                  let parentAfter = after[follower.parent.id] else { continue }
            let carried = parentAfter * parentBefore.inverse * own
            before[follower.object.id] = own
            after[follower.object.id] = carried
            follower.object.setMirroredTransform(carried)
        }
    }

    /// The Python the commit sends; nil when nothing changed.
    public var python: String? { start.python(writing: edited, to: object.name) }

    /// Everything drawn back where the edit found it.
    public func rollBackDrawing() {
        if let startWorld {
            object.setMirroredTransform(startWorld)
        } else if drawsChannels {
            object.location = startPose.location
            object.rotation = startPose.rotation
            object.scale = startPose.scale
        }
        // Only the children `change` moved: the ones drawn through a matrix.
        for follower in followers {
            if let matrix = follower.matrix { follower.object.setMirroredTransform(matrix) }
        }
    }
}

extension BpyBridge {
    /// A Transform field's edit, written: one assignment per changed field,
    /// as one undo step named for the row. The preview is rolled back first,
    /// so the mirroring pass `run` ends with draws what Blender holds — the
    /// new value, or the old one where Blender refused it — rather than a
    /// preview on top of it. Nil when there was nothing to write.
    @discardableResult
    public func commitTransformField(_ edit: TransformFieldEdit,
                                     group: TransformChannels.Group) -> Outcome? {
        edit.rollBackDrawing()
        guard let python = edit.python else { return nil }
        return run(python, undo: group.undoName)
    }
}
