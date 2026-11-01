import Foundation

/// One setting of a declared modifier row (round 4, group 8): Blender's
/// property, the words Blender's own panel draws it with (MOD_*.cc
/// `panel_draw`), and what kind of control it is.
///
/// The eleven kinds Add Modifier gained rows for keep their settings as the
/// text the mirror sent (`Modifier.values`), by these keys. A row shows that
/// text, and an edit sends one assignment built from it (`python(for:)`), so
/// what the row shows is what Blender holds and what it sends is Blender's
/// property — the rule every modifier row keeps.
public struct ModifierField: Sendable, Equatable {
    public enum Unit: Sendable, Equatable { case none, meters, degrees, frames }

    public enum Kind: Sendable, Equatable {
        /// A float, with its step and Blender's hard range where it has one.
        case number(step: Float, unit: Unit, min: Float?, max: Float?)
        case integer(ClosedRange<Int>)
        case toggle
        /// An enum, its identifiers and names as Blender's RNA lists them.
        case choice([Choice])
        /// An enum set (`is_enum_flag`): any of the identifiers.
        case flags([Choice])
        /// Three floats, as Normal Edit's Offset.
        case vector3(step: Float)
        /// Another object, of one of `types` (Blender's `Object.type`), or any
        /// object but the modifier's own when nil. Blender leaves a pointer
        /// as it was for an object of another type without a word (measured
        /// in 5.2.1 for each: a mesh, a text and an empty given to Curve's,
        /// Armature's and Surface Deform's left them unchanged), and raises
        /// "ID type does not support assignment to itself" for its own.
        case object(types: [String]?)
        /// Shown, never sent: a Bind's state, a Hook's vertex count.
        case readOnly
    }

    public struct Choice: Sendable, Equatable, Hashable {
        public let identifier: String
        public let label: String
        public init(_ identifier: String, _ label: String) {
            self.identifier = identifier
            self.label = label
        }
    }

    public let key: String
    public let label: String
    public let kind: Kind
    /// The sub-panel Blender draws it in ("Falloff", "Vertex Data", …), nil
    /// for the modifier's main panel.
    public let panel: String?

    public init(_ key: String, _ label: String, _ kind: Kind, panel: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.panel = panel
    }

    public var isObject: Bool {
        if case .object = kind { return true }
        return false
    }

    public var isReadOnly: Bool { kind == .readOnly }

    /// The Python literal for `value` — the record's text for this setting —
    /// or nil when it does not parse (then nothing is sent).
    public func python(for value: String) -> String? {
        func number(_ text: Substring) -> String? {
            guard let v = Double(text), v.isFinite else { return nil }
            return String(format: "%.6g", v)
        }
        switch kind {
        case .number:
            return number(Substring(value))
        case .integer:
            guard let v = Double(value), v.isFinite, abs(v) < 1e9 else { return nil }
            return "\(Int(v.rounded()))"
        case .toggle:
            return value == "1" || value == "True" ? "True" : "False"
        case .choice(let choices):
            guard choices.contains(where: { $0.identifier == value }) else { return nil }
            return "'\(value)'"
        case .flags(let choices):
            let picked = Self.flagSet(value)
            guard picked.allSatisfy({ id in choices.contains { $0.identifier == id } }) else { return nil }
            return picked.isEmpty ? "set()" : "{" + picked.sorted().map { "'\($0)'" }.joined(separator: ", ") + "}"
        case .vector3:
            let parts = value.split(separator: ",").compactMap(number)
            return parts.count == 3 ? "(" + parts.joined(separator: ", ") + ")" : nil
        case .object:
            return value.isEmpty ? "None" : "bpy.data.objects[\(Bpy.quote(value))]"
        case .readOnly:
            return nil
        }
    }

    /// The identifiers of an enum set, as the record joins them.
    public static func flagSet(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
}

public extension ModifierKind {
    /// Whether this kind's rows are declared (`fields`) and its settings kept
    /// in `Modifier.values`.
    var isDeclared: Bool { !fields.isEmpty }

