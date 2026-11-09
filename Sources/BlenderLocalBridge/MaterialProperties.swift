import Foundation
import simd

/// Properties ▸ Material, as Blender 5.x draws it, read from Blender
/// (`_blenderkit_material.state`, one JSON line): the active object's
/// material slots, every material in the file for the browse menu, and the
/// active slot's material — its Surface and Volume as the output node's
/// inputs, its Settings and its Viewport Display.
///
/// Nothing here is the app's own: every control of the tab sends one
/// `MaterialBpy.Command` and the tab shows what comes back.
public struct MaterialPanelState: Decodable, Equatable, Sendable {

    /// A value as Blender holds it: a number, a switch, a name or a vector
    /// (a colour is four linear components).
    public enum Value: Decodable, Equatable, Sendable {
        case number(Double)
        case bool(Bool)
        case text(String)
        case vector([Double])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let v = try? c.decode([Double].self) { self = .vector(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a value Blender holds")
        }

        public var number: Double? { if case .number(let d) = self { return d }; return nil }
        public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
        public var text: String? { if case .text(let s) = self { return s }; return nil }
        public var vector: [Double]? { if case .vector(let v) = self { return v }; return nil }
    }

    public struct Slot: Decodable, Equatable, Sendable {
        public var material: String?
        /// Blender's `MaterialSlot.link`: DATA or OBJECT.
        public var link: String
        /// sRGB, for the list's swatch; nil for an empty slot.
        public var swatch: [Double]?
    }

    /// A material of the file, as the browse menu lists it.
    public struct Listed: Decodable, Equatable, Sendable {
        public var name: String
        public var users: Int
        public var fakeUser: Bool
        public var swatch: [Double]?

        enum CodingKeys: String, CodingKey { case name, users, fakeUser = "fake_user", swatch }
    }

    public struct Input: Decodable, Equatable, Sendable {
        public var id: String
        /// The socket's index on its node: the Info log's `inputs[n]`.
        public var index: Int
        public var label: String
        /// Blender's socket type: RGBA, VALUE, VECTOR, BOOLEAN, INT, STRING,
        /// SHADER, MENU.
        public var type: String
        public var hideValue: Bool
        public var inactive: Bool
        /// The linked node's name as Blender's link button says it, or nil.
        public var link: String?
        public var value: Value?
        public var subtype: String?
        /// The range the interface drags within (the declaration's).
        public var min: Double?
        public var max: Double?

        enum CodingKeys: String, CodingKey {
            case id, index, label, type, hideValue = "hide_value", inactive, link, value, subtype, min, max
        }

        /// A value clamped to the range Blender's interface drags within.
        public func clamped(_ v: Double) -> Double {
            guard v.isFinite else { return value?.number ?? 0 }
            var r = v
            if let min { r = Swift.max(r, min) }
            if let max { r = Swift.min(r, max) }
            return r
        }
    }

    /// A node's own enum setting (`distribution`, `subsurface_method`, …).
    public struct Prop: Decodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var value: String
        public var options: [[String]]

        /// The option's name Blender shows for `identifier`.
        public func name(of identifier: String) -> String {
            options.first { $0.first == identifier }.flatMap { $0.count > 1 ? $0[1] : nil } ?? identifier
        }
    }

