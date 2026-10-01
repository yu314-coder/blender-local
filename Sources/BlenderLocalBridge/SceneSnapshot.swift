import Foundation
import simd

// A serialisable picture of the scene. It backs two features at once: the undo
// stack pushes one before every operator, and File > Save writes one to disk.

public struct ObjectState: Codable, Sendable {
    public var name: String
    public var kind: String
    public var location: [Float]
    public var rotation: [Float]
    public var scale: [Float]
    public var color: [Float]
    public var visible: Bool
    public var modifiers: [Modifier]
    /// A camera's, light's or empty's display, as `ObjectDisplay` writes it.
    /// Absent for everything else, and in files written before it existed.
    public var displayType: String? = nil
    public var displayData: String? = nil
    public var displayRecord: String? = nil
    /// The shim's keyframes. Blender keeps an object's animation with the
    /// object; an undo that rebuilt objects without it lost every key in the
    /// scene. Optional, so files saved before it existed still open.
    public var animation: AnimationData? = nil
    /// Blender's two reasons for not drawing an object, which `visible`
    /// alone cannot tell apart: the view layer's hide (H, the Outliner's eye)
    /// and Disable in Viewports (the Outliner's monitor, Properties ▸ Show in
    /// Viewports). The simulator's shim sets both. Restored from `visible`
    /// alone, a disabled object came back hidden instead — its monitor gone,
    /// its eye closed, and Alt+H bringing back what Blender's Show Hidden
    /// leaves alone. Optional, so files saved before they existed still open.
    public var hiddenInViewLayer: Bool? = nil
    public var disabledInViewports: Bool? = nil
}

public struct SceneSnapshot: Codable, Sendable {
    /// Bumped when the format changes, so an old file can be rejected with a
    /// clear message instead of decoding into nonsense.
    public var version: Int = 1
    public var objects: [ObjectState]
    /// Selection is stored by name; UUIDs are regenerated on load.
    public var selection: [String]
    public var active: String?

    /// Geometry for objects that cannot be rebuilt from their primitive.
    ///
    /// Restoring used to rebuild every object from `kind`, which is right for
    /// something the Add menu made and wrong for everything else. With the real
    /// module the sync reports every object as a cube — geometry is what it
    /// carries, not provenance — so an undo rebuilt the entire scene as cubes.
    ///
    /// Held outside the Codable surface: a saved scene keeps describing
    /// primitives and modifiers, while undo, which lives only in memory, keeps
    /// the meshes it needs.
    public var meshes: [String: MeshData] = [:]
    /// The names in `meshes` whose mesh is an evaluator's output — Blender's
    /// evaluated mesh, installed with `setEvaluatedMesh` — rather than a base
    /// the Swift stack runs over. In memory only, like `meshes`.
    ///
    /// `meshes` used to hold `mesh`, the stack's output, for every mirrored
    /// object, and `restore` put it back as the base and ran the stack over it
    /// again: measured through `UndoStack` in the simulator, a cube with
    /// Mirror X and Clipping, one vertex dragged, went 24 base / 48 shown
    /// after the drag and 48 / 96 after an undo and a redo (round 2's review).
    public var evaluatedMeshes: Set<String> = []

    /// The frame range, which Blender keeps in the file and restores on undo.
    public var frameStart: Int? = nil
    public var frameEnd: Int? = nil

    /// The 3D cursor and the transform tool settings, which Blender also keeps
    /// in the file. Without them the simulator's undo of a Cursor to Selected
    /// left the cursor where the operator had put it. Optional, so a snapshot
    /// written before they existed still decodes.
    public var cursor: [Float]? = nil
    public var tools: TransformToolSettings? = nil

    /// Texture Paint's pixels and UV maps, by object name, for the simulator's
    /// undo. In memory only, like `meshes`: on device the undo step is a
    /// .blend with the image packed into it. Images are kept as shared tiles
    /// (TexturePaintUndo.swift), so a step costs only what changed.
    public var paint: [String: (surface: PaintSurface, images: [String: TexturePaintUndoImage])] = [:]

    enum CodingKeys: String, CodingKey {
        case version, objects, selection, active
        case frameStart, frameEnd
        case cursor, tools
    }
}

public extension BKScene {

    func snapshot() -> SceneSnapshot {
        let selected = Set(selection)
        return SceneSnapshot(
            objects: objects.map { obj in
                ObjectState(name: obj.name,
                            kind: obj.kind.rawValue,
                            location: [obj.location.x, obj.location.y, obj.location.z],
                            rotation: [obj.rotation.x, obj.rotation.y, obj.rotation.z],
                            scale: [obj.scale.x, obj.scale.y, obj.scale.z],
                            color: [obj.color.x, obj.color.y, obj.color.z, obj.color.w],
                            visible: obj.visible,
                            modifiers: obj.modifiers,
                            animation: obj.animation.isEmpty ? nil : obj.animation,
                            hiddenInViewLayer: obj.hiddenInViewLayer,
                            disabledInViewports: obj.disabledInViewports)
                    .carryingDisplay(of: obj)
            },
            selection: objects.filter { selected.contains($0.id) }.map(\.name),
            active: active?.name,
            // The geometry the object is rebuilt from: the base the stack
            // runs over, or the evaluator's output when that is what it holds.
            meshes: Dictionary(
                objects.filter(\.isMirrored).map { ($0.name, $0.meshIsEvaluated ? $0.mesh : $0.evaluatedBase) },
                uniquingKeysWith: { a, _ in a }),
            evaluatedMeshes: Set(objects.lazy.filter { $0.isMirrored && $0.meshIsEvaluated }.map(\.name)),
            frameStart: frameStart,
            frameEnd: frameEnd,
            cursor: [cursor.x, cursor.y, cursor.z],
            tools: tools,
            paint: paintSnapshot()
        )
    }