    /// The settings Blender's panel for this kind draws, in its order. Labels
    /// are read from 5.2.1's MOD_*.cc `panel_draw` (the property's RNA name
    /// where the panel gives none); enum items from its RNA.
    var fields: [ModifierField] {
        typealias F = ModifierField
        typealias C = ModifierField.Choice
        switch self {
        case .curve:
            return [F("object", "Curve Object", .object(types: ["CURVE"])),
                    F("deform_axis", "Deform Axis", .choice([
                        C("POS_X", "X"), C("POS_Y", "Y"), C("POS_Z", "Z"),
                        C("NEG_X", "-X"), C("NEG_Y", "-Y"), C("NEG_Z", "-Z")]))]
        case .wireframe:
            return [F("thickness", "Thickness", .number(step: 0.005, unit: .meters, min: nil, max: nil)),
                    F("offset", "Offset", .number(step: 0.01, unit: .none, min: nil, max: nil)),
                    F("use_boundary", "Boundary", .toggle),
                    F("use_replace", "Replace Original", .toggle),
                    F("use_even_offset", "Even", .toggle, panel: "Thickness"),
                    F("use_relative_offset", "Relative", .toggle, panel: "Thickness"),
                    F("use_crease", "Crease Edges", .toggle),
                    F("crease_weight", "Weight", .number(step: 0.01, unit: .none, min: nil, max: nil)),
                    F("material_offset", "Material Offset", .integer(-32768...32767)),
                    F("thickness_vertex_group", "Factor", .number(step: 0.01, unit: .none, min: 0, max: 1),
                      panel: "Vertex Group")]
        case .skin:
            return [F("branch_smoothing", "Branch Smoothing", .number(step: 0.01, unit: .none, min: 0, max: 1)),
                    F("use_x_symmetry", "X", .toggle, panel: "Symmetry"),
                    F("use_y_symmetry", "Y", .toggle, panel: "Symmetry"),
                    F("use_z_symmetry", "Z", .toggle, panel: "Symmetry"),
                    F("use_smooth_shade", "Smooth Shading", .toggle)]
        case .hook:
            return [F("object", "Object", .object(types: nil)),
                    F("strength", "Strength", .number(step: 0.01, unit: .none, min: 0, max: 1)),
                    F("falloff_type", "Type", .choice([
                        C("NONE", "No Falloff"), C("CURVE", "Curve"), C("SMOOTH", "Smooth"),
                        C("SPHERE", "Sphere"), C("ROOT", "Root"), C("INVERSE_SQUARE", "Inverse Square"),
                        C("SHARP", "Sharp"), C("LINEAR", "Linear"), C("CONSTANT", "Constant")]),
                      panel: "Falloff"),
                    F("falloff_radius", "Radius", .number(step: 0.01, unit: .meters, min: 0, max: nil),
                      panel: "Falloff"),
                    F("use_falloff_uniform", "Uniform Falloff", .toggle, panel: "Falloff"),
                    F("vertex_count", "Vertices", .readOnly)]
        case .armature:
            return [F("object", "Object", .object(types: ["ARMATURE"])),
                    F("use_deform_preserve_volume", "Preserve Volume", .toggle),
                    F("use_multi_modifier", "Multi Modifier", .toggle),
                    F("use_vertex_groups", "Vertex Groups", .toggle, panel: "Bind To"),
                    F("use_bone_envelopes", "Bone Envelopes", .toggle, panel: "Bind To")]
        case .surfaceDeform:
            return [F("target", "Target", .object(types: ["MESH"])),
                    F("falloff", "Interpolation Falloff", .number(step: 0.1, unit: .none, min: 2, max: 16)),
                    F("strength", "Strength", .number(step: 0.01, unit: .none, min: -100, max: 100)),
                    F("use_sparse_bind", "Sparse Bind", .toggle),
                    F("is_bound", "Bound", .readOnly)]
        case .meshDeform:
            return [F("object", "Object", .object(types: ["MESH"])),
                    F("precision", "Precision", .integer(2...10)),
                    F("use_dynamic_bind", "Dynamic", .toggle),
                    F("is_bound", "Bound", .readOnly)]
        case .dataTransfer:
            let mix = [C("REPLACE", "Replace"), C("ABOVE_THRESHOLD", "Above Threshold"),
                       C("BELOW_THRESHOLD", "Below Threshold"), C("MIX", "Mix"), C("ADD", "Add"),
                       C("SUB", "Subtract"), C("MUL", "Multiply")]
            return [F("object", "Source", .object(types: ["MESH"])),
                    F("use_object_transform", "Object Transform", .toggle),
                    F("mix_mode", "Mix Mode", .choice(mix)),
                    F("mix_factor", "Mix Factor", .number(step: 0.01, unit: .none, min: 0, max: 1)),
                    F("use_vert_data", "Vertex Data", .toggle, panel: "Vertex Data"),
                    F("data_types_verts", "Data Types", .flags([
                        C("VGROUP_WEIGHTS", "Vertex Groups"), C("BEVEL_WEIGHT_VERT", "Bevel Weight"),
                        C("COLOR_VERTEX", "Colors")]), panel: "Vertex Data"),
                    F("vert_mapping", "Mapping", .choice([
                        C("TOPOLOGY", "Topology"), C("NEAREST", "Nearest Vertex"),
                        C("EDGE_NEAREST", "Nearest Edge Vertex"),
                        C("EDGEINTERP_NEAREST", "Nearest Edge Interpolated"),
                        C("POLY_NEAREST", "Nearest Face Vertex"),
                        C("POLYINTERP_NEAREST", "Nearest Face Interpolated"),
                        C("POLYINTERP_VNORPROJ", "Projected Face Interpolated")]), panel: "Vertex Data"),
                    F("use_edge_data", "Edge Data", .toggle, panel: "Edge Data"),
                    F("data_types_edges", "Data Types", .flags([
                        C("SHARP_EDGE", "Sharp"), C("SEAM", "UV Seam"), C("CREASE", "Crease"),
                        C("BEVEL_WEIGHT_EDGE", "Bevel Weight"), C("FREESTYLE_EDGE", "Freestyle")]),
                      panel: "Edge Data"),
                    F("edge_mapping", "Mapping", .choice([
                        C("TOPOLOGY", "Topology"), C("VERT_NEAREST", "Nearest Vertices"),
                        C("NEAREST", "Nearest Edge"), C("POLY_NEAREST", "Nearest Face Edge"),
                        C("EDGEINTERP_VNORPROJ", "Projected Edge Interpolated")]), panel: "Edge Data"),
                    F("use_loop_data", "Face Corner Data", .toggle, panel: "Face Corner Data"),
                    F("data_types_loops", "Data Types", .flags([
                        C("CUSTOM_NORMAL", "Custom Normals"), C("COLOR_CORNER", "Colors"), C("UV", "UVs")]),
                      panel: "Face Corner Data"),
                    F("loop_mapping", "Mapping", .choice([
                        C("TOPOLOGY", "Topology"),
                        C("NEAREST_NORMAL", "Nearest Corner and Best Matching Normal"),
                        C("NEAREST_POLYNOR", "Nearest Corner and Best Matching Face Normal"),
                        C("NEAREST_POLY", "Nearest Corner of Nearest Face"),
                        C("POLYINTERP_NEAREST", "Nearest Face Interpolated"),
                        C("POLYINTERP_LNORPROJ", "Projected Face Interpolated")]), panel: "Face Corner Data"),
                    F("use_poly_data", "Face Data", .toggle, panel: "Face Data"),
                    F("data_types_polys", "Data Types", .flags([
                        C("SMOOTH", "Smooth"), C("FREESTYLE_FACE", "Freestyle Mark")]), panel: "Face Data"),
                    F("poly_mapping", "Mapping", .choice([
                        C("TOPOLOGY", "Topology"), C("NEAREST", "Nearest Face"),
                        C("NORMAL", "Best Normal-Matching"),
                        C("POLYINTERP_PNORPROJ", "Projected Face Interpolated")]), panel: "Face Data")]
        case .normalEdit:
            return [F("mode", "Mode", .choice([C("RADIAL", "Radial"), C("DIRECTIONAL", "Directional")])),
                    F("target", "Target", .object(types: nil)),
                    F("use_direction_parallel", "Parallel Normals", .toggle),
                    F("mix_mode", "Mix Mode", .choice([C("COPY", "Copy"), C("ADD", "Add"),
                                                       C("SUB", "Subtract"), C("MUL", "Multiply")]),
                      panel: "Mix"),
                    F("mix_factor", "Mix Factor", .number(step: 0.01, unit: .none, min: 0, max: 1), panel: "Mix"),
                    F("mix_limit", "Max Angle", .number(step: 0.01, unit: .degrees, min: 0, max: .pi),
                      panel: "Mix"),
                    F("no_polynors_fix", "Lock Polygon Normals", .toggle, panel: "Mix"),
                    F("offset", "Offset", .vector3(step: 0.01), panel: "Offset")]
        case .mask:
            return [F("mode", "Mode", .choice([C("VERTEX_GROUP", "Vertex Group"), C("ARMATURE", "Armature")])),
                    F("armature", "Armature", .object(types: ["ARMATURE"])),
                    F("use_smooth", "Smooth", .toggle),
                    F("threshold", "Threshold", .number(step: 0.01, unit: .none, min: 0, max: 1))]
        case .build:
            return [F("frame_start", "Start Frame", .number(step: 1, unit: .frames, min: -1048574, max: 1048574)),
                    F("frame_duration", "Length", .number(step: 1, unit: .frames, min: 1, max: 1048574)),
                    F("use_reverse", "Reversed", .toggle),
                    F("use_random_order", "Randomize", .toggle, panel: "Randomize"),
                    F("seed", "Seed", .integer(1...1048574), panel: "Randomize")]
        default:
            return []
        }
    }
}

public extension Modifier {
    /// A declared setting as Blender sent it, or nil when the record did not
    /// carry it.
    func setting(_ key: String) -> String? { values[key] }

