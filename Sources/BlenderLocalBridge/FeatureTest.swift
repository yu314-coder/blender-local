import Foundation

/// Test All Features: every feature of the app run on the device it is
/// installed on, one after another, through the code its button, menu row or
/// stroke runs, and rated by how it feels.
///
/// An app-only feature, so it keeps its own name. Preferences ▸ Testing has
/// its button; it ships in Release, because the TestFlight build is the one a
/// user holds and calls hard to use, and the point is to say which features
/// are smooth on that iPad and which are not.
///
/// The Self-Test asks whether the crash fixes hold; this asks what a tap
/// costs. So the features do not run as one Python call: each is the Swift
/// call its control makes (`FeatureTestRunner`, in the interface), measured
/// from the call to the 3D View's next drawn frame (`FrameClock`), with the
/// longest the main thread went without answering meanwhile
/// (`MainThreadWatchdog`). A drag, a stroke or playback is synthesized over a
/// second or two and its frame times kept.
///
/// What is here is the part that needs no interface: the inventory, the
/// rating, the report and its lines, and the Python that saves the user's
/// scene first and puts it back after (`_blenderkit_featuretest`, which
/// reuses the Self-Test's own fingerprint and scratch scene).
public enum FeatureTest {
    // MARK: Inventory

    /// How a feature is measured.
    public enum Kind: String, Sendable {
        /// A tap: the call, the mirror into the 3D View, the next frame.
        case command
        /// A drag, a stroke or playback, synthesized over a second or two:
        /// its frame times as well as its stalls.
        case continuous
        /// A render, a save, an import, Image to 3D: held to whether the
        /// interface stayed responsive and showed progress, its total time
        /// reported but not held to 250 ms.
        case long
    }

    /// Whether, and how, a feature is in the run.
    public enum Coverage: Sendable, Equatable {
        case run(Kind)
        /// Run only when the sheet's switch for it is on; otherwise listed as
        /// not tested, with the reason.
        case optIn(Kind, reason: String)
        case notTested(reason: String)
    }

    /// One user-facing feature, by its name in the app (Blender's own name
    /// for Blender's features).
    public struct Entry: Sendable, Equatable, Identifiable {
        public let key: String
        public let area: String
        public let name: String
        public let coverage: Coverage
        public var id: String { key }

        public init(_ key: String, _ area: String, _ name: String, _ coverage: Coverage) {
            self.key = key
            self.area = area
            self.name = name
            self.coverage = coverage
        }

        public var kind: Kind? {
            switch coverage {
            case .run(let kind), .optIn(let kind, _): return kind
            case .notTested: return nil
            }
        }
    }

    /// The large mesh the drags and strokes work on: Add ▸ UV Sphere adjusted
    /// in its redo panel to this many segments and rings — 64,226 vertices,
    /// the size of a model being sculpted.
    public static let sphereSegments = 288
    public static let sphereRings = 224
    public static var sphereVertices: Int { sphereSegments * (sphereRings - 1) + 2 }

    /// How long a synthesized drag or stroke lasts.
    public static let strokeSeconds: TimeInterval = 1.5