    public indirect enum Item: Decodable, Equatable, Sendable {
        case input(Input)
        case prop(Prop)
        case panel(label: String, open: Bool, items: [Item])

        enum CodingKeys: String, CodingKey { case kind, label, open, items }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "input": self = .input(try Input(from: decoder))
            case "prop": self = .prop(try Prop(from: decoder))
            case "panel":
                self = .panel(label: try c.decode(String.self, forKey: .label),
                              open: (try? c.decode(Bool.self, forKey: .open)) ?? false,
                              items: try c.decode([Item].self, forKey: .items))
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown item")
            }
        }
    }

    public struct Node: Decodable, Equatable, Sendable {
        public var name: String
        public var type: String
        public var label: String
        public var items: [Item]

        /// Every input, panels opened up.
        public var inputs: [Input] {
            func walk(_ items: [Item]) -> [Input] {
                items.flatMap { item -> [Input] in
                    switch item {
                    case .input(let i): return [i]
                    case .prop: return []
                    case .panel(_, _, let inner): return walk(inner)
                    }
                }
            }
            return walk(items)
        }
    }

    /// The Material Output's Surface or Volume, as its panel draws it.
    public struct SocketView: Decodable, Equatable, Sendable {
        /// The output node's name; nil with no output ("No output node").
        public var output: String?
        public var socket: String?
        public var missing: Bool?
        public var link: String?
        public var node: Node?
    }

    public struct Viewport: Decodable, Equatable, Sendable {
        /// Linear RGBA.
        public var color: [Double]
        public var metallic: Double
        public var roughness: Double
    }

    public struct Material: Decodable, Equatable, Sendable {
        public var name: String
        /// Blender's real users: its user button shows the number past one.
        public var users: Int
        public var fakeUser: Bool
        public var library: Bool
        public var viewport: Viewport
        public var settings: [String: Value]
        public var surface: SocketView
        public var volume: SocketView

        enum CodingKeys: String, CodingKey {
            case name, users, fakeUser = "fake_user", library, viewport, settings, surface, volume
        }
    }

    public var object: String?
    public var type: String?
    public var mode: String?
    public var slots: [Slot]
    /// `active_material_index`; -1 with no slot.
    public var active: Int
    public var materials: [Listed]
    public var material: Material?
    public var hasMaterials: Bool

    enum CodingKeys: String, CodingKey {
        case object, type, mode, slots, active, materials, material, hasMaterials = "has_materials"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        object = try c.decodeIfPresent(String.self, forKey: .object)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        slots = try c.decodeIfPresent([Slot].self, forKey: .slots) ?? []
        active = try c.decodeIfPresent(Int.self, forKey: .active) ?? -1
        materials = try c.decodeIfPresent([Listed].self, forKey: .materials) ?? []
        material = try c.decodeIfPresent(Material.self, forKey: .material)
        hasMaterials = try c.decodeIfPresent(Bool.self, forKey: .hasMaterials) ?? false
    }

    /// The last line of `text` that is a state, as `_blenderkit_material.state` prints it.
    public static func parse(_ text: String) -> MaterialPanelState? {
        SculptJSON.last(MaterialPanelState.self, in: text)
    }

    public var editing: Bool { mode == "EDIT" }
    public var activeSlot: Slot? { slots.indices.contains(active) ? slots[active] : nil }
    /// Two or more slots: Blender draws the move arrows then.
    public var isSortable: Bool { slots.count > 1 }
}

/// sRGB and Blender's scene linear, the two ways a colour is written.
public enum ColorSpace {
    /// `srgb_to_linearrgb`: what a picked colour is in Blender.
    public static func linear(_ s: Float) -> Float {
        s <= 0.04045 ? max(s, 0) / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    /// `linearrgb_to_srgb`: what a stored colour looks like in a picker.
    public static func srgb(_ l: Float) -> Float {
        l < 0.0031308 ? max(l, 0) * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    }

    public static func linear(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(linear(c.x), linear(c.y), linear(c.z)) }
    public static func srgb(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(srgb(c.x), srgb(c.y), srgb(c.z)) }
}

/// What each control of Properties ▸ Material sends.
///
/// Each is one `Command`: the Python Blender's Info log would show for it
/// (`call`), the undo step's name — nil where Blender's undo takes nothing
/// back (measured: in Edit Mode a material's values, its settings, a slot
/// added and its link stay changed after Undo, see `_blenderkit_material`) —
/// and what runs: the module's function, held to the conditions Blender's
/// own button is held to.
public enum MaterialBpy {

    public struct Command: Equatable, Sendable {
        public let call: String
        public let undo: String?
        public let executed: String
    }

    static let module = "import _blenderkit_material as _bk_mat"

    private static func command(_ call: String, undo: String?, _ function: String,
                                _ arguments: [String]) -> Command {
        Command(call: call, undo: undo,
                executed: module + "\n_bk_mat.\(function)(\(arguments.joined(separator: ", ")))")
    }

    private static func q(_ s: String) -> String { Bpy.quote(s) }
    public static func f(_ v: Double) -> String {
        guard v.isFinite else { return "0.0" }
        let s = String(format: "%.6g", v)
        return s.contains(".") || s.contains("e") ? s : s + ".0"
    }
    private static func py(_ b: Bool) -> String { b ? "True" : "False" }
    private static func material(_ name: String) -> String { "bpy.data.materials[\(q(name))]" }

