import Foundation
import simd

// Blender's Grease Pencil (5.x, "GPv3": object type GREASEPENCIL) as the app
// mirrors it: each layer's drawing at the current frame and its onion skins,
// the layers, the material slots and the onion settings
// (`_blenderkit_gpencil.record`). What the viewport draws from it is
// GreasePencilGeometry.swift; what Draw Mode writes back is
// GreasePencilStroke.swift.

/// One drawing: Blender's curves geometry for a keyframe of a layer, as its
/// attributes hold it. `vertexColours` and `fillColours` are empty when the
/// drawing has no such attribute.
public struct GPDrawing: Equatable, Sendable {
    public var positions: [SIMD3<Float>] = []
    public var radii: [Float] = []
    public var opacities: [Float] = []
    public var vertexColours: [SIMD4<Float>] = []
    /// `curve_offsets`: stroke `s` is points `offsets[s] ..< offsets[s + 1]`.
    public var offsets: [Int] = [0]
    public var cyclic: [Bool] = []
    /// The stroke's material slot; -1 for a stroke Blender hides.
    public var materials: [Int] = []
    /// Blender 5.2's `fill_id`: a stroke is filled only when it is not 0.
    public var fillIDs: [Int] = []
    /// Blender 5.2's `hide_stroke`: the stroke's line is not drawn, its fill
    /// is (the Monkey's face).
    public var hideStroke: [Bool] = []
    public var fillColours: [SIMD4<Float>] = []

    public init() {}

    public var pointCount: Int { positions.count }
    public var strokeCount: Int { max(offsets.count - 1, 0) }
    public func points(of stroke: Int) -> Range<Int> { offsets[stroke] ..< offsets[stroke + 1] }
}

/// One of a layer's keyframes, as the timeline and the Layers panel show it.
public struct GPKeyframe: Equatable, Sendable {
    public var frame: Int
    /// Blender's `keyframe_type`: KEYFRAME, BREAKDOWN, MOVING_HOLD, EXTREME,
    /// JITTER, GENERATED.
    public var type: String
    public var selected: Bool
}

/// A layer, bottom first as `GreasePencil.layers` lists them.
public struct GPLayer: Equatable, Sendable, Identifiable {
    public var name: String
    public var hidden = false
    public var locked = false
    public var opacity: Float = 1
    /// Tint Color and its Factor (Adjustments), rgb then the factor.
    public var tint = SIMD4<Float>(0, 0, 0, 0)
    public var onionSkinning = true
    /// The layer's own transform, layer space to the object's; nil for none.
    public var matrix: simd_float4x4?
    public var keyframes: [GPKeyframe] = []
    /// The keyframe whose drawing the layer shows at the current frame, by its
    /// frame number; nil before the first.
    public var frameInEffect: Int?
    public var blendMode = "REGULAR"
    public var useLights = true

    public var id: String { name }
}

/// A material slot's Grease Pencil settings, the colours scene-linear.
public struct GPMaterial: Equatable, Sendable {
    public var name: String
    public var stroke: SIMD4<Float>
    public var fill: SIMD4<Float>
    public var showStroke: Bool
    public var showFill: Bool
    public var hidden: Bool
    public var locked: Bool
}

/// Object Data ▸ Onion Skinning (`GreasePencil.onion_*`, `ghost_*`).
public struct GPOnionSettings: Equatable, Sendable {
    /// ABSOLUTE (Frames), RELATIVE (Keyframes) or SELECTED (Selected).
    public var mode = "RELATIVE"
    public var factor: Float = 0.5
    public var filter = "ALL"
    public var before = 1
    public var after = 1
    public var customColours = true
    public var beforeColour = SIMD3<Float>(0.145, 0.42, 0.137)
    public var afterColour = SIMD3<Float>(0.125, 0.082, 0.529)
    public var fade = true
    public var loop = false

    public init() {}
}

/// What the panels show of a Grease Pencil object: small, observed, and
/// replaced only when it changed.
public struct GreasePencilInfo: Equatable, Sendable {
    public var layers: [GPLayer] = []
    public var activeLayer: Int?
    /// One per material slot; nil for a slot without a Grease Pencil material.
    public var materials: [GPMaterial?] = []
    public var activeMaterial = 0
    /// Blender's Stroke Depth Order: 2D Layers (false) or 3D Location.
    public var depthOrder3D = false
    /// The object's Show In Front, which Add Grease Pencil turns on.
    public var inFront = false
    public var onion = GPOnionSettings()
    /// The frame the record was read at.
    public var frame = 1
    /// Points and strokes the current frame draws.
    public var pointCount = 0
    public var strokeCount = 0

    public init() {}

    public var active: GPLayer? { activeLayer.flatMap { layers.indices.contains($0) ? layers[$0] : nil } }
}

