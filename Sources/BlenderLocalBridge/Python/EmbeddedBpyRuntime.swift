import Foundation
import simd

/// The scene the `_blenderkit` C callbacks act on.
///
/// The bridge is plain C function pointers with no context parameter, so the
/// current scene has to be reachable from a global. Scripts only ever run from
/// the main thread (`evaluate` is called from SwiftUI), so this is not shared
/// across threads.
enum PythonSceneBridge {
    nonisolated(unsafe) static var scene: BKScene?

    static func object(_ name: String) -> BKObject? {
        scene?.objects.first { $0.name == name }
    }
}

private func copyOut(_ s: String, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    guard let out, cap > 0 else { return -1 }
    let bytes = Array(s.utf8.prefix(Int(cap) - 1))
    bytes.withUnsafeBufferPointer { buf in
        out.withMemoryRebound(to: UInt8.self, capacity: Int(cap)) { dst in
            dst.update(from: buf.baseAddress!, count: bytes.count)
            dst[bytes.count] = 0
        }
    }
    return 0
}

// MARK: - C entry points called by the `_blenderkit` module




@_cdecl("bk_scene_add_primitive")
func bk_scene_add_primitive(_ kind: UnsafePointer<CChar>?,
                            _ x: Double, _ y: Double, _ z: Double,
                            _ outName: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let kindStr = kind.map({ String(cString: $0) }),
              let primitive = PrimitiveKind(pythonName: kindStr)
        else { return -1 }
        let obj = scene.add(primitive, at: SIMD3(Float(x), Float(y), Float(z)))
        return copyOut(obj.name, outName, cap)
    }
}

/// Build a torus at the requested proportions.
///
/// Every other primitive can be sized by scaling the default one, because a
/// cube or a cylinder scales into any cube or cylinder. A torus cannot: its
/// major and minor radii are independent, and no scale takes the default
/// (1, 0.25) ring to, say, a bicycle rim. So the mesh is built to order and
/// installed as the object's geometry.
@_cdecl("bk_scene_add_torus")
func bk_scene_add_torus(_ x: Double, _ y: Double, _ z: Double,
                        _ major: Double, _ minor: Double,
                        _ majorSeg: Int32, _ minorSeg: Int32,
                        _ outName: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return -1 }
        let obj = scene.add(.torus, at: SIMD3(Float(x), Float(y), Float(z)))
        obj.setMirroredMesh(MeshBuilder.torus(major: Float(major), minor: Float(minor),
                                              majorSeg: max(3, Int(majorSeg)),
                                              minorSeg: max(3, Int(minorSeg))))
        return copyOut(obj.name, outName, cap)
    }
}

@_cdecl("bk_scene_delete_selected")
func bk_scene_delete_selected() -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return 0 }
        let n = scene.selection.count
        scene.deleteSelection()
        return Int32(n)
    }
}

@_cdecl("bk_scene_duplicate_selected")
func bk_scene_duplicate_selected() -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return 0 }
        return Int32(scene.duplicateSelection().count)
    }
}

@_cdecl("bk_scene_select_all")
func bk_scene_select_all(_ select: Int32) {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return }
        if select != 0 {
            scene.selection = Set(scene.objects.map(\.id))
            scene.activeID = scene.objects.last?.id
        } else {
            scene.deselectAll()
        }
    }
}

@_cdecl("bk_scene_select")
func bk_scene_select(_ name: UnsafePointer<CChar>?, _ on: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        if on != 0 {
            scene.selection.insert(obj.id)
            scene.activeID = obj.id
        } else {
            scene.selection.remove(obj.id)
            if scene.activeID == obj.id { scene.activeID = scene.selection.first }
        }
        return 0
    }
}

/// Make one object active without touching the selection.
///
/// Blender keeps "active" and "selected" separate — `view_layer.objects.active`
/// picks which object an operator reads settings from and which one a join
/// merges into, whether or not it is selected. Routing that through `select`
/// would quietly widen the selection, so it gets its own entry point.
/// Wires the heartbeat to CPython. Called once, when the interpreter starts.
///
/// It lives here rather than in `ConsoleStream` because this file is the only
/// one allowed to name the C API: the bridge is compiled without it by the
/// host test suites, and a direct call there breaks every one of them.
func bk_install_pump_request() {
    ConsoleStream.requestPump = { _ = bk_request_pump() }
}

@_cdecl("bk_console_emit")
func bk_console_emit(_ text: UnsafePointer<CChar>?) {
    // Deliberately *not* wrapped in `onMain`, unlike every other callback here.
    //
    // The sink does its own marshalling — it joins chunks into lines on
    // whichever thread they arrive on and hands only the finished lines over —
    // and pumping the run loop is something that may only happen on the main
    // thread when it is *not* inside a `sync` block. Wrapping this one
    // deadlocked the first script that printed: the script thread waited on
    // main, and main, inside that block, ran a nested run loop.
    guard let sink = ConsoleStream.sink,
          let chunk = text.map({ String(cString: $0) }),
          !chunk.isEmpty
    else { return }
    sink(chunk)
    // A no-op off the main thread, which is where this now usually runs: when
    // the script has its own thread the interface redraws on its own.
    ConsoleStream.pumpIfDue()
}

@_cdecl("bk_scene_set_active")
func bk_scene_set_active(_ name: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return -1 }
        guard let n = name.map({ String(cString: $0) }), !n.isEmpty else {
            scene.activeID = nil
            return 0
        }
        guard let obj = PythonSceneBridge.object(n) else { return -1 }
        scene.activeID = obj.id
        return 0
    }
}

@_cdecl("bk_scene_object_count")
func bk_scene_object_count() -> Int32 {
    onMain {
        Int32(PythonSceneBridge.scene?.objects.count ?? 0)
    }
}

@_cdecl("bk_scene_object_name")
func bk_scene_object_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              index >= 0, Int(index) < scene.objects.count
        else { return -1 }
        return copyOut(scene.objects[Int(index)].name, out, cap)
    }
}

@_cdecl("bk_scene_object_kind")
func bk_scene_object_kind(_ name: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        return copyOut(obj.kind.rawValue, out, cap)
    }
}

@_cdecl("bk_scene_get_vec")
func bk_scene_get_vec(_ name: UnsafePointer<CChar>?, _ prop: UnsafePointer<CChar>?,
                      _ x: UnsafeMutablePointer<Double>?,
                      _ y: UnsafeMutablePointer<Double>?,
                      _ z: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let p = prop.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        let v: SIMD3<Float>
        switch p {
        case "location":       v = obj.location
        case "rotation_euler": v = obj.rotation
        case "scale":          v = obj.scale
        default: return -1
        }
        x?.pointee = Double(v.x); y?.pointee = Double(v.y); z?.pointee = Double(v.z)
        return 0
    }
}

@_cdecl("bk_scene_set_vec")
func bk_scene_set_vec(_ name: UnsafePointer<CChar>?, _ prop: UnsafePointer<CChar>?,
                      _ x: Double, _ y: Double, _ z: Double) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let p = prop.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        let v = SIMD3(Float(x), Float(y), Float(z))
        switch p {
        case "location":       obj.location = v
        case "rotation_euler": obj.rotation = v
        case "scale":          obj.scale = v
        default: return -1
        }
        return 0
    }
}

extension PrimitiveKind {
    /// The name the bundled `bpy` shim passes across the bridge.
    init?(pythonName: String) {
        switch pythonName {
        case "plane":      self = .plane
        case "cube":       self = .cube
        case "circle":     self = .circle
        case "uv_sphere":  self = .uvSphere
        case "ico_sphere": self = .icoSphere
        case "cylinder":   self = .cylinder
        case "cone":       self = .cone
        case "torus":      self = .torus
        case "grid":       self = .grid
        case "monkey":     self = .monkey
        default: return nil
        }
    }
}

// MARK: - The runtime

/// Real CPython, running from the copy of the interpreter inside the app
/// bundle. No network access is involved at any point: the stdlib, the
/// extension modules and the `bpy` shim all ship in the app.
public final class EmbeddedBpyRuntime: BpyRuntime {

    public enum StartupError: Error, CustomStringConvertible {
        case missingRuntime(String)
        case initFailed(Int32)

        public var description: String {
            switch self {
            case .missingRuntime(let p): return "bundled Python not found at \(p)"
            case .initFailed(let c):     return "Py_InitializeFromConfig failed (\(c))"
            }
        }
    }

    public private(set) var isReal = true
    private var version = ""

    /// True when Blender's own `bpy` was staged into the bundle. Device builds
    /// carry it; the simulator cannot, because the shipped module is arm64 with
    /// no simulator slice.
    public private(set) var usingRealBlender = false
    public var usesRealBlender: Bool { usingRealBlender }
    public private(set) var lastSyncDuration: TimeInterval = 0
    private var blenderVersion = ""
    /// Set when a `bpy` package is staged but does not look importable, so the
    /// banner can report it instead of silently running the shim.
    public private(set) var stagingWarning: String?