    /// Every feature, in the order the run takes them, each tested or listed
    /// with why it is not. `FeatureTestRunner` has a case for every key that
    /// runs (held to it by tests/featuretest).
    public static let inventory: [Entry] = {
        let mesh = { (op: LastOperator.Mesh) in "Mesh ▸ \(op.displayName)" }
        var all: [Entry] = [
            Entry("workspace.scripting", "Workspaces", "Scripting tab", .run(.command)),
            Entry("workspace.layout", "Workspaces", "Layout tab", .run(.command)),
            Entry("file.new", "File", "File ▸ New ▸ General", .run(.command)),
        ]
        all += PrimitiveKind.allCases.map {
            Entry("add.\($0.rawValue)", "Add", "Add ▸ Mesh ▸ \($0.displayName)", .run(.command))
        }
        all += [
            Entry("add.curve", "Add", "Add ▸ Curve ▸ Bézier", .run(.command)),
            Entry("add.text", "Add", "Add ▸ Text", .run(.command)),
            Entry("add.empty", "Add", "Add ▸ Empty ▸ Plain Axes", .run(.command)),
            Entry("add.light", "Add", "Add ▸ Light ▸ Point", .run(.command)),
            Entry("add.camera", "Add", "Add ▸ Camera", .run(.command)),
            Entry("add.lattice", "Add", "Add ▸ Lattice", .run(.command)),
            Entry("add.reference", "Add", "Add ▸ Image ▸ Reference", .run(.command)),
            Entry("select.all_objects", "Select", "Select ▸ All (Object Mode)", .run(.command)),
            Entry("object.delete", "Object", "Object ▸ Delete", .run(.command)),
            Entry("redo.uv_sphere", "Adjust Last Operation",
                  "Adjust Last Operation: Add UV Sphere's Segments and Rings", .run(.command)),
            Entry("view.frame_all", "View", "View ▸ Frame All", .run(.command)),
            Entry("view.orbit", "View", "Orbit (a one-finger drag)", .run(.continuous)),
            Entry("view.pan", "View", "Pan (a two-finger drag)", .run(.continuous)),
            Entry("view.zoom", "View", "Zoom (a pinch)", .run(.continuous)),
            Entry("view.wireframe", "View", "Viewport Shading ▸ Wireframe", .run(.command)),
            Entry("view.material", "View", "Viewport Shading ▸ Material Preview", .run(.command)),
            Entry("view.solid", "View", "Viewport Shading ▸ Solid", .run(.command)),
            Entry("view.xray", "View", "Toggle X-Ray", .run(.command)),
            Entry("view.perspective", "View", "View ▸ Perspective/Orthographic", .run(.command)),
            Entry("view.rendered", "View", "Viewport Shading ▸ Rendered",
                  .notTested(reason: "greyed out in this build: the 3D View has no rendered shading")),
            Entry("select.tap_object", "Select", "Tweak: a tap on an object", .run(.command)),
            Entry("tool.move", "Tools", "Move (a drag of the gizmo)", .run(.continuous)),
            Entry("tool.rotate", "Tools", "Rotate (a drag of the gizmo)", .run(.continuous)),
            Entry("tool.scale", "Tools", "Scale (a drag of the gizmo)", .run(.continuous)),
            Entry("transform.move_g", "Tools", "Move (G): X, 1, Confirm", .run(.command)),
            Entry("transform.rotate_r", "Tools", "Rotate (R): Z, 30, Confirm", .run(.command)),
            Entry("transform.scale_s", "Tools", "Scale (S): X, 1.25, Confirm", .run(.command)),
            Entry("edit.undo", "Undo", "Undo", .run(.command)),
            Entry("edit.redo", "Undo", "Redo", .run(.command)),
            Entry("properties.location", "Properties", "Properties ▸ Object ▸ Location X", .run(.command)),
            Entry("object.shade_smooth", "Object", "Object ▸ Shade Smooth", .run(.command)),
            Entry("object.shade_flat", "Object", "Object ▸ Shade Flat", .run(.command)),
            Entry("object.shade_auto_smooth", "Object", "Object ▸ Shade Auto Smooth", .run(.command)),
            Entry("object.duplicate", "Object", "Object ▸ Duplicate Objects", .run(.command)),
            Entry("object.set_origin", "Object", "Object ▸ Set Origin ▸ Origin to Geometry", .run(.command)),
            Entry("object.apply_scale", "Object", "Object ▸ Apply ▸ Scale", .run(.command)),
            Entry("object.hide", "Object", "Object ▸ Show/Hide ▸ Hide Selected", .run(.command)),
            Entry("object.reveal", "Object", "Object ▸ Show/Hide ▸ Show Hidden Objects", .run(.command)),
            Entry("view.local_view", "View", "View ▸ Local View ▸ Toggle Local View", .run(.command)),
            Entry("object.snap_cursor", "Object", "Object ▸ Snap ▸ Cursor to Selected", .run(.command)),
            Entry("tool.cursor", "Tools", "Cursor (a tap places the 3D cursor)", .run(.command)),
            Entry("tool.measure", "Tools", "Measure (a drag makes a ruler)", .run(.continuous)),
            Entry("object.parent", "Object", "Object ▸ Parent ▸ Object", .run(.command)),
            Entry("object.clear_parent", "Object", "Object ▸ Parent ▸ Clear Parent", .run(.command)),
            Entry("object.join", "Object", "Object ▸ Join", .run(.command)),
            Entry("object.convert", "Object", "Object ▸ Convert ▸ Mesh", .run(.command)),
            Entry("object.move_to_collection", "Object",
                  "Object ▸ Collection ▸ Move to Collection ▸ New Collection", .run(.command)),
            Entry("outliner.select", "Outliner", "Outliner: a tap on a row", .run(.command)),
            Entry("outliner.hide", "Outliner", "Outliner: Hide in Viewport", .run(.command)),
            Entry("outliner.rename", "Outliner", "Outliner: Rename", .run(.command)),
            Entry("properties.material", "Properties", "Properties ▸ Material ▸ Base Color", .run(.command)),
            Entry("modifier.add", "Properties",
                  "Properties ▸ Modifiers ▸ Add Modifier ▸ Subdivision Surface", .run(.command)),
            Entry("modifier.edit", "Properties", "Modifiers: Levels Viewport", .run(.command)),
            Entry("modifier.apply", "Properties", "Modifiers: Apply", .run(.command)),
            Entry("constraint.add", "Properties",
                  "Properties ▸ Constraints ▸ Add Object Constraint ▸ Copy Location", .run(.command)),
            Entry("camera.lens", "Properties", "Properties ▸ Camera ▸ Focal Length", .run(.command)),
            Entry("light.power", "Properties", "Properties ▸ Light ▸ Power", .run(.command)),
            Entry("mode.edit_large", "Edit Mode", "Edit Mode, on the large sphere", .run(.command)),
            Entry("mode.object_large", "Edit Mode", "Object Mode from Edit Mode, on the large sphere",
                  .run(.command)),
            Entry("edit.select_edge", "Edit Mode", "Mesh Select Mode ▸ Edge", .run(.command)),
            Entry("edit.select_face", "Edit Mode", "Mesh Select Mode ▸ Face", .run(.command)),
            Entry("edit.select_vertex", "Edit Mode", "Mesh Select Mode ▸ Vertex", .run(.command)),
            Entry("select.all_elements", "Select", "Select ▸ All (Edit Mode)", .run(.command)),
            Entry("select.none", "Select", "Select ▸ None", .run(.command)),
            Entry("select.invert", "Select", "Select ▸ Invert", .run(.command)),
            Entry("mesh.subdivide", "Mesh", mesh(.subdivide), .run(.command)),
            Entry("mesh.extrude", "Mesh", mesh(.extrude), .run(.command)),
            Entry("mesh.inset", "Mesh", mesh(.inset), .run(.command)),
            Entry("mesh.bevel", "Mesh", mesh(.bevel), .run(.command)),
            Entry("mesh.merge_by_distance", "Mesh", mesh(.mergeByDistance), .run(.command)),
            Entry("select.tap_vertex", "Select", "Tweak: a tap on a vertex", .run(.command)),
            Entry("mesh.delete_vertices", "Mesh", "Mesh ▸ Delete ▸ Vertices", .run(.command)),
            Entry("select.box", "Select", "Select Box (a drag)", .run(.continuous)),
            Entry("select.more", "Select", "Select ▸ More/Less ▸ More", .run(.command)),
            Entry("select.linked", "Select", "Select ▸ Select Linked ▸ Linked", .run(.command)),
            Entry("tool.loop_cut", "Tools", "Loop Cut (a tap shows the ring, a tap cuts)", .run(.command)),
            Entry("tool.knife", "Tools", "Knife (two taps, then Confirm)", .run(.command)),
            Entry("mode.vertex_paint", "Paint", "Vertex Paint", .run(.command)),
            Entry("paint.vertex", "Paint", "Vertex Paint: a Brush stroke", .run(.continuous)),
            Entry("mode.weight_paint", "Paint", "Weight Paint", .run(.command)),
            Entry("paint.weight", "Paint", "Weight Paint: a Brush stroke", .run(.continuous)),
            Entry("mode.texture_paint", "Paint", "Texture Paint (adds UVs and an image to paint)",
                  .run(.command)),
            Entry("paint.texture", "Paint", "Texture Paint: a Brush stroke", .run(.continuous)),
            Entry("mode.sculpt", "Sculpt", "Sculpt Mode", .run(.command)),
            Entry("sculpt.draw", "Sculpt", "Sculpt: a Draw stroke", .run(.continuous)),
            Entry("sculpt.mask_fill", "Sculpt", "Mask ▸ Fill Mask", .run(.command)),
            Entry("sculpt.voxel_remesh", "Sculpt", "Voxel Remesh", .run(.command)),
            Entry("mode.object_from_sculpt", "Sculpt", "Object Mode from Sculpt Mode", .run(.command)),
            Entry("anim.insert_keyframe", "Timeline", "Timeline: Insert Keyframe", .run(.command)),
            Entry("anim.play", "Timeline", "Timeline: Play", .run(.continuous)),
            Entry("anim.scrub", "Timeline", "Timeline: a scrub of the playhead", .run(.continuous)),
            Entry("script.run", "Scripting", "Text Editor: Run Script", .run(.long)),
            Entry("console.python", "Scripting", "Python Console: a line", .run(.command)),
            Entry("console.shell", "Scripting", "Console: a shell command", .run(.command)),
            Entry("opsearch.run", "Scripting", "Operator Search: Run", .run(.command)),
            Entry("render.eevee", "Render", "Render ▸ Render Image (EEVEE)", .run(.long)),
            Entry("render.cycles", "Render", "Render ▸ Render Image (Cycles)",
                  .optIn(.long, reason: "Cycles' first GPU render builds its Metal kernels, which takes "
                         + "minutes; the switch for it was off")),
            Entry("image3d.relief", "Image to 3D", "Add ▸ Image to 3D Model (Relief)", .run(.long)),
            Entry("image3d.full", "Image to 3D", "Add ▸ Image to 3D Model (Full 3D)",
                  .notTested(reason: "it needs TripoSG's 7.95 GB download and minutes for each model; "
                             + "Relief is tested instead")),
            Entry("file.pack", "File", "File ▸ External Data ▸ Pack Resources", .run(.command)),
            Entry("file.autosave", "File", "The recovery file (autosave), as the app writes it", .run(.long)),
            Entry("file.save", "File", "File ▸ Save", .run(.long)),
            Entry("file.export", "File", "File ▸ Export ▸ glTF 2.0 (.glb/.gltf)", .run(.long)),
            Entry("file.import", "File", "File ▸ Import ▸ glTF 2.0 (.glb/.gltf)", .run(.long)),
            Entry("file.open", "File", "File ▸ Open…", .run(.long)),
            Entry("file.recent", "File", "File ▸ Open Recent and Revert",
                  .notTested(reason: "they open your own files; File ▸ Open is tested on the test's own copy")),
            Entry("file.share", "File", "File ▸ Share Saved File… and the Files app",
                  .notTested(reason: "system sheets, which hand the file to another app")),
            Entry("panels", "Editors", "The Outliner, Properties, Tool Settings and Render panels opening",
                  .notTested(reason: "each opens as a sheet, and none can open over the test's own sheet; "
                             + "the commands their controls send are tested above")),
            Entry("workspaces.hidden", "Editors",
                  "Shader Editor, UV Editor, Compositor and Geometry Nodes editor",
                  .notTested(reason: "not reachable in this build: the top bar has only the Scripting and "
                             + "Layout tabs")),
            Entry("edit.points", "Edit Mode", "Edit Mode on curves and lattices (control points)",
                  .notTested(reason: "their point drags are a gesture of their own, not timed in this version; "
                             + "the mesh's Edit Mode is")),
            Entry("pencil", "Input", "Apple Pencil pressure, hover and barrel double-tap",
                  .notTested(reason: "needs a Pencil's own touches, which code cannot make")),
            Entry("keyboard", "Input", "Keyboard shortcuts",
                  .notTested(reason: "each runs the function of the menu row tested above")),
        ]
        return all
    }()