    /// Every painted image, by object, so an undo step keeps the pixels it was
    /// taken with rather than whatever a later stroke made them.
    private func paintSnapshot() -> [String: (surface: PaintSurface, images: [String: TexturePaintUndoImage])] {
        var out: [String: (surface: PaintSurface, images: [String: TexturePaintUndoImage])] = [:]
        for obj in objects {
            guard let surface = obj.paintSurface else { continue }
            var images: [String: TexturePaintUndoImage] = [:]
            for name in surface.slotImages where !name.isEmpty {
                guard let image = TexturePaintImages.image(named: name) else { continue }
                images[name] = TexturePaintUndoImage.capture(image)
            }
            out[obj.name] = (surface, images)
        }
        return out
    }

    func restore(_ snapshot: SceneSnapshot) {
        func vec3(_ a: [Float]) -> SIMD3<Float> {
            a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : .zero
        }

        var restoredImages: [String: TextureImage] = [:]
        objects = snapshot.objects.map { state in
            let obj = BKObject(name: state.name,
                               kind: PrimitiveKind(rawValue: state.kind) ?? .cube,
                               location: vec3(state.location),
                               rotation: vec3(state.rotation),
                               scale: state.scale.count >= 3 ? vec3(state.scale) : .one)
            // Geometry that did not come from the primitive is put back
            // directly; rebuilding it from `kind` would lose it.
            if let mesh = snapshot.meshes[state.name] {
                if snapshot.evaluatedMeshes.contains(state.name) {
                    obj.setEvaluatedMesh(mesh)
                } else {
                    obj.setMirroredMesh(mesh)
                }
            }
            obj.visible = state.visible
            // A step or a file from before the two flags were kept knows only
            // whether the object was drawn, and the eye is the likelier reason.
            obj.hiddenInViewLayer = state.hiddenInViewLayer ?? !state.visible
            obj.disabledInViewports = state.disabledInViewports ?? false
            if state.color.count >= 4 {
                obj.color = SIMD4(state.color[0], state.color[1], state.color[2], state.color[3])
            }
            // Assigning the stack rebuilds the mesh through the didSet.
            obj.modifiers = state.modifiers
            // A camera, light or empty comes back as one, not as the cube its
            // placeholder kind names.
            if let display = state.overlayDisplay { obj.install(display) }
            if let animation = state.animation { obj.animation = animation }
            if let paint = snapshot.paint[state.name] {
                obj.paintSurface = paint.surface
                for (name, image) in paint.images where restoredImages[name] == nil {
                    // A fresh image, so painting after the undo cannot reach
                    // back into the step it came from — one per image, however
                    // many objects share it.
                    let restored = image.restore()
                    restoredImages[name] = restored
                    TexturePaintImages.register(restored, as: name)
                }
                obj.texture = paint.surface.activeImageName.flatMap { TexturePaintImages.image(named: $0) }
                obj.textureVersion &+= 1
            }
            return obj
        }

        let byName = Dictionary(objects.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        selection = Set(snapshot.selection.compactMap { byName[$0] })
        activeID = snapshot.active.flatMap { byName[$0] }
        if let start = snapshot.frameStart, let end = snapshot.frameEnd {
            frameStart = start
            frameEnd = end
        }
        if let stored = snapshot.cursor, stored.count >= 3 {
            cursor = vec3(stored)
        }
        if let stored = snapshot.tools { tools = stored }
    }
}

/// Blender pushes one undo step per operator, and that is the granularity used
/// here: a whole gesture or menu action, never an intermediate frame.
@Observable
public final class UndoStack {
    private var steps: [(name: String, snapshot: SceneSnapshot)] = []
    /// Index of the state currently shown. -1 means nothing recorded yet.
    private var cursor: Int = -1
    /// Blender's default is 32 steps; snapshots here are small, so 64 is cheap.
    private let limit = 64

    public init() {}

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor >= 0 && cursor < steps.count - 1 }
    public var undoName: String? { canUndo ? steps[cursor].name : nil }
    public var redoName: String? { canRedo ? steps[cursor + 1].name : nil }

    /// Records the state *after* an operator ran, labelled with its name.
    ///
    /// The first call also seeds the stack with that state, so the very first
    /// undo has somewhere to go back to.
    public func push(_ name: String, _ scene: BKScene) {
        if cursor < steps.count - 1 {
            steps.removeSubrange((cursor + 1)...)   // a new action discards the redo branch
        }
        steps.append((name, scene.snapshot()))
        if steps.count > limit {
            steps.removeFirst(steps.count - limit)
        }
        cursor = steps.count - 1
    }

