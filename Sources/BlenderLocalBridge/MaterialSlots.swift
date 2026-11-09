import Foundation
import simd

/// One material slot as the 3D View colours it, read from Blender by the
/// mirror (`_blenderkit_material.look`).
///
/// Solid shading's colour is Blender's default colour type, Material: the
/// material's Viewport Display Color (`diffuse_color`). Material Preview
/// shades with the surface shader's values, as near as one metallic-roughness
/// surface can: Principled BSDF's Base Color, Metallic, Roughness, IOR,
/// Alpha and Emission; Emission's colour as emission; Metallic and Glossy
/// BSDF as metal; Diffuse and the other rough ones without a highlight.
/// An empty slot, or none, draws as Blender's default material.
public struct MaterialLook: Equatable, Sendable {
    /// The material's name; nil for an empty slot.
    public var material: String?
    /// Viewport Display: Color (linear RGBA), Metallic, Roughness.
    public var display: SIMD4<Float>
    public var displayMetallic: Float
    public var displayRoughness: Float
    /// Whether anything is linked into the Material Output's Surface; a
    /// material with nothing there renders black, as Blender's does.
    public var connected: Bool
    /// The surface shader's type (`bl_idname`), "" with none.
    public var shader: String
    /// Linear RGB.
    public var base: SIMD3<Float>
    /// The base colour comes from a link (an Image Texture), which the
    /// texture pass draws where it has the image.
    public var baseLinked: Bool
    public var metallic: Float
    public var roughness: Float
    public var ior: Float
    public var alpha: Float
    public var emission: SIMD3<Float>
    public var strength: Float

    /// Blender's default surface: what an object with no material, or an
    /// empty slot, is drawn with (`BKE_material_default_surface`: 0.8 grey,
    /// roughness 0.5 — its Viewport Display Roughness 0.4).
    public static let `default` = MaterialLook(
        material: nil, display: SIMD4(0.8, 0.8, 0.8, 1), displayMetallic: 0, displayRoughness: 0.4,
        connected: true, shader: "ShaderNodeBsdfPrincipled", base: SIMD3(0.8, 0.8, 0.8), baseLinked: false,
        metallic: 0, roughness: 0.5, ior: 1.5, alpha: 1, emission: .zero, strength: 0)

    public init(material: String?, display: SIMD4<Float>, displayMetallic: Float, displayRoughness: Float,
                connected: Bool, shader: String, base: SIMD3<Float>, baseLinked: Bool, metallic: Float,
                roughness: Float, ior: Float, alpha: Float, emission: SIMD3<Float>, strength: Float) {
        self.material = material; self.display = display; self.displayMetallic = displayMetallic
        self.displayRoughness = displayRoughness; self.connected = connected; self.shader = shader
        self.base = base; self.baseLinked = baseLinked; self.metallic = metallic; self.roughness = roughness
        self.ior = ior; self.alpha = alpha; self.emission = emission; self.strength = strength
    }

    /// Solid's colour: the Viewport Display Color.
    public var solidColour: SIMD4<Float> { SIMD4(display.x, display.y, display.z, 1) }

    /// Material Preview's base colour: black with nothing connected, as
    /// Blender renders it.
    public var previewBase: SIMD4<Float> {
        connected ? SIMD4(base.x, base.y, base.z, alpha) : SIMD4(0, 0, 0, 1)
    }

    /// Material Preview's emission, colour and strength.
    public var previewEmission: SIMD4<Float> {
        SIMD4(emission.x, emission.y, emission.z, connected ? strength : 0)
    }