    /// The choices Blender takes for `field` now. Data Transfer's Mix Mode is
    /// Blender's one dynamic list here (`rna_DataTransferModifier_mix_mode_itemf`):
    /// Replace always; Above and Below Threshold when a picked data type
    /// supports a threshold; Mix, Add, Subtract and Multiply when one
    /// supports mixing (`BKE_object_data_transfer_get_dttypes_capacity`).
    /// Measured: with no data type picked, `mix_mode = 'ABOVE_THRESHOLD'`
    /// raised "enum not found in ('REPLACE')".
    func choices(for field: ModifierField) -> [ModifierField.Choice] {
        guard case .choice(let all) = field.kind else { return [] }
        guard kind == .dataTransfer, field.key == "mix_mode" else { return all }
        var types = Set<String>()
        for (toggle, key) in [("use_vert_data", "data_types_verts"), ("use_edge_data", "data_types_edges"),
                              ("use_loop_data", "data_types_loops"), ("use_poly_data", "data_types_polys")]
        where flag(toggle) == true {
            types.formUnion(flagSet(key))
        }
        let mixing: Set<String> = ["VGROUP_WEIGHTS", "COLOR_VERTEX", "COLOR_CORNER", "CUSTOM_NORMAL"]
        let threshold: Set<String> = ["VGROUP_WEIGHTS", "COLOR_VERTEX", "COLOR_CORNER", "SHARP_EDGE", "SEAM",
                                      "FREESTYLE_EDGE", "SMOOTH", "FREESTYLE_FACE"]
        var allowed: Set<String> = ["REPLACE"]
        if !types.isDisjoint(with: threshold) { allowed.formUnion(["ABOVE_THRESHOLD", "BELOW_THRESHOLD"]) }
        if !types.isDisjoint(with: mixing) { allowed.formUnion(["MIX", "ADD", "SUB", "MUL"]) }
        return all.filter { allowed.contains($0.identifier) }
    }

