import Foundation
import simd
import CoreGraphics

// The second stage of scripts/run-camlight-blender-check.sh: Blender 5.2.1's
// own camera frames (Camera.view_frame, and the same through matrix_world),
// each beside the record the mirror sent for that camera — held against what
// ObjectDisplay reads from the record and ObjectOverlays draws from it. Then
// every record the mirror sent for the scenario, read back into the values
// bpy gave it.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func vectors(_ any: Any?) -> [SIMD3<Float>] {
    ((any as? [[NSNumber]]) ?? []).map { SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue) }
}
func number(_ any: Any?) -> Float? { (any as? NSNumber)?.floatValue }
func load(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { print("  FAIL  nothing to read at \(path)"); exit(1) }
    return json
}

let view = OverlayView(camera: ViewportCamera(), size: CGSize(width: 1000, height: 800))
let frames = (load(CommandLine.arguments[1])["frames"] as? [[String: Any]]) ?? []
check("Blender's frames arrived", frames.count == 45, "\(frames.count)")

var worstFrame: Float = 0, worstWorld: Float = 0
var wrongFrames: [String] = [], wrongWorld: [String] = [], wrongValues: [String] = []
for frame in frames {
    let label = frame["label"] as? String ?? "?"
    guard let record = frame["record"] as? String, let data = frame["data"] as? String,
          case .camera(let camera)? = ObjectDisplay(type: "CAMERA", dataName: data, record: record)
    else { wrongFrames.append(label + ": no camera in the record"); continue }

    // The record read back into the values bpy had.
    let truth = frame["truth"] as? [String: Any] ?? [:]
    let read: [String: Float] = ["lens": camera.lens, "sensor_width": camera.sensorWidth,
                                 "sensor_height": camera.sensorHeight, "ortho_scale": camera.orthoScale,
                                 "clip_start": camera.clipStart, "clip_end": camera.clipEnd,
                                 "shift_x": camera.shiftX, "shift_y": camera.shiftY,
                                 "display_size": camera.displaySize, "aspect_x": camera.aspectX,
                                 "aspect_y": camera.aspectY, "focus_distance": camera.focusDistance]
    for (key, value) in read {
        guard let want = number(truth[key]) else { continue }
        if abs(value - want) > 1e-4 * max(1, abs(want)) { wrongValues.append("\(label) \(key) \(value) vs \(want)") }
    }

    // Camera.view_frame is BKE_camera_view_frame: unit scale, and a draw size
    // of 1 whatever the camera's display size.
    let blender = vectors(frame["view_frame"])
    let mine = camera.viewFrame(drawSize: 1).corners
    for (a, b) in zip(mine, blender) { worstFrame = max(worstFrame, length(a - b)) }
    if blender.count != 4 || zip(mine, blender).contains(where: { length($0 - $1) > 1e-4 * max(1, length($1)) }) {
        wrongFrames.append("\(label): \(mine) vs \(blender)")
    }

    // Drawn: the frame's corners through the object's matrix — for this
    // uniformly scaled camera, view_frame at the display size through
    // matrix_world when perspective, and through its rotation and location
    // alone when orthographic (verify.py says why).
    let rows = (frame["matrix"] as? [NSNumber] ?? []).map(\.floatValue)
    guard rows.count == 16 else { wrongWorld.append(label + ": no matrix"); continue }
    var m = simd_float4x4()
    for c in 0..<4 { m[c] = SIMD4(rows[c], rows[4 + c], rows[8 + c], rows[12 + c]) }
    let object = BKObject(name: "Camera", kind: .cube)
    object.install(.camera(camera))
    object.setMirroredTransform(m)
    let scene = BKScene(startupFile: false)
    scene.objects = [object]
    let drawn = ObjectOverlays.geometry(for: object, in: scene, view: view).lines.flatMap { [$0.a, $0.b] }
    for corner in vectors(frame["world_frame"]) {
        let nearest = drawn.map { length($0 - corner) }.min() ?? .infinity
        worstWorld = max(worstWorld, nearest)
        if nearest > 1e-3 * max(1, length(corner)) { wrongWorld.append("\(label): \(corner) is \(nearest) from a line end") }
    }
}
check("ObjectDisplay reads back every value bpy put in the \(frames.count) records", wrongValues.isEmpty,
      wrongValues.prefix(5).joined(separator: "; "))
check("viewFrame matches Camera.view_frame for all of them, perspective, orthographic and panoramic, "
      + "every sensor fit, shift and render shape (worst \(worstFrame))", wrongFrames.isEmpty,
      wrongFrames.prefix(3).joined(separator: "; "))
check("and the drawn frame sits where Blender's overlay puts it, scaled with a perspective camera "
      + "and not with an orthographic one (worst \(worstWorld))",
      wrongWorld.isEmpty,
      wrongWorld.prefix(3).joined(separator: "; "))

if CommandLine.arguments.count > 2 {
    let records = load(CommandLine.arguments[2])
    var unread: [String] = []
    for (name, any) in records {
        guard let entry = any as? [String: Any], let type = entry["type"] as? String,
              let data = entry["data"] as? String, let record = entry["record"] as? String else { continue }
        guard let display = ObjectDisplay(type: type, dataName: data, record: record) else {
            unread.append(name); continue
        }
        // What was read writes back to the same record, key for key.
        let again = DisplayRecordCheck.fields(display.record)
        for (key, text) in DisplayRecordCheck.fields(record) {
            guard let mine = again[key] else { unread.append("\(name).\(key) dropped"); continue }
            let a = mine.split(separator: ","), b = text.split(separator: ",")
            let same = a.count == b.count && zip(a, b).allSatisfy { x, y in
                if let fx = Float(x), let fy = Float(y) { return abs(fx - fy) <= 1e-5 * max(1, abs(fy)) }
                return x == y
            }
            if !same { unread.append("\(name).\(key): \(mine) vs \(text)") }
        }
    }
    check("every camera, light and empty in the scenario is read as the mirror sent it (\(records.count))",
          unread.isEmpty, unread.prefix(5).joined(separator: "; "))
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

enum DisplayRecordCheck {
    static func fields(_ record: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in record.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            out[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return out
    }
}
