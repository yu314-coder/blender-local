import Foundation
import simd

/// The modifiers Blender Local implements. Blender ships dozens; these are the
/// ones that carry most day-to-day modelling, and each is a real mesh
/// operation rather than a display trick — `obj.mesh` genuinely changes, so the
/// viewport, the vertex counts and ray-picking all agree.
///
/// Every other modifier Blender has is `.other`, and still has a row: the
/// panel lists the whole stack Blender holds, in Blender's order.
public enum ModifierKind: String, Codable, CaseIterable, Sendable {
    // Blender ships 83 modifiers. These are the ones that are real mesh
    // operations on a triangulated mesh without a half-edge structure, a
    // particle system or a node graph behind them.
    case subdivision, array, mirror
    case solidify, smooth, cast, simpleDeform, displace, weld, wave, triangulate
    // The two every hard-surface course reaches for and neither of which was
    // here: Bevel puts the edge highlight on a whole object without going
    // into edit mode, and Boolean is how one shape is cut out of another.
    case bevel, boolean
    // Shrinkwrap drapes one surface onto another, Screw is how a thread or a
    // spiral is made, Decimate is the retopology workhorse and Remesh rebuilds
    // a surface at a uniform density.
    case shrinkwrap, screw, decimate, remesh
    // A Geometry Nodes modifier, which this app cannot build a graph for but
    // must not hide: Shade Auto Smooth adds one ("Smooth by Angle"), and a
    // stack that drops it shows "No modifiers" over a mesh a modifier is
    // changing. Never offered by Add Modifier (`addable`): an empty one does
    // nothing.
    case geometryNodes
    // The rest of what a hard-surface or sculpting workflow reaches for.
    // Weighted Normal fixes the shading of a bevelled hard-surface mesh;
    // Multires is how a sculpt gets its detail levels; Edge Split, Laplacian
    // Smooth and Corrective Smooth are the other shading and smoothing tools;
    // Lattice deforms a mesh by a cage. Each was measured "No modifiers" in
    // the panel over a mesh it was changing, because the mirror dropped
    // every kind not listed here.
    //
    // Lattice's row picks only lattice objects: Blender silently ignores a
    // mesh assigned to `LatticeModifier.object` (measured in 5.2.1: the
    // assignment does not raise and leaves `object` None), so a mesh in the
    // list would accept a pick and then do nothing.
    case weightedNormal, multires, edgeSplit, laplacianSmooth, correctiveSmooth, lattice
    // Any modifier Blender has that the app has no settings rows for —
    // Armature, Hook, Curve, Surface Deform, Wireframe, the physics ones.
    // The modifier's own type travels in `Modifier.blenderType`. Its row
    // names that type and carries the controls every modifier has: show in
    // viewport and render, move up and down, Apply and remove. Never
    // offered by Add Modifier.
    case other

    /// What Add Modifier lists: every kind the app has settings rows for.
    public static var addable: [ModifierKind] {
        allCases.filter { $0 != .geometryNodes && $0 != .other }
    }

    /// The kinds Blender's `modifier_add` refuses on a curve, a text or a
    /// surface object, with a TypeError listing its whole enum. Measured in
    /// 5.2.1 by adding every `addable` kind to a Bézier curve, a text and a
    /// NURBS sphere: these six were refused on all three, everything else
    /// was taken.
    public static let meshOnly: Set<ModifierKind> = [
        .displace, .boolean, .weightedNormal, .multires, .laplacianSmooth, .correctiveSmooth,
    ]

    /// What Add Modifier lists on an object of Blender type `blenderType`:
    /// `addable`, less `meshOnly` on a curve, text or surface.
    public static func addable(on blenderType: String) -> [ModifierKind] {
        guard ["CURVE", "FONT", "SURFACE"].contains(blenderType) else { return addable }
        return addable.filter { !meshOnly.contains($0) }
    }

    /// Blender's `ModifierTypeType::OnlyDeform`: moves vertices and makes no
    /// geometry. Read from each kind's MOD_*.cc in 5.2.1's source; every
    /// other kind here is Constructive or Nonconstructive. An `.other` kind is
    /// taken as not a pure deform: the simulator never has one.
    public var onlyDeforms: Bool {
        switch self {
        case .smooth, .cast, .simpleDeform, .displace, .wave, .shrinkwrap,
             .laplacianSmooth, .correctiveSmooth, .lattice:
            return true
        default:
            return false
        }
    }

    /// Blender's `eModifierTypeFlag_RequiresOriginalData`, which only
    /// Multires and Soft Body carry in 5.2.1's source; Soft Body is not a kind
    /// here. It is what Blender's add and move rules turn on
    /// (`ModifierStack.insertionIndex`, `ModifierStack.canMove`).
    public var requiresOriginalData: Bool { self == .multires }

    /// The kind whose `bpyType` is `type`, or nil for one this app has no
    /// rows for.
    public static func modelled(_ type: String) -> ModifierKind? {
        allCases.first { $0 != .other && $0.bpyType == type }
    }

    /// The name Blender gives a newly added modifier of this kind.
    ///
    /// These are the names `modifier_add` actually assigns, not the labels in
    /// the Add Modifier menu — the two differ for Subdivision, and a script
    /// written against Blender does `modifiers["Subdivision"]`. Measured in
    /// 5.2.1: Simple Deform is "SimpleDeform", Weighted Normal
    /// "WeightedNormal", Multiresolution "Multires", and so on (see `label`).
    public var displayName: String {
        switch self {
        case .subdivision:  return "Subdivision"
        case .array:        return "Array"
        case .mirror:       return "Mirror"
        case .solidify:     return "Solidify"
        case .smooth:       return "Smooth"
        case .cast:         return "Cast"
        case .simpleDeform: return "SimpleDeform"
        case .displace:     return "Displace"
        case .weld:         return "Weld"
        case .wave:         return "Wave"
        case .triangulate:  return "Triangulate"
        case .bevel:        return "Bevel"
        case .boolean:      return "Boolean"
        case .shrinkwrap:   return "Shrinkwrap"
        case .screw:        return "Screw"
        case .decimate:     return "Decimate"
        case .remesh:       return "Remesh"
        case .geometryNodes: return "GeometryNodes"
        case .weightedNormal:   return "WeightedNormal"
        case .multires:         return "Multires"
        case .edgeSplit:        return "EdgeSplit"
        case .laplacianSmooth:  return "LaplacianSmooth"
        case .correctiveSmooth: return "CorrectiveSmooth"
        case .lattice:          return "Lattice"
        case .other:            return "Modifier"
        }
    }

    /// What Blender's Add Modifier menu calls this kind: the name of its
    /// `Modifier.type` enum item (read from 5.2.1's RNA). The rows show
    /// `Modifier.name`, which is Blender's own and may be anything.
    public var label: String {
        switch self {
        case .subdivision:      return "Subdivision Surface"
        case .simpleDeform:     return "Simple Deform"
        case .geometryNodes:    return "Geometry Nodes"
        case .weightedNormal:   return "Weighted Normal"
        case .multires:         return "Multiresolution"
        case .edgeSplit:        return "Edge Split"
        case .laplacianSmooth:  return "Smooth Laplacian"
        case .correctiveSmooth: return "Smooth Corrective"
        default:                return displayName
        }
    }

    /// The string Blender's `modifier_add(type=…)` expects.
    public var bpyType: String {
        switch self {
        case .subdivision:  return "SUBSURF"
        case .array:        return "ARRAY"
        case .mirror:       return "MIRROR"
        case .solidify:     return "SOLIDIFY"
        case .smooth:       return "SMOOTH"
        case .cast:         return "CAST"
        case .simpleDeform: return "SIMPLE_DEFORM"
        case .displace:     return "DISPLACE"
        case .weld:         return "WELD"
        case .wave:         return "WAVE"
        case .triangulate:  return "TRIANGULATE"
        case .bevel:        return "BEVEL"
        case .boolean:      return "BOOLEAN"
        case .shrinkwrap:   return "SHRINKWRAP"
        case .screw:        return "SCREW"
        case .decimate:     return "DECIMATE"
        case .remesh:       return "REMESH"
        case .geometryNodes: return "NODES"
        case .weightedNormal:   return "WEIGHTED_NORMAL"
        case .multires:         return "MULTIRES"
        case .edgeSplit:        return "EDGE_SPLIT"
        case .laplacianSmooth:  return "LAPLACIANSMOOTH"
        case .correctiveSmooth: return "CORRECTIVE_SMOOTH"
        case .lattice:          return "LATTICE"
        // Never sent: an `.other` modifier's type is its own
        // (`Modifier.blenderType`), and Add Modifier does not offer one.
        case .other:            return ""
        }
    }

    public var icon: String {
        switch self {
        case .subdivision:  return "circle.grid.3x3"
        case .array:        return "square.grid.3x1.below.line.grid.1x2"
        case .mirror:       return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .solidify:     return "square.stack.3d.down.right"
        case .smooth:       return "drop"
        case .cast:         return "circle.dashed.inset.filled"
        case .simpleDeform: return "tornado"
        case .displace:     return "waveform.path"
        case .weld:         return "point.topleft.down.to.point.bottomright.curvepath"
        case .wave:         return "wave.3.right"
        case .triangulate:  return "triangle"
        case .bevel:        return "square.on.circle"
        case .boolean:      return "circle.lefthalf.filled"
        case .shrinkwrap:   return "shippingbox.and.arrow.backward"
        // "tornado" is Simple Deform's, so Screw takes the turning arrow.
        case .screw:        return "arrow.triangle.turn.up.right.circle"
        case .decimate:     return "arrow.down.right.and.arrow.up.left"
        case .remesh:       return "cube.transparent"
        case .geometryNodes: return "circle.hexagongrid"
        case .weightedNormal:   return "arrow.up.to.line"
        case .multires:         return "square.grid.4x3.fill"
        case .edgeSplit:        return "scissors"
        case .laplacianSmooth:  return "drop.halffull"
        case .correctiveSmooth: return "wand.and.stars"
        case .lattice:          return "grid"
        case .other:            return "puzzlepiece.extension"
        }
    }
}