    /// The tab's whole state, printed.
    public static func state(object name: String) -> String {
        module + "\nprint(_bk_mat.state(\(q(name))))"
    }

    // MARK: the slot list

    /// A tap on a slot's row: `active_material_index`. No step in Edit
    /// Mode, where Blender's undo leaves the index (measured).
    public static func setActiveSlot(_ index: Int, object name: String, editing: Bool) -> Command {
        command("bpy.context.object.active_material_index = \(index)",
                undo: editing ? nil : "Active Material Index", "set_active_slot", [q(name), "\(index)"])
    }

    public static func addSlot(object name: String, editing: Bool) -> Command {
        command("bpy.ops.object.material_slot_add()", undo: editing ? nil : "Add Material Slot",
                "slot_add", [q(name)])
    }

    public static func removeSlot(object name: String) -> Command {
        command("bpy.ops.object.material_slot_remove()", undo: "Remove Material Slot", "slot_remove", [q(name)])
    }

    public static func moveSlot(up: Bool, object name: String, editing: Bool) -> Command {
        let direction = up ? "UP" : "DOWN"
        return command("bpy.ops.object.material_slot_move(direction='\(direction)')",
                       undo: editing ? nil : "Move Material", "slot_move", [q(name), "'\(direction)'"])
    }

    /// Edit Mode's Assign: the selected faces take the active slot.
    public static func assign(object name: String) -> Command {
        command("bpy.ops.object.material_slot_assign()", undo: "Assign Material Slot", "assign", [q(name)])
    }

    public static func select(_ select: Bool, object name: String) -> Command {
        command("bpy.ops.object.material_slot_\(select ? "select" : "deselect")()",
                undo: select ? "Select Material Slot" : "Deselect Material Slot",
                "select", [q(name), py(select)])
    }

    // MARK: Material Specials (MATERIAL_MT_context_menu)

    /// The rows of Material Specials, in Blender's order, by its names.
    public enum Special: String, CaseIterable, Sendable {
        case copyMaterial = "Copy Material"
        case copyToSelected = "Copy Material to Selected"
        case pasteMaterial = "Paste Material"
        case removeUnused = "Remove Unused Slots"
        case removeAll = "Remove All Materials"

        public var call: String {
            switch self {
            case .copyMaterial:   return "bpy.ops.material.copy()"
            case .copyToSelected: return "bpy.ops.object.material_slot_copy()"
            case .pasteMaterial:  return "bpy.ops.material.paste()"
            case .removeUnused:   return "bpy.ops.object.material_slot_remove_unused()"
            case .removeAll:      return "bpy.ops.object.material_slot_remove_all()"
            }
        }

        var function: String {
            switch self {
            case .copyMaterial:   return "copy_material"
            case .copyToSelected: return "copy_to_selected"
            case .pasteMaterial:  return "paste_material"
            case .removeUnused:   return "remove_unused"
            case .removeAll:      return "remove_all"
            }
        }

        /// Blender's polls: the removals fail theirs in Edit Mode ("Unable
        /// to remove material slot in edit mode").
        public func available(editing: Bool) -> Bool {
            !(editing && (self == .removeUnused || self == .removeAll))
        }

        /// Copy changes nothing in the file, so no step; the rest are
        /// Blender's operators' own names, and nothing in Edit Mode, where
        /// Blender's undo does not hold a material.
        public func undo(editing: Bool) -> String? {
            self == .copyMaterial || editing ? nil : rawValue
        }
    }

    public static func special(_ row: Special, object name: String, editing: Bool) -> Command {
        command(row.call, undo: row.undo(editing: editing), row.function, [q(name)])
    }

    // MARK: the material datablock

    /// New: Blender's `material.new` — a new material in an empty slot, a
    /// copy of the slot's material in a full one.
    public static func newMaterial(object name: String, editing: Bool) -> Command {
        command("bpy.ops.material.new()", undo: editing ? nil : "New Material", "new_material", [q(name)])
    }