/// The drawings themselves: each shown layer's at the current frame, and the
/// onion skins.
public struct GreasePencilDrawings: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public var layer: Int
        /// 0 for the drawing in effect; negative for a keyframe before it,
        /// positive after, by how far (Blender's onion id).
        public var onion: Int
        public var frame: Int?
        public var drawing: GPDrawing
    }
    public var blocks: [Block] = []

    public init() {}
}

// MARK: - The wire

/// `_blenderkit_gpencil.record`'s JSON and buffers, read.
public enum GreasePencilWire {

    public struct Parsed: Equatable {
        public var info: GreasePencilInfo
        public var drawings: GreasePencilDrawings
    }

    /// Nil for anything malformed: a record that is not the JSON written, or
    /// buffers that do not hold what it says, or a stroke whose points run
    /// past the drawing's.
    public static func parse(record: String, blob: UnsafeRawBufferPointer) -> Parsed? {
        guard let data = record.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var info = GreasePencilInfo()
        for item in root["layers"] as? [[String: Any]] ?? [] {
            var layer = GPLayer(name: item["name"] as? String ?? "")
            layer.hidden = item["hide"] as? Bool ?? false
            layer.locked = item["lock"] as? Bool ?? false
            layer.opacity = float(item["opacity"]) ?? 1
            if let t = floats(item["tint"]), t.count == 4 { layer.tint = SIMD4(t[0], t[1], t[2], t[3]) }
            layer.onionSkinning = item["onion"] as? Bool ?? true
            if let m = floats(item["matrix"]), m.count == 16 {
                // Row-major from Blender; simd takes columns.
                var matrix = simd_float4x4()
                for c in 0..<4 { matrix[c] = SIMD4(m[c], m[4 + c], m[8 + c], m[12 + c]) }
                layer.matrix = matrix
            }
            layer.frameInEffect = item["frame"] as? Int
            layer.blendMode = item["blend"] as? String ?? "REGULAR"
            layer.useLights = item["lights"] as? Bool ?? true
            for key in item["frames"] as? [[Any]] ?? [] where key.count == 3 {
                guard let frame = key[0] as? Int else { continue }
                layer.keyframes.append(GPKeyframe(frame: frame, type: key[1] as? String ?? "KEYFRAME",
                                                  selected: key[2] as? Bool ?? false))
            }
            info.layers.append(layer)
        }
        if let a = root["active_layer"] as? Int, info.layers.indices.contains(a) { info.activeLayer = a }
        for item in root["materials"] as? [Any] ?? [] {
            guard let m = item as? [String: Any], let s = floats(m["stroke"]), let f = floats(m["fill"]),
                  s.count == 4, f.count == 4 else {
                info.materials.append(nil)
                continue
            }
            info.materials.append(GPMaterial(name: m["name"] as? String ?? "",
                                             stroke: SIMD4(s[0], s[1], s[2], s[3]),
                                             fill: SIMD4(f[0], f[1], f[2], f[3]),
                                             showStroke: m["show_stroke"] as? Bool ?? true,
                                             showFill: m["show_fill"] as? Bool ?? false,
                                             hidden: m["hide"] as? Bool ?? false,
                                             locked: m["lock"] as? Bool ?? false))
        }
        info.activeMaterial = root["active_material"] as? Int ?? 0
        info.depthOrder3D = (root["depth_order"] as? String) == "3D"
        info.inFront = root["in_front"] as? Bool ?? false
        info.frame = root["frame"] as? Int ?? 1
        if let o = root["onion"] as? [String: Any] {
            var onion = GPOnionSettings()
            onion.mode = o["mode"] as? String ?? onion.mode
            onion.factor = float(o["factor"]) ?? onion.factor
            onion.filter = o["filter"] as? String ?? onion.filter
            onion.before = o["before"] as? Int ?? onion.before
            onion.after = o["after"] as? Int ?? onion.after
            onion.customColours = o["custom"] as? Bool ?? onion.customColours
            if let c = floats(o["before_color"]), c.count >= 3 { onion.beforeColour = SIMD3(c[0], c[1], c[2]) }
            if let c = floats(o["after_color"]), c.count >= 3 { onion.afterColour = SIMD3(c[0], c[1], c[2]) }
            onion.fade = o["fade"] as? Bool ?? onion.fade
            onion.loop = o["loop"] as? Bool ?? onion.loop
            info.onion = onion
        }

        var reader = Reader(blob: blob)
        var drawings = GreasePencilDrawings()
        for block in root["blocks"] as? [[String: Any]] ?? [] {
            guard let n = block["points"] as? Int, let s = block["strokes"] as? Int, n >= 0, s >= 0,
                  let layer = block["layer"] as? Int, info.layers.indices.contains(layer)
            else { return nil }
            var d = GPDrawing()
            guard let pos = reader.floats(3 * n), let rad = reader.floats(n), let op = reader.floats(n)
            else { return nil }
            d.positions = (0..<n).map { SIMD3(pos[3 * $0], pos[3 * $0 + 1], pos[3 * $0 + 2]) }
            d.radii = rad
            d.opacities = op
            if block["vcol"] as? Bool == true {
                guard let v = reader.floats(4 * n) else { return nil }
                d.vertexColours = (0..<n).map { SIMD4(v[4 * $0], v[4 * $0 + 1], v[4 * $0 + 2], v[4 * $0 + 3]) }
            }
            guard let off = reader.ints(s + 1), let cyc = reader.ints(s), let mat = reader.ints(s),
                  let fid = reader.ints(s), let hid = reader.ints(s) else { return nil }
            // Offsets that do not climb from 0 to the point count would read
            // outside the drawing.
            guard off.first == 0, off.last == n, zip(off, off.dropFirst()).allSatisfy({ $0 <= $1 })
            else { return nil }
            d.offsets = off
            d.cyclic = cyc.map { $0 != 0 }
            d.materials = mat
            d.fillIDs = fid
            d.hideStroke = hid.map { $0 != 0 }
            if block["fcol"] as? Bool == true {
                guard let f = reader.floats(4 * s) else { return nil }
                d.fillColours = (0..<s).map { SIMD4(f[4 * $0], f[4 * $0 + 1], f[4 * $0 + 2], f[4 * $0 + 3]) }
            }
            info.pointCount += block["onion"] as? Int == 0 ? n : 0
            info.strokeCount += block["onion"] as? Int == 0 ? s : 0
            drawings.blocks.append(.init(layer: layer, onion: block["onion"] as? Int ?? 0,
                                         frame: block["frame"] as? Int, drawing: d))
        }
        // Every byte accounted for: a record and buffers out of step are not
        // drawn at all rather than drawn wrong.
        guard reader.offset == blob.count else { return nil }
        return Parsed(info: info, drawings: drawings)
    }