    /// The setting as a number, a switch or a set — nil when Blender did not
    /// send it or it does not parse.
    func number(_ key: String) -> Float? { values[key].flatMap(Float.init) }
    func flag(_ key: String) -> Bool? { values[key].map { $0 == "1" || $0 == "True" } }
    func flagSet(_ key: String) -> Set<String> { ModifierField.flagSet(values[key] ?? "") }
}

/// Blender's Add Modifier menu (`OBJECT_MT_modifier_add` and its Edit,
/// Generate, Deform, Normals, Physics and Color menus in 5.2.1's
/// properties_data_modifier.py), by object type: every row Blender lists, in
/// its order, with its words.
///
/// The menus' `template_modifier_asset_menu_items` and the root catalogs add
/// node groups from asset libraries, which the device's Blender has none of;
/// the three Essentials rows Generate draws by name are listed as `asset`.
public enum ModifierCatalog {
    public struct Row: Hashable, Sendable {
        /// Blender's `Modifier.type`, or the node group's name for an asset row.
        public let type: String
        public let label: String
        /// An Essentials node group (`object.modifier_add_node_group`).
        public let asset: Bool

        public init(type: String, label: String, asset: Bool = false) {
            self.type = type
            self.label = label
            self.asset = asset
        }

        /// The kind the app has rows for, or nil for one opened in the Data
        /// API browser.
        public var kind: ModifierKind? { asset ? nil : ModifierKind.modelled(type) }

