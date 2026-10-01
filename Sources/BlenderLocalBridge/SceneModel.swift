import Foundation
import simd
import CoreGraphics
import Observation

/// What a paint dab does, which is what the toolbar picks between: Draw lays
/// the brush value down, Blur softens toward each vertex's neighbours, and
/// Average pulls everything under the brush toward their shared mean.
public enum VertexPaintOp: Sendable { case draw, blur, average }

/// Blender's mesh symmetry — the Mesh's `use_mirror_x`, `use_mirror_y`,
/// `use_mirror_z` and `use_mirror_topology` — as one value.
///
/// Blender keeps it on the mesh datablock, not the tool: the X / Y / Z buttons
/// of the edit, sculpt and paint headers all write the same three flags
/// (`Mesh.symmetry`), and Topology Mirror is `Mesh.editflag`'s
/// ME_EDIT_MIRROR_TOPO. The mirror reads all four back from Blender with each
/// object (`_blenderkit_sync._kind`), so this is never a local copy.
///
/// A `SIMD3<Bool>` would read better but `Bool` is not a `SIMDScalar`, so this
/// is three flags with a subscript that keeps the call sites looking the same.
public struct MeshSymmetry: Sendable, Equatable {
    public var x = false
    public var y = false
    public var z = false
    /// Topology Mirror: pairs found by the mesh's edges rather than by
    /// position. On its own it mirrors nothing — it changes how the axes on
    /// find their pairs (SymmetricEdit).
    public var topology = false

    public init(x: Bool = false, y: Bool = false, z: Bool = false, topology: Bool = false) {
        self.x = x; self.y = y; self.z = z; self.topology = topology
    }

    public subscript(axis: Int) -> Bool {
        get { axis == 0 ? x : (axis == 1 ? y : z) }
        set { if axis == 0 { x = newValue } else if axis == 1 { y = newValue } else { z = newValue } }
    }

    /// Whether any axis mirrors. Topology alone does not.
    public var isOn: Bool { x || y || z }
    /// The axis letters Blender shows in the header, e.g. "XZ".
    public var label: String { (x ? "X" : "") + (y ? "Y" : "") + (z ? "Z" : "") }

    /// The `|mirror=…` flag `_blenderkit_sync._kind` writes: one letter per
    /// flag Blender has on, x y z and t for topology.
    public init(flag: String) {
        self.init(x: flag.contains("x"), y: flag.contains("y"), z: flag.contains("z"),
                  topology: flag.contains("t"))
    }
}

/// The kinds of object Blender's Add menu creates. Each case carries the mesh
/// primitive and the `bpy.ops.mesh.primitive_*` operator it corresponds to, so
/// the Tools tab and the Scripting tab describe the same operation.
public enum PrimitiveKind: String, CaseIterable, Identifiable, Sendable {
    case plane, cube, circle, uvSphere, icoSphere, cylinder, cone, torus, grid, monkey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plane:     return "Plane"
        case .cube:      return "Cube"
        case .circle:    return "Circle"
        case .uvSphere:  return "UV Sphere"
        case .icoSphere: return "Ico Sphere"
        case .cylinder:  return "Cylinder"
        case .cone:      return "Cone"
        case .torus:     return "Torus"
        case .grid:      return "Grid"
        case .monkey:    return "Monkey"
        }
    }

    /// The SF Symbol standing in for Blender's own icon.
    public var icon: String {
        switch self {
        case .plane:     return "square"
        case .cube:      return "cube"
        case .circle:    return "circle"
        case .uvSphere:  return "globe"
        case .icoSphere: return "globe.desk"
        case .cylinder:  return "cylinder"
        case .cone:      return "cone"
        case .torus:     return "circle.circle"
        case .grid:      return "grid"
        case .monkey:    return "face.smiling"
        }
    }

    /// The exact bpy operator, so the Scripting tab can show the user the
    /// Python their tool click is equivalent to.
    /// The stem of `bpy.ops.mesh.primitive_<name>_add`.
    public var bpyPrimitive: String {
        switch self {
        case .plane: return "plane"
        case .cube: return "cube"
        case .circle: return "circle"
        case .uvSphere: return "uv_sphere"
        case .icoSphere: return "ico_sphere"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .torus: return "torus"
        case .grid: return "grid"
        case .monkey: return "monkey"
        }
    }

    public var bpyOperator: String {
        switch self {
        case .plane:     return "bpy.ops.mesh.primitive_plane_add"
        case .cube:      return "bpy.ops.mesh.primitive_cube_add"
        case .circle:    return "bpy.ops.mesh.primitive_circle_add"
        case .uvSphere:  return "bpy.ops.mesh.primitive_uv_sphere_add"
        case .icoSphere: return "bpy.ops.mesh.primitive_ico_sphere_add"
        case .cylinder:  return "bpy.ops.mesh.primitive_cylinder_add"
        case .cone:      return "bpy.ops.mesh.primitive_cone_add"
        case .torus:     return "bpy.ops.mesh.primitive_torus_add"
        case .grid:      return "bpy.ops.mesh.primitive_grid_add"
        case .monkey:    return "bpy.ops.mesh.primitive_monkey_add"
        }
    }

    /// Blender's default name for a new object of this kind.
    public var defaultName: String {
        switch self {
        case .plane:     return "Plane"
        case .cube:      return "Cube"
        case .circle:    return "Circle"
        case .uvSphere:  return "Sphere"
        case .icoSphere: return "Icosphere"
        case .cylinder:  return "Cylinder"
        case .cone:      return "Cone"
        case .torus:     return "Torus"
        case .grid:      return "Grid"
        case .monkey:    return "Suzanne"
        }
    }
}

/// One scene object. Mirrors the parts of `bpy.types.Object` the viewport needs.
@Observable
public final class BKObject: Identifiable {
    public var blenderType = "MESH"
    public var outlinerIcon: String {
        switch blenderType {
        case "CAMERA": return "camera"
        case "LIGHT": return "lightbulb"
        case "EMPTY": return "plus"
        case "CURVE", "SURFACE": return "scribble.variable"
        case "FONT": return "textformat"
        case "ARMATURE": return "figure.stand"
        case "LATTICE": return "grid"
        default: return kind.icon
        }
    }

    /// Whether Edit Mesh means anything for this object.
    ///
    /// Only a mesh has the edit, sculpt and paint modes this app offers, and
    /// `mode_set` on anything else fails with the enum it was handed rather
    /// than a sentence. The button is disabled from here so the question is
    /// answered before Blender is asked.
    public var hasEditMode: Bool { blenderType == "MESH" }