    /// The mode an entry needs when that mode is not offered
    /// (`InteractionMode.isOffered`): its feature is not in the app, so it is
    /// not run, and the report says why.
    static func hiddenMode(_ entry: Entry) -> InteractionMode? {
        let mode: InteractionMode?
        switch entry.key {
        case "mode.vertex_paint", "paint.vertex": mode = .vertexPaint
        case "mode.weight_paint", "paint.weight": mode = .weightPaint
        case "mode.texture_paint", "paint.texture": mode = .texturePaint
        default: mode = entry.area == "Sculpt" ? .sculpt : nil
        }
        guard let mode, !mode.isOffered else { return nil }
        return mode
    }

    /// The inventory's entries that run, given whether Cycles is switched on.
    public static func planned(cycles: Bool) -> [Entry] {
        inventory.filter {
            if hiddenMode($0) != nil { return false }
            switch $0.coverage {
            case .run: return true
            case .optIn: return cycles
            case .notTested: return false
            }
        }
    }

    /// And those that do not, with why.
    public static func notPlanned(cycles: Bool) -> [(name: String, reason: String)] {
        inventory.compactMap {
            if let mode = hiddenMode($0) {
                return ($0.name, mode.label + " is hidden: the app offers Object Mode and Edit Mode")
            }
            switch $0.coverage {
            case .run: return nil
            case .optIn(_, let reason): return cycles ? nil : ($0.name, reason)
            case .notTested(let reason): return ($0.name, reason)
            }
        }
    }