    public init() throws {
        // The interpreter is staged into the bundle by the "Stage Python"
        // build phase; see project.yml.
        guard let home = Bundle.main.resourceURL?.appendingPathComponent("python") else {
            throw StartupError.missingRuntime("<no resource url>")
        }
        let stdlib   = home.appendingPathComponent("lib/python3.14")
        let dynload  = stdlib.appendingPathComponent("lib-dynload")
        let sitePkgs = stdlib.appendingPathComponent("site-packages")
        let shim     = home.appendingPathComponent("site")

        let fm = FileManager.default
        guard fm.fileExists(atPath: stdlib.path) else {
            throw StartupError.missingRuntime(stdlib.path)
        }

        // Which `bpy` will import, decided before Python starts because it
        // gates the USD environment below and the viewport mirroring later.
        //
        // The build stages Blender's module as `bpy/__init__.so`, and then
        // hands it to the BeeWare installer — Apple rejects a loose .so, so the
        // binary moves into Frameworks/ and a `.fwork` pointer is left in its
        // place. The shipped bundle therefore has `__init__.fwork` and no
        // `.so` at all. Looking only for the `.so` answered "no real Blender"
        // on every device build ever shipped: the module still imported, since
        // site-packages precedes the shim on sys.path and the .fwork loader
        // resolves it, but the mirroring that puts Blender's scene on screen
        // stayed switched off. Scripts built a bike nobody could see.
        let bpyDir = sitePkgs.appendingPathComponent("bpy")
        let entryPoints = ["__init__.so", "__init__.fwork"]
        usingRealBlender = entryPoints.contains {
            fm.fileExists(atPath: bpyDir.appendingPathComponent($0).path)
        }
        // A staged package with neither entry point is a staging change that
        // broke this check again. Say so rather than quietly falling back to
        // the shim, which is how the first one went unnoticed for nine builds.
        if !usingRealBlender, fm.fileExists(atPath: bpyDir.path) {
            stagingWarning = "site-packages/bpy exists but has neither "
                + entryPoints.joined(separator: " nor ")
                + " — running the shim, and the viewport will not follow bpy."
        }

        if usingRealBlender {
            // OpenUSD's plugin registry has to be pointed at the bundled
            // manifests before bpy loads, or usd_import/usd_export find no
            // file-format plugins. The monolithic libusd_ms carries the code;
            // these directories carry the plugInfo.json manifests.
            let usd = sitePkgs.appendingPathComponent("bpy/usd_resources")
            if fm.fileExists(atPath: usd.path) {
                let plugins = [usd.appendingPathComponent("lib_usd").path,
                               usd.appendingPathComponent("plugin_usd").path]
                    .joined(separator: ":")
                setenv("PXR_PLUGINPATH_NAME", plugins, 0)
            }
        }

        // site-packages precedes the shim, so the real bpy wins when present
        // and the shim only answers when it is absent. The shim's `mathutils`
        // must never shadow the one Blender's binary provides.
        let searchPath = [stdlib.path, dynload.path, sitePkgs.path, shim.path]
            .joined(separator: ":")
        // The app binary, which sys.executable must point at — see the note in
        // bk_python_start: the .fwork loader resolves against its directory.
        let executable = Bundle.main.executableURL?.path ?? ""
        let rc = home.path.withCString { h in
            searchPath.withCString { p in
                executable.withCString { e in bk_python_start(h, p, e) }
            }
        }
        guard rc == 0 else { throw StartupError.initFailed(rc) }
        version = String(cString: bk_python_version())
        bk_install_pump_request()
    }

    public var versionBanner: String {
        let warning = stagingWarning.map { "\n\u{26A0} \($0)" } ?? ""
        if usingRealBlender {
            return """
            Python \(version)
            Blender bpy — the real module, running on device. The viewport
            mirrors bpy.data after every run.
            Convenience imports: bpy, mathutils, math · C = bpy.context, D = bpy.data
            Runs entirely on device; no network required.
            """
        }
        return """
        Python \(version)
        bpy shim — Blender Local's own, driving the viewport. Not Blender's bpy.
        The real module is arm64-only, so simulator builds use this.\(warning)
        Convenience imports: bpy, mathutils, math · C = bpy.context, D = bpy.data
        Runs entirely on device; no network required.
        """
    }

    /// With the real backend, Blender owns the scene, so the viewport has to be
    /// re-read from `bpy.data` after anything runs.
    ///
    /// Against the shim this is off by default — BKScene is already the source
    /// of truth there, and mirroring would round-trip it for no gain and drop
    /// the primitive kind and modifier stack. `-mirror` turns it on anyway, to
    /// exercise this path in the simulator, which is the only place it can be
    /// tested: the real bpy is arm64-only.
    private var shouldMirror: Bool {
        if mirroringSuspended { return false }
        if usingRealBlender { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-mirror")
        #else
        return false
        #endif
    }

    public func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        introspectionCache.removeAll()
        PythonSceneBridge.scene = scene
        defer { PythonSceneBridge.scene = nil }

        var ok: Int32 = 1
        guard let raw = source.withCString({ bk_python_run($0, &ok) }) else { return [] }
        let output = String(cString: raw)
        free(raw)

        var lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(while: { $0.isEmpty })
            .map { BpyLine(ok == 0 ? .error : .output, String($0)) }

        if shouldMirror {
            let started = Date()
            lines += mirrorScene()
            lastSyncDuration = Date().timeIntervalSince(started)
        } else {
            lastSyncDuration = 0
        }
        return lines
    }

    public func requestInterrupt() { bk_python_request_interrupt() }

    public func query(_ source: String, scene: BKScene) -> [BpyLine] {
        withoutMirroring { evaluate(source, scene: scene) }
    }

    /// What a dotted path really has on it, asked of the interpreter.
    ///
    /// This is the difference between a completion list that knows about
    /// `bpy.data` because somebody typed the names into a table, and one that
    /// knows because it asked. The table went stale the moment Blender added
    /// anything; this cannot.
    ///
    /// Three things make it safe enough to run on a keystroke. Only a chain of
    /// plain identifiers is resolved — no calls, no subscripts — so completing
    /// after `delete_everything().` looks up nothing rather than running it.
    /// It walks with `getattr` rather than `eval`. And the answer is cached,
    /// because `bpy.data`'s attributes do not change between keystrokes and a
    /// round trip per character typed would be felt.
    public func introspect(_ path: String) -> [(name: String, callable: Bool)]? {
        if let cached = introspectionCache[path] { return cached }
        // The empty path is the global namespace: what is defined right now.
        // Not cached, because that is the one thing that changes as the reader
        // works — every run binds new names.
        if path.isEmpty { return globalNames() }
        guard Self.isPlainPath(path) else { return nil }

        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        let rest = parts.dropFirst().map { "    _o = getattr(_o, \"\($0)\")" }
            .joined(separator: "\n")
        let source = """
        try:
            import builtins as _b
            _g = globals()
            _o = _g["\(first)"] if "\(first)" in _g else getattr(_b, "\(first)")
        \(rest)
            for _n in sorted(n for n in dir(_o) if not n.startswith("_")):
                try:
                    _c = callable(getattr(_o, _n))
                except Exception:
                    _c = False
                print(_n + ("\\t1" if _c else "\\t0"))
        except Exception:
            pass
        """

        // Quiet, and without the mirroring pass: this is the interface asking
        // Blender about itself between two keystrokes, not an edit. Mirroring
        // a twenty-thousand-vertex scene per character typed would make the
        // editor unusable, which is the opposite of the point.
        let names = withoutMirroring { Self.parse(self.capture(source)) }
        let result = names.isEmpty ? nil : names
        introspectionCache[path] = result
        return result
    }