/// One entry in an object's modifier stack. A single struct carries the
/// settings for every kind, which keeps it `Codable` and keeps the stack a
/// plain array — Blender's own modifiers are similarly a tagged union.
public struct Modifier: Codable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ModifierKind
    public var name: String

    /// Subdivision: how many times to subdivide. Blender's default viewport
    /// level is 1; 3 is already 64x the faces, so it is capped there.
    public var levels: Int
    /// Array: number of copies including the original.
    public var count: Int
    /// Array: offset as a fraction of the object's bounding box, matching
    /// Blender's "Relative Offset".
    public var relativeOffset: SIMD3<Float>
    /// Mirror: which axes to mirror across.
    public var mirrorX: Bool
    public var mirrorY: Bool
    public var mirrorZ: Bool
    /// Mirror's Bisect, per axis (`use_bisect_axis`): cut the mesh at the
    /// mirror plane and drop what lies across it before mirroring. Measured on
    /// a cube spanning x = -0.5…1.5: 16 vertices mirrored whole, 12 bisected,
    /// spanning ±1.5. An axis that is not mirrored cuts nothing (bisect Y
    /// with only X mirrored left all 16).
    public var bisectX: Bool
    public var bisectY: Bool
    public var bisectZ: Bool
    /// Mirror's Flip, per axis (`use_bisect_flip_axis`): keep the other side
    /// of the cut. The same cube flipped kept x = -0.5…0 and spanned ±0.5.
    public var bisectFlipX: Bool
    public var bisectFlipY: Bool
    public var bisectFlipZ: Bool
    /// Mirror's Clipping (`use_clip`): an edit-mode transform may not carry a
    /// vertex across the mirror plane, and one on the plane stays on it.
    /// It changes what a drag commits, so the drag's preview applies it too
    /// (`MirrorClip`).
    public var mirrorClip: Bool
    /// Mirror's Merge (`use_mirror_merge`) and its distance
    /// (`merge_threshold`): a vertex welds to its own mirror image when the
    /// two are that close — measured, a cube face 0.01 from the plane merged
    /// at 0.021 and not at 0.019, the gap between the two being 0.02. The
    /// distance is also Clipping's tolerance, whether Merge is on or not.
    public var mirrorMerge: Bool
    public var mergeThreshold: Float
    /// Blender's `show_viewport`. Only Mirror's record carries it, and only
    /// Clipping reads it: Blender clips for a Mirror enabled in the viewport
    /// and not for one that is off (measured), whatever the edit-mode toggle.
    public var showInViewport: Bool

    /// Solidify thickness, Displace strength, Wave height.
    public var thickness: Float
    /// Smooth factor, Cast factor — how far toward the target shape.
    public var factor: Float
    /// Smooth repeats, and Simple Deform's angle in radians.
    public var iterations: Int
    public var angle: Float
    /// Simple Deform's and Screw's axis: 0=X, 1=Y, 2=Z.
    public var axis: Int
    /// Wave's Motion X and Y, Blender's `use_x` and `use_y`: which way the
    /// ripple travels. Both on is Blender's default and a ring; one alone is
    /// a line of crests along that axis; neither lifts every vertex by the same
    /// amount (measured on a grid in 5.2.1). Wave always displaces along Z —
    /// it has no axis to pick, which is what the row used to offer: its "Z"
    /// sent both off, and a new Wave on device showed Z while Blender held a
    /// ring.
    public var waveX: Bool
    public var waveY: Bool
    /// Simple Deform mode, matching Blender's enum.
    public var deformMode: DeformMode
    /// Bevel: how many segments across the rounded edge. 1 is a chamfer.
    public var segments: Int
    /// Boolean: which of Blender's three operations, and the other object.
    /// A Boolean with no object set does nothing, which is what Blender does
    /// too — the row says so rather than looking finished.
    public var booleanOperation: BooleanOperation
    /// Boolean's `object` and Shrinkwrap's `target`. One struct carries one
    /// kind at a time, and the two never share a record key — Blender spells
    /// them differently, which is exactly the trap this field hides.
    public var targetName: String

    /// Blender's `isDisabled` for the kinds here that point at another
    /// object: a Boolean, Shrinkwrap or Lattice with nothing picked does
    /// nothing, and Apply on one is refused with "Modifier is disabled,
    /// skipping apply" (measured in 5.2.1 for the Lattice; verify.py).
    public var isDisabled: Bool {
        [.boolean, .shrinkwrap, .lattice].contains(kind) && targetName.isEmpty
    }

    /// Decimate's collapse ratio. 1 keeps every face.
    public var ratio: Float
    /// Decimate's `decimate_type` as Blender reports it. The panel only
    /// drives COLLAPSE, where `ratio` means something; this is kept so a
    /// script that left it on UNSUBDIV or DISSOLVE shows up as that, rather
    /// than behind a Ratio field that is silently inert.
    public var decimateType: String
    /// Decimate's `face_count`: what Blender's collapse actually produced.
    /// Read-only in RNA and never written back — it is the only way the row
    /// can be honest on a low-poly mesh, where ratio 0.5 on a default cube
    /// measurably leaves all six faces in place.
    public var faceCount: Int
    /// Remesh: the VOXEL mode's cell size, and the octree depth the other
    /// three modes use.
    public var voxelSize: Float
    public var octreeDepth: Int
    /// Remesh: the largest dimension of the mesh it remeshes — its input, not
    /// what it makes of it — or 0 when that is not known. The Voxel Size row's
    /// floor is taken from it (`ModifierStack.remeshVoxelFloor(for:on:)`).
    /// Read-only, like `faceCount`: `input_size` in the mirror's record, and
    /// in the simulator what the stack above the Remesh produced.
    public var inputSize: Float
    /// Shrinkwrap: how a vertex finds the target surface.
    public var wrapMethod: WrapMethod
    /// Remesh: which of Blender's four algorithms.
    public var remeshMode: RemeshMode
    /// Geometry Nodes: the node group's name, empty for none.
    public var nodeGroup: String
    /// Geometry Nodes: whether the mirror read the two inputs of Blender's
    /// Smooth by Angle — its Angle, carried in `angle`, and this — so the row
    /// can offer them. False for any other group, whose inputs the row does
    /// not know, and then it shows no number rather than a made-up one.
    public var smoothByAngle: Bool
    public var ignoreSharpness: Bool

    /// Blender's identifier for the modifier's type and the name its menus
    /// give it: `kind.bpyType` and `kind.label` for a kind the app models,
    /// and for `.other` whatever the mirror said — SURFACE_DEFORM, "Surface
    /// Deform". What an `.other` row names itself by.
    public var blenderType: String
    public var typeLabel: String
    /// Blender's `show_render`, beside `showInViewport`. Every row has both
    /// switches, whatever its kind.
    public var showInRender: Bool

    /// Weighted Normal: `mode`, `weight` (1…100), `thresh`, `keep_sharp` and
    /// `use_face_influence`.
    public var weightMode: WeightMode
    public var weight: Int
    public var threshold: Float
    public var keepSharp: Bool
    public var faceInfluence: Bool

    /// Multires: its viewport level is `levels`, beside these two. All three
    /// are clamped by Blender to `total_levels` (measured: 5 on a Multires of
    /// 2 reads back 2), which only the Subdivide, Unsubdivide and Delete
    /// Higher operators change — it is read-only in RNA.
    public var sculptLevels: Int
    public var renderLevels: Int
    public var totalLevels: Int

    /// Edge Split: `use_edge_angle` and `use_edge_sharp`. Its `split_angle`
    /// is carried in `angle`.
    public var edgeSplitAngle: Bool
    public var edgeSplitSharp: Bool

    /// Laplacian Smooth: `lambda_factor`, `lambda_border`, the `use_x/y/z`
    /// axis flags, `use_volume_preserve` and `use_normalized`. Its repeat is
    /// `iterations`. `use_x` and `use_y` are Wave's Motion names too, which is
    /// why the record is read per kind for them.
    public var lambdaFactor: Float
    public var lambdaBorder: Float
    public var smoothX: Bool
    public var smoothY: Bool
    public var smoothZ: Bool
    public var preserveVolume: Bool
    public var normalized: Bool

    /// Corrective Smooth: `scale`, `smooth_type`, `use_only_smooth` and
    /// `use_pin_boundary`; its Factor and Repeat are `factor` and
    /// `iterations`. `rest_source` and `is_bind` are shown, never sent:
    /// binding is an operator this app does not run, and a Bind rest source
    /// without one leaves the mesh alone with "Bind data required".
    public var smoothScale: Float
    public var smoothType: SmoothType
    public var onlySmooth: Bool
    public var pinBoundary: Bool
    public var restSource: String
    public var isBound: Bool

    /// `vertex_group` and `invert_vertex_group`, for the kinds that take one
    /// (`ModifierKind.takesVertexGroup`): the group that weights the
    /// modifier, "" for none. Blender clears a name that is not one of the
    /// object's groups (measured: 'Nope' read back ''), so the row's picker
    /// offers only those, and shows what came back.
    public var vertexGroup: String
    public var invertVertexGroup: Bool

    public enum WeightMode: String, Codable, CaseIterable, Sendable {
        case faceArea, cornerAngle, faceAreaWithAngle
        public var label: String {
            switch self {
            case .faceArea:          return "Face Area"
            case .cornerAngle:       return "Corner Angle"
            case .faceAreaWithAngle: return "Face Area & Angle"
            }
        }
        public var bpyValue: String {
            switch self {
            case .faceArea:          return "FACE_AREA"
            case .cornerAngle:       return "CORNER_ANGLE"
            case .faceAreaWithAngle: return "FACE_AREA_WITH_ANGLE"
            }
        }
    }

    public enum SmoothType: String, Codable, CaseIterable, Sendable {
        case simple, lengthWeighted
        public var label: String { self == .simple ? "Simple" : "Length Weight" }
        public var bpyValue: String { self == .simple ? "SIMPLE" : "LENGTH_WEIGHTED" }
    }

    public enum BooleanOperation: String, Codable, CaseIterable, Sendable {
        case difference, union, intersect
        public var label: String { rawValue.capitalized }
        public var bpyValue: String { rawValue.uppercased() }
    }

    public enum WrapMethod: String, Codable, CaseIterable, Sendable {
        case nearestSurfacePoint, project, nearestVertex, targetProject
        public var label: String {
            switch self {
            case .nearestSurfacePoint: return "Nearest Surface"
            case .project:             return "Project"
            case .nearestVertex:       return "Nearest Vertex"
            case .targetProject:       return "Target Project"
            }
        }
        /// Spelled out rather than derived from the case name: Blender's
        /// identifier is NEAREST_SURFACEPOINT, one word where the label has two.
        public var bpyValue: String {
            switch self {
            case .nearestSurfacePoint: return "NEAREST_SURFACEPOINT"
            case .project:             return "PROJECT"
            case .nearestVertex:       return "NEAREST_VERTEX"
            case .targetProject:       return "TARGET_PROJECT"
            }
        }
    }

    public enum RemeshMode: String, Codable, CaseIterable, Sendable {
        // Declaration order is Blender's enum order, which the simulator's
        // bridge passes as an index.
        case blocks, smooth, sharp, voxel
        public var label: String { rawValue.capitalized }
        public var bpyValue: String { rawValue.uppercased() }
    }

    public enum DeformMode: String, Codable, CaseIterable, Sendable {
        case twist, bend, taper, stretch
        public var label: String { rawValue.capitalized }
        public var bpyValue: String { rawValue.uppercased() }
    }

    public init(kind: ModifierKind, name: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.name = name ?? kind.displayName
        self.levels = 1
        self.count = 2
        self.relativeOffset = SIMD3(1, 0, 0)
        self.mirrorX = true
        self.mirrorY = false
        self.mirrorZ = false
        // A new Mirror modifier in 5.2.1: no bisect, no flip, no clipping,
        // Merge on at 0.001.
        self.bisectX = false
        self.bisectY = false
        self.bisectZ = false
        self.bisectFlipX = false
        self.bisectFlipY = false
        self.bisectFlipZ = false
        self.mirrorClip = false
        self.mirrorMerge = true
        self.mergeThreshold = 0.001
        self.showInViewport = true
        // Blender's own defaults for each of these.
        self.thickness = 0.1
        self.factor = 0.5
        self.iterations = 1
        self.angle = .pi / 4
        self.axis = 2
        self.waveX = true
        self.waveY = true
        self.deformMode = .twist
        // Blender's own Bevel modifier defaults.
        self.segments = 1
        self.booleanOperation = .difference
        self.targetName = ""
        self.ratio = 1
        self.decimateType = "COLLAPSE"
        self.faceCount = 0
        self.voxelSize = 0.1
        self.octreeDepth = 4
        self.inputSize = 0
        self.wrapMethod = .nearestSurfacePoint
        self.remeshMode = .voxel
        self.nodeGroup = ""
        self.smoothByAngle = false
        self.ignoreSharpness = false
        self.blenderType = kind.bpyType
        self.typeLabel = kind.label
        self.showInRender = true
        // Blender's own defaults for a new modifier of each kind (5.2.1).
        self.weightMode = .faceArea
        self.weight = 50
        self.threshold = 0.01
        self.keepSharp = false
        self.faceInfluence = false
        self.sculptLevels = 0
        self.renderLevels = 0
        self.totalLevels = 0
        self.edgeSplitAngle = true
        self.edgeSplitSharp = true
        self.lambdaFactor = 0.01
        self.lambdaBorder = 0.01
        self.smoothX = true
        self.smoothY = true
        self.smoothZ = true
        self.preserveVolume = true
        self.normalized = true
        self.smoothScale = 1
        self.smoothType = .simple
        self.onlySmooth = false
        self.pinBoundary = false
        self.restSource = "ORCO"
        self.isBound = false
        self.vertexGroup = ""
        self.invertVertexGroup = false

        // The shared defaults above are Subdivision's and Simple Deform's, and
        // a few kinds disagree with them. On device these are never on screen
        // for a setting the mirror carries: a modifier is added in Blender and
        // its row is built from the record that comes back. In the simulator
        // the shim adds `Modifier(kind:)` itself, so these are what its rows
        // show. A freshly added Screw read 45 degrees rather than Blender's
        // full turn until this switch existed.
        switch kind {
        case .screw:
            self.angle = 2 * .pi
            self.count = 16
            self.axis = 2
            self.thickness = 0   // screw_offset: at 0 a Screw is a lathe
        case .shrinkwrap:
            self.thickness = 0   // offset
        case .geometryNodes:
            self.angle = 30 * .pi / 180   // Smooth by Angle's default
        case .multires:
            self.levels = 0               // nothing until Subdivide
        case .edgeSplit:
            self.angle = 30 * .pi / 180   // split_angle
        case .correctiveSmooth:
            self.iterations = 5
        case .lattice:
            self.thickness = 1            // strength
        default:
            break
        }
    }
}

