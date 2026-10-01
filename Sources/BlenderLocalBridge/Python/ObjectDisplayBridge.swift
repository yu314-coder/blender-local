import Foundation
import simd

// The `_blenderkit` entry points for cameras, lights and empties.
//
// `sync_display` is the mirror's: straight after pushing one of these objects,
// `_blenderkit_sync` hands over what Blender draws it from. The other three
// serve the simulator's shim, which keeps the same record on the app's side and
// reads and writes it for `bpy.data.cameras`, `object.empty_display_type` and
// the rest. See `ObjectDisplay`.

private func copyText(_ text: String, _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Bool {
    guard let out, capacity > 0 else { return false }
    let bytes = Array(text.utf8.prefix(Int(capacity) - 1))
    out.withMemoryRebound(to: UInt8.self, capacity: Int(capacity)) { dst in
        for (i, byte) in bytes.enumerated() { dst[i] = byte }
        dst[bytes.count] = 0
    }
    return true
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

@_cdecl("bk_sync_display")
func bk_sync_display(_ name: UnsafePointer<CChar>?, _ type: UnsafePointer<CChar>?,
                     _ dataName: UnsafePointer<CChar>?, _ record: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard SceneSync.active,
              let name = string(name), let type = string(type),
              let display = ObjectDisplay(type: type, dataName: string(dataName) ?? "",
                                          record: string(record) ?? "")
        else { return -1 }
        // It describes the object pushed just before it, so that is the one to
        // look at first; a search is only the fallback.
        let target = SceneSync.pending.last?.name == name
            ? SceneSync.pending.last
            : SceneSync.pending.last { $0.name == name }
        guard let target else { return -1 }
        target.display = display
        return 0
    }
}

@_cdecl("bk_scene_add_object")
func bk_scene_add_object(_ type: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?,
                         _ x: Double, _ y: Double, _ z: Double,
                         _ dataName: UnsafePointer<CChar>?, _ record: UnsafePointer<CChar>?,
                         _ select: Int32,
                         _ outName: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let type = string(type), let base = string(name), !base.isEmpty,
              let display = ObjectDisplay(type: type, dataName: string(dataName) ?? "",
                                          record: string(record) ?? "")
        else { return -1 }
        let obj = scene.addObject(display, named: base,
                                  at: SIMD3(Float(x), Float(y), Float(z)), select: select != 0)
        return copyText(obj.name, outName, cap) ? 0 : -1
    }
}

@_cdecl("bk_scene_object_display")
func bk_scene_object_display(_ name: UnsafePointer<CChar>?,
                             _ outType: UnsafeMutablePointer<CChar>?, _ typeCap: Int32,
                             _ outData: UnsafeMutablePointer<CChar>?, _ dataCap: Int32,
                             _ outRecord: UnsafeMutablePointer<CChar>?, _ recordCap: Int32) -> Int32 {
    onMain {
        guard let name = string(name), let obj = PythonSceneBridge.object(name) else { return -1 }
        guard let display = obj.overlayDisplay else { return 0 }
        _ = copyText(display.blenderType, outType, typeCap)
        _ = copyText(display.dataName ?? "", outData, dataCap)
        _ = copyText(display.record, outRecord, recordCap)
        return 1
    }
}

@_cdecl("bk_scene_set_object_display")
func bk_scene_set_object_display(_ name: UnsafePointer<CChar>?, _ dataName: UnsafePointer<CChar>?,
                                 _ record: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let name = string(name), let obj = PythonSceneBridge.object(name) else { return -1 }
        guard let current = obj.overlayDisplay,
              let display = ObjectDisplay(type: current.blenderType,
                                          dataName: string(dataName) ?? "",
                                          record: string(record) ?? "")
        else { return -2 }
        obj.display = display
        return 0
    }
}

/// The object's modifier stack, as Blender has it.
///
/// The Modifiers panel used to show only what this app had added through its
/// own path, which on the real backend is nothing: `modifier_add` runs inside
/// Blender and the mirror never carried the result back. So a modifier could
/// be added and then not seen, not adjusted, not reordered and not removed —
/// and the settings rows wrote to a cache no renderer reads.
///
/// One record per stack, `kind=…;name=…;key=value` joined by `|`, in the same
/// shape `bk_sync_display` uses.
@_cdecl("bk_sync_modifiers")
func bk_sync_modifiers(_ name: UnsafePointer<CChar>?, _ record: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard SceneSync.active, let name = string(name) else { return -1 }
        let target = SceneSync.pending.last?.name == name
            ? SceneSync.pending.last
            : SceneSync.pending.last { $0.name == name }
        guard let target else { return -1 }
        target.modifiers = Modifier.stack(from: string(record) ?? "")
        return 0
    }
}