    // MARK: Rating

    /// How a feature feels, from best to worst.
    public enum Rating: String, CaseIterable, Sendable {
        case smooth = "Smooth", ok = "OK", slow = "Slow", freeze = "Freeze", failed = "Failed"

        /// Worse is larger: Failed, Freeze, Slow, OK, Smooth.
        public var severity: Int { Self.allCases.firstIndex(of: self)! }

        public func worse(_ other: Rating) -> Rating { other.severity > severity ? other : self }
    }

    /// The thresholds, in seconds: Apple's own. Under 100 ms a response reads
    /// as immediate; past 250 ms iOS calls the main thread hung; past a second
    /// it is a freeze. A frame is 16.7 ms at 60 Hz, two are 33.3 ms: frame
    /// times come in whole frames, so "33 ms" is read as two frames (up to
    /// 33.4 ms) and a third is past it.
    public static let smoothStall: TimeInterval = 0.100
    public static let okStall: TimeInterval = 0.250
    public static let freezeStall: TimeInterval = 1.0
    public static let smoothFrame: TimeInterval = 0.017
    public static let okFrame: TimeInterval = 0.0334

    /// Smooth: no stall of 100 ms, and for a drag or a stroke 95 frames in
    /// 100 at 17 ms or less. OK: under 250 ms, 33 ms. Slow: a stall of 250 ms
    /// to a second (Apple's hang), or frames past 33 ms. Freeze: past a
    /// second. Failed: an error or a refusal where none was expected. A long
    /// job is held to its stalls, not its time; one of a second or more that
    /// showed no progress meanwhile is OK at best.
    ///
    /// Playback is held to the pace it asks for (`pace`, a frame of the
    /// scene's frame rate) rather than to the screen's: a 24 fps animation
    /// shows a new frame every 41.7 ms, which a 60 Hz screen draws as gaps of
    /// 50 ms, and those are as smooth as it can be played. Its frames are
    /// Smooth up to that pace rounded up to the screen's next refresh, and OK
    /// one refresh past it.
    public static func rate(kind: Kind, stall: TimeInterval, frames: FrameStats?, failed: Bool,
                            seconds: TimeInterval, progressShown: Bool,
                            pace: TimeInterval? = nil) -> Rating {
        if failed { return .failed }
        var rating: Rating = stall > freezeStall ? .freeze
            : stall >= okStall ? .slow
            : stall >= smoothStall ? .ok : .smooth
        if kind == .continuous, let frames {
            var smooth = smoothFrame, ok = okFrame
            // A pace no slower than the screen's leaves a drag's thresholds.
            if let pace, pace > smoothFrame + 0.001 {
                let refresh = 1.0 / 60
                let paced = (pace / refresh - 0.05).rounded(.up) * refresh + 0.001
                smooth = max(smooth, paced)
                ok = max(ok, paced + refresh)
            }
            rating = rating.worse(frames.p95 > ok ? .slow : frames.p95 > smooth ? .ok : .smooth)
        }
        if kind == .long, !progressShown, seconds >= 1 { rating = rating.worse(.ok) }
        return rating
    }