    public let id = UUID()
    public var name: String
    public var kind: PrimitiveKind
    // Moving any of these makes a mirrored `matrix_world` stale, and stale is
    // worse than absent: `modelMatrix` prefers the matrix, so the renderer
    // would keep drawing the object where Blender last said it was while the
    // drag moved numbers nobody reads. See `invalidateMirroredTransform`.
    public var location: SIMD3<Float> { didSet { invalidateMirroredTransform() } }
    public var rotation: SIMD3<Float> { didSet { invalidateMirroredTransform() } }
    public var scale: SIMD3<Float> { didSet { invalidateMirroredTransform() } }
    /// Whether the viewport draws it — Blender's `visible_get()`, which is
    /// false for either flag below and for an object in a hidden collection.
    public var visible: Bool = true
    /// Blender's `hide_get()`: hidden in the view layer, which is what H,
    /// Alt+H and the Outliner's eye change.
    public var hiddenInViewLayer = false
    /// Blender's `hide_viewport`, Disable in Viewports: the Outliner's monitor.
    /// Show Hidden Objects leaves it alone (measured in 5.2.1), so it has its
    /// own control.
    public var disabledInViewports = false

    /// Viewport display colour — Blender's `object.color`, shown in Material
    /// Preview shading.
    public var color: SIMD4<Float> = SIMD4(0.8, 0.8, 0.8, 1)

    /// The modifier stack, evaluated top to bottom. Changing it rebuilds the
    /// mesh immediately rather than lazily, so vertex counts and ray-picking
    /// never disagree with what is on screen.
    public var modifiers: [Modifier] = [] {
        didSet { if !recordingEvaluation { rebuildMesh() } }
    }

    /// True while `rebuildMesh` writes back what evaluating the stack
    /// reported, which must not evaluate it again.
    @ObservationIgnored private var recordingEvaluation = false

    /// The evaluated mesh — the base primitive with the modifier stack applied.
    public private(set) var mesh: MeshData

    /// Bumped on every rebuild so the renderer knows to re-upload its buffers.
    public private(set) var meshVersion: Int = 0

    /// Keyframed transform channels for this object.
    public var animation = AnimationData()
    /// Blender's keys on this object and its data, as timeline columns, when
    /// the scene is mirrored from Blender; nil in the simulator, whose keys are
    /// `animation`. Read through `timelineKeys` (AnimationTimeline.swift).
    public var mirroredKeys: [TimelineKey]?

    /// The object's material and its node graph. Blender allows several slots;
    /// this is the single slot every object starts with.
    public var material = Material()
    public var shaderGraph = ShaderGraph()
    /// The paintable base-colour texture, created on first paint.
    /// The object's geometry node tree, evaluated after the modifier stack.
    public var geometryNodes = GeometryNodeTree() {
        didSet { rebuildMesh() }
    }
    @ObservationIgnored public var texture: TextureImage?
    /// Bumped alongside the texture so the view redraws.
    public var textureVersion: Int = 0
    /// The UV map and images Texture Paint paints through, one UV per triangle
    /// corner so a seam needs no split vertex. See `PaintSurface`.
    @ObservationIgnored public var paintSurface: PaintSurface?

    /// Per-vertex colour, Blender's colour attribute. Empty until something
    /// paints; `vertexColour(at:)` falls back to white so the renderer never
    /// has to branch on whether the layer exists.
    @ObservationIgnored public var vertexColours: [SIMD4<Float>] = []
    /// Per-vertex weight, Blender's vertex group. Same emptiness convention.
    @ObservationIgnored public var vertexWeights: [Float] = []

    /// Blender's sculpt mask (`.sculpt_mask`), one value per vertex of the
    /// mesh drawn, 0 to 1; empty when nothing is masked. Mirrored from Blender
    /// with the mesh (`_blenderkit_sculpt.push_mask`), never painted here: the
    /// Sculpt Mode viewport darkens what is masked, as Blender's mask overlay
    /// does. `sculptMaskVersion` changes with it, for the renderer's buffer.
    @ObservationIgnored public var sculptMask: [Float] = []
    public var sculptMaskVersion: Int = 0

    /// The mask as the renderer draws it: only when its count is the mesh's,
    /// since a mesh that changed since (a remesh the mirror has not caught up
    /// with) would take the values of other vertices.
    public var drawnSculptMask: [Float]? {
        sculptMask.isEmpty || sculptMask.count != mesh.vertices.count ? nil : sculptMask
    }

    /// Blender's mesh symmetry (`data.use_mirror_x/y/z`, `use_mirror_topology`),
    /// as the mirror last read it: what an edit-mode drag mirrors
    /// (SymmetricEdit) and what the paint strokes repeat across each axis.
    ///
    /// Written only by a mirroring pass (`SceneMirror.object` and `merge`).
    /// The header's toggles send `SymmetryBpy` through `bridge.run` and show
    /// this value once Blender has it. It used to be the app's own: written by
    /// ToolHeader, which nothing instantiated, and never sent to Blender — so
    /// it was always off here whatever the mesh held.
    public var symmetry = MeshSymmetry()

    /// Blender's `hide_render`: kept out of renders while staying in the
    /// viewport. The Outliner's camera column toggles it.
    public var hideRender = false

    /// What Blender draws this object with when it is a camera, a light or an
    /// empty, none of which has a surface to mirror. See `ObjectDisplay`.
    public var display: ObjectDisplay?

    /// Set when the mirror sent this object's bounding box in place of a mesh
    /// past its vertex limit: how many vertices Blender has that are not
    /// drawn. Nil for an object drawn as it is.
    public var undrawnVertexCount: Int?

    /// How this object's viewport mesh lines up with Blender's while it is
    /// being edited — present only when the mirror found that it does, index
    /// for index. See `EditTopology`.
    @ObservationIgnored public var editTopology: EditTopology?

    /// Blender's `parent`, by name, and every object whose transform or
    /// geometry this one's depends on — the parent, constraint targets,
    /// objects its modifiers and drivers read. What a drag has to leave out
    /// of its snap targets and carry along in its preview; see
    /// ObjectRelations.swift. Empty in the simulator, whose shim has neither.
    ///
    /// The parent is observed — Properties ▸ Object ▸ Relations shows it, and
    /// a Parent that leaves the child's channels as they were changes nothing
    /// else that panel reads — and the merge sets it only when it changed.
    public var parentName: String?
    @ObservationIgnored public var dependencies: Set<String> = []

    /// What a drag may snap to on this object when it is not its mesh: a
    /// curve with no surface, which Blender snaps by its control points alone
    /// (`_blenderkit_sync._push_knots`), in the object's own space. Nil for
    /// everything snapped by its mesh.
    @ObservationIgnored public var snapPoints: [SIMD3<Float>]?

    /// Blender's Display As Bounds, which its snapping skips.
    @ObservationIgnored public var displaysBounds = false