    /// The browse menu: an existing material into the active slot. The step
    /// is the browse button's own words, as Blender names it (its tooltip:
    /// `template_id_browse_tip`); none in Edit Mode, where Blender's undo
    /// leaves the slot as it was set (measured).
    public static func browse(_ materialName: String, object name: String, editing: Bool) -> Command {
        command("bpy.context.object.active_material = \(material(materialName))",
                undo: editing ? nil : "Browse Material to be linked", "browse", [q(name), q(materialName)])
    }

    /// Blender's X: the slot emptied, the material kept ("Unlink Data-Block").
    public static func unlink(object name: String, editing: Bool) -> Command {
        command("bpy.context.object.active_material = None", undo: editing ? nil : "Unlink Data-Block",
                "unlink", [q(name)])
    }

    /// The user count, tapped: a copy of the shared material into this slot.
    public static func makeSingleUser(_ materialName: String, object name: String, editing: Bool) -> Command {
        command("bpy.context.object.active_material = \(material(materialName)).copy()",
                undo: editing ? nil : "Make Single User", "single_user", [q(name)])
    }

    public static func fakeUser(_ materialName: String, _ on: Bool, editing: Bool) -> Command {
        command("\(material(materialName)).use_fake_user = \(py(on))", undo: editing ? nil : "Fake User",
                "fake_user", [q(materialName), py(on)])
    }

    public static func rename(_ materialName: String, to wanted: String, editing: Bool) -> Command {
        command("\(material(materialName)).name = \(q(wanted))", undo: editing ? nil : "Name",
                "rename", [q(materialName), q(wanted)])
    }

    /// The slot's Link: Data or Object.
    public static func link(_ link: String, slot: Int, object name: String, editing: Bool) -> Command {
        command("bpy.context.object.material_slots[\(slot)].link = '\(link)'", undo: editing ? nil : "Link",
                "set_link", [q(name), "'\(link)'"])
    }

    // MARK: Surface and Volume

    /// Blender's Surface and Volume menus: every shader node, by its name,
    /// in the order `uiTemplateNodeLink` lists them. Held to
    /// `_blenderkit_material.SHADERS` and to Blender by the check.
    public static let shaders: [(type: String, name: String)] = [
        ("ShaderNodeAddShader", "Add Shader"), ("ShaderNodeBackground", "Background"),
        ("ShaderNodeBsdfDiffuse", "Diffuse BSDF"), ("ShaderNodeEmission", "Emission"),
        ("ShaderNodeBsdfGlass", "Glass BSDF"), ("ShaderNodeBsdfAnisotropic", "Glossy BSDF"),
        ("ShaderNodeBsdfHair", "Hair BSDF"), ("ShaderNodeHoldout", "Holdout"),
        ("ShaderNodeBsdfMetallic", "Metallic BSDF"), ("ShaderNodeMixShader", "Mix Shader"),
        ("ShaderNodeBsdfPrincipled", "Principled BSDF"), ("ShaderNodeBsdfHairPrincipled", "Principled Hair BSDF"),
        ("ShaderNodeVolumePrincipled", "Principled Volume"), ("ShaderNodeBsdfRayPortal", "Ray Portal BSDF"),
        ("ShaderNodeBsdfRefraction", "Refraction BSDF"), ("ShaderNodeBsdfSheen", "Sheen BSDF"),
        ("ShaderNodeEeveeSpecular", "Specular BSDF"), ("ShaderNodeSubsurfaceScattering", "Subsurface Scattering"),
        ("ShaderNodeBsdfToon", "Toon BSDF"), ("ShaderNodeBsdfTranslucent", "Translucent BSDF"),
        ("ShaderNodeBsdfTransparent", "Transparent BSDF"), ("ShaderNodeVolumeAbsorption", "Volume Absorption"),
        ("ShaderNodeVolumeCoefficients", "Volume Coefficients"), ("ShaderNodeVolumeScatter", "Volume Scatter"),
    ]

    /// The undo step every change through the menu makes: `ui_node_link`'s
    /// own `ED_undo_push(C, "Node input modify")`.
    public static let nodeInputModify = "Node input modify"