    /// Frame times: the gaps between consecutive frames, in seconds.
    public struct FrameStats: Equatable, Sendable {
        public let count: Int
        public let median: TimeInterval
        public let p95: TimeInterval
        public let worst: TimeInterval

        public init(count: Int, median: TimeInterval, p95: TimeInterval, worst: TimeInterval) {
            self.count = count
            self.median = median
            self.p95 = p95
            self.worst = worst
        }
    }

    /// The stats of the gaps between `times` (seconds, any order); nil with
    /// fewer than three frames, which say nothing about pacing.
    public static func frameStats(_ times: [TimeInterval]) -> FrameStats? {
        let sorted = times.sorted()
        guard sorted.count >= 3 else { return nil }
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.sorted()
        func rank(_ p: Double) -> TimeInterval {
            gaps[min(gaps.count - 1, max(0, Int((p * Double(gaps.count)).rounded(.up)) - 1))]
        }
        return FrameStats(count: gaps.count, median: rank(0.5), p95: rank(0.95), worst: gaps.last!)
    }

    /// Which frame times a continuous interaction is read by: the times the
    /// system says each frame reached the screen, when it said so for most
    /// of them; otherwise when each began, which a stalled main thread delays
    /// the same way.
    public static func frameTimes(began: [TimeInterval], presented: [TimeInterval]) -> [TimeInterval] {
        presented.count >= max(3, began.count * 4 / 5) ? presented : began
    }