    /// While a curve or a lattice is in Edit Mode, its control points as
    /// Blender holds them (`_blenderkit_points`, ControlPoints.swift): what
    /// Edit Mode draws, picks and moves for it, and what the status bar
    /// counts. Nil otherwise. Replaced only when it differs.
    public var controlCage: ControlCage?

    /// A curve's or a lattice's own settings, as the Data tab shows them.
    /// Written only by the mirror. Nil for every other type.
    public var dataSettings: ObjectDataSettings?

    /// A mesh's vertex groups and shape keys, as the Data tab shows them
    /// (MeshGroups.swift). Written only by the mirror; nil in the simulator,
    /// whose stand-in has neither, and for anything that is not a mesh.
    public var meshGroups: MeshGroups?

    /// Whether Edit Mode edits this object by its control points: a curve or
    /// a lattice. Their Edit Mode is Blender's, and the mesh tools are not
    /// theirs (`hasEditMode` stays the mesh's).
    public var editsPoints: Bool { blenderType == "CURVE" || blenderType == "LATTICE" }

    /// Whether the object has an Edit Mode here at all.
    public var canEnterEditMode: Bool { hasEditMode || editsPoints }

    /// Every place one stroke should land, given the symmetry settings: the
    /// original point plus a mirrored copy per enabled axis and per combination
    /// of them, which is what makes X+Y produce four strokes rather than three.
    public func symmetryPoints(_ p: SIMD3<Float>) -> [SIMD3<Float>] {
        var points = [p]
        for axis in 0..<3 where symmetry[axis] {
            points += points.map { q -> SIMD3<Float> in
                var m = q
                m[axis] = -m[axis]
                return m
            }
        }
        return points
    }

    public init(name: String,
                kind: PrimitiveKind,
                location: SIMD3<Float> = .zero,
                rotation: SIMD3<Float> = .zero,
                scale: SIMD3<Float> = .one) {
        self.name = name
        self.kind = kind
        self.location = location
        self.rotation = rotation
        self.scale = scale
        self.mesh = MeshBuilder.make(kind)
    }

    /// Set when the mesh came from Blender's evaluated depsgraph rather than
    /// from MeshBuilder. The modifier stack and primitive kind no longer
    /// describe it, so it must not be rebuilt locally.
    public private(set) var isMirrored = false
    /// Blender's `matrix_world`, used verbatim when mirroring — location,
    /// rotation and scale are Blender's business in that mode.
    public private(set) var mirroredTransform: simd_float4x4?

    /// The object's own channels as Blender holds them — what
    /// `transform_apply` bakes — when the scene is mirrored from Blender; nil
    /// in the simulator, where `location`, `rotation` and `scale` already are
    /// those channels. See `LocalTransform` for why `matrix_world` cannot
    /// stand in for them.
    public var localTransform: LocalTransform?

    /// What the Transform fields show and write — `location`, the rotation in
    /// the object's own mode and property, `scale`, no deltas — as Blender
    /// holds them, when the scene is mirrored. Nil until the mirror sends them.
    /// See `TransformChannels` for why neither `location`/`rotation`/`scale`
    /// (a decomposition of `matrix_world`) nor `localTransform` (deltas folded
    /// in) can stand in for them; `shownChannels` is what the fields read.
    public var channels: TransformChannels?

    /// The UV map Blender's UV Editor draws, when it is not the one `mesh`
    /// carries: the object's own mesh before its modifiers, mirrored by
    /// `sync_uv_layout` (`SceneMirror.uvLayout`). Nil when the two are the
    /// same — no modifier, or none that changes the map — and in the
    /// simulator. Read by the UV Editor alone; the viewport textures `mesh`.
    public var uvLayout: MeshData?

    /// Installs geometry that did not come from the primitive — a join, an
    /// edit-mode operator, or a sync from the real module.
    ///
    /// The mesh is kept as the new *base*, so the modifier stack still applies
    /// on top of it. Before this, `isMirrored` short-circuited `rebuildMesh`
    /// entirely, which meant adding a Subdivision to anything that had been
    /// edited silently did nothing.
    public func setMirroredMesh(_ data: MeshData) {
        mirroredBase = data
        isMirrored = true
        meshIsEvaluated = false
        mesh = modifiers.isEmpty ? data : ModifierStack.apply(modifiers, to: data)
        meshVersion &+= 1
    }

    /// Installs a mesh the mirror sent: Blender's *evaluated* geometry, with
    /// its modifier stack already applied.
    ///
    /// That is the difference from `setMirroredMesh`, and it matters once the
    /// stack is mirrored too. `_blenderkit_sync` pushes `evaluated_get().to_mesh()`
    /// — so does the simulator's stand-in, whose own comment says the evaluated
    /// object *is* the object. Running `ModifierStack.apply` over that applied
    /// every modifier twice: a Subdivision at level 2 drew as Blender's level 2
    /// plus this file's approximation on top. It was invisible for as long as
    /// the mirror never carried `modifiers`, because an empty stack is a no-op,
    /// and it appeared the day it started to.
    public func setEvaluatedMesh(_ data: MeshData) {
        mirroredBase = data
        isMirrored = true
        meshIsEvaluated = true
        mesh = data
        meshVersion &+= 1
    }

    /// True while `mesh` is the evaluator's output rather than a base the
    /// Swift stack should run over. Then the stack is a description for the
    /// Modifiers panel, and `rebuildMesh` leaves the geometry alone — the next
    /// mirroring pass brings Blender's result for whatever the panel changed.
    public private(set) var meshIsEvaluated = false

    /// The un-modified geometry behind a mirrored mesh.
    @ObservationIgnored private var mirroredBase: MeshData?

    /// The geometry the modifier stack is applied to — the edited mesh once
    /// something has replaced the primitive, and the primitive otherwise.
    /// This is what a duplicate has to start from.
    public var evaluatedBase: MeshData {
        mirroredBase ?? MeshBuilder.make(kind)
    }

    /// True only while `setMirroredTransform` is writing the decomposition back
    /// into location/rotation/scale, so those writes do not throw away the very
    /// matrix they came from.
    @ObservationIgnored private var decomposing = false

    /// Drop a mirrored `matrix_world` that no longer describes the object.
    ///
    /// On device Blender owns the scene, and every object comes back from the
    /// mirror carrying its `matrix_world`; `modelMatrix` uses that in
    /// preference to location/rotation/scale, because while Blender owns the
    /// transform its matrix is the truth.
    ///
    /// A live drag is the one moment that stops being true. The drag moves the
    /// object's components directly — sending Python per frame of a 60 fps
    /// gesture could not keep up — and the matrix from before the drag then
    /// pinned the object in place on screen. It moved only when the finger
    /// lifted and the real transform came back through bpy, so a move looked
    /// like a jump with nothing in between. In the simulator, where the shim
    /// sets no matrix, the same drag animated perfectly.
    private func invalidateMirroredTransform() {
        guard !decomposing else { return }
        mirroredTransform = nil
    }