extension Modifier {
    /// File > Save and the autosave write modifiers with the synthesized
    /// encoder, which carries only the fields the writing build knew about.
    /// The synthesized decoder throws `keyNotFound` for any field added since,
    /// and it throws for the whole scene over one missing number: seven fields
    /// were added for Shrinkwrap, Screw, Decimate and Remesh, and without this
    /// any saved file or autosave that had a modifier would stop opening.
    /// Everything past the kind and name falls back to that kind's own default,
    /// the convention `ObjectState`'s optional fields already follow.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(ModifierKind.self, forKey: .kind),
                  name: try c.decode(String.self, forKey: .name))
        func take<T: Decodable>(_ key: CodingKeys, _ field: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: key) { field = v }
        }
        try take(.id, &id)
        try take(.levels, &levels)
        try take(.count, &count)
        try take(.relativeOffset, &relativeOffset)
        try take(.mirrorX, &mirrorX)
        try take(.mirrorY, &mirrorY)
        try take(.mirrorZ, &mirrorZ)
        try take(.bisectX, &bisectX)
        try take(.bisectY, &bisectY)
        try take(.bisectZ, &bisectZ)
        try take(.bisectFlipX, &bisectFlipX)
        try take(.bisectFlipY, &bisectFlipY)
        try take(.bisectFlipZ, &bisectFlipZ)
        try take(.mirrorClip, &mirrorClip)
        try take(.mirrorMerge, &mirrorMerge)
        try take(.mergeThreshold, &mergeThreshold)
        try take(.showInViewport, &showInViewport)
        try take(.thickness, &thickness)
        try take(.factor, &factor)
        try take(.iterations, &iterations)
        try take(.angle, &angle)
        try take(.axis, &axis)
        try take(.waveX, &waveX)
        try take(.waveY, &waveY)
        try take(.deformMode, &deformMode)
        try take(.segments, &segments)
        try take(.booleanOperation, &booleanOperation)
        try take(.targetName, &targetName)
        try take(.ratio, &ratio)
        try take(.decimateType, &decimateType)
        try take(.faceCount, &faceCount)
        try take(.voxelSize, &voxelSize)
        try take(.octreeDepth, &octreeDepth)
        try take(.inputSize, &inputSize)
        try take(.wrapMethod, &wrapMethod)
        try take(.remeshMode, &remeshMode)
        try take(.nodeGroup, &nodeGroup)
        try take(.smoothByAngle, &smoothByAngle)
        try take(.ignoreSharpness, &ignoreSharpness)
        try take(.blenderType, &blenderType)
        try take(.typeLabel, &typeLabel)
        try take(.showInRender, &showInRender)
        try take(.weightMode, &weightMode)
        try take(.weight, &weight)
        try take(.threshold, &threshold)
        try take(.keepSharp, &keepSharp)
        try take(.faceInfluence, &faceInfluence)
        try take(.sculptLevels, &sculptLevels)
        try take(.renderLevels, &renderLevels)
        try take(.totalLevels, &totalLevels)
        try take(.edgeSplitAngle, &edgeSplitAngle)
        try take(.edgeSplitSharp, &edgeSplitSharp)
        try take(.lambdaFactor, &lambdaFactor)
        try take(.lambdaBorder, &lambdaBorder)
        try take(.smoothX, &smoothX)
        try take(.smoothY, &smoothY)
        try take(.smoothZ, &smoothZ)
        try take(.preserveVolume, &preserveVolume)
        try take(.normalized, &normalized)
        try take(.smoothScale, &smoothScale)
        try take(.smoothType, &smoothType)
        try take(.onlySmooth, &onlySmooth)
        try take(.pinBoundary, &pinBoundary)
        try take(.restSource, &restSource)
        try take(.isBound, &isBound)
        try take(.vertexGroup, &vertexGroup)
        try take(.invertVertexGroup, &invertVertexGroup)
    }

    /// Read a stack out of the mirror's record.
    ///
    /// `kind=SUBSURF;name=Subdivision;levels=2|kind=BEVEL;name=Bevel;width=0.02`
    /// — one entry per modifier, Blender's own property names, in Blender's
    /// stack order. Every entry becomes a row. A kind this build has no
    /// settings rows for is `.other`, carrying its type (`blenderType`) and
    /// Blender's name for it (`type_label`).
    ///
    /// Those used to be skipped, on the reasoning that a row that cannot edit
    /// what is under it is worse than none. It was not: measured on a cube
    /// with Multires, Weighted Normal, Edge Split, Laplacian Smooth and
    /// Subdivision, the panel showed the Subdivision alone, and a mesh changed
    /// only by one of the others read "No modifiers" — with no way to turn
    /// the modifier off, apply it or remove it.
    public static func stack(from record: String) -> [Modifier] {
        record.split(separator: "|").compactMap { entry in
            let fields = Modifier.fields(entry)
            guard let raw = fields["kind"], !raw.isEmpty else { return nil }
            // `unread`: the mirror could not read this modifier's settings, so
            // it gets the controls every row has and no settings rows — rows
            // of its kind would show defaults Blender does not hold.
            let kind = fields["unread"] == "1" ? .other : (ModifierKind.modelled(raw) ?? .other)
            var m = Modifier(kind: kind, name: fields["name"] ?? kind.displayName)
            if kind == .other {
                m.blenderType = raw
                m.typeLabel = fields["type_label"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? Modifier.label(forType: raw)
            }
            m.read(fields)
            return m
        }
    }

    /// Takes every setting `fields` names — Blender's property names, as the
    /// mirror's record carries them — and leaves the rest as they are.
    ///
    /// The record's reader, and the DEBUG launch hook's way of making a row's
    /// change by Blender's names (`-modifier-steps`).
    public mutating func read(_ fields: [String: String]) {
        var m = self
        defer { self = m }
        let kind = m.kind
        // Every number arrives float-formatted: `_record_value` in
        // _blenderkit_sync.py normalises with `repr(float(v))`, so
        // Blender's `levels = 2` reaches here as "2.0" and the Int
        // initialiser returns nil for it. Parsing through Float is what
        // makes an integer setting mirror back at all — levels, count,
        // segments and iterations had all been silently keeping their
        // defaults after every sync.
        //
        // The range check is not decoration: Int(Float) traps on a
        // non-finite value and on anything past Int.max, and this text
        // comes from a script that is free to have set nonsense.
        func int(_ key: String) -> Int? {
            guard let v = fields[key].flatMap(Float.init),
                  v.isFinite, v > -1e9, v < 1e9 else { return nil }
            return Int(v.rounded())
        }
        func float(_ key: String) -> Float? { fields[key].flatMap(Float.init) }
        func bool(_ key: String) -> Bool? {
            fields[key].map { $0 == "True" || $0 == "1" }
        }
        // The two switches every modifier has, whatever its kind.
        if let v = bool("show_viewport")     { m.showInViewport = v }
        if let v = bool("show_render")       { m.showInRender = v }
        if let v = int("levels")     { m.levels = v }
        if let v = int("count")      { m.count = v }
        if let v = int("steps")      { m.count = v }
        if let v = int("segments")   { m.segments = v }
        if let v = int("iterations") { m.iterations = v }
        if let v = int("octree_depth") { m.octreeDepth = v }
        if let v = int("face_count") { m.faceCount = v }
        if let v = float("thickness")  { m.thickness = v }
        if let v = float("width")      { m.thickness = v }
        // Displace's strength and Lattice's: the same field here.
        if let v = float("strength")   { m.thickness = v }
        if let v = float("height")     { m.thickness = v }
        if let v = float("offset")       { m.thickness = v }
        if let v = float("screw_offset") { m.thickness = v }
        if let v = float("factor")     { m.factor = v }
        if let v = float("angle")      { m.angle = v }
        if let v = float("ratio")      { m.ratio = v }
        if let v = float("voxel_size") { m.voxelSize = v }
        if let v = float("input_size"), v.isFinite, v > 0 { m.inputSize = v }
        if let v = bool("use_axis_x")  { m.mirrorX = v }
        if let v = bool("use_axis_y")  { m.mirrorY = v }
        if let v = bool("use_axis_z")  { m.mirrorZ = v }
        if let v = bool("use_bisect_axis_x") { m.bisectX = v }
        if let v = bool("use_bisect_axis_y") { m.bisectY = v }
        if let v = bool("use_bisect_axis_z") { m.bisectZ = v }
        if let v = bool("use_bisect_flip_axis_x") { m.bisectFlipX = v }
        if let v = bool("use_bisect_flip_axis_y") { m.bisectFlipY = v }
        if let v = bool("use_bisect_flip_axis_z") { m.bisectFlipZ = v }
        if let v = bool("use_clip")          { m.mirrorClip = v }
        if let v = bool("use_mirror_merge")  { m.mirrorMerge = v }
        if let v = float("merge_threshold")  { m.mergeThreshold = v }
        if let v = fields["deform_method"],
           let mode = Modifier.DeformMode(rawValue: v.lowercased()) { m.deformMode = mode }
        if let v = fields["deform_axis"] { m.axis = ["X", "Y", "Z"].firstIndex(of: v) ?? m.axis }
        // Screw spells its axis `axis` and Simple Deform `deform_axis`;
        // Wave has none, only the two Motion booleans read below.
        if let v = fields["axis"] { m.axis = ["X", "Y", "Z"].firstIndex(of: v) ?? m.axis }
        if let v = fields["operation"],
           let op = Modifier.BooleanOperation(rawValue: v.lowercased()) { m.booleanOperation = op }
        // Matched against the identifier, not a lowercased rawValue:
        // NEAREST_SURFACEPOINT does not round-trip through camel case.
        if let v = fields["wrap_method"],
           let w = Modifier.WrapMethod.allCases.first(where: { $0.bpyValue == v }) {
            m.wrapMethod = w
        }
        if let v = fields["decimate_type"], !v.isEmpty { m.decimateType = v }
        // Boolean's and Lattice's `object`, Shrinkwrap's `target`.
        if let v = fields["object"] { m.targetName = v }
        if let v = fields["target"] { m.targetName = v }
        if kind.takesVertexGroup {
            if let v = fields["vertex_group"] { m.vertexGroup = v }
            if let v = bool("invert_vertex_group") { m.invertVertexGroup = v }
        }
        // Names two kinds use for different things are read per kind:
        // `mode` is Remesh's algorithm and Weighted Normal's weighting,
        // `use_x` / `use_y` are Wave's Motion and Laplacian Smooth's axes.
        switch kind {
        case .wave:
            if let v = bool("use_x") { m.waveX = v }
            if let v = bool("use_y") { m.waveY = v }
        case .remesh:
            if let v = fields["mode"],
               let r = Modifier.RemeshMode(rawValue: v.lowercased()) { m.remeshMode = r }
        case .geometryNodes:
            if let v = fields["group"] { m.nodeGroup = v }
            if fields["angle"] != nil { m.smoothByAngle = true }
            if let v = bool("ignore_sharpness") { m.ignoreSharpness = v }
        case .weightedNormal:
            if let v = fields["mode"],
               let w = Modifier.WeightMode.allCases.first(where: { $0.bpyValue == v }) {
                m.weightMode = w
            }
            if let v = int("weight")            { m.weight = v }
            if let v = float("thresh")          { m.threshold = v }
            if let v = bool("keep_sharp")       { m.keepSharp = v }
            if let v = bool("use_face_influence") { m.faceInfluence = v }
        case .multires:
            if let v = int("sculpt_levels")     { m.sculptLevels = v }
            if let v = int("render_levels")     { m.renderLevels = v }
            if let v = int("total_levels")      { m.totalLevels = v }
        case .edgeSplit:
            if let v = float("split_angle")     { m.angle = v }
            if let v = bool("use_edge_angle")   { m.edgeSplitAngle = v }
            if let v = bool("use_edge_sharp")   { m.edgeSplitSharp = v }
        case .laplacianSmooth:
            if let v = float("lambda_factor")   { m.lambdaFactor = v }
            if let v = float("lambda_border")   { m.lambdaBorder = v }
            if let v = bool("use_x")            { m.smoothX = v }
            if let v = bool("use_y")            { m.smoothY = v }
            if let v = bool("use_z")            { m.smoothZ = v }
            if let v = bool("use_volume_preserve") { m.preserveVolume = v }
            if let v = bool("use_normalized")   { m.normalized = v }
        case .correctiveSmooth:
            if let v = float("scale")           { m.smoothScale = v }
            if let v = fields["smooth_type"],
               let t = Modifier.SmoothType.allCases.first(where: { $0.bpyValue == v }) {
                m.smoothType = t
            }
            if let v = bool("use_only_smooth")  { m.onlySmooth = v }
            if let v = bool("use_pin_boundary") { m.pinBoundary = v }
            if let v = fields["rest_source"], !v.isEmpty { m.restSource = v }
            if let v = bool("is_bind")          { m.isBound = v }
        default:
            break
        }
    }

    /// The `key=value;…` pairs of one record entry.
    ///
    /// A value has its separators percent-escaped by `_modifier_value` in
    /// _blenderkit_sync.py — Blender takes `a;b|c=d%e` as a modifier's name
    /// (measured in 5.2.1), and unescaped it split the entry and cut the name
    /// short. A value that is not valid percent-encoding is kept as it came.
    public static func fields(_ entry: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in entry.split(separator: ";") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let value = String(pair[pair.index(after: eq)...])
            fields[String(pair[pair.startIndex..<eq])] = value.contains("%")
                ? (value.removingPercentEncoding ?? value) : value
        }
        return fields
    }

    /// A readable name for a modifier type the record did not label:
    /// SURFACE_DEFORM reads "Surface Deform". Blender's own names come in
    /// `type_label`; this is only what a record without one falls back to.
    public static func label(forType type: String) -> String {
        type.split(separator: "_").map { $0.prefix(1) + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

/// The controls every modifier row has, whatever its kind — and Multires's
/// four buttons — as the Python each sends and the undo step it names.
///
/// One place, so the Modifiers panel and the DEBUG launch hook that drives it
/// (`-modifier-action`) send the same thing: a hook that built its own Python
/// would test something no button sends.
public enum ModifierRowAction: Equatable, Sendable {
    case toggleViewport, toggleRender, moveUp, moveDown, apply, remove
    case multires(Bpy.MultiresOperation)

    /// The action a hook names: `viewport`, `render`, `up`, `down`, `apply`,
    /// `remove`, or a Multires operation's raw value.
    public init?(hookName: String) {
        switch hookName {
        case "viewport": self = .toggleViewport
        case "render":   self = .toggleRender
        case "up":       self = .moveUp
        case "down":     self = .moveDown
        case "apply":    self = .apply
        case "remove":   self = .remove
        default:
            guard let op = Bpy.MultiresOperation(rawValue: hookName) else { return nil }
            self = .multires(op)
        }
    }

    /// What the row sends for this action on `modifier`, the stack as the
    /// mirror last reported it, and the name of the undo step — Blender's
    /// own operator names. Nil when the action has nothing to do: a move past
    /// either end of the stack, whose button is disabled, or a Multires
    /// operation on another kind.
    public func command(for modifier: Modifier, in stack: [Modifier]) -> (lines: [String], undo: String)? {
        let index = stack.firstIndex { $0.name == modifier.name }
        switch self {
        case .toggleViewport, .toggleRender:
            var changed = modifier
            if self == .toggleViewport { changed.showInViewport.toggle() } else { changed.showInRender.toggle() }
            return (Bpy.modifierEdit(from: modifier, to: changed), "Edit Modifier")
        case .moveUp:
            guard let index, index > 0 else { return nil }
            return ([Bpy.moveModifier(modifier.name, up: true)], "Move Up Modifier")
        case .moveDown:
            guard let index, index + 1 < stack.count else { return nil }
            return ([Bpy.moveModifier(modifier.name, up: false)], "Move Down Modifier")
        case .apply:
            return ([Bpy.applyModifier(modifier.name)], "Apply Modifier")
        case .remove:
            return ([Bpy.removeModifier(modifier.name)], "Remove Modifier")
        case .multires(let op):
            guard modifier.kind == .multires else { return nil }
            let undo: String
            switch op {
            case .subdivide:    undo = "Multires Subdivide"
            case .unsubdivide:  undo = "Unsubdivide"
            case .deleteHigher: undo = "Delete Higher Levels"
            case .applyBase:    undo = "Multires Apply Base"
            }
            return ([Bpy.multires(op, modifier.name)], undo)
        }
    }
}

/// Evaluates a modifier stack, in order, exactly as Blender does: each
/// modifier consumes the output of the one above it.
public enum ModifierStack {

    /// Where Blender's `modifier_add` puts a new modifier of `kind`: at the
    /// end, except one that needs the original mesh, which goes above the
    /// first modifier that is not a pure deform (`ED_object_modifier_add`).
    /// Measured in 5.2.1: Multires added under a Subdivision lands first.
    /// The simulator used to append it, below the Subdivision.
    public static func insertionIndex(for kind: ModifierKind, in stack: [Modifier]) -> Int {
        guard kind.requiresOriginalData else { return stack.count }
        return stack.firstIndex { !$0.kind.onlyDeforms } ?? stack.count
    }

    /// Whether Blender's Move Up or Move Down takes the modifier at `index`
    /// (`modifier_move_up` / `modifier_move_down` in object_modifier.cc):
    /// never past either end; nothing but a pure deform moves above one that
    /// needs the original mesh; and one that needs it moves below a pure
    /// deform only. Blender answers the rest CANCELLED, and so does the
    /// simulator now, whose stand-in swapped any two rows.
    public static func canMove(_ index: Int, up: Bool, in stack: [Modifier]) -> Bool {
        guard stack.indices.contains(index) else { return false }
        let other = up ? index - 1 : index + 1
        guard stack.indices.contains(other) else { return false }
        let moving = stack[index].kind, neighbour = stack[other].kind
        if up { return moving.onlyDeforms || !neighbour.requiresOriginalData }
        return !moving.requiresOriginalData || neighbour.onlyDeforms
    }

    /// `observe` sees each modifier's output as it is made, by the modifier's
    /// index — how the simulator reads a Decimate's face count, which Blender
    /// reports as `face_count` and the mirror carries on device.
    ///
    /// A modifier turned off in the viewport (`showInViewport`) passes the
    /// mesh through, as Blender's does — the row's switch has to change what
    /// the simulator draws, or it is a control that does nothing there.
    public static func apply(_ modifiers: [Modifier], to mesh: MeshData,
                             observe: ((Int, MeshData) -> Void)? = nil) -> MeshData {
        var result = mesh
        for (index, modifier) in modifiers.enumerated() {
            if modifier.showInViewport { result = apply(modifier, to: result) }
            observe?(index, result)
        }
        return result
    }

    static func apply(_ modifier: Modifier, to result: MeshData) -> MeshData {
        switch modifier.kind {
        case .subdivision:
            return subdivide(result, levels: min(max(modifier.levels, 0), 3))
        case .array:
            return array(result, count: max(modifier.count, 1),
                         relativeOffset: modifier.relativeOffset)
        case .mirror:
            return mirror(result, modifier)
        case .solidify:
            return solidify(result, thickness: modifier.thickness)
        case .smooth:
            return smoothed(result, factor: modifier.factor,
                            repeats: max(1, min(modifier.iterations, 10)))
        case .cast:
            return cast(result, factor: modifier.factor)
        case .simpleDeform:
            return simpleDeform(result, mode: modifier.deformMode,
                                angle: modifier.angle, axis: modifier.axis)
        case .displace:
            return displace(result, strength: modifier.thickness)
        case .weld:
            return weld(result)
        case .wave:
            return wave(result, height: modifier.thickness,
                        motionX: modifier.waveX, motionY: modifier.waveY)
        case .triangulate:
            // The meshes here are triangles already, so this is a no-op —
            // which is exactly what Blender's Triangulate does to one.
            return result
        case .bevel:
            // The shim has no half-edge structure to walk, so it rounds
            // the silhouette the way its Subdivision does rather than
            // cutting real chamfers. On device this modifier is Blender's.
            return smoothed(result, factor: min(max(modifier.thickness, 0), 1),
                            repeats: max(1, min(modifier.segments, 4)))
        case .boolean:
            // A boolean needs the other object's evaluated mesh, which a
            // per-mesh stack does not have. Blender's own runs on device;
            // here the mesh is left alone rather than quietly wrong.
            return result
        case .shrinkwrap:
            // Same reason as .boolean: the target's evaluated surface is
            // what every wrap method searches, and this stack only has
            // the one mesh. Left alone rather than approximated into
            // something that is not a shrinkwrap at all.
            return result
        case .screw:
            return screw(result, angle: modifier.angle,
                         steps: max(1, min(modifier.count, 512)),
                         screwOffset: modifier.thickness, axis: modifier.axis)
        case .decimate:
            return decimate(result, ratio: min(max(modifier.ratio, 0), 1))
        case .remesh:
            return remesh(result, mode: modifier.remeshMode,
                          voxelSize: modifier.voxelSize,
                          octreeDepth: max(1, min(modifier.octreeDepth, 8)))
        case .geometryNodes:
            // The node graph is Blender's to evaluate. The simulator never has
            // one (its Shade Auto Smooth refuses), and a mesh mirrored from
            // Blender is never run through this stack.
            return result
        case .multires:
            // A fresh Multires at level n is Catmull-Clark at n, which this
            // file approximates the way its Subdivision does. The viewport
            // level cannot pass the levels Subdivide has made (Blender clamps
            // it to `total_levels`).
            return subdivide(result, levels: min(max(min(modifier.levels, modifier.totalLevels), 0), 3))
        case .laplacianSmooth:
            return laplacianSmoothed(result, modifier)
        case .correctiveSmooth:
            // With nothing deforming the mesh above it, Corrective Smooth
            // gives the mesh back: it smooths the rest shape and the input
            // alike and restores the difference (measured in 5.2.1 on a UV
            // sphere, alone in its stack: no vertex moved more than 1e-6).
            // The simulator has nothing that deforms a mesh ahead of it
            // except the modifiers here, whose rest shape it does not keep.
            //
            // Only Smooth skips the correction, and Blender then smooths the
            // mesh outright (tests/modifiers/blender/verify.py measures it).
            // The simulator used to give the mesh back for it too, so the
            // switch changed nothing there. Its smoothing is this file's
            // Laplacian pass, not Blender's Simple or Length Weight.
            guard modifier.onlySmooth else { return result }
            return smoothed(result, factor: min(max(modifier.factor, 0), 1),
                            repeats: max(0, min(modifier.iterations, 200)))
        case .weightedNormal, .edgeSplit:
            // Both change shading, not shape: Weighted Normal writes custom
            // normals and Edge Split splits vertices along sharp edges. The
            // simulator's primitives are already split flat-shaded soups, so
            // the shape here is the shape either leaves.
            return result
        case .lattice:
            // A lattice object is what it deforms by, and the simulator's
            // stand-in has none (its Lattice row finds nothing to pick).
            // Blender leaves the mesh alone for a Lattice with no object.
            return result
        case .other:
            // Never in the simulator's own stack: its Add Modifier offers
            // only the kinds above.
            return result
        }
    }

    /// Blender's Laplacian Smooth, approximated by this file's welded
    /// Laplacian pass: `iterations` passes at `lambda_factor`, each axis moved
    /// only when its flag is on. Blender's is the Desbrun operator with
    /// volume preservation and a separate border factor; this is not, and
    /// the default factor of 0.01 moves a UV sphere by about 1e-4 in either
    /// (measured in 5.2.1: 1.3e-4 at the default, 0.064 at 1.0 × 5).
    static func laplacianSmoothed(_ mesh: MeshData, _ m: Modifier) -> MeshData {
        let repeats = max(0, min(m.iterations, 10))
        guard repeats > 0, m.lambdaFactor.isFinite else { return mesh }
        let smoothedMesh = smoothed(mesh, factor: max(0, min(m.lambdaFactor, 1)), repeats: repeats)
        guard smoothedMesh.vertices.count == mesh.vertices.count else { return smoothedMesh }
        let axes = [m.smoothX, m.smoothY, m.smoothZ]
        var result = smoothedMesh
        for i in result.vertices.indices {
            for axis in 0..<3 where !axes[axis] {
                result.vertices[i].position[axis] = mesh.vertices[i].position[axis]
            }
        }
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Subdivision

    /// Splits every triangle into four, then relaxes each vertex toward the
    /// average of its neighbours.
    ///
    /// Blender's Subdivision Surface is Catmull-Clark on quads; this mesh is
    /// triangulated, so a 1-to-4 split plus Laplacian smoothing is used to get
    /// the same visual result — a cube rounds off, a sphere gets denser and
    /// smoother. It is an approximation, not Catmull-Clark.
    static func subdivide(_ mesh: MeshData, levels: Int) -> MeshData {
        guard levels > 0 else { return mesh }
        var current = mesh
        for _ in 0..<levels {
            current = smooth(split(current))
        }
        return current
    }

    private static func split(_ mesh: MeshData) -> MeshData {
        var verts = mesh.vertices
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count * 4)

        // Midpoints are shared between adjacent triangles, so cache them by
        // the edge's unordered vertex pair or the mesh comes apart at the seams.
        var midpoints: [UInt64: UInt32] = [:]

        func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let existing = midpoints[key] { return existing }
            let va = verts[Int(a)], vb = verts[Int(b)]
            let position = (va.position + vb.position) * 0.5
            let normal = normalize(va.normal + vb.normal)
            // UInt32 indices cap the mesh at 65,535 vertices; stop growing
            // rather than wrapping around into corruption.
            guard verts.count < Int(UInt32.max) else { return a }
            verts.append(MeshVertex(position, normal))
            let index = UInt32(verts.count - 1)
            midpoints[key] = index
            return index
        }

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
            indices += [a, ab, ca,
                        ab, b, bc,
                        ca, bc, c,
                        ab, bc, ca]
            i += 3
        }
        return MeshData(vertices: verts, indices: indices)
    }

    /// One Laplacian pass: move each vertex partway toward the average of the
    /// vertices it shares an edge with. This is what rounds the silhouette.
    ///
    /// The primitives are flat-shaded, so each face carries its own copy of
    /// every corner — a cube is 24 vertices, not 8. Smoothing those copies
    /// independently pulls each face toward its own centre and the mesh comes
    /// apart into floating panels, so coincident vertices are welded first and
    /// every copy is moved together.
    private static func smooth(_ mesh: MeshData, strength: Float = 0.5) -> MeshData {
        let weld = weldMap(mesh.vertices)
        let groupCount = (weld.max() ?? 0) + 1

        var sums = [SIMD3<Float>](repeating: .zero, count: groupCount)
        var counts = [Float](repeating: 0, count: groupCount)

        // Adjacency is accumulated on the welded graph, and an edge between two
        // copies of the same point contributes nothing.
        var seen = Set<UInt64>()
        var e = 0
        while e + 1 < mesh.edges.count {
            let ga = weld[Int(mesh.edges[e])], gb = weld[Int(mesh.edges[e + 1])]
            if ga != gb {
                let key = UInt64(min(ga, gb)) << 32 | UInt64(max(ga, gb))
                if seen.insert(key).inserted {
                    sums[ga] += mesh.vertices[Int(mesh.edges[e + 1])].position; counts[ga] += 1
                    sums[gb] += mesh.vertices[Int(mesh.edges[e])].position; counts[gb] += 1
                }
            }
            e += 2
        }

        var moved = [SIMD3<Float>?](repeating: nil, count: groupCount)
        var verts = mesh.vertices
        for i in verts.indices {
            let g = weld[i]
            if moved[g] == nil, counts[g] > 0 {
                moved[g] = mix(verts[i].position, sums[g] / counts[g], t: strength)
            }
            if let p = moved[g] { verts[i].position = p }
        }

        var result = MeshData(vertices: verts, indices: mesh.indices)
        recomputeNormals(&result, weld: weld, groupCount: groupCount)
        return result
    }

    /// Groups vertices that sit at the same position, so a flat-shaded mesh can
    /// be treated as the connected surface it represents.
    ///
    /// `cell` is the grid the positions are quantised onto. The default is far
    /// below any modelling scale, so it only ever merges coincident copies;
    /// Decimate and Remesh pass a coarse cell to make the same routine cluster
    /// distinct vertices together.
    static func weldMap(_ verts: [MeshVertex], cell: Float = 1e-5) -> [Int] {
        // Quantising to a grid makes the lookup exact-match rather than a
        // nearest-neighbour search.
        struct Key: Hashable { var x: Int32; var y: Int32; var z: Int32 }
        let scale = cell > 0 ? 1 / cell : 100_000

        // Int32(_:) traps on a non-finite value and on anything past about
        // 21 km at this scale — both reachable, and both crashed the app rather
        // than drawing a strange mesh. A vertex whose normal came out
        // degenerate can carry NaN into a position, and a script is free to
        // move something a long way from the origin.
        func quantise(_ v: Float) -> Int32 {
            guard v.isFinite else { return Int32.min }
            let scaled = (v * scale).rounded()
            if scaled >= Float(Int32.max) { return Int32.max }
            if scaled <= Float(Int32.min) + 1 { return Int32.min + 1 }
            return Int32(scaled)
        }
        func key(_ p: SIMD3<Float>) -> Key {
            Key(x: quantise(p.x), y: quantise(p.y), z: quantise(p.z))
        }
        var groups: [Key: Int] = [:]
        var map = [Int](repeating: 0, count: verts.count)
        for (i, v) in verts.enumerated() {
            let k = key(v.position)
            if let g = groups[k] {
                map[i] = g
            } else {
                let g = groups.count
                groups[k] = g
                map[i] = g
            }
        }
        return map
    }

    // MARK: Array

    static func array(_ mesh: MeshData, count: Int, relativeOffset: SIMD3<Float>) -> MeshData {
        guard count > 1, !mesh.vertices.isEmpty else { return mesh }

        // Blender's relative offset is measured in bounding-box widths.
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices { lo = min(lo, v.position); hi = max(hi, v.position) }
        let step = (hi - lo) * relativeOffset

        // Stay inside the UInt32 index space.
        let maxCopies = max(1, Int(UInt32.max) / max(mesh.vertices.count, 1))
        let copies = min(count, maxCopies)

        var verts: [MeshVertex] = []
        var indices: [UInt32] = []
        verts.reserveCapacity(mesh.vertices.count * copies)
        indices.reserveCapacity(mesh.indices.count * copies)

        for c in 0..<copies {
            let base = UInt32(verts.count)
            let shift = step * Float(c)
            verts += mesh.vertices.map { MeshVertex($0.position + shift, $0.normal) }
            indices += mesh.indices.map { $0 + base }
        }
        return MeshData(vertices: verts, indices: indices)
    }

    // MARK: Mirror

    /// Blender's Mirror, axis by axis as `BKE_mesh_mirror_apply_mirror_on_axis_for_modifier`
    /// does it: bisect at that axis's plane, reflect, then weld each vertex to
    /// its own image when Merge is on.
    static func mirror(_ mesh: MeshData, _ m: Modifier) -> MeshData {
        var current = mesh
        let axes = [(m.mirrorX, m.bisectX, m.bisectFlipX),
                    (m.mirrorY, m.bisectY, m.bisectFlipY),
                    (m.mirrorZ, m.bisectZ, m.bisectFlipZ)]
        for (axis, (enabled, bisect, flip)) in axes.enumerated() where enabled {
            if bisect { current = bisected(current, axis: axis, keepNegative: flip) }
            current = mirrorOnce(current, axis: axis,
                                 merge: m.mirrorMerge ? m.mergeThreshold : nil)
        }
        return current
    }

    /// Blender's `bisect_threshold`, which the panel does not offer: within
    /// it a vertex is snapped onto the plane rather than cut away.
    static let bisectDistance: Float = 0.001

    /// The half of `mesh` on the kept side of the plane through the origin
    /// normal to `axis`: the positive side, or the negative with Flip.
    /// Triangles that cross it are cut along it, sharing each new vertex
    /// between the two triangles either side of the edge it lies on.
    static func bisected(_ mesh: MeshData, axis: Int, keepNegative: Bool) -> MeshData {
        // A wire has no triangles to cut, and rebuilding it from none would
        // drop the edges it is drawn with.
        guard !mesh.indices.isEmpty else { return mesh }
        var verts = mesh.vertices
        // Blender's `use_snap_center`: near enough counts as on the plane.
        for i in verts.indices where abs(verts[i].position[axis]) <= bisectDistance {
            verts[i].position[axis] = 0
        }
        func side(_ i: UInt32) -> Float {
            keepNegative ? -verts[Int(i)].position[axis] : verts[Int(i)].position[axis]
        }
        var cuts: [UInt64: UInt32] = [:]
        func cut(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let made = cuts[key] { return made }
            let va = verts[Int(a)], vb = verts[Int(b)]
            let t = side(a) / (side(a) - side(b))
            var v = va
            v.position = mix(va.position, vb.position, t: t)
            v.position[axis] = 0
            let n = mix(va.normal, vb.normal, t: t)
            v.normal = simd_length(n) > 0 ? simd_normalize(n) : va.normal
            v.uv = mix(va.uv, vb.uv, t: SIMD2(repeating: t))
            verts.append(v)
            cuts[key] = UInt32(verts.count - 1)
            return cuts[key]!
        }
        var indices: [UInt32] = []
        var i = 0
        while i + 2 < mesh.indices.count {
            let tri = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
            i += 3
            let inside = tri.map { side($0) >= 0 }
            if inside.allSatisfy({ $0 }) { indices += tri; continue }
            if !inside.contains(true) { continue }
            // Sutherland–Hodgman against the one plane, then a fan: a
            // triangle clipped by a plane is a triangle or a quad.
            var polygon: [UInt32] = []
            for k in 0..<3 {
                let a = tri[k], b = tri[(k + 1) % 3]
                if inside[k] { polygon.append(a) }
                if inside[k] != inside[(k + 1) % 3] { polygon.append(cut(a, b)) }
            }
            for k in stride(from: 1, to: polygon.count - 1, by: 1) {
                indices += [polygon[0], polygon[k], polygon[k + 1]]
            }
        }
        // Blender deletes the vertices across the plane; left here unused
        // they would still be counted, and mirrored.
        var remap = [UInt32](repeating: .max, count: verts.count)
        var kept: [MeshVertex] = []
        for index in indices where remap[Int(index)] == .max {
            remap[Int(index)] = UInt32(kept.count)
            kept.append(verts[Int(index)])
        }
        return MeshData(vertices: kept, indices: indices.map { remap[Int($0)] })
    }

    /// Reflects `mesh` across the plane normal to `axis` and appends the
    /// image. With `merge`, a vertex closer than that to its own image is
    /// welded to it at the plane, as Blender's merge map does (`< tolerance`,
    /// the average of the two), and an image triangle whose three corners all
    /// welded is dropped: it lies on the original, as a cube's face on the
    /// plane does (measured: 12 faces mirrored, 11 merged).
    private static func mirrorOnce(_ mesh: MeshData, axis: Int, merge: Float? = nil) -> MeshData {
        guard mesh.vertices.count * 2 < Int(UInt32.max) else { return mesh }
        var verts = mesh.vertices
        var indices = mesh.indices
        var target = [UInt32](repeating: 0, count: mesh.vertices.count)
        var welded = [Bool](repeating: false, count: mesh.vertices.count)

        for (i, v) in mesh.vertices.enumerated() {
            if let merge, 2 * abs(v.position[axis]) < merge {
                // No image: the vertex is its own, on the plane.
                verts[i].position[axis] = 0
                target[i] = UInt32(i)
                welded[i] = true
                continue
            }
            var image = v
            image.position[axis] = -v.position[axis]
            image.normal[axis] = -v.normal[axis]
            verts.append(image)
            target[i] = UInt32(verts.count - 1)
        }

        // Reflecting reverses the winding, so swap two indices of each triangle
        // to keep the mirrored half facing outward.
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            i += 3
            if welded[a] && welded[b] && welded[c] { continue }
            indices += [target[a], target[c], target[b]]
        }
        return MeshData(vertices: verts, indices: indices)
    }

    // MARK: Solidify

    /// Gives the surface thickness by adding an inner shell with reversed
    /// winding. Blender also builds a rim between the shells; without a
    /// boundary-edge structure this produces the two shells only, which reads
    /// correctly on closed meshes.
    static func solidify(_ mesh: MeshData, thickness: Float) -> MeshData {
        guard abs(thickness) > 1e-5, mesh.vertices.count * 2 < Int(UInt32.max) else { return mesh }
        var verts = mesh.vertices
        var indices = mesh.indices
        let base = UInt32(verts.count)

        for v in mesh.vertices {
            verts.append(MeshVertex(v.position - v.normal * thickness, -v.normal))
        }
        var i = 0
        while i + 2 < mesh.indices.count {
            // Reversed winding so the inner shell faces inward.
            indices += [mesh.indices[i] + base,
                        mesh.indices[i + 2] + base,
                        mesh.indices[i + 1] + base]
            i += 3
        }
        return MeshData(vertices: verts, indices: indices)
    }

    // MARK: Smooth

    /// Blender's Smooth modifier: relax vertices toward their neighbours
    /// without adding geometry. Reuses the same welded Laplacian pass that
    /// subdivision relies on.
    static func smoothed(_ mesh: MeshData, factor: Float, repeats: Int) -> MeshData {
        var current = mesh
        for _ in 0..<repeats {
            current = smooth(current, strength: factor)
        }
        return current
    }

    // MARK: Cast

    /// Blender's Cast modifier, sphere type: blends each vertex toward the
    /// sphere that encloses the mesh.
    static func cast(_ mesh: MeshData, factor: Float) -> MeshData {
        guard !mesh.vertices.isEmpty else { return mesh }
        let centre = mesh.vertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                   / Float(mesh.vertices.count)
        let radius = mesh.vertices.reduce(Float(0)) { max($0, length($1.position - centre)) }
        guard radius > 1e-5 else { return mesh }

        var result = mesh
        for i in result.vertices.indices {
            let offset = result.vertices[i].position - centre
            let len = length(offset)
            guard len > 1e-6 else { continue }
            let onSphere = centre + offset / len * radius
            result.vertices[i].position = mix(result.vertices[i].position, onSphere, t: factor)
        }
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Simple Deform

    /// Blender's Simple Deform: twist, bend, taper and stretch about an axis.
    static func simpleDeform(_ mesh: MeshData, mode: Modifier.DeformMode,
                             angle: Float, axis: Int) -> MeshData {
        guard !mesh.vertices.isEmpty else { return mesh }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in mesh.vertices {
            lo = min(lo, v.position[axis]); hi = max(hi, v.position[axis])
        }
        let span = hi - lo
        guard span > 1e-5 else { return mesh }

        // The two axes perpendicular to the deform axis.
        let a = (axis + 1) % 3, b = (axis + 2) % 3

        var result = mesh
        for i in result.vertices.indices {
            var p = result.vertices[i].position
            // 0 at one end of the object, 1 at the other.
            let t = (p[axis] - lo) / span

            switch mode {
            case .twist:
                let theta = angle * t
                let c = cos(theta), s = sin(theta)
                let (u, v) = (p[a], p[b])
                p[a] = u * c - v * s
                p[b] = u * s + v * c
            case .bend:
                // Wrap the axis around a circle of the radius that makes the
                // full span subtend `angle`.
                guard abs(angle) > 1e-5 else { break }
                let radius = span / angle
                let theta = angle * (t - 0.5)
                let offset = p[a]
                p[axis] = (radius - offset) * sin(theta)
                p[a] = radius - (radius - offset) * cos(theta)
            case .taper:
                let k = 1 + angle * (t - 0.5)
                p[a] *= k
                p[b] *= k
            case .stretch:
                let k = 1 + angle * (t - 0.5)
                p[axis] = lo + (p[axis] - lo) * k
            }
            result.vertices[i].position = p
        }
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Displace

    /// Blender's Displace with no texture: pushes every vertex along its
    /// normal by a constant amount, which inflates or shrinks the surface.
    static func displace(_ mesh: MeshData, strength: Float) -> MeshData {
        var result = mesh
        for i in result.vertices.indices {
            result.vertices[i].position += result.vertices[i].normal * strength
        }
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Weld

    /// Blender's Weld: merge vertices that sit at the same place. The
    /// primitives ship with duplicated corners for flat shading, so this
    /// visibly drops the vertex count without changing the shape.
    static func weld(_ mesh: MeshData, cell: Float = 1e-5) -> MeshData {
        let map = weldMap(mesh.vertices, cell: cell)
        let groups = (map.max() ?? 0) + 1
        var representative = [Int?](repeating: nil, count: groups)
        var verts: [MeshVertex] = []
        var remap = [UInt32](repeating: 0, count: mesh.vertices.count)

        for (i, v) in mesh.vertices.enumerated() {
            let g = map[i]
            if let r = representative[g] {
                remap[i] = UInt32(r)
            } else {
                verts.append(v)
                representative[g] = verts.count - 1
                remap[i] = UInt32(verts.count - 1)
            }
        }

        var indices: [UInt32] = []
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[i])]
            let b = remap[Int(mesh.indices[i + 1])]
            let c = remap[Int(mesh.indices[i + 2])]
            // Welding can collapse a triangle to a line; drop those.
            if a != b, b != c, a != c { indices += [a, b, c] }
            i += 3
        }
        var result = MeshData(vertices: verts, indices: indices)
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Wave

    /// Blender's Wave, frozen at time zero: a sine displacement radiating from
    /// the object's origin.
    /// Blender's Wave (`MOD_wave.cc`) at its default Width 1.5, Narrowness
    /// 1.5, Speed 0.25 and Start (0, 0), cyclic, at frame 1 — the frame a new
    /// scene opens on; the stack has no clock. Each vertex rises along Z by
    /// `height` times a Gaussian of how far the wave has travelled to it:
    /// radially with both Motion flags, along X or Y with one, and not at all
    /// with neither, which lifts every vertex alike. Checked against 5.2.1 on
    /// a grid 8 wide: 0.49479 at x = 0.293 with Motion X alone, and 0 from
    /// x = 1.854 on, where the first crest has not yet arrived.
    static func wave(_ mesh: MeshData, height: Float, motionX: Bool, motionY: Bool,
                     frame: Float = 1) -> MeshData {
        let width: Float = 1.5, narrow: Float = 1.5, speed: Float = 0.25
        let minimum = 1 / exp(width * narrow * width * narrow)
        var result = mesh
        for i in result.vertices.indices {
            let p = result.vertices[i].position
            var travelled: Float = 0
            if motionX && motionY { travelled = (p.x * p.x + p.y * p.y).squareRoot() }
            else if motionX { travelled = p.x }
            else if motionY { travelled = p.y }
            travelled -= frame * speed
            // Cyclic: fmodf keeps the dividend's sign, as C's does.
            travelled = fmodf(travelled - width, 2 * width) + width
            guard travelled > -width, travelled < width else { continue }
            let a = travelled * narrow
            result.vertices[i].position.z += height * (1 / exp(a * a) - minimum)
        }
        recomputeNormals(&result, welded: true)
        return result
    }

    // MARK: Screw

    /// Blender's Screw, as far as a triangle soup can carry it: `steps` copies
    /// of the profile, each rotated its share of `angle` about the axis and
    /// raised its share of `screw_offset`. With a nonzero offset that is a
    /// spiral; with zero it is a lathe.
    ///
    /// Blender bridges consecutive steps into one swept surface — measured on
    /// a closed cube at steps 8, 6 faces become 96 and 8 vertices become 64,
    /// which is more geometry than unbridged copies give. Bridging means
    /// walking the profile's boundary edges in order, and MeshData has no
    /// structure that says which edges are on a boundary — the same reason the
    /// Bevel shim rounds the silhouette instead of cutting chamfers. So here a
    /// screwed profile reads as a spiral of separate copies rather than one
    /// continuous surface. On device this modifier is Blender's own.
    static func screw(_ mesh: MeshData, angle: Float, steps: Int,
                      screwOffset: Float, axis: Int) -> MeshData {
        guard steps > 1, !mesh.vertices.isEmpty, angle.isFinite, screwOffset.isFinite
        else { return mesh }
        let up = max(0, min(axis, 2))
        let a = (up + 1) % 3, b = (up + 2) % 3

        // No more vertices than the mirror would draw (_MAX_VERTS in
        // _blenderkit_sync.py), which also keeps inside the UInt32 index
        // space. The simulator is the only place this runs — on device the
        // mesh is Blender's evaluated one, which this stack never touches.
        let maxCopies = max(1, 10_000_000 / max(mesh.vertices.count, 1))
        let copies = min(steps, maxCopies)

        var verts: [MeshVertex] = []
        var indices: [UInt32] = []
        verts.reserveCapacity(mesh.vertices.count * copies)
        indices.reserveCapacity(mesh.indices.count * copies)

        for c in 0..<copies {
            let t = Float(c) / Float(copies)
            let cs = cos(angle * t), sn = sin(angle * t)
            let rise = screwOffset * t
            let base = UInt32(verts.count)
            for v in mesh.vertices {
                var p = v.position, n = v.normal
                let pu = p[a], pv = p[b]
                p[a] = pu * cs - pv * sn
                p[b] = pu * sn + pv * cs
                p[up] += rise
                let nu = n[a], nv = n[b]
                n[a] = nu * cs - nv * sn
                n[b] = nu * sn + nv * cs
                verts.append(MeshVertex(p, n))
            }
            indices += mesh.indices.map { $0 + base }
        }
        return MeshData(vertices: verts, indices: indices)
    }

    // MARK: Decimate

    /// Vertex-clustering decimation (Rossignac-Borrel): the mesh is welded onto
    /// a grid coarse enough that the survivors land near `ratio` of the
    /// original vertex count, and triangles that collapse onto themselves are
    /// dropped by the weld.
    ///
    /// This is a real reduction, but it is NOT the quadric edge collapse
    /// Blender runs. Clustering knows nothing about curvature, so a silhouette
    /// Blender would have kept gets faceted, and the result lands near the
    /// ratio rather than on it — Blender's `face_count` is exact, this is not.
    /// On device this modifier is Blender's own.
    static func decimate(_ mesh: MeshData, ratio: Float) -> MeshData {
        guard ratio < 1, !mesh.vertices.isEmpty else { return mesh }
        let unique = (weldMap(mesh.vertices).max() ?? 0) + 1
        // Four is the fewest points a closed solid can keep.
        let target = max(4, Int((Float(unique) * max(ratio, 0)).rounded()))
        // A ratio near 1 on a small mesh asks for no reduction at all. Welding
        // anyway would re-shade a flat-shaded primitive smooth for nothing.
        guard target < unique else { return mesh }

        let (lo, hi) = bounds(mesh)
        let diagonal = length(hi - lo)
        guard diagonal.isFinite, diagonal > 1e-5 else { return mesh }

        // Cluster count falls as the cell grows, so bisect for the finest cell
        // that reaches the target. Fourteen passes over the vertices is cheap
        // beside the mesh rebuild this feeds, and only the simulator runs it.
        var fine = diagonal * 1e-4, coarse = diagonal
        var chosen = coarse
        for _ in 0..<14 {
            let mid = (fine + coarse) * 0.5
            let count = (weldMap(mesh.vertices, cell: mid).max() ?? 0) + 1
            if count > target { fine = mid } else { coarse = mid; chosen = mid }
        }
        return weld(mesh, cell: chosen)
    }

    // MARK: Remesh

    /// Blender's Remesh, approximated by the same grid clustering Decimate
    /// uses: VOXEL clusters at `voxel_size`, the three octree modes at the
    /// bounding-box diagonal divided by 2^depth. That gives the uniform
    /// density and the faceting the modifier is recognised by.
    ///
    /// It does NOT rebuild the surface from a volume, so unlike Blender's it
    /// does not close holes, does not fuse separate shells and cannot make a
    /// self-intersecting mesh manifold — which is half of what Remesh is
    /// reached for. MarchingCubes.swift could do the real thing, but it wants
    /// an n^3 sampled field and there is no mesh voxeliser to build one. On
    /// device this modifier is Blender's own.
    static func remesh(_ mesh: MeshData, mode: Modifier.RemeshMode,
                       voxelSize: Float, octreeDepth: Int) -> MeshData {
        guard !mesh.vertices.isEmpty else { return mesh }
        let cell: Float
        if mode == .voxel {
            cell = max(voxelSize, remeshVoxelFloor(for: mesh))
        } else {
            let (lo, hi) = bounds(mesh)
            let diagonal = length(hi - lo)
            guard diagonal.isFinite, diagonal > 1e-5 else { return mesh }
            cell = diagonal / Float(1 << max(1, min(octreeDepth, 8)))
        }
        guard cell.isFinite, cell > 1e-5 else { return mesh }
        return weld(mesh, cell: cell)
    }

    // MARK: Remesh's finest voxel

    /// How many voxels across its largest dimension a Remesh may be set to.
    ///
    /// Blender's VOXEL remesh gives about 6 N² vertices on a cube N voxels
    /// across, whatever the cube's size (measured in 5.2.1: 396,296 at N = 256
    /// on a 2 m and on a 6 m cube, 4.7 N² on a UV sphere, 5.6 N² on a
    /// cylinder). A floor of a fixed 0.01 m let a 6 m cube reach 2.17 million
    /// vertices and anything past about 13 m cross the mirror's
    /// 10,000,000-vertex limit. 256 across is the octree's own ceiling —
    /// Octree Depth stops at 8 — so a voxel remesh can be no denser than an
    /// octree one, at any size.
    public static let remeshVoxelsAcross: Float = 256

    /// The smallest Voxel Size the row sends for a mesh of this size: its
    /// largest dimension over `remeshVoxelsAcross`. The mesh is the one on
    /// screen, in the object's own space, which is where `voxel_size` is
    /// measured. With no geometry to measure, the old fixed floor.
    public static func remeshVoxelFloor(for mesh: MeshData) -> Float {
        remeshVoxelFloor(largest: largestDimension(mesh))
    }

    /// The floor for a mesh whose largest dimension is `largest`.
    public static func remeshVoxelFloor(largest: Float) -> Float {
        guard largest.isFinite, largest > 0 else { return 0.01 }
        // Blender's own soft minimum for voxel_size.
        return max(largest / remeshVoxelsAcross, 0.0001)
    }

    /// The floor the Voxel Size row of `modifier` clamps to, on an object
    /// showing `mesh`.
    ///
    /// From the Remesh's input when that is known (`Modifier.inputSize`), and
    /// never from its output. On device the mesh on screen is Blender's
    /// evaluated one — what the Remesh made — so a floor read off it fed on
    /// itself: measured in 5.2.1, a 2 m cube at Voxel Size 2.0 (the row's own
    /// ceiling) evaluates to a 0.667 m cube, which put the floor at 0.0026
    /// rather than 0.0078, and committing it gave 3,548,168 vertices in 4 s
    /// against 396,296 at the floor intended; a 100 m cube at 60 did the same
    /// (0.130 for 0.391). The input is known whenever nothing enabled comes
    /// before the Remesh, and always in the simulator. Otherwise the output is
    /// all there is, and the floor is its own as before.
    public static func remeshVoxelFloor(for modifier: Modifier, on mesh: MeshData) -> Float {
        modifier.inputSize > 0 ? remeshVoxelFloor(largest: modifier.inputSize)
                               : remeshVoxelFloor(for: mesh)
    }

    /// The largest extent of the mesh's axis-aligned bounds, 0 for none.
    public static func largestDimension(_ mesh: MeshData) -> Float {
        guard !mesh.vertices.isEmpty else { return 0 }
        let (lo, hi) = bounds(mesh)
        let largest = (hi - lo).max()
        return largest.isFinite ? max(largest, 0) : 0
    }

    // MARK: helpers

    /// The mesh's axis-aligned bounds.
    static func bounds(_ mesh: MeshData) -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices where v.position.x.isFinite && v.position.y.isFinite
                                     && v.position.z.isFinite {
            lo = min(lo, v.position); hi = max(hi, v.position)
        }
        return (lo, hi)
    }

    /// Area-weighted vertex normals, accumulated across welded copies so a
    /// subdivided surface shades smoothly instead of showing the facets of the
    /// original flat-shaded primitive.
    static func recomputeNormals(_ mesh: inout MeshData, weld: [Int]? = nil,
                                 groupCount: Int? = nil, welded: Bool? = nil) {
        // `welded` is the shade-smooth/flat switch: smooth accumulates across
        // coincident vertices, flat keeps each face's own normal.
        var weld = weld
        var groupCount = groupCount
        if let welded {
            if welded {
                let map = weldMap(mesh.vertices)
                weld = map
                groupCount = (map.max() ?? 0) + 1
            } else {
                weld = nil
                groupCount = nil
            }
        }
        let map = weld ?? Array(mesh.vertices.indices)
        let count = groupCount ?? mesh.vertices.count
        var normals = [SIMD3<Float>](repeating: .zero, count: count)

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            let pa = mesh.vertices[a].position
            let pb = mesh.vertices[b].position
            let pc = mesh.vertices[c].position
            // An uncorrected cross product is already area-weighted.
            let face = cross(pb - pa, pc - pa)
            normals[map[a]] += face; normals[map[b]] += face; normals[map[c]] += face
            i += 3
        }
        for i in mesh.vertices.indices {
            let n = normals[map[i]]
            // Falling back to the existing normal keeps a NaN alive forever
            // once anything introduces one, so the fallback has to be a normal
            // that is definitely valid.
            if length(n) > 1e-8 {
                mesh.vertices[i].normal = normalize(n)
            } else {
                let previous = mesh.vertices[i].normal
                mesh.vertices[i].normal =
                    (previous.x.isFinite && previous.y.isFinite && previous.z.isFinite
                     && length(previous) > 1e-8) ? previous : SIMD3(0, 0, 1)
            }
        }
    }
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}