    // MARK: Results and the report

    /// One feature's outcome, as the sheet and the report have it.
    public struct Result: Equatable, Identifiable, Sendable {
        public let index: Int
        public let rating: Rating
        /// The longest the main thread went without answering, in seconds.
        public let stall: TimeInterval
        /// From the call to the frame that showed it, or the whole job.
        public let seconds: TimeInterval
        public let frames: FrameStats?
        /// The highest footprint while it ran, in bytes; nil when unread.
        public let peak: UInt64?
        public let name: String
        public let detail: String
        public var id: Int { index }

        public init(index: Int, rating: Rating, stall: TimeInterval, seconds: TimeInterval,
                    frames: FrameStats?, peak: UInt64?, name: String, detail: String) {
            self.index = index
            self.rating = rating
            self.stall = stall
            self.seconds = seconds
            self.frames = frames
            self.peak = peak
            self.name = name
            self.detail = detail
        }
    }

    /// Documents/Self-Test, beside the Self-Test's reports.
    public static var folder: URL { SelfTest.folder }

    /// `feature-test-2026-11-01-14.03.12.txt`.
    public static func reportName(at date: Date = Date()) -> String {
        SelfTest.reportName(at: date, prefix: "feature-test-")
    }

    /// The newest report, and the feature it was running if it has no
    /// summary line: a run that took the app down.
    public static func latestReport(in folder: URL = folder) -> (url: URL, stoppedDuring: String?)? {
        SelfTest.latestReport(in: folder, prefix: "feature-test-")
    }