    /// Reads one slot of `_blenderkit_material.record`; nil for an entry that
    /// is not a slot.
    public static func parse(_ entry: Substring) -> MaterialLook? {
        let f = Modifier.fields(entry)
        guard f["kind"] == "slot" else { return nil }
        if f["none"] == "1" { return .default }
        func numbers(_ key: String) -> [Float] {
            (f[key] ?? "").split(separator: ",").compactMap { Float($0) }.map { $0.isFinite ? $0 : 0 }
        }
        func number(_ key: String, _ fallback: Float) -> Float { numbers(key).first ?? fallback }
        func vec3(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            let v = numbers(key)
            return v.count >= 3 ? SIMD3(v[0], v[1], v[2]) : fallback
        }
        let d = numbers("display")
        let display = d.count >= 4 ? SIMD4(d[0], d[1], d[2], d[3])
            : d.count == 3 ? SIMD4(d[0], d[1], d[2], 1) : MaterialLook.default.display
        return MaterialLook(
            material: f["name"], display: display,
            displayMetallic: number("display_metallic", 0), displayRoughness: number("display_roughness", 0.4),
            connected: f["connected"] != "0", shader: f["shader"] ?? "",
            base: vec3("base", SIMD3(0.8, 0.8, 0.8)), baseLinked: f["base_linked"] == "1",
            metallic: number("metallic", 0), roughness: number("roughness", 0.5), ior: number("ior", 1.5),
            alpha: number("alpha", 1), emission: vec3("emission", .zero), strength: number("strength", 0))
    }

    /// Every slot of a record; an empty record is an object with no slot.
    public static func parseRecord(_ record: String) -> [MaterialLook] {
        guard !record.isEmpty else { return [] }
        return record.split(separator: "|", omittingEmptySubsequences: false).map { parse($0) ?? .default }
    }
}

public extension BKObject {
    /// The look of slot `slot`, as Blender draws it: a material index past
    /// the last slot is drawn with the last slot (`BKE_object_material_get`
    /// clamps it), no slot at all with Blender's default material.
    func materialLook(slot: Int) -> MaterialLook {
        guard !materialLooks.isEmpty else { return .default }
        return materialLooks[min(max(slot, 0), materialLooks.count - 1)]
    }

    /// The slots the drawn triangles use, each with its triangles, when the
    /// object has more than one slot in use: nil means every triangle is
    /// drawn with slot 0's look. The triangle slots must be one per drawn
    /// triangle; a mesh they do not fit (a Multires level, a mesh the mirror
    /// has not caught up with) is drawn with one look.
    func slotRuns() -> [(slot: Int, triangles: [Int])]? {
        let count = mesh.indices.count / 3
        guard materialLooks.count > 1, !triangleSlots.isEmpty, triangleSlots.count == count else { return nil }
        let last = materialLooks.count - 1
        var bySlot: [Int: [Int]] = [:]
        for t in 0..<count {
            bySlot[min(Int(triangleSlots[t]), last), default: []].append(t)
        }
        guard bySlot.count > 1 else { return nil }
        return bySlot.keys.sorted().map { ($0, bySlot[$0]!) }
    }

    /// The slot drawn when the object is drawn with one look: the one every
    /// triangle uses.
    var soleSlot: Int {
        guard let first = triangleSlots.first, triangleSlots.count == mesh.indices.count / 3 else { return 0 }
        return Int(first)
    }
}

public extension SceneMirror {
    /// Installs one object's material slots: its looks (`record`) and each
    /// triangle's slot. Values below 0 are slot 0. True when anything changed.
    @discardableResult
    static func installMaterials(record: String, triangleSlots: UnsafeBufferPointer<Int32>,
                                 on obj: BKObject) -> Bool {
        let looks = MaterialLook.parseRecord(record)
        var changed = false
        if obj.materialLooks != looks {
            obj.materialLooks = looks
            changed = true
        }
        var slots = triangleSlots.map { UInt16(clamping: max(0, Int($0))) }
        if slots.allSatisfy({ $0 == 0 }) { slots = [] }
        if obj.setTriangleSlots(slots) { changed = true }
        return changed
    }

    /// Where `bk_sync_materials` puts what it carries: during a pass on the
    /// object the pass just pushed, outside one on the object of that name on
    /// screen, as `carryShading` does. 1 when taken, 0 when nothing on screen
    /// has the name, -1 for a pass naming an object it did not push.
    @discardableResult
    static func carryMaterials(record: String, triangleSlots: UnsafeBufferPointer<Int32>, named name: String,
                               pass: [BKObject]?, screen: [BKObject],
                               index: ObjectNameIndex = ObjectNameIndex()) -> Int {
        let target: BKObject?
        if let pass {
            target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        } else {
            target = index.object(named: name, in: screen)
        }
        guard let target else { return pass == nil ? 0 : -1 }
        installMaterials(record: record, triangleSlots: triangleSlots, on: target)
        return 1
    }
}