        /// Whether the simulator's stand-in can add it: the kinds its Swift
        /// engine models (`ModifierKind(bpyName:)` in EmbeddedBpyRuntime.swift),
        /// which are the modelled ones but Curve — the stand-in keeps a Curve
        /// modifier of its own — and Geometry Nodes.
        public var simulatorCanAdd: Bool {
            guard let kind else { return false }
            return kind != .curve && kind != .geometryNodes
        }
    }

    public struct Category: Hashable, Sendable {
        public let name: String
        public let rows: [Row]
    }

    /// The name of each modifier type as Blender's RNA enum gives it, which
    /// is what the menu shows (`MODIFIER_TYPES_TO_LABELS`).
    public static let labels: [String: String] = [
        "DATA_TRANSFER": "Data Transfer", "MESH_CACHE": "Mesh Cache",
        "MESH_SEQUENCE_CACHE": "Mesh Sequence Cache", "UV_PROJECT": "UV Project", "UV_WARP": "UV Warp",
        "VERTEX_WEIGHT_EDIT": "Vertex Weight Edit", "VERTEX_WEIGHT_MIX": "Vertex Weight Mix",
        "VERTEX_WEIGHT_PROXIMITY": "Vertex Weight Proximity",
        "ARRAY": "Array", "BEVEL": "Bevel", "BOOLEAN": "Boolean", "BUILD": "Build",
        "DECIMATE": "Decimate", "EDGE_SPLIT": "Edge Split", "NODES": "Geometry Nodes", "MASK": "Mask",
        "MIRROR": "Mirror", "MESH_TO_VOLUME": "Mesh to Volume", "MULTIRES": "Multiresolution",
        "REMESH": "Remesh", "SCREW": "Screw", "SKIN": "Skin", "SOLIDIFY": "Solidify",
        "SUBSURF": "Subdivision Surface", "TRIANGULATE": "Triangulate", "VOLUME_TO_MESH": "Volume to Mesh",
        "WELD": "Weld", "WIREFRAME": "Wireframe",
        "ARMATURE": "Armature", "CAST": "Cast", "CURVE": "Curve", "DISPLACE": "Displace", "HOOK": "Hook",
        "LAPLACIANDEFORM": "Laplacian Deform", "LATTICE": "Lattice", "MESH_DEFORM": "Mesh Deform",
        "SHRINKWRAP": "Shrinkwrap", "SIMPLE_DEFORM": "Simple Deform", "SMOOTH": "Smooth",
        "CORRECTIVE_SMOOTH": "Smooth Corrective", "LAPLACIANSMOOTH": "Smooth Laplacian",
        "SURFACE_DEFORM": "Surface Deform", "WARP": "Warp", "WAVE": "Wave",
        "VOLUME_DISPLACE": "Volume Displace", "NORMAL_EDIT": "Normal Edit",
        "WEIGHTED_NORMAL": "Weighted Normal", "CLOTH": "Cloth", "COLLISION": "Collision",
        "DYNAMIC_PAINT": "Dynamic Paint", "EXPLODE": "Explode", "FLUID": "Fluid", "OCEAN": "Ocean",
        "PARTICLE_INSTANCE": "Particle Instance", "PARTICLE_SYSTEM": "Particle System",
        "SOFT_BODY": "Soft Body",
        "GREASE_PENCIL_TEXTURE": "Texture Mapping", "GREASE_PENCIL_TIME": "Time Offset",
        "GREASE_PENCIL_VERTEX_WEIGHT_PROXIMITY": "Vertex Weight Proximity",
        "GREASE_PENCIL_VERTEX_WEIGHT_ANGLE": "Vertex Weight Angle",
        "GREASE_PENCIL_ARRAY": "Array", "GREASE_PENCIL_BUILD": "Build", "GREASE_PENCIL_DASH": "Dot Dash",
        "GREASE_PENCIL_ENVELOPE": "Envelope", "GREASE_PENCIL_LENGTH": "Length", "LINEART": "Line Art",
        "GREASE_PENCIL_MIRROR": "Mirror", "GREASE_PENCIL_MULTIPLY": "Multiple Strokes",
        "GREASE_PENCIL_OUTLINE": "Outline", "GREASE_PENCIL_SIMPLIFY": "Simplify",
        "GREASE_PENCIL_SUBDIV": "Subdivide", "GREASE_PENCIL_ARMATURE": "Armature",
        "GREASE_PENCIL_HOOK": "Hook", "GREASE_PENCIL_LATTICE": "Lattice", "GREASE_PENCIL_NOISE": "Noise",
        "GREASE_PENCIL_OFFSET": "Offset", "GREASE_PENCIL_SHRINKWRAP": "Shrinkwrap",
        "GREASE_PENCIL_SMOOTH": "Smooth", "GREASE_PENCIL_THICKNESS": "Thickness",
        "GREASE_PENCIL_COLOR": "Hue/Saturation", "GREASE_PENCIL_OPACITY": "Opacity",
        "GREASE_PENCIL_TINT": "Tint",
    ]