/// The object's parent and every object it depends on, by name — what a drag
/// leaves out of its snap targets and carries along in its preview
/// (ObjectRelations.swift). Sent only for an object that has either; one the
/// pass does not describe has none, which is what `fresh` starts with.
@_cdecl("bk_sync_relations")
func bk_sync_relations(_ name: UnsafePointer<CChar>?, _ parent: UnsafePointer<CChar>?,
                       _ names: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int32) -> Int32 {
    onMain {
        guard SceneSync.active, let name = string(name), count >= 0 else { return -1 }
        let dependencies = (0..<Int(count)).compactMap { names?[$0].map { String(cString: $0) } }
        return SceneMirror.carryRelations(parent: string(parent), dependencies: dependencies,
                                          named: name, pass: SceneSync.pending) ? 0 : -1
    }
}

/// A curve's control points (three floats each, in its own space), for a
/// curve with no surface: what Blender snaps it to (`GeometrySnap`).
@_cdecl("bk_sync_knots")
func bk_sync_knots(_ name: UnsafePointer<CChar>?, _ points: UnsafePointer<Float>?, _ count: Int32) -> Int32 {
    onMain {
        guard SceneSync.active, let name = string(name), count >= 0, count % 3 == 0 else { return -1 }
        let values = points.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) } ?? []
        return SceneMirror.carryKnots(values, named: name, pass: SceneSync.pending) ? 0 : -1
    }
}

/// A curve's or a lattice's settings and, while it is edited, its control
/// points (`_blenderkit_points.push`): during a pass onto the object the pass
/// pushed, otherwise — a drag's frame, a tap — onto the one on screen.
@_cdecl("bk_sync_points")
func bk_sync_points(_ name: UnsafePointer<CChar>?, _ record: UnsafePointer<CChar>?,
                    _ positions: UnsafePointer<Float>?, _ flags: UnsafePointer<UInt8>?, _ count: Int32,
                    _ lines: UnsafePointer<UInt32>?, _ lineCount: Int32, _ duringPass: Int32) -> Int32 {
    onMain {
        guard let name = string(name), count >= 0, lineCount >= 0 else { return -1 }
        let n = Int(count)
        let values = positions.map { Array(UnsafeBufferPointer(start: $0, count: 3 * n)) } ?? []
        let bytes = flags.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? []
        let indices = lines.map { Array(UnsafeBufferPointer(start: $0, count: Int(lineCount))) } ?? []
        let inPass = duringPass != 0 && SceneSync.active
        return SceneMirror.carryPoints(record: string(record) ?? "", positions: values, flags: bytes,
                                       lines: indices, named: name,
                                       pass: inPass ? SceneSync.pending : nil,
                                       screen: PythonSceneBridge.scene?.objects ?? []) ? 0 : -1
    }
}

/// A mesh's vertex groups and shape keys (`_blenderkit_groups.push`): during a
/// pass onto the object the pass pushed, otherwise — a tap, a frame change —
/// onto the one on screen.
@_cdecl("bk_sync_groups")
func bk_sync_groups(_ name: UnsafePointer<CChar>?, _ record: UnsafePointer<CChar>?,
                    _ duringPass: Int32) -> Int32 {
    onMain {
        guard let name = string(name) else { return -1 }
        let inPass = duringPass != 0 && SceneSync.active
        return SceneMirror.carryGroups(record: string(record) ?? "", named: name,
                                       pass: inPass ? SceneSync.pending : nil,
                                       screen: PythonSceneBridge.scene?.objects ?? []) ? 0 : -1
    }
}

/// The object's own location, rotation and scale — `LocalTransform` — which
/// is what Object ▸ Apply bakes and `matrix_world` cannot say.
///
/// A frame change sends it too, outside any pass: a keyed channel moves with
/// the playhead, and `_blenderkit_anim.push_frame` pushes matrices only for
/// the objects it moved. Where the channels go, and why an object the screen
/// does not hold is not an error then, is `SceneMirror.carryLocal`'s — the
/// mirror's host suite runs it.
@_cdecl("bk_sync_local")
func bk_sync_local(_ name: UnsafePointer<CChar>?, _ values: UnsafePointer<Double>?) -> Int32 {
    onMain {
        guard let name = string(name), let values else { return -1 }
        let carried = SceneMirror.carryLocal(
            Array(UnsafeBufferPointer(start: values, count: 10)), named: name,
            pass: SceneSync.active ? SceneSync.pending : nil,
            screen: PythonSceneBridge.scene?.objects ?? [], index: SceneMirror.frameIndex)
        return carried < 0 ? -1 : 0
    }
}

/// What the Transform fields show and write — `TransformChannels` — sent
/// beside `bk_sync_local`, by the same rule: onto the object the pass pushed,
/// or on a frame change onto the one on screen (`SceneMirror.carryChannels`).
@_cdecl("bk_sync_channels")
func bk_sync_channels(_ name: UnsafePointer<CChar>?, _ values: UnsafePointer<Double>?) -> Int32 {
    onMain {
        guard let name = string(name), let values else { return -1 }
        let carried = SceneMirror.carryChannels(
            Array(UnsafeBufferPointer(start: values, count: 11)), named: name,
            pass: SceneSync.active ? SceneSync.pending : nil,
            screen: PythonSceneBridge.scene?.objects ?? [], index: SceneMirror.frameIndex)
        return carried < 0 ? -1 : 0
    }
}