    /// One `name\tcallable` line each.
    static func parse(_ text: String) -> [(name: String, callable: Bool)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard let name = parts.first, !name.isEmpty else { return nil }
            return (String(name), parts.count > 1 && parts[1] == "1")
        }
    }

    /// Runs source purely for its output, without the mirroring pass.
    private func capture(_ source: String) -> String {
        var ok: Int32 = 1
        guard let raw = source.withCString({ bk_python_run($0, &ok) }) else { return "" }
        let text = String(cString: raw)
        free(raw)
        return ok != 0 ? text : ""
    }

    /// Only a chain of plain identifiers. Anything with a call or a subscript
    /// in it is refused rather than resolved: completing a path should never
    /// be the thing that runs the reader's code.
    static func isPlainPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let head = part.first, head.isLetter || head == "_" else { return false }
            guard part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }

    /// The names bound in the console's namespace.
    private func globalNames() -> [(name: String, callable: Bool)]? {
        let source = """
        for _n in sorted(n for n in globals() if not n.startswith("_")):
            try:
                _c = callable(globals()[_n])
            except Exception:
                _c = False
            print(_n + ("\\t1" if _c else "\\t0"))
        """
        let names = withoutMirroring { Self.parse(self.capture(source)) }
        return names.isEmpty ? nil : names
    }

    @ObservationIgnored private var introspectionCache: [String: [(name: String, callable: Bool)]?] = [:]
    @ObservationIgnored private var mirroringSuspended = false

    private func withoutMirroring<T>(_ body: () -> T) -> T {
        let was = mirroringSuspended
        mirroringSuspended = true
        defer { mirroringSuspended = was }
        return body()
    }

    /// Runs the mirroring pass and returns anything it reported.
    private func mirrorScene() -> [BpyLine] {
        var ok: Int32 = 1
        // Bound to a name: the runner echoes a bare expression's value, and a
        // stray object count in the console reads like script output.
        let script = "import _blenderkit_sync; _mirrored = _blenderkit_sync.sync()"
        guard let raw = script.withCString({ bk_python_run($0, &ok) }) else { return [] }
        let out = String(cString: raw)
        free(raw)
        guard !out.isEmpty else { return [] }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(while: { $0.isEmpty })
            .map { BpyLine(ok == 0 ? .error : .info, String($0)) }
    }
}

private extension Array {
    /// Trailing newline from `print` would otherwise add an empty console line.
    func dropLast(while predicate: (Element) -> Bool) -> [Element] {
        var copy = self
        while let last = copy.last, predicate(last) { copy.removeLast() }
        return copy
    }
}

// MARK: - Scene operations added for bpy parity

@_cdecl("bk_scene_rename")
func bk_scene_rename(_ oldName: UnsafePointer<CChar>?, _ newName: UnsafePointer<CChar>?,
                     _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let o = oldName.map({ String(cString: $0) }),
              let n = newName.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(o)
        else { return -1 }
        // Blender never lets two objects share a name; it suffixes instead.
        let resolved = (n == obj.name) ? n : scene.uniqueName(n)
        obj.name = resolved
        return copyOut(resolved, out, cap)
    }
}

@_cdecl("bk_scene_remove")
func bk_scene_remove(_ name: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        scene.objects.removeAll { $0.id == obj.id }
        scene.selection.remove(obj.id)
        if scene.activeID == obj.id { scene.activeID = scene.selection.first }
        return 0
    }
}

@_cdecl("bk_scene_active_name")
func bk_scene_active_name(_ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let active = PythonSceneBridge.scene?.active else { return -1 }
        return copyOut(active.name, out, cap)
    }
}

@_cdecl("bk_scene_is_selected")
func bk_scene_is_selected(_ name: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        return scene.selection.contains(obj.id) ? 1 : 0
    }
}

@_cdecl("bk_scene_bounds")
func bk_scene_bounds(_ name: UnsafePointer<CChar>?, _ out6: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n),
              let out6, !obj.mesh.vertices.isEmpty
        else { return -1 }
        let m = obj.modelMatrix
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in obj.mesh.vertices {
            let w = (m * SIMD4(v.position, 1)).xyz
            lo = min(lo, w); hi = max(hi, w)
        }
        for (i, c) in [lo.x, lo.y, lo.z, hi.x, hi.y, hi.z].enumerated() {
            out6[i] = Double(c)
        }
        return 0
    }
}

/// `which`: 0 Disable in Viewports is off (`hide_viewport`), 1 the view layer
/// does not hide it (`hide_get()`), 2 it is drawn (`visible_get()`).
@_cdecl("bk_scene_get_visible")
func bk_scene_get_visible(_ name: UnsafePointer<CChar>?, _ which: Int32) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        switch which {
        case 0:  return obj.disabledInViewports ? 0 : 1
        case 1:  return obj.hiddenInViewLayer ? 0 : 1
        default: return obj.visible ? 1 : 0
        }
    }
}

/// Sets one of the two flags, 0 or 1 as for `bk_scene_get_visible`; the object
/// is drawn when neither is set, as Blender draws it.
@_cdecl("bk_scene_set_visible")
func bk_scene_set_visible(_ name: UnsafePointer<CChar>?, _ visible: Int32, _ which: Int32) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n),
              let scene = PythonSceneBridge.scene
        else { return -1 }
        // BKScene.setHidden has what Blender was measured doing: hiding
        // either way deselects.
        scene.setHidden(obj, visible == 0, inViewLayer: which == 1)
        return 0
    }
}

/// `bpy.ops.transform.translate / rotate / resize` in the simulator.
///
/// The operation is TransformOperation — the code the gizmo's preview runs —
/// so a drag commits exactly what it showed. This used to add the rotation to
/// each object's Euler angles and multiply its scale in place, dropping
/// `center_override` and every proportional argument: the pivots and
/// proportional editing previewed one thing and committed another, silently.
@_cdecl("bk_scene_transform_operator")
func bk_scene_transform_operator(_ json: UnsafePointer<CChar>?,
                              _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else {
            _ = copyOut("no scene to transform", out, cap)
            return -1
        }
        let text = json.map { String(cString: $0) } ?? ""
        guard let operation = TransformOperation(json: text) else {
            _ = copyOut("the simulator could not read this transform: " + text, out, cap)
            return -1
        }
        return Int32(scene.perform(operation))
    }
}

@_cdecl("bk_scene_mesh_counts")
func bk_scene_mesh_counts(_ name: UnsafePointer<CChar>?,
                          _ verts: UnsafeMutablePointer<Int32>?,
                          _ tris: UnsafeMutablePointer<Int32>?) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n)
        else { return -1 }
        verts?.pointee = Int32(obj.mesh.vertices.count)
        tris?.pointee = Int32(obj.mesh.indices.count / 3)
        return 0
    }
}

// MARK: - Modifiers and material colour

@_cdecl("bk_scene_modifier_add")
func bk_scene_modifier_add(_ obj: UnsafePointer<CChar>?, _ kind: UnsafePointer<CChar>?,
                           _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o) else { return -1 }
        guard let k = kind.map({ String(cString: $0) }),
              let modKind = ModifierKind(bpyName: k) else { return -2 }
        return copyOut(target.addModifier(modKind).name, out, cap)
    }
}

@_cdecl("bk_scene_modifier_remove")
func bk_scene_modifier_remove(_ obj: UnsafePointer<CChar>?, _ mod: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o),
              let m = mod.map({ String(cString: $0) })
        else { return -1 }
        return target.removeModifier(named: m) ? 0 : -1
    }
}

@_cdecl("bk_scene_modifier_list")
func bk_scene_modifier_list(_ obj: UnsafePointer<CChar>?,
                            _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o) else { return -1 }
        let text = target.modifiers
            .map { "\($0.name)|\($0.kind.rawValue)" }
            .joined(separator: "\n")
        return copyOut(text, out, cap)
    }
}