    public func setMirroredTransform(_ m: simd_float4x4) {
        decomposing = true
        defer { decomposing = false }
        mirroredTransform = m
        // The renderer draws through the matrix, but the Properties and sidebar
        // fields read location/rotation/scale — so decompose, or the panels
        // report 0,0,0 for an object that is plainly not at the origin.
        let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let sx = length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))

        location = t
        scale = SIMD3(sx, sy, sz)

        // Strip the scale, then read XYZ Euler back out of the rotation part.
        // Blender composes Z*Y*X, so this inverts that order.
        guard sx > 1e-6, sy > 1e-6, sz > 1e-6 else { rotation = .zero; return }
        let r0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / sx
        let r1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / sy
        let r2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / sz

        let sy2 = -r0.z
        if abs(sy2) > 0.99999 {
            // Gimbal lock: pitch is vertical, so yaw and roll are degenerate
            // and only their sum is recoverable.
            rotation = SIMD3(atan2(-r2.y, r1.y), sy2 > 0 ? .pi / 2 : -.pi / 2, 0)
        } else {
            rotation = SIMD3(atan2(r1.z, r2.z), asin(sy2), atan2(r0.y, r0.x))
        }
    }

    public func rebuildMesh() {
        // Geometry the evaluator already produced is not re-evaluated here.
        // See `setEvaluatedMesh`: doing so applied every modifier twice.
        if meshIsEvaluated { return }
        // Blender evaluates modifiers and geometry nodes in stack order; the
        // node tree is a modifier, so it runs after the rest. An object whose
        // geometry came from outside evaluates the stack over *that* rather
        // than over its primitive — the primitive stopped describing it the
        // moment it was edited.
        let source = isMirrored ? (mirroredBase ?? mesh) : MeshBuilder.make(kind)
        // A Decimate's Faces row shows what the collapse produced — Blender's
        // `face_count`, which the mirror carries on device. Here the stack is
        // the evaluator, so it is read off the stack's own output; nothing
        // else wrote it, and the row read 0 for ever in the simulator.
        var faces: [Int: Int] = [:]
        // Likewise each Remesh's input size, which the mirror carries on
        // device as `input_size` and the Voxel Size row's floor is taken from
        // (`ModifierStack.remeshVoxelFloor(for:on:)`).
        var inputs: [Int: Float] = [:]
        let stack = modifiers
        if stack.first?.kind == .remesh { inputs[0] = ModifierStack.largestDimension(source) }
        let base = ModifierStack.apply(stack, to: source) { index, output in
            // A Decimate turned off in the viewport made nothing to count.
            if stack[index].kind == .decimate, stack[index].showInViewport {
                faces[index] = output.indices.count / 3
            }
            if index + 1 < stack.count, stack[index + 1].kind == .remesh {
                inputs[index + 1] = ModifierStack.largestDimension(output)
            }
        }
        mesh = GeometryNodeEvaluator.evaluate(geometryNodes, on: base)
        meshVersion &+= 1
        if faces.contains(where: { modifiers[$0.key].faceCount != $0.value })
            || inputs.contains(where: { modifiers[$0.key].inputSize != $0.value }) {
            recordingEvaluation = true
            defer { recordingEvaluation = false }
            for (index, count) in faces { modifiers[index].faceCount = count }
            for (index, size) in inputs { modifiers[index].inputSize = size }
        }
    }

    /// `bpy.ops.object.modifier_add`.
    @discardableResult
    public func addModifier(_ kind: ModifierKind) -> Modifier {
        let existing = modifiers.filter { $0.kind == kind }.count
        var m = Modifier(kind: kind)
        if existing > 0 { m.name = "\(kind.displayName).\(String(format: "%03d", existing))" }
        // Where Blender puts it: a Multires goes above the first modifier
        // that is not a pure deform (`ModifierStack.insertionIndex`).
        modifiers.insert(m, at: ModifierStack.insertionIndex(for: kind, in: modifiers))
        return m
    }

    public func removeModifier(named name: String) -> Bool {
        let before = modifiers.count
        modifiers.removeAll { $0.name == name }
        return modifiers.count != before
    }

    /// `bpy.ops.object.modifier_apply` in the simulator: that one modifier,
    /// run over the object's own mesh, becomes the mesh, and the rest of the
    /// stack stays on top of it.
    ///
    /// Blender applies the modifier to `object.data` alone — which is why it
    /// warns "Applied modifier was not first, result may not be as expected"
    /// — and it applies one turned off in the viewport too (both measured in
    /// 5.2.1: Edge Split third in a stack turned the base cube's 8 vertices
    /// into 24; a hidden Subdivision applied to 26). The shim used to freeze
    /// the whole evaluated stack and then run what was left of it over that,
    /// so with two modifiers every one below the applied one ran twice.
    @discardableResult
    public func applyModifier(named name: String) -> Bool {
        guard let index = modifiers.firstIndex(where: { $0.name == name }),
              !modifiers[index].isDisabled  // Blender refuses: "Modifier is disabled, skipping apply"
        else { return false }
        var one = modifiers[index]
        one.showInViewport = true
        let applied = ModifierStack.apply([one], to: evaluatedBase)
        var rest = modifiers
        rest.remove(at: index)
        recordingEvaluation = true
        modifiers = rest
        recordingEvaluation = false
        setMirroredMesh(applied)
        return true
    }

    /// Blender composes as location * rotation * scale, rotating XYZ Euler in
    /// that order.
    // MARK: vertex attributes  (vertex paint / weight paint)

    /// White where nothing has been painted, which is what Blender shows for a
    /// mesh with no colour attribute.
    public func vertexColour(at i: Int) -> SIMD4<Float> {
        i < vertexColours.count ? vertexColours[i] : SIMD4(1, 1, 1, 1)
    }

    public func vertexWeight(at i: Int) -> Float {
        i < vertexWeights.count ? vertexWeights[i] : 0
    }

    /// Grows the attribute arrays to match the mesh. Called before any paint
    /// stroke, since a modifier can change the vertex count under them.
    public func ensurePaintAttributes() {
        let n = mesh.vertices.count
        if vertexColours.count != n {
            vertexColours = (0..<n).map { $0 < vertexColours.count ? vertexColours[$0]
                                                                   : SIMD4(1, 1, 1, 1) }
        }
        if vertexWeights.count != n {
            vertexWeights = (0..<n).map { $0 < vertexWeights.count ? vertexWeights[$0] : 0 }
        }
    }

    public func mapVertexWeights(_ f: (Float) -> Float) {
        ensurePaintAttributes()
        vertexWeights = vertexWeights.map(f)
        textureVersion &+= 1
    }

    /// One paint dab in vertex-paint or weight-paint mode: every vertex within
    /// `radius` of the hit point is blended toward the brush value, falling off
    /// with distance the way Blender's brushes do.
    public func paintVertices(at point: SIMD3<Float>, radius: Float, strength: Float,
                              op: VertexPaintOp = .draw,
                              colour: SIMD4<Float>?, weight: Float?,
                              blend: BrushBlend = .mix,
                              falloff: BrushFalloff = .smooth) -> Int {
        ensurePaintAttributes()
        let local = (modelMatrix.inverse * SIMD4(point, 1)).xyz
        var touched = 0
        // Symmetry lands the same dab on each mirrored copy of the point, which
        // is how Blender keeps a symmetrical model symmetrical while painting.
        for centre in symmetryPoints(local) {
            let inRange = mesh.vertices.indices.filter {
                distance(mesh.vertices[$0].position, centre) < radius
            }
            guard !inRange.isEmpty else { continue }

            // Average needs the mean of what is under the brush before it can
            // move anything toward it, so it is computed once per dab.
            var meanColour = SIMD4<Float>.zero
            var meanWeight: Float = 0
            if op == .average {
                for i in inRange {
                    meanColour += vertexColours[i]
                    meanWeight += vertexWeights[i]
                }
                meanColour /= Float(inRange.count)
                meanWeight /= Float(inRange.count)
            }

            for i in inRange {
                let d = distance(mesh.vertices[i].position, centre)
                let amount = falloff.weight(d / radius) * strength
                switch op {
                case .draw:
                    if let colour { vertexColours[i] = blend.apply(vertexColours[i], colour, amount) }
                    if let weight { vertexWeights[i] += (weight - vertexWeights[i]) * amount }
                case .average:
                    if colour != nil { vertexColours[i] += (meanColour - vertexColours[i]) * amount }
                    if weight != nil { vertexWeights[i] += (meanWeight - vertexWeights[i]) * amount }
                case .blur:
                    // Toward the average of this vertex's own neighbours, which
                    // softens a boundary rather than flattening the whole dab.
                    let (nc, nw, n) = neighbourAverage(of: i)
                    guard n > 0 else { continue }
                    if colour != nil { vertexColours[i] += (nc - vertexColours[i]) * amount }
                    if weight != nil { vertexWeights[i] += (nw - vertexWeights[i]) * amount }
                }
                touched += 1
            }
        }
        if touched > 0 { textureVersion &+= 1 }
        return touched
    }

    /// The mean colour and weight of the vertices sharing an edge with `i`.
    private func neighbourAverage(of i: Int) -> (SIMD4<Float>, Float, Int) {
        var colour = SIMD4<Float>.zero
        var weight: Float = 0
        var count = 0
        for e in stride(from: 0, to: mesh.edges.count, by: 2) {
            let a = Int(mesh.edges[e]), b = Int(mesh.edges[e + 1])
            let other = a == i ? b : (b == i ? a : -1)
            guard other >= 0, other < vertexColours.count else { continue }
            colour += vertexColours[other]
            weight += vertexWeights[other]
            count += 1
        }
        guard count > 0 else { return (.zero, 0, 0) }
        return (colour / Float(count), weight / Float(count), count)
    }

    /// The object's axis-aligned bounds in world space.
    ///
    /// Its own mesh through its own transform: a rotated object's world bounds
    /// are larger than its local ones, and box select needs the extent that is
    /// actually on screen.
    public var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !mesh.vertices.isEmpty else { return (location, location) }
        let m = modelMatrix
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            let w = (m * SIMD4(v.position, 1)).xyz
            lo = min(lo, w); hi = max(hi, w)
        }
        return (lo, hi)
    }

    public var modelMatrix: simd_float4x4 {
        if let mirroredTransform { return mirroredTransform }
        let t = simd_float4x4(translation: location)
        let r = simd_float4x4(eulerXYZ: rotation)
        let s = simd_float4x4(scale: scale)
        return t * r * s
    }
}