    private static func float(_ any: Any?) -> Float? {
        (any as? NSNumber).map { $0.floatValue }
    }

    private static func floats(_ any: Any?) -> [Float]? {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    private struct Reader {
        let blob: UnsafeRawBufferPointer
        var offset = 0

        mutating func floats(_ count: Int) -> [Float]? {
            let bytes = count * 4
            guard count >= 0, offset + bytes <= blob.count else { return nil }
            var out = [Float](repeating: 0, count: count)
            out.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: blob[offset ..< offset + bytes])) }
            offset += bytes
            // A non-finite value would draw nothing or everything.
            for i in out.indices where !out[i].isFinite { out[i] = 0 }
            return out
        }

        mutating func ints(_ count: Int) -> [Int]? {
            let bytes = count * 4
            guard count >= 0, offset + bytes <= blob.count else { return nil }
            var raw = [Int32](repeating: 0, count: count)
            raw.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: blob[offset ..< offset + bytes])) }
            offset += bytes
            return raw.map(Int.init)
        }
    }
}

// MARK: - On the object

public extension BKObject {
    /// Installs what `sync_gpencil` carried, unless it is exactly what
    /// `previous` — the object of that name on screen when the pass began, or
    /// this one outside a pass — already has: compared as the bytes Blender
    /// sent, so an unchanged drawing costs one comparison, no parse and no GPU
    /// upload. True when it changed, nil for anything malformed.
    @discardableResult
    func installGreasePencil(record: String, blob: UnsafeRawBufferPointer,
                             previous: BKObject? = nil) -> Bool? {
        let known = previous ?? self
        if let source = known.greasePencilSource, source.record == record,
           source.blob.count == blob.count,
           source.blob.withUnsafeBytes({ $0.elementsEqual(blob) }) {
            if known !== self {
                greasePencilSource = source
                setGreasePencil(info: known.greasePencilInfo, drawings: known.greasePencilDrawings)
            }
            return false
        }
        guard let parsed = GreasePencilWire.parse(record: record, blob: blob) else { return nil }
        greasePencilSource = (record, Data(blob))
        setGreasePencil(info: parsed.info, drawings: parsed.drawings)
        return true
    }

    /// The drawings and the panels' record, each set only when it changed.
    func setGreasePencil(info: GreasePencilInfo?, drawings: GreasePencilDrawings?) {
        if greasePencilInfo != info { greasePencilInfo = info }
        if greasePencilDrawings != drawings {
            greasePencilDrawings = drawings
            greasePencilVersion &+= 1
        }
    }

    /// Takes another object's Grease Pencil state: the mirror's merge, from
    /// the object a pass made onto the one already on screen.
    func takeGreasePencil(from fresh: BKObject) {
        guard fresh.greasePencilSource?.record != greasePencilSource?.record
              || fresh.greasePencilSource?.blob != greasePencilSource?.blob
        else { return }
        greasePencilSource = fresh.greasePencilSource
        setGreasePencil(info: fresh.greasePencilInfo, drawings: fresh.greasePencilDrawings)
    }

    var isGreasePencil: Bool { blenderType == "GREASEPENCIL" }
}