@_cdecl("bk_scene_modifier_set")
func bk_scene_modifier_set(_ obj: UnsafePointer<CChar>?, _ mod: UnsafePointer<CChar>?,
                           _ key: UnsafePointer<CChar>?,
                           _ a: Double, _ b: Double, _ c: Double) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o),
              let m = mod.map({ String(cString: $0) }),
              let k = key.map({ String(cString: $0) }),
              let index = target.modifiers.firstIndex(where: { $0.name == m })
        else { return -1 }

        // Int(Double) traps on a non-finite value and on anything past
        // Int.max, and these doubles come straight from a script's float().
        func whole(_ v: Double) -> Int {
            v.isFinite ? Int(max(-1e9, min(v, 1e9))) : 0
        }
        /// An enum passed across a double-only bridge as its position in
        /// Blender's own enum order, which the Swift enum's case order matches.
        func pick<T: CaseIterable>(_: T.Type, _ v: Double) -> T
        where T.AllCases.Index == Int {
            let all = T.allCases
            return all[max(0, min(whole(v), all.count - 1))]
        }

        // Mutating the array element re-triggers the didSet, so the mesh rebuilds.
        var stack = target.modifiers
        switch k {
        case "levels":          stack[index].levels = stack[index].kind == .multires
                                    ? max(0, min(whole(a), stack[index].totalLevels)) : whole(a)
        case "count", "steps":  stack[index].count = whole(a)
        case "relative_offset": stack[index].relativeOffset = SIMD3(Float(a), Float(b), Float(c))
        case "use_axis":        stack[index].mirrorX = a != 0
                                stack[index].mirrorY = b != 0
                                stack[index].mirrorZ = c != 0
        case "use_bisect_axis": stack[index].bisectX = a != 0
                                stack[index].bisectY = b != 0
                                stack[index].bisectZ = c != 0
        case "use_bisect_flip_axis":
                                stack[index].bisectFlipX = a != 0
                                stack[index].bisectFlipY = b != 0
                                stack[index].bisectFlipZ = c != 0
        // The two switches every modifier has.
        case "show_viewport":   stack[index].showInViewport = a != 0
        case "show_render":     stack[index].showInRender = a != 0
        case "use_clip":        stack[index].mirrorClip = a != 0
        case "use_mirror_merge": stack[index].mirrorMerge = a != 0
        // RNA's hard minimum is 0, and Blender clamps an assignment below it
        // to that rather than raising.
        case "merge_threshold": stack[index].mergeThreshold = Float(max(0, a.isFinite ? a : 0))
        // Wave's Motion X and Y. It has no axis: `deform_axis` on a Wave raises
        // AttributeError in Blender (measured), and the shim no longer takes it.
        // Laplacian Smooth's axis flags have the same names.
        case "use_x":           if stack[index].kind == .laplacianSmooth { stack[index].smoothX = a != 0 }
                                else { stack[index].waveX = a != 0 }
        case "use_y":           if stack[index].kind == .laplacianSmooth { stack[index].smoothY = a != 0 }
                                else { stack[index].waveY = a != 0 }
        case "use_z":           stack[index].smoothZ = a != 0
        // Six of Blender's names for one number, because a Solidify's
        // thickness, a Bevel's width and a Screw's rise are the same field here.
        case "thickness", "strength", "height", "width", "offset", "screw_offset":
                                stack[index].thickness = Float(a)
        case "factor":          stack[index].factor = Float(a)
        case "iterations":      stack[index].iterations = whole(a)
        case "angle":           stack[index].angle = Float(a)
        case "segments":        stack[index].segments = whole(a)
        case "ratio":           stack[index].ratio = Float(a)
        case "voxel_size":      stack[index].voxelSize = Float(a)
        case "octree_depth":    stack[index].octreeDepth = max(1, min(whole(a), 8))
        case "deform_axis", "axis":
                                stack[index].axis = max(0, min(whole(a), 2))
        case "deform_method":
            // Passed as the index of Blender's enum, which the shim maps by order.
            stack[index].deformMode = pick(Modifier.DeformMode.self, a)
        case "operation":       stack[index].booleanOperation = pick(Modifier.BooleanOperation.self, a)
        case "wrap_method":     stack[index].wrapMethod = pick(Modifier.WrapMethod.self, a)
        // Remesh's algorithm and Weighted Normal's weighting share the name.
        case "mode":            if stack[index].kind == .weightedNormal {
                                    stack[index].weightMode = pick(Modifier.WeightMode.self, a)
                                } else {
                                    stack[index].remeshMode = pick(Modifier.RemeshMode.self, a)
                                }
        // Weighted Normal. Blender's hard range for `weight` is 1…100 and it
        // clamps rather than raising.
        case "weight":          stack[index].weight = max(1, min(whole(a), 100))
        case "thresh":          stack[index].threshold = Float(max(0, min(a.isFinite ? a : 0, 10)))
        case "keep_sharp":      stack[index].keepSharp = a != 0
        case "use_face_influence": stack[index].faceInfluence = a != 0
        // Multires. Blender clamps each level to what Subdivide has made
        // (measured: 5 on a Multires of 2 reads back 2).
        case "sculpt_levels":   stack[index].sculptLevels = max(0, min(whole(a), stack[index].totalLevels))
        case "render_levels":   if stack[index].kind == .multires {
                                    stack[index].renderLevels = max(0, min(whole(a), stack[index].totalLevels))
                                } else {
                                    stack[index].levels = whole(a)
                                }
        // Not settings: `total_levels` is read-only in RNA. These two are
        // the shim's Subdivide and Delete Higher operators. Subdivide adds a
        // level and raises all three to it, as Blender's does outside sculpt
        // mode (measured in 5.2.1: 1 1 1 1, then 2 2 2 2); Delete Higher
        // drops every level above the viewport one (total 4 at viewport 1:
        // all read 1 after).
        case "multires_subdivide":
            guard stack[index].kind == .multires else { return -2 }
            let total = min(stack[index].totalLevels + 1, 255)
            stack[index].totalLevels = total
            stack[index].levels = total
            stack[index].sculptLevels = total
            stack[index].renderLevels = total
        case "multires_delete_higher":
            guard stack[index].kind == .multires else { return -2 }
            let total = stack[index].levels
            stack[index].totalLevels = total
            stack[index].sculptLevels = min(stack[index].sculptLevels, total)
            stack[index].renderLevels = min(stack[index].renderLevels, total)
        // Edge Split.
        case "split_angle":     stack[index].angle = Float(max(0, min(a.isFinite ? a : 0, .pi)))
        case "use_edge_angle":  stack[index].edgeSplitAngle = a != 0
        case "use_edge_sharp":  stack[index].edgeSplitSharp = a != 0
        // Laplacian Smooth.
        case "lambda_factor":   stack[index].lambdaFactor = Float(a)
        case "lambda_border":   stack[index].lambdaBorder = Float(a)
        case "use_volume_preserve": stack[index].preserveVolume = a != 0
        case "use_normalized":  stack[index].normalized = a != 0
        // Corrective Smooth.
        case "scale":           stack[index].smoothScale = Float(a)
        case "smooth_type":     stack[index].smoothType = pick(Modifier.SmoothType.self, a)
        case "use_only_smooth": stack[index].onlySmooth = a != 0
        case "use_pin_boundary": stack[index].pinBoundary = a != 0
        case "decimate_type":
            // Only COLLAPSE has a shim here. UNSUBDIV and DISSOLVE would be
            // quietly wrong, so they surface as unsupported instead.
            if whole(a) != 0 { return -2 }
        default: return -2
        }
        target.modifiers = stack
        return 0
    }
}

/// A Boolean's or a Lattice's `object`, or a Shrinkwrap's `target`: the other
/// object, by name, or "" for None. The simulator's modifiers used to refuse both, so a picked
/// target raised AttributeError there and the row went on showing it anyway.
/// Returns -2 for a key that is not one of the two, -3 for the modifier's own
/// object — which Blender refuses with TypeError — and -4 for a name no
/// object has.
@_cdecl("bk_scene_modifier_set_object")
func bk_scene_modifier_set_object(_ obj: UnsafePointer<CChar>?, _ mod: UnsafePointer<CChar>?,
                                  _ key: UnsafePointer<CChar>?,
                                  _ other: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o),
              let m = mod.map({ String(cString: $0) }),
              let k = key.map({ String(cString: $0) }),
              let index = target.modifiers.firstIndex(where: { $0.name == m })
        else { return -1 }
        let kind = target.modifiers[index].kind
        guard (k == "object" && (kind == .boolean || kind == .lattice))
                || (k == "target" && kind == .shrinkwrap)
        else { return -2 }
        var name = other.map { String(cString: $0) } ?? ""
        if name == o { return -3 }
        guard name.isEmpty || PythonSceneBridge.object(name) != nil else { return -4 }
        // Blender takes only a lattice for a Lattice's object and quietly
        // leaves it None for anything else (measured in 5.2.1: a mesh
        // assigned there raises nothing and reads back None).
        if kind == .lattice, !name.isEmpty, PythonSceneBridge.object(name)?.blenderType != "LATTICE" {
            name = ""
        }
        var stack = target.modifiers
        stack[index].targetName = name
        target.modifiers = stack
        return 0
    }
}

@_cdecl("bk_scene_get_color")
func bk_scene_get_color(_ obj: UnsafePointer<CChar>?, _ rgba: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o), let rgba else { return -1 }
        for (i, c) in [target.color.x, target.color.y, target.color.z, target.color.w].enumerated() {
            rgba[i] = Double(c)
        }
        return 0
    }
}