/// The scene, and the single source of truth both tabs act on.
@Observable
public final class BKScene {
    public var objects: [BKObject] = []
    /// Blender distinguishes the selection from the *active* object (the last
    /// one selected, whose properties the editors show).
    public var selection: Set<UUID> = []
    /// What the Apple Pencil is hovering over — highlighted but not selected.
    public var hoveredID: UUID?

    /// The rectangle a box-select drag is sweeping, in view coordinates.
    /// Nil when no drag is in progress.
    public var selectionBox: CGRect?

    /// The stroke a Circle or Lasso select drag is drawing, in view
    /// coordinates — the same region the selection is then made from
    /// (`RegionSelect`), so what is drawn is what is selected. Nil when no
    /// such drag is in progress.
    public var selectionStroke: SelectionRegion?

    /// What the viewport drag in progress is doing — the transform a gizmo is
    /// applying, or the camera move, or the brush stroke — phrased the way
    /// Blender phrases it in its header.
    ///
    /// Nil when nothing is being dragged, which is what makes it usable as
    /// "is a drag in progress". Two fields rather than one because a transform
    /// takes precedence: grabbing a gizmo handle also pans nothing, but the
    /// gesture recognisers do not know about each other.
    public var transformReadout: String?

    /// The same, for drags that move the view rather than the model: orbit,
    /// pan, zoom, and brush strokes. Shown only when no transform is running.
    public private(set) var viewportDrag: String?

    /// Which gesture put it there.
    ///
    /// Several recognisers watch the viewport at once, and the ones that lose
    /// still report `.failed` or `.cancelled` — so a one-finger orbit fires the
    /// pinch recogniser's end branch as well. A handler that cleared the text
    /// unconditionally would wipe out the readout of the drag that actually
    /// won, which looks exactly like the readout never appearing.
    public private(set) var viewportDragOwner: ViewportDragKind?

    public enum ViewportDragKind: Sendable {
        case orbit, pan, zoom, brush
    }

    /// Claim the readout for one gesture. A gesture may always take it over
    /// from another — the last one to actually move something is the live one.
    public func beginViewportDrag(_ kind: ViewportDragKind, _ text: String) {
        viewportDragOwner = kind
        viewportDrag = text
    }

    /// Release it, but only if this gesture is the one holding it.
    public func endViewportDrag(_ kind: ViewportDragKind) {
        guard viewportDragOwner == kind else { return }
        viewportDragOwner = nil
        viewportDrag = nil
    }