    /// A report's line for one feature: its rating, stall, time, frame times,
    /// peak memory, name and what was measured.
    ///
    ///     Slow    stall   412 ms  time    0.48 s  frames -                         peak   612 MB  Edit Mode — …
    ///     Smooth  stall    18 ms  time    1.52 s  frames 16.7/17.1/33.4 ms (89)    peak   640 MB  Orbit — …
    public static func line(_ r: Result) -> String {
        let frames = r.frames.map {
            String(format: "%.1f/%.1f/%.1f ms (%d)", $0.median * 1000, $0.p95 * 1000, $0.worst * 1000, $0.count)
        } ?? "-"
        let peak = r.peak.map { MemoryFootprint.megabytes($0) } ?? "- MB"
        return r.rating.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
            + " stall " + String(format: "%5.0f ms", r.stall * 1000)
            + "  time " + String(format: "%7.2f s", r.seconds)
            + "  frames " + frames.padding(toLength: max(frames.count, 26), withPad: " ", startingAt: 0)
            + "  peak " + peak.leftPadded(to: 9)
            + "  " + clean(r.name) + " — " + clean(r.detail)
    }

    /// A report line read back; nil for any other line.
    public static func parse(_ line: String, index: Int = 0) -> Result? {
        let pattern = #"^(Smooth|OK|Slow|Freeze|Failed) +stall +(\d+) ms  time +([0-9.]+) s  frames (-|([0-9.]+)/([0-9.]+)/([0-9.]+) ms \((\d+)\)) +peak +([0-9,]+|-) MB  (.*?) — (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: line).map { String(line[$0]) }
        }
        guard let rating = group(1).flatMap(Rating.init(rawValue:)),
              let stall = group(2).flatMap(Double.init), let seconds = group(3).flatMap(Double.init),
              let name = group(10), let detail = group(11) else { return nil }
        var frames: FrameStats?
        if let median = group(5).flatMap(Double.init), let p95 = group(6).flatMap(Double.init),
           let worst = group(7).flatMap(Double.init), let count = group(8).flatMap(Int.init) {
            frames = FrameStats(count: count, median: median / 1000, p95: p95 / 1000, worst: worst / 1000)
        }
        let peak = group(9).flatMap { $0 == "-" ? nil : UInt64($0.replacingOccurrences(of: ",", with: "")) }
            .map { $0 * 1_048_576 }
        return Result(index: index, rating: rating, stall: stall / 1000, seconds: seconds, frames: frames,
                      peak: peak, name: name, detail: detail)
    }

    /// One line, tabs and newlines folded to spaces.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// 64,226: a count as the report writes it.
    public static func number(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// "1.4 s" or "3 min 12.4 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds)
            : String(format: "%d min %.1f s", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// The counts by rating, worst first: "2 Failed, 1 Freeze, 6 Slow, 12 OK, 60 Smooth".
    public static func counts(_ results: [Result]) -> String {
        Rating.allCases.reversed().compactMap { rating -> String? in
            let n = results.filter { $0.rating == rating }.count
            return n == 0 ? nil : "\(n) \(rating.rawValue)"
        }.joined(separator: ", ")
    }

    /// The results as the sheet's summary lists them: Failed, Freeze and
    /// Slow first, then OK, then Smooth; the slowest first within each.
    public static func worstFirst(_ results: [Result]) -> [Result] {
        results.sorted {
            $0.rating.severity != $1.rating.severity ? $0.rating.severity > $1.rating.severity
                : $0.stall != $1.stall ? $0.stall > $1.stall : $0.index < $1.index
        }
    }

    /// The report, written whole after every change: a header, one line per
    /// feature as each ends, the feature in progress as `RUNNING`, what was
    /// not tested, and the summary. A run that takes the app down leaves the
    /// feature it was running as the last line, and the sheet names it the
    /// next time it opens.
    public final class Report {
        public let url: URL
        public var about: [(String, String)]
        public var notes: [String] = []
        public private(set) var results: [Result] = []
        public var notTested: [(name: String, reason: String)] = []
        public var running: String?
        public var total: TimeInterval?
        public var memory: String?
        public var summary: String?
        public let started = Date()

        public init(url: URL, about: [(String, String)]) {
            self.url = url
            self.about = about
        }

        public func record(_ result: Result) {
            results.removeAll { $0.index == result.index }
            results.append(result)
        }

        public var text: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var out = ["Blender Local: Test All Features", ""]
            for (key, value) in about { out.append((key + ":").padding(toLength: 10, withPad: " ", startingAt: 0) + value) }
            out.append("Started:  " + f.string(from: started))
            out.append("Total:    " + (total.map(FeatureTest.duration)
                                       ?? "did not finish (the last feature started is the last line)"))
            if !results.isEmpty { out.append("Features: \(results.count) run: " + FeatureTest.counts(results)
                                             + "; \(notTested.count) not tested") }
            if let memory { out.append("Memory:   " + memory) }
            for note in notes { out.append("Note:     " + note) }
            out.append("Rated:    Smooth under 100 ms of stall (frames at 17 ms or less, 95 in 100); OK under "
                       + "250 ms (33 ms); Slow 250 ms to 1 s, or frames past 33 ms; Freeze past 1 s; Failed on "
                       + "an error. Frames: median/95th percentile/worst.")
            out.append("")
            out += results.sorted { $0.index < $1.index }.map(FeatureTest.line)
            if let running { out.append("RUNNING  " + running) }
            if summary != nil, !notTested.isEmpty {
                out.append("")
                out.append("Not tested:")
                out += notTested.map { "  \($0.name): \($0.reason)" }
            }
            if let summary { out += ["", summary] }
            return out.joined(separator: "\n") + "\n"
        }

        /// Writes it whole, through a partial file renamed over it.
        @discardableResult
        public func write() -> Bool {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let partial = url.appendingPathExtension("partial")
                try text.write(to: partial, atomically: false, encoding: .utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: url)
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// The summary line, which a finished report has and a stopped one does
    /// not (`latestReport`).
    public static func summary(_ results: [Result], notTested: Int, seconds: TimeInterval) -> String {
        "Summary:  \(results.count) run: " + counts(results) + "; \(notTested) not tested; in " + duration(seconds)
    }

    // MARK: The user's scene

    /// The Python that saves the user's scene to `saved` (its own copy, as the
    /// app writes the recovery file), fingerprints it, and opens Blender's
    /// startup file in its place: `_blenderkit_featuretest.begin`. It answers
    /// with one `[feature-test] ` line of JSON (`answer`).
    public static func beginPython(saved: String, historyRoot: String) -> String {
        "import _blenderkit_featuretest as _bk_ft\n"
            + "_bk_ft.begin(\(Bpy.quote(saved)), \(Bpy.quote(historyRoot)))"
    }

    /// The Python that ends it: the history cut back to the test's own step,
    /// the saved scene opened again and compared, that step's place taken by
    /// it. Answers the same way.
    public static let endPython = "import _blenderkit_featuretest as _bk_ft\n_bk_ft.end()"

    static let answerPrefix = "[feature-test] "

    /// The JSON object a begin or an end answered with, from its output lines.
    public static func answer(in lines: [String]) -> [String: Any]? {
        guard let line = lines.last(where: { $0.hasPrefix(answerPrefix) }) else { return nil }
        let json = Data(line.dropFirst(answerPrefix.count).utf8)
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    // MARK: What the sheet says

    /// Said on the sheet before Run.
    public static let notice = """
        Runs every feature of the app on this device, one after another, through the same code its buttons, \
        menu rows and strokes run, and rates each by how it feels: Smooth, OK, Slow, Freeze or Failed. The 3D \
        View works on a scene of its own, with a 64,226-vertex sphere for the drags and strokes. About three \
        minutes; keep Blender Local open until it ends.
        """

    /// Said beside it: what Run does to the open scene.
    public static let undoNotice = """
        Your scene is saved first and opened again when the test ends, and the report says whether it came \
        back exactly. Opening it ends Blender's undo history: afterwards Undo cannot go back past the test.
        """

    /// The legend under the results.
    public static let legend = """
        Smooth: no pause of 100 ms, frames at 60 per second. OK: under 250 ms. Slow: 250 ms to a second \
        (iOS calls that a hang), or frames dropped. Freeze: past a second. Failed: an error.
        """
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