@_cdecl("bk_scene_set_color")
func bk_scene_set_color(_ obj: UnsafePointer<CChar>?,
                        _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Int32 {
    onMain {
        guard let o = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(o) else { return -1 }
        target.color = SIMD4(Float(r), Float(g), Float(b), Float(a))
        return 0
    }
}

extension ModifierKind {
    /// Blender's modifier type strings, as passed to
    /// `bpy.ops.object.modifier_add(type=…)`.
    init?(bpyName: String) {
        switch bpyName.uppercased() {
        case "SUBSURF", "SUBDIVISION", "SUBDIVISION_SURFACE": self = .subdivision
        case "ARRAY":        self = .array
        case "MIRROR":       self = .mirror
        case "SOLIDIFY":     self = .solidify
        case "SMOOTH":       self = .smooth
        case "CAST":         self = .cast
        case "SIMPLE_DEFORM": self = .simpleDeform
        case "DISPLACE":     self = .displace
        case "WELD":         self = .weld
        case "WAVE":         self = .wave
        case "TRIANGULATE":  self = .triangulate
        // BEVEL and BOOLEAN were modelled everywhere else but never listed
        // here, so `modifier_add` answered -2 for them and the simulator's Add
        // Modifier menu could not add either one at all.
        case "BEVEL":        self = .bevel
        case "BOOLEAN":      self = .boolean
        case "SHRINKWRAP":   self = .shrinkwrap
        case "SCREW":        self = .screw
        case "DECIMATE":     self = .decimate
        case "REMESH":       self = .remesh
        case "WEIGHTED_NORMAL":   self = .weightedNormal
        case "MULTIRES":          self = .multires
        case "EDGE_SPLIT":        self = .edgeSplit
        case "LAPLACIANSMOOTH":   self = .laplacianSmooth
        case "CORRECTIVE_SMOOTH": self = .correctiveSmooth
        case "LATTICE":           self = .lattice
        default: return nil
        }
    }
}

// MARK: - Scene mirroring
//
// With the real Blender backend, bpy owns the scene and BKScene becomes a
// mirror of it: after each script runs, the evaluated depsgraph is walked in
// Python and every mesh is handed over here for the Metal renderer to draw.

/// Objects accumulated between `bk_sync_begin` and `bk_sync_end`. The swap is
/// atomic so the renderer never sees a half-built scene.
enum SceneSync {
    nonisolated(unsafe) static var pending: [BKObject] = []
    nonisolated(unsafe) static var pendingSelection: Set<UUID> = []
    nonisolated(unsafe) static var pendingActive: UUID?
    nonisolated(unsafe) static var active = false
    /// What was on screen when the pass began, by name, so a mesh that comes
    /// back unchanged can be recognised without searching the scene per push.
    nonisolated(unsafe) static var previous: [String: BKObject] = [:]
    /// Objects whose geometry came back exactly as it was. Their meshes are
    /// not rebuilt, and so not re-uploaded to the GPU either.
    nonisolated(unsafe) static var unchanged: Set<String> = []
}

@_cdecl("bk_sync_begin")
func bk_sync_begin() {
    onMain {
        SceneSync.pending = []
        SceneSync.pendingSelection = []
        SceneSync.pendingActive = nil
        SceneSync.unchanged = []
        SceneSync.previous = Dictionary(
            (PythonSceneBridge.scene?.objects ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        SceneSync.active = true
        SceneMirror.frameIndex.invalidate()
    }
}

@_cdecl("bk_sync_push")
func bk_sync_push(_ name: UnsafePointer<CChar>?, _ kind: UnsafePointer<CChar>?,
                  _ matrix16: UnsafePointer<Double>?,
                  _ verts: UnsafePointer<Float>?, _ vcount: Int32,
                  _ normals: UnsafePointer<Float>?, _ ncount: Int32,
                  _ tris: UnsafePointer<UInt32>?, _ tcount: Int32,
                  _ selected: Int32, _ active: Int32,
                  _ rgba: UnsafePointer<Float>?) -> Int32 {
    onMain {
        guard SceneSync.active,
              let name = name.map({ String(cString: $0) }),
              let verts, let normals, let matrix16,
              vcount > 0, tcount >= 0, ncount == vcount,
              (tcount == 0 || tris != nil)
        else { return -1 }

        // What the buffers become is SceneMirror's, where the host suites and
        // the mirror's Blender check build objects the same way.
        guard let made = SceneMirror.object(
            named: name, kind: kind.map { String(cString: $0) } ?? "MESH",
            matrix: UnsafeBufferPointer(start: matrix16, count: 16),
            positions: UnsafeBufferPointer(start: verts, count: Int(vcount)),
            normals: UnsafeBufferPointer(start: normals, count: Int(ncount)),
            triangles: UnsafeBufferPointer(start: tris, count: Int(tcount)),
            colour: rgba.map { SIMD4($0[0], $0[1], $0[2], $0[3]) },
            previous: SceneSync.previous[name])
        else { return -1 }
        if made.unchanged { SceneSync.unchanged.insert(name) }

        SceneSync.pending.append(made.object)
        if selected != 0 { SceneSync.pendingSelection.insert(made.object.id) }
        if active != 0 { SceneSync.pendingActive = made.object.id }
        return 0
    }
}

@_cdecl("bk_sync_end")
func bk_sync_end() {
    onMain {
        defer {
            SceneSync.active = false
            SceneSync.pending = []
            SceneSync.previous = [:]
            SceneSync.unchanged = []
            // The merge replaces what is on screen.
            SceneMirror.frameIndex.invalidate()
        }
        guard let scene = PythonSceneBridge.scene else { return }
        // Reconciled against what is already on screen instead of replaced;
        // SceneMirror.merge says why, and is where the host suites test it.
        SceneMirror.merge(SceneSync.pending, into: scene, unchanged: SceneSync.unchanged,
                          selection: SceneSync.pendingSelection, active: SceneSync.pendingActive)
    }
}

/// The edges of the mesh just pushed, for one with no faces: a wire circle,
/// an unfilled curve. `bk_sync_push` carries triangles only, and the mirror
/// used to drop every mesh that had none.
@_cdecl("bk_sync_edges")
func bk_sync_edges(_ name: UnsafePointer<CChar>?, _ edges: UnsafePointer<UInt32>?,
                   _ count: Int32) -> Int32 {
    onMain {
        guard SceneSync.active, let name = name.map({ String(cString: $0) }),
              count >= 0, count == 0 || edges != nil
        else { return -1 }
        let target = SceneSync.pending.last?.name == name
            ? SceneSync.pending.last
            : SceneSync.pending.last { $0.name == name }
        guard let target,
              let checked = SceneMirror.edges(UnsafeBufferPointer(start: edges, count: Int(count)),
                                              vertexCount: target.mesh.vertices.count)
        else { return -1 }
        if SceneMirror.installEdges(checked, on: target) {
            SceneSync.unchanged.remove(name)
        }
        return 0
    }
}

/// Blender's active UV map and seams for the mesh just pushed. `bk_sync_push`
/// carries positions, normals and triangles only, so the UV Editor read "No
/// UVs on this mesh" on the real backend even straight after an unwrap.
@_cdecl("bk_sync_uvs")
func bk_sync_uvs(_ name: UnsafePointer<CChar>?, _ mapName: UnsafePointer<CChar>?,
                 _ loops: UnsafePointer<UInt32>?, _ loopCount: Int32,
                 _ uvs: UnsafePointer<Float>?, _ uvCount: Int32,
                 _ seams: UnsafePointer<UInt32>?, _ seamCount: Int32) -> Int32 {
    onMain {
        guard SceneSync.active, let name = name.map({ String(cString: $0) }),
              loopCount >= 0, uvCount >= 0, seamCount >= 0,
              loopCount == 0 || loops != nil, uvCount == 0 || uvs != nil,
              seamCount == 0 || seams != nil
        else { return -1 }
        let target = SceneSync.pending.last?.name == name
            ? SceneSync.pending.last
            : SceneSync.pending.last { $0.name == name }
        guard let target,
              let changed = SceneMirror.installUVs(
                mapName: mapName.map { String(cString: $0) } ?? "",
                triangleLoops: UnsafeBufferPointer(start: loops, count: Int(loopCount)),
                loopUVs: UnsafeBufferPointer(start: uvs, count: Int(uvCount)),
                seams: UnsafeBufferPointer(start: seams, count: Int(seamCount)),
                on: target)
        else { return -1 }
        if changed { SceneSync.unchanged.remove(name) }
        return 0
    }
}

/// The UV map Blender's UV Editor draws, when the mesh just pushed carries a
/// different one: the object's own mesh before its modifiers. See
/// `SceneMirror.uvLayout`.
@_cdecl("bk_sync_uv_layout")
func bk_sync_uv_layout(_ name: UnsafePointer<CChar>?, _ mapName: UnsafePointer<CChar>?,
                       _ positions: UnsafePointer<Float>?, _ positionCount: Int32,
                       _ triangles: UnsafePointer<UInt32>?, _ triangleCount: Int32,
                       _ loops: UnsafePointer<UInt32>?, _ loopCount: Int32,
                       _ uvs: UnsafePointer<Float>?, _ uvCount: Int32,
                       _ seams: UnsafePointer<UInt32>?, _ seamCount: Int32) -> Int32 {
    onMain {
        guard SceneSync.active, let name = name.map({ String(cString: $0) }),
              positionCount >= 0, triangleCount >= 0, loopCount >= 0, uvCount >= 0, seamCount >= 0,
              positionCount == 0 || positions != nil, triangleCount == 0 || triangles != nil,
              loopCount == 0 || loops != nil, uvCount == 0 || uvs != nil,
              seamCount == 0 || seams != nil
        else { return -1 }
        let target = SceneSync.pending.last?.name == name
            ? SceneSync.pending.last
            : SceneSync.pending.last { $0.name == name }
        guard let target,
              let layout = SceneMirror.uvLayout(
                mapName: mapName.map { String(cString: $0) } ?? "",
                positions: UnsafeBufferPointer(start: positions, count: Int(positionCount)),
                triangles: UnsafeBufferPointer(start: triangles, count: Int(triangleCount)),
                triangleLoops: UnsafeBufferPointer(start: loops, count: Int(loopCount)),
                loopUVs: UnsafeBufferPointer(start: uvs, count: Int(uvCount)),
                seams: UnsafeBufferPointer(start: seams, count: Int(seamCount)))
        else { return -1 }
        target.uvLayout = layout
        return 0
    }
}

/// Blender's edit-mode selection on the object being edited, reported by the
/// mirror once the meshes are in. See `BKScene.mirrorEditSelection`.
@_cdecl("bk_sync_edit_selection")
func bk_sync_edit_selection(_ name: UnsafePointer<CChar>?, _ selectMode: Int32,
                            _ vertexSelected: UnsafePointer<UInt8>?, _ vertexCount: Int32,
                            _ trianglePolygons: UnsafePointer<UInt32>?, _ triangleCount: Int32,
                            _ polygonSelected: UnsafePointer<UInt8>?, _ polygonCount: Int32,
                            _ edgeVertices: UnsafePointer<UInt32>?, _ edgeVertexCount: Int32,
                            _ edgeSelected: UnsafePointer<UInt8>?, _ edgeCount: Int32,
                            _ vertexHidden: UnsafePointer<UInt8>?, _ hiddenCount: Int32,
                            _ vertexCoordinates: UnsafePointer<Float>?, _ coordinateCount: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let n = name.map({ String(cString: $0) }),
              let object = PythonSceneBridge.object(n)
        else { return -1 }
        func copy<T>(_ pointer: UnsafePointer<T>?, _ count: Int32) -> [T] {
            guard let pointer, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
        }
        let report = BlenderEditReport(selectMode: selectMode,
                                       vertexSelected: copy(vertexSelected, vertexCount),
                                       trianglePolygons: copy(trianglePolygons, triangleCount),
                                       polygonSelected: copy(polygonSelected, polygonCount),
                                       edgeVertices: copy(edgeVertices, edgeVertexCount),
                                       edgeSelected: copy(edgeSelected, edgeCount),
                                       vertexHidden: copy(vertexHidden, hiddenCount),
                                       vertexCoordinates: copy(vertexCoordinates, coordinateCount))
        scene.mirrorEditSelection(report, on: object)
        return 0
    }
}

/// Serves the shim's own mesh back to Python, so the extraction code that runs
/// against Blender on device also runs against the shim in the simulator.
/// Passing null buffers queries the sizes.
@_cdecl("bk_scene_mesh_arrays")
func bk_scene_mesh_arrays(_ name: UnsafePointer<CChar>?,
                          _ verts: UnsafeMutablePointer<Float>?, _ vcap: Int32,
                          _ normals: UnsafeMutablePointer<Float>?, _ ncap: Int32,
                          _ tris: UnsafeMutablePointer<UInt32>?, _ tcap: Int32,
                          _ vcount: UnsafeMutablePointer<Int32>?,
                          _ tcount: UnsafeMutablePointer<Int32>?) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let obj = PythonSceneBridge.object(n) else { return -1 }
        let mesh = obj.mesh
        vcount?.pointee = Int32(mesh.vertices.count)
        tcount?.pointee = Int32(mesh.indices.count / 3)

        if let verts, vcap >= Int32(mesh.vertices.count * 3) {
            for (i, v) in mesh.vertices.enumerated() {
                verts[i * 3] = v.position.x
                verts[i * 3 + 1] = v.position.y
                verts[i * 3 + 2] = v.position.z
            }
        }
        if let normals, ncap >= Int32(mesh.vertices.count * 3) {
            for (i, v) in mesh.vertices.enumerated() {
                normals[i * 3] = v.normal.x
                normals[i * 3 + 1] = v.normal.y
                normals[i * 3 + 2] = v.normal.z
            }
        }
        if let tris, tcap >= Int32(mesh.indices.count) {
            for (i, idx) in mesh.indices.enumerated() { tris[i] = UInt32(idx) }
        }
        return 0
    }
}