    static func row(_ type: String, text: String? = nil) -> Row {
        Row(type: type, label: text ?? labels[type] ?? Modifier.label(forType: type))
    }

    /// Geometry Nodes, after a separator, on the types that take one.
    public static func geometryNodes(on type: String) -> Row? {
        ["EMPTY", "MESH", "CURVE", "CURVES", "FONT", "VOLUME", "POINTCLOUD", "GREASEPENCIL"].contains(type)
            ? row("NODES") : nil
    }

    /// The categories Add Modifier shows on an object of Blender type `type`,
    /// each with its rows, as Blender's `draw` functions build them.
    public static func menu(for type: String) -> [Category] {
        let mesh = type == "MESH", gp = type == "GREASEPENCIL"
        let curveLike: Set<String> = ["MESH", "CURVE", "FONT", "SURFACE"]
        let withLattice: Set<String> = ["MESH", "CURVE", "FONT", "SURFACE", "LATTICE"]
        var categories: [Category] = []

        if ["MESH", "CURVE", "CURVES", "FONT", "SURFACE", "LATTICE", "GREASEPENCIL", "POINTCLOUD"].contains(type) {
            var rows: [Row] = []
            if mesh { rows.append(row("DATA_TRANSFER")) }
            if withLattice.contains(type) { rows.append(row("MESH_CACHE")) }
            if ["MESH", "CURVE", "CURVES", "FONT", "POINTCLOUD"].contains(type) { rows.append(row("MESH_SEQUENCE_CACHE")) }
            if mesh {
                rows += ["UV_PROJECT", "UV_WARP", "VERTEX_WEIGHT_EDIT", "VERTEX_WEIGHT_MIX",
                         "VERTEX_WEIGHT_PROXIMITY"].map { row($0) }
            }
            if gp {
                rows += ["GREASE_PENCIL_TEXTURE", "GREASE_PENCIL_TIME", "GREASE_PENCIL_VERTEX_WEIGHT_PROXIMITY",
                         "GREASE_PENCIL_VERTEX_WEIGHT_ANGLE"].map { row($0) }
            }
            categories.append(Category(name: "Edit", rows: rows))
        }
        if ["MESH", "CURVE", "FONT", "SURFACE", "VOLUME", "GREASEPENCIL"].contains(type) {
            var rows: [Row] = []
            let c = curveLike.contains(type)
            if c {
                rows.append(Row(type: "Array", label: "Array", asset: true))
                // Blender 5.2's menu names the modifier "Array (Legacy)"
                // beside the node group; its type's name stays "Array".
                rows.append(row("ARRAY", text: "Array (Legacy)"))
                rows.append(row("BEVEL"))
            }
            if mesh { rows.append(row("BOOLEAN")) }
            if c {
                rows.append(row("BUILD"))
                rows.append(Row(type: "Curve to Tube", label: "Curve to Tube", asset: true))
                rows += [row("DECIMATE"), row("EDGE_SPLIT")]
            }
            if mesh { rows.append(row("MASK")) }
            if c { rows.append(row("MIRROR")) }
            if type == "VOLUME" { rows.append(row("MESH_TO_VOLUME")) }
            if mesh { rows.append(row("MULTIRES")) }
            if c {
                rows.append(row("REMESH"))
                rows.append(Row(type: "Scatter on Surface", label: "Scatter on Surface", asset: true))
                rows.append(row("SCREW"))
            }
            if mesh { rows.append(row("SKIN")) }
            if c { rows += [row("SOLIDIFY"), row("SUBSURF"), row("TRIANGULATE")] }
            if mesh { rows.append(row("VOLUME_TO_MESH")) }
            if c { rows.append(row("WELD")) }
            if mesh { rows.append(row("WIREFRAME")) }
            if gp {
                rows += ["GREASE_PENCIL_ARRAY", "GREASE_PENCIL_BUILD", "GREASE_PENCIL_DASH",
                         "GREASE_PENCIL_ENVELOPE", "GREASE_PENCIL_LENGTH", "LINEART", "GREASE_PENCIL_MIRROR",
                         "GREASE_PENCIL_MULTIPLY", "GREASE_PENCIL_OUTLINE", "GREASE_PENCIL_SIMPLIFY",
                         "GREASE_PENCIL_SUBDIV"].map { row($0) }
            }
            categories.append(Category(name: "Generate", rows: rows))
        }
        if ["MESH", "CURVE", "FONT", "SURFACE", "LATTICE", "VOLUME", "GREASEPENCIL"].contains(type) {
            var rows: [Row] = []
            let l = withLattice.contains(type)
            if l { rows += [row("ARMATURE"), row("CAST"), row("CURVE")] }
            if mesh { rows.append(row("DISPLACE")) }
            if l { rows.append(row("HOOK")) }
            if mesh { rows.append(row("LAPLACIANDEFORM")) }
            if l { rows += [row("LATTICE"), row("MESH_DEFORM"), row("SHRINKWRAP"), row("SIMPLE_DEFORM")] }
            if curveLike.contains(type) { rows.append(row("SMOOTH")) }
            if mesh { rows += [row("CORRECTIVE_SMOOTH"), row("LAPLACIANSMOOTH"), row("SURFACE_DEFORM")] }
            if l { rows += [row("WARP"), row("WAVE")] }
            if type == "VOLUME" { rows.append(row("VOLUME_DISPLACE")) }
            if gp {
                rows += ["GREASE_PENCIL_ARMATURE", "GREASE_PENCIL_HOOK", "GREASE_PENCIL_LATTICE",
                         "GREASE_PENCIL_NOISE", "GREASE_PENCIL_OFFSET", "GREASE_PENCIL_SHRINKWRAP",
                         "GREASE_PENCIL_SMOOTH", "GREASE_PENCIL_THICKNESS"].map { row($0) }
            }
            categories.append(Category(name: "Deform", rows: rows))
        }
        if mesh {
            categories.append(Category(name: "Normals", rows: [row("NORMAL_EDIT"), row("WEIGHTED_NORMAL")]))
        }
        if withLattice.contains(type) {
            var rows: [Row] = []
            if mesh {
                rows += ["CLOTH", "COLLISION", "DYNAMIC_PAINT", "EXPLODE", "FLUID", "OCEAN",
                         "PARTICLE_INSTANCE", "PARTICLE_SYSTEM"].map { row($0) }
            }
            rows.append(row("SOFT_BODY"))
            categories.append(Category(name: "Physics", rows: rows))
        }
        if gp {
            categories.append(Category(name: "Color", rows: [row("GREASE_PENCIL_COLOR"),
                                                             row("GREASE_PENCIL_OPACITY"),
                                                             row("GREASE_PENCIL_TINT")]))
        }
        return categories
    }