    /// Drop it whoever holds it — for when a gizmo takes the gesture over and
    /// the camera readout underneath is no longer the truth.
    public func clearViewportDrag() {
        viewportDragOwner = nil
        viewportDrag = nil
    }

    /// What to put on screen for the drag in progress, if anything. A
    /// transform wins: grabbing a gizmo handle is the more specific answer.
    public var dragReadout: String? { transformReadout ?? viewportDrag }

    /// Blender's 3D cursor: the reference point new objects spawn at and that
    /// the Snap menu works against. Starts at the world origin, as Blender's
    /// does.
    ///
    /// Mirrored from `bpy.context.scene.cursor.location` on every pass, so the
    /// N-panel's fields show where Blender's cursor is rather than where this
    /// interface last put one (TransformTools.swift).
    public var cursor: SIMD3<Float> = .zero

    /// Snapping, the pivot point and proportional editing, as Blender holds
    /// them on `scene.tool_settings`. Written through `_blenderkit_tools` and
    /// mirrored back, never set here.
    public var tools = TransformToolSettings()

    /// Copy Objects / Paste Objects, held for the session.
    public var clipboard: [ObjectState] = []

    // Blender's frame range. Nothing is animated yet, so scrubbing changes no
    // geometry — which is also what Blender does with no keyframes. The frame
    // itself is real state, and playback really advances it.
    /// Blender's interaction mode. Edit mode acts on the active object's mesh.
    public var mode: InteractionMode = .object
    /// Vertex / edge / face, the three buttons in Blender's edit-mode header.
    public var selectMode: MeshSelectMode = .vertex
    /// Sculpt-mode brush settings for the simulator's Swift brushes.
    public var sculpt = SculptSettings()
    /// Blender's sculpt settings — the brush, its Size and Strength, Dynamic
    /// Topology, the voxel size, Multires, the mask — read back from Blender
    /// whenever the history moves in Sculpt Mode (`SculptHeader`). Nil outside
    /// Blender's Sculpt Mode and on the simulator's stand-in.
    public var sculptBlender: SculptState?
    /// Texture-paint brush settings.
    public var paint = PaintSettings()
    /// The most recent render, shown in the Image Editor.
    @ObservationIgnored public var renderResult: TextureImage?
    public var renderVersion: Int = 0
    /// The scene's compositor graph, run over the render result.
    public var compositor = CompositorGraph()
    /// What is selected inside the active object while editing.
    public var editSelection = EditSelection()

    /// True when `editSelection` was changed here — a tap, a box — and Blender
    /// has not been told. The bridge hands it over before the next command,
    /// and the mirror clears it when Blender reports its own.
    @ObservationIgnored public var editSelectionPending = false

    /// Blender only edits one object at a time, and leaving edit mode commits.
    public func setMode(_ next: InteractionMode) {
        guard next != mode else { return }
        if next == .edit && active == nil { return }
        editSelection.clear()
        editSelectionPending = false
        mode = next
    }

    public var frameCurrent: Int = 1 {
        didSet { if frameCurrent != oldValue { evaluateAnimation() } }
    }
    public var frameStart: Int = 1
    public var frameEnd: Int = 250
    /// Blender's frame rate, preview range and keying settings, and the keys
    /// on the scene itself. See AnimationTimeline.swift.
    public var animation = SceneAnimation()
    public var activeID: UUID?

    public var active: BKObject? {
        guard let activeID else { return nil }
        return objects.first { $0.id == activeID }
    }

    public init(startupFile: Bool = true) {
        if startupFile {
            // Blender's startup .blend: a cube at the origin, selected+active.
            let cube = BKObject(name: "Cube", kind: .cube)
            objects = [cube]
            selection = [cube.id]
            activeID = cube.id
        }
    }

    /// Renames an object, applying Blender's collision rule, and returns the
    /// name it actually took — which may carry a `.001` suffix.
    @discardableResult
    public func rename(_ obj: BKObject, to wanted: String) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != obj.name else { return obj.name }
        // Exclude the object itself, or renaming A to A would yield "A.001".
        let taken = Set(objects.filter { $0.id != obj.id }.map(\.name))
        var candidate = trimmed
        var n = 1
        while taken.contains(candidate) {
            candidate = String(format: "%@.%03d", trimmed, n)
            n += 1
        }
        obj.name = candidate
        return candidate
    }

    /// A name that does not collide, using Blender's `.001` suffix convention.
    public func uniqueName(_ base: String) -> String {
        let taken = Set(objects.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 1
        while taken.contains(String(format: "%@.%03d", base, n)) { n += 1 }
        return String(format: "%@.%03d", base, n)
    }

    @discardableResult
    public func add(_ kind: PrimitiveKind, at location: SIMD3<Float> = .zero) -> BKObject {
        let obj = BKObject(name: uniqueName(kind.defaultName), kind: kind, location: location)
        objects.append(obj)
        select(only: obj.id)
        return obj
    }

    public func select(only id: UUID) {
        selection = [id]
        activeID = id
    }

    public func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
            if activeID == id { activeID = selection.first }
        } else {
            selection.insert(id)
            activeID = id
        }
    }

    public func deselectAll() {
        selection.removeAll()
        activeID = nil
    }

    /// `bpy.ops.object.delete()` — removes the whole selection, not just the
    /// active object.
    public func deleteSelection() {
        objects.removeAll { selection.contains($0.id) }
        selection.removeAll()
        activeID = nil
    }

    /// `bpy.ops.object.location_clear()` and friends.
    public func clearTransform(location: Bool = false, rotation: Bool = false, scale: Bool = false) {
        for obj in objects where selection.contains(obj.id) {
            if location { obj.location = .zero }
            if rotation { obj.rotation = .zero }
            if scale    { obj.scale = .one }
        }
    }

    public func invertSelection() {
        let inverted = Set(objects.map(\.id)).subtracting(selection)
        selection = inverted
        activeID = inverted.first
    }

    /// `bpy.ops.object.duplicate_move()`.
    @discardableResult
    public func duplicateSelection() -> [BKObject] {
        let sources = objects.filter { selection.contains($0.id) }
        var made: [BKObject] = []
        for src in sources {
            let copy = BKObject(name: uniqueName(src.name),
                                kind: src.kind,
                                location: src.location,
                                rotation: src.rotation,
                                scale: src.scale)
            // A duplicate has to carry the geometry, not just the primitive
            // kind: anything edited, joined, or applied would otherwise come
            // back as a default cube — silently, since the object still knows
            // which primitive it started as.
            copy.modifiers = src.modifiers
            // Only install geometry when the source's mesh no longer comes
            // from its primitive; a plain cube's duplicate should stay a cube
            // the builder can regenerate.
            if src.meshIsEvaluated {
                // Blender's evaluated mesh, stack and all: running the stack
                // over it again drew a Screwed cube's duplicate at 9,216
                // vertices where Blender has 384 (tests/mirror).
                copy.setEvaluatedMesh(src.evaluatedBase)
            } else if src.isMirrored {
                copy.setMirroredMesh(src.evaluatedBase)
            }
            copy.color = src.color
            copy.material = src.material
            copy.shaderGraph = src.shaderGraph
            copy.visible = src.visible
            copy.hiddenInViewLayer = src.hiddenInViewLayer
            copy.disabledInViewports = src.disabledInViewports
            copy.hideRender = src.hideRender
            copy.symmetry = src.symmetry
            copy.copyDisplay(from: src, in: self)
            objects.append(copy)
            made.append(copy)
        }
        if let last = made.last {
            selection = Set(made.map(\.id))
            activeID = last.id
        }
        return made
    }
}