// MARK: - Edit mode

/// What mode the interface is in, so the shim can answer `object.mode` and
/// `context.mode` honestly.
///
/// It reported "OBJECT" unconditionally before, and `object.mode` did not exist
/// at all. That is why three separate mode bugs reached a device: the simulator
/// had no mode to get wrong, so nothing that depended on one could be tested
/// there.
@_cdecl("bk_scene_mode")
func bk_scene_mode(_ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return -1 }
        return copyOut(scene.mode.bpyMode, out, cap)
    }
}

@_cdecl("bk_scene_set_mode")
func bk_scene_set_mode(_ mode: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let m = mode.map({ String(cString: $0).uppercased() })
        else { return -1 }
        // Driven from the enum so a new mode cannot be reachable from the UI but
        // not from bpy — which is exactly how VERTEX_PAINT and WEIGHT_PAINT were
        // missing here after the mode picker gained them.
        guard let mode = InteractionMode.allCases.first(where: { $0.bpyMode == m }) else { return -1 }
        scene.setMode(mode)
        return 0
    }
}

@_cdecl("bk_scene_mesh_select_all")
func bk_scene_mesh_select_all(_ select: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return 0 }
        return Int32(scene.selectAllEditElements(select != 0))
    }
}

@_cdecl("bk_scene_mesh_op")
func bk_scene_mesh_op(_ op: UnsafePointer<CChar>?, _ amount: Double) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, scene.mode == .edit,
              scene.active != nil,
              let name = op.map({ String(cString: $0) })
        else { return -1 }

        // In SceneOperators.swift, where the host suites run it.
        return scene.editMeshOperator(name, amount: amount)
    }
}

/// The object-level operators, dispatched by name.
///
/// One entry point rather than twenty-seven: these are all "do a thing to the
/// selection", and the shim's job is to answer to Blender's names, not to grow
/// a C function per name. Returns a count where the operator has one, 0 where
/// it does not, and a negative on failure.
@_cdecl("bk_scene_object_op")
func bk_scene_object_op(_ op: UnsafePointer<CChar>?, _ amount: Double) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let name = op.map({ String(cString: $0) })
        else { return -1 }
        let selected = scene.objects.filter { scene.selection.contains($0.id) }

        switch name {
        case "location_clear": scene.clearTransform(location: true)
        case "rotation_clear": scene.clearTransform(rotation: true)
        case "scale_clear":    scene.clearTransform(scale: true)

        case "transform_apply":
            // Blender bakes only the channels the operator was asked for, and
            // which ones matters: `transform_apply(scale=True)` must leave the
            // object's origin alone. Baking the location too moves the origin to
            // the world centre, so any rotation set afterwards swings the object
            // clear across the scene instead of turning it in place.
            //
            // `amount` carries the channel mask: 1 location, 2 rotation, 4 scale.
            // Zero means all three, which is what the operator does when a caller
            // passes nothing.
            // It answers how many it baked: 0 is Blender's CANCELLED.
            let mask = amount == 0 ? 7 : Int(amount)
            return Int32(scene.bakeSelectedTransforms(location: mask & 1 != 0, rotation: mask & 2 != 0,
                                                      scale: mask & 4 != 0))

        case "origin_set":
            // Origin to geometry about the median, the one type the shim has.
            scene.moveSelectedOriginsToMedian()

        // As Blender's (measured in 5.2.1; SceneVisibility.swift): Hide acts
        // on the selection, or with `amount` 1 on everything else, and
        // deselects what it hides; Show Hidden clears the view layer's hide —
        // leaving Disable in Viewports alone — and selects what that brings
        // back unless `amount` is 0. Each answers how many it changed, and 0
        // is Blender's CANCELLED.
        case "hide_view_set":
            return Int32(scene.hideObjects(unselected: amount != 0))
        case "hide_view_clear":
            return Int32(scene.showHiddenObjects(select: amount != 0))

        case "copybuffer":  scene.copySelection()
        case "pastebuffer": return Int32(scene.pasteClipboard())

        case "snap_selected_to_grid":   scene.snapSelectionToGrid(increment: Float(amount == 0 ? 1 : amount))
        case "snap_selected_to_cursor": scene.snapSelectionToCursor(keepOffset: amount != 0)
        case "snap_cursor_to_selected": scene.snapCursorToSelection()
        case "snap_cursor_to_center":   scene.cursor = .zero
        case "snap_cursor_to_grid":     scene.snapCursorToGrid(increment: Float(amount == 0 ? 1 : amount))
        case "snap_selected_to_active": if !scene.snapSelectionToActive() { return -1 }
        case "snap_cursor_to_active":   if !scene.snapCursorToActive() { return -1 }

        case "mirror_x": scene.mirrorSelection(axis: 0)
        case "mirror_y": scene.mirrorSelection(axis: 1)
        case "mirror_z": scene.mirrorSelection(axis: 2)

        case "select_random":
            // Blender's default ratio is 0.5, and it *adds* to the selection.
            let ratio = amount == 0 ? 0.5 : amount
            var picked = scene.selection
            for obj in scene.objects where Double.random(in: 0...1) < ratio { picked.insert(obj.id) }
            scene.selection = picked
            if scene.activeID == nil || !picked.contains(scene.activeID!) {
                scene.activeID = picked.first
            }
            return Int32(picked.count)

        case "keyframe_insert":     return Int32(scene.insertKeyframe())
        case "keyframe_insert_loc": return Int32(scene.insertKeyframe(paths: ["location"]))
        case "keyframe_delete":     return Int32(scene.deleteKeyframe())

        case "modifier_move_up", "modifier_move_down":
            guard let obj = scene.active else { return -1 }
            let index = Int(amount)
            var stack = obj.modifiers
            let up = name == "modifier_move_up"
            // Blender's rule, past either end and around a Multires: CANCELLED.
            guard ModifierStack.canMove(index, up: up, in: stack) else { return 0 }
            stack.swapAt(index, up ? index - 1 : index + 1)
            obj.modifiers = stack
            return 1

        default:
            return -2
        }
        return Int32(selected.count)
    }
}