    /// Every row, the categories' then Geometry Nodes.
    public static func rows(for type: String) -> [Row] {
        menu(for: type).flatMap(\.rows) + (geometryNodes(on: type).map { [$0] } ?? [])
    }
}

/// The buttons the declared rows carry: Blender's operators, run through
/// `_blenderkit_modifiers.run`, which checks what each needs first.
public enum ModifierOperation: String, CaseIterable, Sendable {
    case bindSurface = "bind_surface", bindMesh = "bind_mesh", generate
    case hookReset = "hook_reset", hookRecenter = "hook_recenter", hookSelect = "hook_select"
    case hookAssign = "hook_assign"
    case skinRoot = "skin_root", skinLooseMark = "skin_loose_mark", skinLooseClear = "skin_loose_clear"
    case skinEqualize = "skin_equalize", skinArmature = "skin_armature"

    /// The kind whose row has the button.
    public var kind: ModifierKind {
        switch self {
        case .bindSurface: return .surfaceDeform
        case .bindMesh: return .meshDeform
        case .generate: return .dataTransfer
        case .hookReset, .hookRecenter, .hookSelect, .hookAssign: return .hook
        default: return .skin
        }
    }

    /// The button's words in Blender's panel. Bind reads Unbind while bound.
    public func label(bound: Bool = false) -> String {
        switch self {
        case .bindSurface, .bindMesh: return bound ? "Unbind" : "Bind"
        case .generate: return "Generate Data Layers"
        case .hookReset: return "Reset"
        case .hookRecenter: return "Recenter"
        case .hookSelect: return "Select"
        case .hookAssign: return "Assign"
        case .skinRoot: return "Mark Root"
        case .skinLooseMark: return "Mark Loose"
        case .skinLooseClear: return "Clear Loose"
        case .skinEqualize: return "Equalize Radii"
        case .skinArmature: return "Create Armature"
        }
    }