// MARK: - Edit-mode selection, as Blender reports it

/// How an object's viewport mesh lines up with Blender's mesh while editing.
///
/// The mirror hands the viewport Blender's evaluated mesh, and unless a
/// modifier changes its topology the vertex indices *are* Blender's — so a
/// vertex or an edge can be named to Blender by index. A face cannot: the
/// viewport draws triangles and Blender edits polygons, so each triangle
/// carries the polygon it came from.
public struct EditTopology: Sendable, Equatable {
    public var vertexCount: Int
    public var polygonCount: Int
    /// For each viewport triangle, the Blender polygon it belongs to.
    public var trianglePolygons: [UInt32]
    /// Which of the viewport's edges are Blender's edges.
    ///
    /// The viewport's edge list is built from triangles, so a quad contributes
    /// a diagonal Blender has no edge for. Blender draws no line there and
    /// cannot select one, so edit mode draws and picks only these. Empty means
    /// nobody has said — a mesh mirrored without a report — and then every edge
    /// is drawn, as it was before Blender was asked.
    public var realEdges: Set<Int>
    /// Vertices Blender has hidden (`mesh.hide`). They keep their index, and
    /// edit mode gives them no dot, no tap and no place in a box. Their faces
    /// never reach the viewport while editing, and neither does an edge that
    /// only hidden faces use.
    public var hiddenVertices: Set<Int>
    /// Blender's edges, two vertex indices each, in Blender's own order —
    /// loose edges and the edges of hidden faces included, which the viewport
    /// list (`realEdges`) cannot hold. Topology Mirror pairs vertices by them,
    /// and its pass count depends on their order
    /// (`SymmetricEdit.topologyTable`). Empty when nobody has said.
    public var blenderEdges: [UInt32]
    /// Blender's own coordinates for each vertex — the edit mesh's — when
    /// they are not the ones the viewport drew: a modifier shown in edit mode
    /// that keeps the vertex count (a SimpleDeform, a Shrinkwrap) moves what
    /// is drawn and leaves the numbering alone. Empty when the drawn vertices
    /// are Blender's, which is every mesh without such a modifier.
    ///
    /// X / Y / Z mirror editing pairs vertices on these, as Blender does
    /// (`SymmetricEdit`): measured in 5.2.1 on a grid with a SimpleDeform
    /// Twist, pairing on the drawn positions found no mirror image for a
    /// vertex Blender then moved together with its image.
    public var blenderPositions: [SIMD3<Float>]

    public init(vertexCount: Int, polygonCount: Int, trianglePolygons: [UInt32],
                realEdges: Set<Int> = [], hiddenVertices: Set<Int> = [],
                blenderEdges: [UInt32] = [], blenderPositions: [SIMD3<Float>] = []) {
        self.vertexCount = vertexCount
        self.polygonCount = polygonCount
        self.trianglePolygons = trianglePolygons
        self.realEdges = realEdges
        self.hiddenVertices = hiddenVertices
        self.blenderEdges = blenderEdges
        self.blenderPositions = blenderPositions
    }

    /// Whether this still describes that mesh.
    ///
    /// Everything here is an index into the mesh the mirror read it from, so
    /// against a mesh that has changed since, every one of them names something
    /// else. A subdivide between a mirror pass and the next draw would
    /// otherwise put orange on edges nobody selected.
    public func describes(_ mesh: MeshData) -> Bool {
        vertexCount == mesh.vertices.count && trianglePolygons.count * 3 == mesh.indices.count
    }
}

public extension BKObject {
    /// The vertices Blender has hidden in the mesh being edited, when the
    /// mirror's report still describes the mesh on screen; none otherwise.
    var hiddenEditVertices: Set<Int> {
        guard let topology = editTopology, topology.describes(mesh) else { return [] }
        return topology.hiddenVertices
    }
}

/// Blender's edit-mode selection, as `_blenderkit_sync` reads it out of the
/// mesh: one flag per element, in Blender's own order.
public struct BlenderEditReport: Sendable {
    /// `tool_settings.mesh_select_mode` as bits: 1 vertex, 2 edge, 4 face.
    public var selectMode: Int32
    public var vertexSelected: [UInt8]
    public var trianglePolygons: [UInt32]
    public var polygonSelected: [UInt8]
    /// Two vertex indices per Blender edge.
    public var edgeVertices: [UInt32]
    public var edgeSelected: [UInt8]
    /// One flag per vertex, or empty when Blender has none hidden.
    public var vertexHidden: [UInt8]
    /// Three floats per vertex, the edit mesh's own coordinates, or empty:
    /// sent only when a modifier shown in edit mode may have moved what the
    /// viewport drew (`_blenderkit_sync._edit_coordinates`).
    public var vertexCoordinates: [Float]

    public init(selectMode: Int32, vertexSelected: [UInt8], trianglePolygons: [UInt32],
                polygonSelected: [UInt8], edgeVertices: [UInt32], edgeSelected: [UInt8],
                vertexHidden: [UInt8] = [], vertexCoordinates: [Float] = []) {
        self.selectMode = selectMode
        self.vertexSelected = vertexSelected
        self.trianglePolygons = trianglePolygons
        self.polygonSelected = polygonSelected
        self.edgeVertices = edgeVertices
        self.edgeSelected = edgeSelected
        self.vertexHidden = vertexHidden
        self.vertexCoordinates = vertexCoordinates
    }
}

public extension EditSelection {
    /// Whether two selections hold the same elements.
    func matches(_ other: EditSelection) -> Bool {
        vertices == other.vertices && edges == other.edges && faces == other.faces
    }