/// `bpy.ops.object.shade_smooth` / `shade_flat` — object mode, so it must not
/// go through the mesh-edit path that requires an edit-mode selection.
@_cdecl("bk_scene_object_shade")
func bk_scene_object_shade(_ smooth: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return -1 }
        // On the mesh the stack runs over, once: BKScene.setShading says why.
        return Int32(scene.setShading(smooth: smooth != 0))
    }
}

/// `bpy.ops.object.modifier_apply(modifier=…)` — bakes one modifier into the
/// mesh and drops it from the stack. `BKObject.applyModifier(named:)` has what
/// Blender does and what the shim used to get wrong.
@_cdecl("bk_scene_modifier_apply")
func bk_scene_modifier_apply(_ name: UnsafePointer<CChar>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, let obj = scene.active,
              let n = name.map({ String(cString: $0) })
        else { return -1 }
        // -3: Blender's refusal for a Boolean, Shrinkwrap or Lattice with
        // nothing picked, which the simulator used to bake and drop.
        if obj.modifiers.first(where: { $0.name == n })?.isDisabled == true { return -3 }
        return obj.applyModifier(named: n) ? 0 : -2
    }
}

/// `bpy.ops.object.join()` — merges the selection into the active object.
@_cdecl("bk_scene_join_selected")
func bk_scene_join_selected() -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, scene.active != nil else { return -1 }
        // The objects' own meshes, and the target's stack over them once:
        // BKScene.joinSelection says why, with what Blender does.
        return Int32(scene.joinSelection())
    }
}

// MARK: - Animation and sculpting

@_cdecl("bk_scene_keyframe")
func bk_scene_keyframe(_ obj: UnsafePointer<CChar>?, _ path: UnsafePointer<CChar>?,
                       _ frame: Int32, _ insert: Int32) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n),
              let p = path.map({ String(cString: $0) })
        else { return -1 }

        guard insert != 0 else {
            target.animation.remove(path: p, frame: Int(frame))
            return 0
        }
        let value: SIMD3<Float>
        switch p {
        case "location":       value = target.location
        case "rotation_euler": value = target.rotation
        case "scale":          value = target.scale
        default: return -1
        }
        target.animation.insert(path: p, frame: Int(frame), value: value)
        return 0
    }
}

/// Sets the current frame and returns it. A negative frame is a query — the
/// shim uses it to read `frame_current` without a second bridge function.
@_cdecl("bk_scene_set_frame")
func bk_scene_set_frame(_ frame: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return 0 }
        if frame >= 0 { scene.frameCurrent = Int(frame) }
        return Int32(scene.frameCurrent)
    }
}

@_cdecl("bk_scene_sculpt_stroke")
func bk_scene_sculpt_stroke(_ obj: UnsafePointer<CChar>?,
                            _ x: Double, _ y: Double, _ z: Double,
                            _ nx: Double, _ ny: Double, _ nz: Double,
                            _ brush: UnsafePointer<CChar>?,
                            _ radius: Double, _ strength: Double) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n)
        else { return -1 }
        guard let b = brush.map({ String(cString: $0).lowercased() }),
              let kind = SculptBrush(rawValue: b)
        else { return -2 }

        // Over the mesh the stack runs over, installed once; and -3, never a
        // dab, on Blender's evaluated mesh — `_blenderkit.sculpt_stroke` is
        // callable from a script on a device too (BKObject.sculptStandIn).
        let refusal = target.sculptStandIn { cage in
            SculptEngine.stroke(cage,
                                at: SIMD3(Float(x), Float(y), Float(z)),
                                direction: normalize(SIMD3(Float(nx), Float(ny), Float(nz))),
                                brush: kind,
                                radius: Float(radius),
                                strength: Float(strength))
        }
        return refusal == nil ? 0 : -3
    }
}

// MARK: - UV and materials

@_cdecl("bk_scene_uv_project")
func bk_scene_uv_project(_ obj: UnsafePointer<CChar>?, _ kind: UnsafePointer<CChar>?,
                         _ stretch: UnsafeMutablePointer<Double>?,
                         _ count: UnsafeMutablePointer<Int32>?) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n),
              let k = kind.map({ String(cString: $0).lowercased() })
        else { return -1 }

        // Onto the object's own mesh, installed once: BKScene.projectUVs.
        guard let scene = PythonSceneBridge.scene,
              let projected = scene.projectUVs(of: target, kind: k) else { return -2 }
        stretch?.pointee = Double(projected.stretch)
        count?.pointee = Int32(projected.count)
        return 0
    }
}

@_cdecl("bk_scene_material_set")
func bk_scene_material_set(_ obj: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?,
                           _ a: Double, _ b: Double, _ c: Double) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n),
              let k = key.map({ String(cString: $0) })
        else { return -1 }

        switch k {
        case "Base Color":
            target.material.baseColor = SIMD4(Float(a), Float(b), Float(c), 1)
            target.color = target.material.baseColor
        case "Metallic":          target.material.metallic = Float(a)
        case "Roughness":         target.material.roughness = Float(a)
        case "IOR":               target.material.ior = Float(a)
        case "Emission Color":    target.material.emission = SIMD4(Float(a), Float(b), Float(c), 1)
        case "Emission Strength": target.material.emissionStrength = Float(a)
        default: return -2
        }
        return 0
    }
}

/// Read a Principled input back.
///
/// A script that can set a material input but never read one cannot check its
/// own work — and neither can a test. Returns the value in `out`, which holds
/// three components for the colour inputs and one for the rest.
@_cdecl("bk_scene_material_get")
func bk_scene_material_get(_ obj: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?,
                           _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n),
              let k = key.map({ String(cString: $0) }),
              let out
        else { return -1 }

        let m = target.material
        switch k {
        case "Base Color":
            out[0] = Double(m.baseColor.x); out[1] = Double(m.baseColor.y); out[2] = Double(m.baseColor.z)
            return 3
        case "Emission Color":
            out[0] = Double(m.emission.x); out[1] = Double(m.emission.y); out[2] = Double(m.emission.z)
            return 3
        case "Metallic":          out[0] = Double(m.metallic); return 1
        case "Roughness":         out[0] = Double(m.roughness); return 1
        case "IOR":               out[0] = Double(m.ior); return 1
        case "Emission Strength": out[0] = Double(m.emissionStrength); return 1
        default: return -2
        }
    }
}

// MARK: - Texture painting

@_cdecl("bk_scene_paint")
func bk_scene_paint(_ obj: UnsafePointer<CChar>?,
                    _ u: Double, _ v: Double,
                    _ r: Double, _ g: Double, _ b: Double,
                    _ radius: Double, _ strength: Double) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n) else { return -1 }
        guard target.mesh.hasUVs else { return -2 }

        if target.texture == nil {
            let image = TextureImage(name: "Untitled")
            image.fillChecker()
            target.texture = image
        }
        target.texture?.paint(at: SIMD2(Float(u), Float(v)),
                              radius: Float(radius),
                              colour: SIMD4(Float(r), Float(g), Float(b), 1),
                              strength: Float(strength))
        target.textureVersion &+= 1
        return 0
    }
}