    /// A shader from the Surface (or Volume) menu, replacing what is linked
    /// there as Blender's menu replaces it.
    public static func setShader(_ type: String, socket: String, material materialName: String,
                                 editing: Bool) -> Command {
        command("\(material(materialName)).node_tree.nodes.new(\(q(type)))",
                undo: editing ? nil : nodeInputModify, "set_shader", [q(materialName), q(socket), q(type)])
    }

    /// The menu's Link column: Remove (the nodes) or Disconnect (the link).
    public static func unlinkShader(remove: Bool, socket: String, material materialName: String,
                                    editing: Bool) -> Command {
        command("\(material(materialName)).node_tree.links.remove(…)",
                undo: editing ? nil : nodeInputModify, remove ? "remove" : "disconnect",
                [q(materialName), q(socket)])
    }

    private static func inputPath(_ materialName: String, node: String, index: Int) -> String {
        "\(material(materialName)).node_tree.nodes[\(q(node))].inputs[\(index)].default_value"
    }

    /// A number, a switch or a vector into one input. `value` is Python.
    public static func setInput(_ input: MaterialPanelState.Input, value: String, node: String,
                                material materialName: String, editing: Bool) -> Command {
        command("\(inputPath(materialName, node: node, index: input.index)) = \(value)",
                undo: editing ? nil : input.label, "set_input",
                [q(materialName), q(node), "\(input.index)", value])
    }

    public static func setInput(_ input: MaterialPanelState.Input, number: Double, node: String,
                                material materialName: String, editing: Bool) -> Command {
        let v = input.type == "INT" ? "\(Int(number.rounded()))" : f(input.clamped(number))
        return setInput(input, value: v, node: node, material: materialName, editing: editing)
    }

    public static func setInput(_ input: MaterialPanelState.Input, bool: Bool, node: String,
                                material materialName: String, editing: Bool) -> Command {
        setInput(input, value: py(bool), node: node, material: materialName, editing: editing)
    }

    /// A vector's components, each clamped to the socket's range.
    public static func setInput(_ input: MaterialPanelState.Input, vector: [Double], node: String,
                                material materialName: String, editing: Bool) -> Command {
        let v = "(" + vector.map { f(input.clamped($0)) }.joined(separator: ", ") + ")"
        return setInput(input, value: v, node: node, material: materialName, editing: editing)
    }

    /// A colour picked in sRGB, written linear as Blender keeps it.
    public static func setInput(_ input: MaterialPanelState.Input, srgb: SIMD3<Float>, node: String,
                                material materialName: String, editing: Bool) -> Command {
        setInput(input, value: linearTuple(srgb), node: node, material: materialName, editing: editing)
    }

    /// `(r, g, b)` linear, from an sRGB colour.
    public static func linearTuple(_ srgb: SIMD3<Float>) -> String {
        let l = ColorSpace.linear(srgb)
        return "(\(f(Double(l.x))), \(f(Double(l.y))), \(f(Double(l.z))))"
    }

    /// A node's own setting (Distribution, Subsurface Method, …), by its
    /// RNA name for the step.
    public static func setNodeProp(_ prop: MaterialPanelState.Prop, to value: String, node: String,
                                   material materialName: String, editing: Bool) -> Command {
        command("\(material(materialName)).node_tree.nodes[\(q(node))].\(prop.id) = '\(value)'",
                undo: editing ? nil : prop.label, "set_node_prop",
                [q(materialName), q(node), q(prop.id), q(value)])
    }

    // MARK: Settings and Viewport Display

    /// The Settings panel's rows, by the words Blender draws them with
    /// (properties_material.py, 5.2.1), and their RNA properties.
    public enum Setting: String, CaseIterable, Sendable {
        case passIndex = "pass_index"
        case backfaceCamera = "use_backface_culling"
        case backfaceShadow = "use_backface_culling_shadow"
        case backfaceProbe = "use_backface_culling_lightprobe_volume"
        case displacement = "displacement_method"
        case maxDisplacement = "max_vertex_displacement"
        case transparentShadow = "use_transparent_shadow"
        case renderMethod = "surface_render_method"
        case transparencyOverlap = "use_transparency_overlap"
        case raytraceRefraction = "use_raytrace_refraction"
        case thickness = "thickness_mode"
        case thicknessFromShadow = "use_thickness_from_shadow"
        case volumeIntersection = "volume_intersection_method"