    /// Blender's selection in the viewport's terms, or nil when the viewport's
    /// mesh is not Blender's mesh index for index.
    ///
    /// Faces come back as every triangle of a selected polygon, and edges by
    /// their two ends — the viewport's edge list is built from triangles and
    /// has diagonals Blender does not, so its numbering is its own.
    static func mirrored(_ report: BlenderEditReport,
                         display mesh: MeshData) -> (selection: EditSelection,
                                                     topology: EditTopology)? {
        let vertexCount = mesh.vertices.count
        let triangleCount = mesh.indices.count / 3
        guard vertexCount > 0,
              report.vertexSelected.count == vertexCount,
              report.trianglePolygons.count == triangleCount,
              report.edgeVertices.count == report.edgeSelected.count * 2,
              report.vertexHidden.isEmpty || report.vertexHidden.count == vertexCount,
              report.vertexCoordinates.isEmpty || report.vertexCoordinates.count == 3 * vertexCount
        else { return nil }

        var selection = EditSelection()
        for (i, flag) in report.vertexSelected.enumerated() where flag != 0 {
            selection.vertices.insert(i)
        }
        for (t, polygon) in report.trianglePolygons.enumerated() {
            let p = Int(polygon)
            if p < report.polygonSelected.count, report.polygonSelected[p] != 0 {
                selection.faces.insert(t)
            }
        }
        var byEnds: [UInt64: Int] = [:]
        byEnds.reserveCapacity(mesh.edges.count / 2)
        for e in 0..<(mesh.edges.count / 2) {
            byEnds[edgeKey(mesh.edges[2 * e], mesh.edges[2 * e + 1])] = e
        }
        // Which viewport edges Blender actually has, so the wireframe stops
        // drawing the diagonals triangulation left behind and a tap cannot
        // pick one.
        var realEdges: Set<Int> = []
        for e in 0..<report.edgeSelected.count {
            let key = edgeKey(report.edgeVertices[2 * e], report.edgeVertices[2 * e + 1])
            guard let shown = byEnds[key] else { continue }
            realEdges.insert(shown)
            if report.edgeSelected[e] != 0 { selection.edges.insert(shown) }
        }
        var hidden: Set<Int> = []
        for (i, flag) in report.vertexHidden.enumerated() where flag != 0 { hidden.insert(i) }
        let topology = EditTopology(vertexCount: vertexCount,
                                    polygonCount: report.polygonSelected.count,
                                    trianglePolygons: report.trianglePolygons,
                                    realEdges: realEdges, hiddenVertices: hidden,
                                    blenderEdges: report.edgeVertices,
                                    blenderPositions: blenderPositions(report.vertexCoordinates, drawn: mesh))
        return (selection, topology)
    }

    /// The report's coordinates, or none when they are the drawn ones — a
    /// modifier on in edit mode that moved nothing — so a plain mesh's drag
    /// goes on taking exactly the path it took before they were sent.
    private static func blenderPositions(_ flat: [Float], drawn mesh: MeshData) -> [SIMD3<Float>] {
        guard !flat.isEmpty, flat.count == 3 * mesh.vertices.count else { return [] }
        var differs = false
        let positions = mesh.vertices.indices.map { i -> SIMD3<Float> in
            let p = SIMD3(flat[3 * i], flat[3 * i + 1], flat[3 * i + 2])
            if !differs, p != mesh.vertices[i].position { differs = true }
            return p
        }
        return differs ? positions : []
    }

    private static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(min(a, b)) << 32 | UInt64(max(a, b))
    }
}

public extension BKScene {
    /// Installs Blender's edit selection on the object being edited.
    ///
    /// Returns false when the viewport's mesh does not line up with Blender's —
    /// a modifier changed its topology — in which case nothing on screen could
    /// honestly be shown selected, and nothing is.
    @discardableResult
    func mirrorEditSelection(_ report: BlenderEditReport, on object: BKObject) -> Bool {
        if let mode = MeshSelectMode(blenderBits: report.selectMode), mode != selectMode {
            selectMode = mode
        }
        editSelectionPending = false
        guard let mirrored = EditSelection.mirrored(report, display: object.mesh) else {
            object.editTopology = nil
            if !editSelection.isEmpty { editSelection.clear() }
            return false
        }
        object.editTopology = mirrored.topology
        if !editSelection.matches(mirrored.selection) { editSelection = mirrored.selection }
        return true
    }
}

public extension BKObject {
    /// The mesh elements a dragged rectangle covers, for box select in edit
    /// mode, with X-Ray's rules: everything inside counts, front or back.
    ///
    /// In vertex mode a vertex counts when it is inside; in edge mode an edge
    /// counts when both ends are — or, when none is wholly inside, one that
    /// crosses the rectangle, Blender's second pass; in face mode a face counts
    /// when its centre is, which is what Blender tests against the face dot.
    /// What that implies comes too — the corners of a face, the edges between
    /// selected vertices — so the viewport shows what Blender will once it is
    /// told.
    ///
    /// The viewport's own box select is `RegionSelect`, which this now is too,
    /// and which also leaves out what the surface hides when X-Ray is off.
    /// Edges the triangulation invented are left out, and a face is taken by
    /// its polygon's centre rather than by each triangle's — otherwise a box
    /// could take half a quad, and the viewport would light half a face.
    func editElements(in rect: CGRect, mode: MeshSelectMode,
                      viewProjection: simd_float4x4, size: CGSize) -> EditSelection {
        // The cage the edit selection numbers (`editCage`): the mesh on device,
        // the base under the Swift stack in the simulator.
        let own = RegionSelect.elements(mesh: editCage, topology: editTopology, model: modelMatrix,
                                        viewProjection: viewProjection, size: size,
                                        region: .box(rect), mode: mode, seeThrough: true)
        return EditSelection.implied(by: own, mode: mode, mesh: editCage, topology: editTopology)
    }
}

public extension MeshData {
    /// Whether a mirroring pass is handing over exactly this geometry again.
    ///
    /// Every pass used to rebuild every object's mesh — edges hashed, the
    /// modifier stack re-applied, the GPU buffers re-uploaded — even when
    /// nothing about it had changed, which after a tap or a single bevel is
    /// every object but one.
    func matches(positions: UnsafeBufferPointer<Float>,
                 normals: UnsafeBufferPointer<Float>,
                 triangles: UnsafeBufferPointer<UInt32>) -> Bool {
        guard positions.count == vertices.count * 3,
              normals.count == positions.count,
              triangles.count == indices.count
        else { return false }
        for (i, v) in vertices.enumerated() {
            let b = i * 3
            if v.position.x != positions[b] || v.position.y != positions[b + 1]
                || v.position.z != positions[b + 2]
                || v.normal.x != normals[b] || v.normal.y != normals[b + 1]
                || v.normal.z != normals[b + 2] {
                return false
            }
        }
        return indices.elementsEqual(triangles)
    }
}