@_cdecl("bk_scene_texture_info")
func bk_scene_texture_info(_ obj: UnsafePointer<CChar>?,
                           _ w: UnsafeMutablePointer<Int32>?,
                           _ h: UnsafeMutablePointer<Int32>?,
                           _ painted: UnsafeMutablePointer<Int32>?) -> Int32 {
    onMain {
        guard let n = obj.map({ String(cString: $0) }),
              let target = PythonSceneBridge.object(n),
              let image = target.texture else { return -1 }
        w?.pointee = Int32(image.width)
        h?.pointee = Int32(image.height)
        // Pixels differing from the checker's two greys — a crude but honest
        // measure of how much has actually been painted.
        var count: Int32 = 0
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            let px = image.pixels[i]
            if px != 0xC0 && px != 0x60 { count += 1 }
        }
        painted?.pointee = count
        return 0
    }
}

@_cdecl("bk_scene_set_timeline")
func bk_scene_set_timeline(_ start: Int32, _ end: Int32, _ current: Int32) {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return }
        scene.frameStart = Int(start)
        scene.frameEnd = Int(end)
        scene.frameCurrent = Int(current)
    }
}

// MARK: - Animation
//
// `_blenderkit_anim` hands the timeline Blender's range, rate, settings and keys
// after each full mirror, and a frame change's matrices and deformed meshes
// without one. These unpack the buffers; AnimationMirror.swift, which the host
// tests can compile, applies them.

private func animationBuffer<T>(_ pointer: UnsafePointer<T>?, _ count: Int32) -> UnsafeBufferPointer<T> {
    guard let pointer, count > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }
    return UnsafeBufferPointer(start: pointer, count: Int(count))
}

@_cdecl("bk_anim_set_state")
func bk_anim_set_state(_ ints: UnsafePointer<Int32>?, _ doubles: UnsafePointer<Double>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, let ints, let doubles else { return -1 }
        AnimationMirror.apply(AnimationMirror.State(
            start: Int(ints[0]), end: Int(ints[1]), current: Int(ints[2]),
            subframe: Float(doubles[0]), fps: doubles[1],
            usePreviewRange: ints[3] != 0, previewStart: Int(ints[4]), previewEnd: Int(ints[5]),
            autoKey: ints[6] != 0, autoKeyReplace: ints[7] != 0,
            onlyInsertAvailable: ints[8] != 0, onlySelectedKeys: ints[9] != 0,
            loopMode: PlaybackLoopMode(rawValue: Int(ints[10])) ?? .infinite), to: scene)
        return 0
    }
}

@_cdecl("bk_anim_get_state")
func bk_anim_get_state(_ ints: UnsafeMutablePointer<Int32>?, _ doubles: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, let ints, let doubles else { return -1 }
        let s = AnimationMirror.state(of: scene)
        let values = [s.start, s.end, s.current, s.usePreviewRange ? 1 : 0, s.previewStart,
                      s.previewEnd, s.autoKey ? 1 : 0, s.autoKeyReplace ? 1 : 0,
                      s.onlyInsertAvailable ? 1 : 0, s.onlySelectedKeys ? 1 : 0, s.loopMode.rawValue]
        for (i, value) in values.enumerated() { ints[i] = Int32(clamping: value) }
        doubles[0] = Double(s.subframe)
        doubles[1] = s.fps
        return 0
    }
}

@_cdecl("bk_anim_set_keys")
func bk_anim_set_keys(_ names: UnsafePointer<UInt8>?, _ namesLength: Int32,
                      _ counts: UnsafePointer<UInt32>?, _ objectCount: Int32,
                      _ frames: UnsafePointer<Float>?, _ selected: UnsafePointer<UInt8>?,
                      _ keyCount: Int32,
                      _ sceneFrames: UnsafePointer<Float>?, _ sceneSelected: UnsafePointer<UInt8>?,
                      _ sceneKeyCount: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene else { return -1 }
        let applied = AnimationMirror.applyKeys(
            names: AnimationMirror.names(animationBuffer(names, namesLength)),
            counts: animationBuffer(counts, objectCount),
            frames: animationBuffer(frames, keyCount),
            selected: animationBuffer(selected, keyCount),
            sceneFrames: animationBuffer(sceneFrames, sceneKeyCount),
            sceneSelected: animationBuffer(sceneSelected, sceneKeyCount),
            to: scene)
        return applied ? 0 : -1
    }
}

@_cdecl("bk_anim_set_frame")
func bk_anim_set_frame(_ frame: Int32, _ subframe: Double,
                       _ names: UnsafePointer<UInt8>?, _ namesLength: Int32,
                       _ matrices: UnsafePointer<Double>?, _ matrixCount: Int32) -> Int32 {
    onMain {
        // The frame's last call: its sync_local and anim_mesh calls came
        // first and shared the name index, which goes with the frame.
        defer { SceneMirror.frameIndex.invalidate() }
        guard let scene = PythonSceneBridge.scene else { return -1 }
        return Int32(AnimationMirror.applyFrame(
            Int(frame), subframe: Float(subframe),
            names: AnimationMirror.names(animationBuffer(names, namesLength)),
            matrices: animationBuffer(matrices, matrixCount * 16), to: scene))
    }
}

@_cdecl("bk_anim_set_mesh")
func bk_anim_set_mesh(_ name: UnsafePointer<CChar>?, _ verts: UnsafePointer<Float>?, _ vcount: Int32,
                      _ normals: UnsafePointer<Float>?, _ ncount: Int32,
                      _ tris: UnsafePointer<UInt32>?, _ tcount: Int32,
                      _ edges: UnsafePointer<UInt32>?, _ ecount: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let name = name.map({ String(cString: $0) }) else { return -1 }
        // -1: a mesh with faces, whose edges come from its triangles.
        return Int32(AnimationMirror.applyMesh(named: name,
                                               positions: animationBuffer(verts, vcount),
                                               normals: animationBuffer(normals, ncount),
                                               triangles: animationBuffer(tris, tcount),
                                               edges: ecount < 0 ? nil : animationBuffer(edges, ecount),
                                               to: scene, index: SceneMirror.frameIndex))
    }
}

@_cdecl("bk_anim_notice")
func bk_anim_notice(_ text: UnsafePointer<CChar>?) {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let text = text.map({ String(cString: $0) }) else { return }
        AnimationMirror.notice(text, on: scene)
    }
}

@_cdecl("bk_anim_channels")
func bk_anim_channels(_ name: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<CChar>?,
                      _ cap: Int32) -> Int32 {
    onMain {
        guard let n = name.map({ String(cString: $0) }),
              let object = PythonSceneBridge.object(n) else { return -1 }
        let bytes = Array(AnimationMirror.channels(of: object).utf8)
        guard let out, Int(cap) > bytes.count else { return Int32(bytes.count) }
        bytes.withUnsafeBufferPointer { source in
            out.withMemoryRebound(to: UInt8.self, capacity: Int(cap)) { destination in
                if let base = source.baseAddress { destination.update(from: base, count: bytes.count) }
                destination[bytes.count] = 0
            }
        }
        return Int32(bytes.count)
    }
}

// MARK: - Tool settings
//
// `_blenderkit_tools` hands the header Blender's snapping, pivot point,
// proportional editing and 3D cursor after each full mirror, and the shim reads
// them back before merging one change into them. Thin for the same reason the
// animation pair is: TransformTools.swift is where the work is, and the host
// test suites can compile that.

@_cdecl("bk_tool_set_state")
func bk_tool_set_state(_ ints: UnsafePointer<Int32>?, _ doubles: UnsafePointer<Double>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, let ints, let doubles,
              let state = TransformToolsMirror.state(
                ints: (0..<11).map { Int(ints[$0]) },
                doubles: (0..<5).map { doubles[$0] })
        else { return -1 }
        TransformToolsMirror.apply(state, to: scene)
        return 0
    }
}

@_cdecl("bk_tool_get_state")
func bk_tool_get_state(_ ints: UnsafeMutablePointer<Int32>?, _ doubles: UnsafeMutablePointer<Double>?) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene, let ints, let doubles else { return -1 }
        let scalars = TransformToolsMirror.scalars(TransformToolsMirror.state(of: scene))
        for (i, value) in scalars.ints.enumerated() { ints[i] = Int32(clamping: value) }
        for (i, value) in scalars.doubles.enumerated() { doubles[i] = value }
        return 0
    }
}