    /// The operator's own name, which is Blender's undo step for it.
    public var undo: String {
        switch self {
        case .bindSurface: return "Surface Deform Bind"
        case .bindMesh: return "Mesh Deform Bind"
        case .generate: return "Transfer Mesh Data Layout"
        case .hookReset: return "Reset Hook"
        case .hookRecenter: return "Recenter Hook"
        case .hookSelect: return "Select Hook"
        case .hookAssign: return "Assign to Hook"
        case .skinRoot: return "Skin Root Mark"
        case .skinLooseMark, .skinLooseClear: return "Skin Mark/Clear Loose"
        case .skinEqualize: return "Skin Radii Equalize"
        case .skinArmature: return "Skin Armature Create"
        }
    }

    /// Blender's panel shows these in Edit Mode only (the Hook's four, the
    /// Skin's marks); the others in any mode, and they run in Object Mode.
    public var editModeOnly: Bool {
        switch self {
        case .hookReset, .hookRecenter, .hookSelect, .hookAssign,
             .skinRoot, .skinLooseMark, .skinLooseClear, .skinEqualize:
            return true
        default:
            return false
        }
    }

    public func python(_ modifier: String) -> String {
        "import _blenderkit_modifiers\n_blenderkit_modifiers.run(\(Bpy.quote(rawValue)), \(Bpy.quote(modifier)))"
    }
}

public extension Bpy {
    /// What Add Modifier ▸ `row` sends on an object showing `mesh`: the
    /// vertex budget's price first (`_blenderkit_budget.price_add`), which
    /// refuses a modifier whose result would pass it — every kind, at
    /// Blender's own defaults for it (round 4's fix round: the price used to
    /// know only the kinds on a list) — then the add, Remesh's floor with it
    /// and in its price. An Essentials row loads its node group through
    /// `_blenderkit_modifiers.add_asset`.
    static func addModifierRow(_ row: ModifierCatalog.Row, on mesh: MeshData) -> [String] {
        if row.asset {
            return ["import _blenderkit_modifiers\n_blenderkit_modifiers.add_asset(\(quote(row.type)))"]
        }
        if let kind = row.kind {
            return addModifier(kind, on: mesh)
        }
        return [priceAdd(row.type), addModifier(row.type)]
    }
}