        public var label: String {
            switch self {
            case .passIndex:           return "Pass Index"
            case .backfaceCamera:      return "Camera"
            case .backfaceShadow:      return "Shadow"
            case .backfaceProbe:       return "Light Probe Volume"
            case .displacement:        return "Displacement"
            case .maxDisplacement:     return "Max Distance"
            case .transparentShadow:   return "Transparent Shadows"
            case .renderMethod:        return "Render Method"
            case .transparencyOverlap: return "Transparency Overlap"
            case .raytraceRefraction:  return "Raytraced Transmission"
            case .thickness:           return "Thickness"
            case .thicknessFromShadow: return "From Shadow"
            case .volumeIntersection:  return "Intersection"
            }
        }

        /// An enum's items, as Blender names them (5.2.1's RNA).
        public var options: [(id: String, name: String)] {
            switch self {
            case .displacement:
                return [("BUMP", "Bump Only"), ("DISPLACEMENT", "Displacement Only"),
                        ("BOTH", "Displacement and Bump")]
            case .renderMethod: return [("DITHERED", "Dithered"), ("BLENDED", "Blended")]
            case .thickness: return [("SPHERE", "Sphere"), ("SLAB", "Slab")]
            case .volumeIntersection: return [("FAST", "Fast"), ("ACCURATE", "Accurate")]
            default: return []
            }
        }
    }

    public static func setSetting(_ setting: Setting, _ value: String, material materialName: String,
                                  editing: Bool) -> Command {
        command("\(material(materialName)).\(setting.rawValue) = \(value)",
                undo: editing ? nil : setting.label, "set_material",
                [q(materialName), q(setting.rawValue), value])
    }

    public static func setSetting(_ setting: Setting, bool: Bool, material materialName: String,
                                  editing: Bool) -> Command {
        setSetting(setting, py(bool), material: materialName, editing: editing)
    }

    public static func setSetting(_ setting: Setting, option: String, material materialName: String,
                                  editing: Bool) -> Command {
        setSetting(setting, "'\(option)'", material: materialName, editing: editing)
    }

    /// Pass Index: 0 to 32767 (its RNA range); Max Distance: 0 up.
    public static func setSetting(_ setting: Setting, number: Double, material materialName: String,
                                  editing: Bool) -> Command {
        let v = setting == .passIndex ? "\(Int(min(max(number.rounded(), 0), 32767)))" : f(max(number, 0))
        return setSetting(setting, v, material: materialName, editing: editing)
    }

    /// Viewport Display: Color (picked in sRGB, written linear with its
    /// alpha), Metallic and Roughness (0 to 1).
    public static func setViewportColor(srgb: SIMD4<Float>, material materialName: String,
                                        editing: Bool) -> Command {
        let l = ColorSpace.linear(SIMD3(srgb.x, srgb.y, srgb.z))
        let value = "(\(f(Double(l.x))), \(f(Double(l.y))), \(f(Double(l.z))), \(f(Double(min(max(srgb.w, 0), 1)))))"
        return command("\(material(materialName)).diffuse_color = \(value)", undo: editing ? nil : "Color",
                       "set_material", [q(materialName), q("diffuse_color"), value])
    }

    public static func setViewport(metallic: Bool, _ v: Double, material materialName: String,
                                   editing: Bool) -> Command {
        let key = metallic ? "metallic" : "roughness"
        let value = f(min(max(v, 0), 1))
        return command("\(material(materialName)).\(key) = \(value)",
                       undo: editing ? nil : (metallic ? "Metallic" : "Roughness"),
                       "set_material", [q(materialName), q(key), value])
    }
}

public extension BKScene {
    /// Previews a material's values on every object drawn with it, before
    /// Blender has them: a colour or a number being dragged in the Material
    /// tab shows in the 3D View under the finger, and the commit's mirroring
    /// pass replaces it with what Blender holds. A material is shared, so
    /// every slot of every object using it changes, as it will in Blender.
    func previewMaterial(_ name: String, _ change: (inout MaterialLook) -> Void) {
        for obj in objects where obj.materialLooks.contains(where: { $0.material == name }) {
            var looks = obj.materialLooks
            for i in looks.indices where looks[i].material == name { change(&looks[i]) }
            obj.materialLooks = looks
        }
    }
}