    /// Overwrites the step on top instead of adding one.
    ///
    /// Adjusting the last operation is an edit *to* that operation, so it
    /// should leave the stack the same height it found it. Without this,
    /// scrubbing a slider would bury the state before the add under sixty
    /// intermediate ones, and undo would have to be pressed sixty times to get
    /// back to it.
    public func replaceTop(_ name: String, _ scene: BKScene) {
        guard cursor >= 0 else { return push(name, scene) }
        steps[cursor] = (name, scene.snapshot())
    }

    /// Seeds the stack with the opening state so the first operator is undoable.
    public func seed(_ scene: BKScene) {
        guard steps.isEmpty else { return }
        steps = [("Original", scene.snapshot())]
        cursor = 0
    }

    @discardableResult
    public func undo(into scene: BKScene) -> String? {
        guard canUndo else { return nil }
        let undone = steps[cursor].name
        cursor -= 1
        scene.restore(steps[cursor].snapshot)
        return undone
    }

    @discardableResult
    public func redo(into scene: BKScene) -> String? {
        guard canRedo else { return nil }
        cursor += 1
        scene.restore(steps[cursor].snapshot)
        return steps[cursor].name
    }

    public func clear() {
        steps.removeAll()
        cursor = -1
    }
}

/// Reading and writing scenes on disk. Blender uses `.blend`; this is a small
/// JSON document with its own extension, since it stores Blender Local's scene,
/// not Blender's.
public enum SceneDocument {

    public static let fileExtension = "bkit"

    public static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the scene is kept between launches, so closing the app does not
    /// lose work.
    public static var autosaveURL: URL {
        documentsURL.appendingPathComponent("autosave.\(fileExtension)")
    }

    public static func write(_ scene: BKScene, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scene.snapshot()).write(to: url, options: .atomic)
    }

    public static func read(_ url: URL, into scene: BKScene) throws {
        let snapshot = try JSONDecoder().decode(SceneSnapshot.self,
                                                from: Data(contentsOf: url))
        guard snapshot.version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scene.restore(snapshot)
    }

    public static func listSaved() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == fileExtension || $0.pathExtension == "blend" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

// MARK: - File ▸ Export

public extension BpySession {

    /// The exporters File ▸ Export offers, by the extension each writes.
    ///
    /// Kept beside the call that runs them so the menu and the launch hook
    /// that tests it cannot drift apart: an exporter that fails its poll
    /// writes nothing, and a menu item that quietly writes nothing is the
    /// worst way to find that out.
    static let exporters: [(ext: String, op: String, label: String)] = [
        ("glb", "export_scene.gltf", "glTF Binary (.glb)"),
        ("obj", "wm.obj_export", "Wavefront (.obj)"),
        ("usd", "wm.usd_export", "Universal Scene Description (.usd)"),
        ("stl", "wm.stl_export", "STL (.stl)"),
        ("ply", "wm.ply_export", "Stanford PLY (.ply)"),
        ("fbx", "export_scene.fbx", "FBX (.fbx)"),
        ("abc", "wm.alembic_export", "Alembic (.abc)"),
    ]

    /// The importers File ▸ Import Model… offers, by file extension.
    ///
    /// `import_scene.*` are Python add-ons; `wm.*_import` are Blender's own C++
    /// operators, and those poll for a window. That is the whole reason an
    /// import has to run where the menus run rather than on the script thread.
    static let importers: [String: String] = [
        "obj": "wm.obj_import", "glb": "import_scene.gltf", "gltf": "import_scene.gltf",
        "usd": "wm.usd_import", "usda": "wm.usd_import", "usdc": "wm.usd_import",
        "stl": "wm.stl_import", "ply": "wm.ply_import", "fbx": "import_scene.fbx",
        "abc": "wm.alembic_import",
    ]

    /// The line an importer is run by.
    static func importPython(_ op: String, from path: String) -> String {
        "bpy.ops.\(op)(filepath=\(Bpy.quote(path)))"
    }

    /// The line an exporter is run by. `print` is how the outcome comes back:
    /// a Blender operator returns a set, and `{'FINISHED'}` is the only one
    /// that means a file was written.
    static func exportPython(_ op: String, to path: String) -> String {
        "import bpy; print(bpy.ops.\(op)(filepath=\(Bpy.quote(path))))"
    }

    /// Runs one exporter into Documents, and returns where it went.
    ///
    /// Nil when the operator did not finish *or* wrote nothing: several of
    /// Blender's exporters report success having written no file, and a menu
    /// that says "Exported" without a file to show for it is a lie.
    func exportModel(_ op: String, ext: String,
                     name: String = "Export-" + UUID().uuidString) -> URL? {
        let url = SceneDocument.documentsURL.appendingPathComponent(name + "." + ext)
        let result = capture(Self.exportPython(op, to: url.path))
        guard result?.contains("FINISHED") == true,
              let size = try? FileManager.default
                  .attributesOfItem(atPath: url.path)[.size] as? Int, size > 0
        else { return nil }
        return url
    }
}
