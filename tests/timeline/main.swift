import Foundation
import CoreGraphics

// The Timeline as an animation editor, on the Mac: which column a finger is
// on, the frames a box spans, where a dragged key lands, the numbers and the
// time along the top, the markers' layout and jumps, the view's zoom, pan and
// framing, the report's bytes, and what each control sends — selections
// without the mirroring pass and with one undo step unless nothing changed,
// edits through it — against a runtime that records what would reach Blender.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func near(_ a: Double, _ b: Double, _ e: Double = 1e-6) -> Bool { abs(a - b) <= e }

print("Timeline")

// MARK: - Hit testing

print("\n  a tap finds the column under it, the nearest when they crowd")
do {
    let w = TimelineWindow(first: 0, last: 100, width: 1000)
    let keys = [TimelineKey(frame: 10), TimelineKey(frame: 11), TimelineKey(frame: 50, selected: true)]
    check("frames map to points and back", w.x(10) == 100 && near(w.frame(at: 250), 25) && w.wholeFrame(at: 104) == 10)
    check("a tap 3 points off frame 10 takes it",
          TimelineHit.column(at: 103, in: keys, window: w, radius: 16)?.frame == 10)
    check("between 10 and 11, the nearer wins (10.7 → 11)",
          TimelineHit.column(at: 107, in: keys, window: w, radius: 16)?.frame == 11)
    check("a tap beyond the reach takes nothing", TimelineHit.column(at: 300, in: keys, window: w, radius: 16) == nil)
    check("a tap at the reach's edge still takes it",
          TimelineHit.column(at: 516, in: keys, window: w, radius: 16)?.frame == 50)
    check("and one point past it does not", TimelineHit.column(at: 517, in: keys, window: w, radius: 16) == nil)
    let markers = [TimelineMarker(name: "A", frame: 20), TimelineMarker(name: "B", frame: 22)]
    check("a marker by its index in the scene's list",
          TimelineHit.marker(at: 218, in: markers, window: w, radius: 16) == 1)
    check("no marker beside every marker", TimelineHit.marker(at: 600, in: markers, window: w, radius: 16) == nil)
}

print("\n  a box spans frames either way round, its edges in")
do {
    let w = TimelineWindow(first: 0, last: 100, width: 1000)
    let (a, b) = TimelineHit.frames(from: 400, to: 150, window: w)
    check("dragged right to left it is the same box", near(a, 15) && near(b, 40), "\(a) \(b)")
    let keys = (0...10).map { TimelineKey(frame: Float($0 * 5)) }
    let inside = TimelineHit.columns(in: (15, 40), of: keys).map(\.frame)
    check("the keys on its edges are inside (BEZT_OK_FRAMERANGE)", inside == [15, 20, 25, 30, 35, 40], "\(inside)")
}

// MARK: - Snapping

print("\n  a drag lands keys where Blender's Snap puts them (measured in 5.2.1)")
do {
    let snap = TimelineSnap()
    check("Snap ▸ Frame: the move by whole frames (2.4 → 2, 2.6 → 3)",
          snap.delta(2.4) == 2 && snap.delta(2.6) == 3 && snap.delta(-2.6) == -3)
    check("a key on 2.5 keeps its half (TIME_TRANSLATE by 3: 5.5)", snap.landing(2.5, raw: 3) == 5.5)
    check("Ctrl held inverts it: 2.4 stays 2.4", snap.delta(2.4, inverted: true) == 2.4)
    let off = TimelineSnap(on: false)
    check("with Snap off a move is as dragged, and Ctrl snaps it",
          off.delta(2.4) == 2.4 && off.delta(2.4, inverted: true) == 2)
    let absolute = TimelineSnap(absolute: true)
    check("Absolute Time Snap puts each key on a whole frame (7.5 + 1 → 9, 15 + 1 → 16)",
          absolute.landing(7.5, raw: 1) == 9 && absolute.landing(15, raw: 1) == 16)
    let seconds = TimelineSnap(element: "SECOND", fps: 24)
    check("by seconds: a move of 30 frames is one second at 24 fps", seconds.delta(30) == 24)
    check("S scales about the current frame, onto whole frames (9 by 2 about 10 → 8)",
          snap.scaled(9, factor: 2, pivot: 10) == 8 && snap.scaled(16, factor: 2, pivot: 10) == 22)
    check("the line snap_state prints reads back",
          TimelineSnap.parse("x\nBK_KEYS_SNAP 1 SECOND 1 25.0") == TimelineSnap(on: true, element: "SECOND",
                                                                               absolute: true, fps: 25))
    check("and nothing is made of a line it did not print", TimelineSnap.parse("Traceback") == nil)
}

print("\n  a move's preview: the selection where it lands, the rest where it was")
do {
    let keys = [TimelineKey(frame: 1), TimelineKey(frame: 10, selected: true),
                TimelineKey(frame: 20, selected: true, type: .breakdown, partial: true)]
    let moved = TimelinePreview.moved(keys, raw: 2.6, snap: TimelineSnap(), inverted: false, duplicate: false)
    let frames = moved.map { "\($0.frame)\($0.selected ? "*" : "")" }
    check("selected columns move 3, a partly selected one leaves its unselected key behind",
          frames == ["1.0", "13.0*", "23.0*", "20.0"], "\(frames)")
    check("the part left behind keeps its type", moved.last?.type == .breakdown)
    let dup = TimelinePreview.moved(keys, raw: 2, snap: TimelineSnap(), inverted: false, duplicate: true)
    check("Shift+D leaves the originals where they were",
          dup.filter { !$0.selected }.map(\.frame) == [1, 10, 20], "\(dup)")
    let scaled = TimelinePreview.scaled(keys, factor: 0.5, pivot: 0, snap: TimelineSnap(on: false), inverted: false)
    check("S's preview scales about the current frame",
          scaled.map(\.frame) == [1, 5, 10, 20], "\(scaled.map(\.frame))")
}

// MARK: - The view

print("\n  the view: Frame Scene Range, a pinch, a pan, Frame All")
do {
    let w = TimelineWindow(range: 1...250, width: 1000)
    // ANIM_frame_range_view2d_add_xmargin: 40 points of frames, at most an
    // eighth of the range: 249 frames over 1000 points → 9.96 frames.
    check("the scene range with Blender's margin", near(w.first, 1 - 9.96, 1e-9) && near(w.last, 250 + 9.96, 1e-9),
          "\(w.first) \(w.last)")
    let narrow = TimelineWindow(range: 1...250, width: 100)
    check("on a narrow body the margin stops at an eighth of the range",
          near(narrow.first, 1 - 249.0 / 8) && near(narrow.last, 250 + 249.0 / 8))
    let zoomed = w.zoomed(by: 2, about: 250)
    check("a pinch zooms about the fingers: the frame under them stays",
          near(zoomed.frame(at: 250), w.frame(at: 250), 1e-9) && near(zoomed.span, w.span / 2, 1e-9))
    check("zooming in stops at two frames across", w.zoomed(by: 1e6, about: 0).span == TimelineWindow.minimumSpan)
    let panned = w.panned(by: 100)
    check("a two-finger drag moves the frames with the fingers",
          near(panned.frame(at: 600), w.frame(at: 500), 1e-9))
    let all = w.framingKeys([20, 80], sceneRange: 1...250)!
    check("Frame All frames the keys with the margin",
          near(all.first, 20 - 40 * 60 / 1000.0) && near(all.last, 80 + 40 * 60 / 1000.0), "\(all)")
    let one = w.framingKeys([42], sceneRange: 1...250)!
    check("one key is centred, the span kept", near((one.first + one.last) / 2, 42) && near(one.span, w.span))
    let none = w.framingKeys([], sceneRange: 1...250)!
    check("Frame All with no keys frames the scene range", near(none.first, w.first) && near(none.last, w.last))
    check("Frame Selected with nothing selected changes nothing", w.framingKeys([], sceneRange: nil) == nil)
    let centred = w.centred(on: 100)
    check("Go to Current Frame keeps the span and centres the frame",
          near((centred.first + centred.last) / 2, 100) && near(centred.span, w.span))
    check("a resized body keeps the frames", w.resized(to: 500).first == w.first && w.resized(to: 500).width == 500)
}

print("\n  the numbers along the top: Blender's grid (calculate_grid_step, base the frame rate)")
do {
    check("get_divisor: 24 → 2, 6 → 3 (leaves 2), 2 → 2, 7 → 7",
          TimelineGrid.divisor(24) == 2 && TimelineGrid.divisor(6) == 3 && TimelineGrid.divisor(2) == 2
          && TimelineGrid.divisor(7) == 7)
    check("at 3.8 points a frame, 24 fps: every 12 frames",
          TimelineGrid.step(base: 24, pixelsPerFrame: 3.8, minimumDistance: 45) == 12)
    check("at 30 points a frame: every 2 frames (24, 12, 6, 2 — not 1)",
          TimelineGrid.step(base: 24, pixelsPerFrame: 30, minimumDistance: 45) == 2)
    check("zoomed out to a point a frame: doubling up from 24 to 48",
          TimelineGrid.step(base: 24, pixelsPerFrame: 1, minimumDistance: 45) == 48)
    check("at 25 fps: 25, then 5 (25 / 5), then 1", TimelineGrid.step(base: 25, pixelsPerFrame: 10, minimumDistance: 45) == 5)
    check("the minimum is the grid's 45 points, or the widest label",
          TimelineGrid.minimumDistance(labels: ["1", "250"]) == 45
          && TimelineGrid.minimumDistance(labels: ["00:10+12"]) == 54)
    let w = TimelineWindow(first: -2, last: 30, width: 320)
    check("the numbered frames are the step's multiples in view", w.numbered(step: 12) == [0, 12, 24])
}

print("\n  Use Timecode: Blender's Minimal timecode (BLI_timecode_string_from_time)")
do {
    check("frame 0 at 24 fps is 00:00+00", Timecode.playhead(frame: 0, fps: 24) == "00:00+00")
    check("frame 25 is a second and a frame", Timecode.playhead(frame: 25, fps: 24) == "00:01+01")
    check("frame 1467 is 1 minute 1 second 3 frames", Timecode.playhead(frame: 24 * 61 + 3, fps: 24) == "01:01+03")
    check("an hour on, the hours lead", Timecode.playhead(frame: 24 * 3600 + 24 * 2, fps: 24) == "01:00:02+00")
    check("before frame 0 it is negative", Timecode.playhead(frame: -12, fps: 24) == "-00:00+12")
    check("numbers a second apart drop the frames", Timecode.label(frame: 48, step: 24, fps: 24) == "00:02")
    check("numbers closer keep them", Timecode.label(frame: 36, step: 12, fps: 24) == "00:01+12")
    check("at 30 fps, frame 45 is 00:01+15", Timecode.playhead(frame: 45, fps: 30) == "00:01+15")
}

// MARK: - Markers

print("\n  markers as ED_markers_draw places them, and Jump to Marker")
do {
    let markers = [TimelineMarker(name: "C", frame: 40), TimelineMarker(name: "A", frame: 10),
                   TimelineMarker(name: "B", frame: 20, selected: true)]
    let placed = TimelineMarkerLayout.place(markers, current: 12)
    check("lower names first, the elevated last on top", placed.map(\.marker.name) == ["C", "A", "B"],
          "\(placed.map(\.marker.name))")
    let a = placed.first { $0.marker.name == "A" }!
    let b = placed.first { $0.marker.name == "B" }!
    let c = placed.first { $0.marker.name == "C" }!
    check("the one the current frame is past (12 after A's 10, before B's 20) is raised", a.elevated)
    check("the selected one is raised", b.elevated && !c.elevated)
    check("a name ends at the next marker, the last one's at none",
          a.nameEnd == 20 && b.nameEnd == 40 && c.nameEnd == nil)
    check("each keeps its index in the scene's list", a.index == 1 && b.index == 2 && c.index == 0)
    let scene = BKScene(startupFile: false)
    scene.animation.markers = markers
    scene.frameCurrent = 20
    check("Jump to Next Marker from 20 is 40, Previous is 10",
          scene.markerJumpTarget(next: true) == 40 && scene.markerJumpTarget(next: false) == 10)
    scene.frameCurrent = 40
    check("past the last there is none: \"No more markers to jump to in this direction\"",
          scene.markerJumpTarget(next: true) == nil)
    check("a bound marker shows its camera's name", TimelineMarker(name: "F_01", frame: 1, camera: "Camera").shownName == "Camera")
}

// MARK: - The report's bytes

print("\n  the keys' report: selection, type and partly selected in a byte")
do {
    let k = TimelineKey(frame: 3, flag: 0b0001_0101)
    check("bit 0 selected, bits 1-3 the type (2 Breakdown), bit 4 partly selected",
          k.selected && k.type == .breakdown && k.partial, "\(k)")
    check("an old report's 1 is a selected Keyframe", TimelineKey(frame: 1, flag: 1) == TimelineKey(frame: 1, selected: true))
    check("partly selected means nothing on an unselected column", !TimelineKey(frame: 1, flag: 16).partial)
    let merged = TimelineKey.merged([TimelineKey(frame: 5, type: .breakdown),
                                     TimelineKey(frame: 5.005, selected: true, type: .extreme),
                                     TimelineKey(frame: 9, type: .jitter), TimelineKey(frame: 9, type: .keyframe),
                                     TimelineKey(frame: 12, type: .generated), TimelineKey(frame: 12, type: .breakdown)])
    check("columns from several objects merge within a hundredth of a frame", merged.count == 3, "\(merged)")
    check("one selected and one not make a partly selected column", merged[0].selected && merged[0].partial)
    check("the first key's type unless one is a Keyframe (nupdate_ak_bezt)",
          merged[0].type == .breakdown && merged[1].type == .keyframe && merged[2].type == .generated,
          "\(merged.map(\.type))")
    check("R's menu order and Blender's names",
          KeyframeType.menuOrder.map(\.name) == ["Keyframe", "Breakdown", "Moving Hold", "Extreme", "Jitter", "Generated"])
    check("drawn at draw_keyframe_shape's sizes",
          KeyframeType.extreme.size == 1.2 && KeyframeType.generated.size == 0.75 && KeyframeType.breakdown.size == 0.85)
}

print("\n  the markers' report")
do {
    let scene = BKScene(startupFile: false)
    let frames: [Int32] = [5, 30]
    let flags: [UInt8] = [1, 0]
    let applied = frames.withUnsafeBufferPointer { f in
        flags.withUnsafeBufferPointer { s in
            AnimationMirror.applyMarkers(names: ["Start", "Hit"], cameras: [], frames: f, selected: s,
                                         locked: true, to: scene)
        }
    }
    check("names, frames, selection and Lock Markers arrive", applied
          && scene.animation.markers == [TimelineMarker(name: "Start", frame: 5, selected: true),
                                         TimelineMarker(name: "Hit", frame: 30)]
          && scene.animation.lockMarkers, "\(scene.animation.markers)")
    let one: [Int32] = [7], sel: [UInt8] = [0]
    let empty = one.withUnsafeBufferPointer { f in
        sel.withUnsafeBufferPointer { s in
            AnimationMirror.applyMarkers(names: [], cameras: [], frames: f, selected: s, locked: false, to: scene)
        }
    }
    check("one marker with an empty name joins to no bytes, and still arrives",
          empty && scene.animation.markers == [TimelineMarker(name: "", frame: 7)])
    let bad = one.withUnsafeBufferPointer { f in
        sel.withUnsafeBufferPointer { s in
            AnimationMirror.applyMarkers(names: ["a", "b"], cameras: [], frames: f, selected: s, locked: false, to: scene)
        }
    }
    check("buffers that disagree change nothing", !bad && scene.animation.markers.count == 1)
}

// MARK: - The menus

print("\n  the menus, by Blender's names")
do {
    for id in TimelineMenus.ids {
        let rows = TimelineMenus.rows(id)
        check("\(id) has rows, each named", !rows.isEmpty && rows.allSatisfy { $0.kind == .separator || !$0.title.isEmpty })
        for row in rows {
            if case .submenu(let sub) = row.kind {
                check("  \(id) ▸ \(row.title) opens \(sub)", !TimelineMenus.rows(sub).isEmpty)
            }
        }
    }
    check("T's menu: Blender's interpolation items under its three headings",
          TimelineMenus.rows("action.interpolation_type").filter { $0.kind == .heading }.map(\.title)
          == ["Interpolation", "Easing (by strength)", "Dynamic Effects"]
          && TimelineMenus.rows("action.interpolation_type").filter { $0.kind != .heading }.count == 13)
    check("View ▸ Use Timecode is Blender 5.2.1's name for Show Seconds, on Ctrl T",
          TimelineMenus.rows("TIME_MT_view").contains { $0.title == "Use Timecode" && $0.key == "Ctrl T" })
    check("Frame Preview Range when the preview range is on",
          TimelineMenus.rows("TIME_MT_view", usePreviewRange: true).contains { $0.title == "Frame Preview Range" })
}

// MARK: - What the controls send

print("\n  what each control sends, and the undo step Blender names after its operator")
final class Recording: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var evaluated: [String] = []
    var queried: [String] = []
    var answer: (String) -> String = { _ in "" }
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        evaluated.append(source)
        return []
    }
    func query(_ source: String, scene: BKScene) -> [BpyLine] {
        queried.append(source)
        return [BpyLine(.output, answer(source))]
    }
    func requestInterrupt() {}
}
do {
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    undo.seed(scene)
    let runtime = Recording()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    let editor = TimelineKeyEditor()
    editor.bind(scene: scene, session: session, bridge: bridge)

    /// The labels of the history steps pushed since `n`: `_bk_undo.push(root, label, …)`.
    /// The history's own first step, "Original", is the seed, not an action's.
    func pushes(since n: Int) -> [String] {
        runtime.queried.dropFirst(n).compactMap { source -> String? in
            guard let r = source.range(of: "_bk_undo.push(") else { return nil }
            let parts = source[r.upperBound...].components(separatedBy: ", ")
            return parts.count > 1 ? parts[1].replacingOccurrences(of: "\"", with: "'") : nil
        }.filter { $0 != "'Original'" }
    }

    var q = runtime.queried.count
    var e = runtime.evaluated.count
    editor.clickSelect(frame: 10, extend: false)
    check("a tap selects by frame without a mirroring pass",
          runtime.evaluated.count == e && runtime.queried.dropFirst(q).contains { $0.contains("click_select(10.0000, extend=False)") })
    check("and records Blender's Select Keyframes step", pushes(since: q) == ["'Select Keyframes'"], "\(pushes(since: q))")
    runtime.answer = { $0.contains("click_select") ? BpyKeys.unchanged : "" }
    q = runtime.queried.count
    editor.clickSelect(frame: nil, extend: false)
    check("a tap that changed nothing records no step", pushes(since: q).isEmpty, "\(pushes(since: q))")
    check("a tap beside every key asks Blender for no frame",
          runtime.queried.dropFirst(q).contains { $0.contains("click_select(float('nan'), extend=False)") })
    runtime.answer = { _ in "" }
    q = runtime.queried.count
    editor.boxSelect((12.25, 40), mode: "ADD")
    check("a Shift box adds, as one Box Select step",
          runtime.queried.dropFirst(q).contains { $0.contains("box_select(12.2500, 40.0000, mode='ADD')") }
          && pushes(since: q) == ["'Box Select'"], "\(pushes(since: q))")

    e = runtime.evaluated.count
    q = runtime.queried.count
    editor.move(by: 3, duplicate: false)
    check("a move goes through the mirroring pass, as Blender's transform",
          runtime.evaluated.dropFirst(e).contains { $0.contains("_blenderkit_keys.move(3)") }
          && pushes(since: q) == ["'Transform'"], "\(runtime.evaluated.dropFirst(e)) \(pushes(since: q))")
    e = runtime.evaluated.count
    editor.move(by: -2, duplicate: true)
    check("Shift+D is Blender's Duplicate macro",
          runtime.evaluated.dropFirst(e).contains { $0.contains("_blenderkit_keys.duplicate_move(-2)") })
    e = runtime.evaluated.count
    editor.scale(by: 1.5)
    check("S is TIME_SCALE", runtime.evaluated.dropFirst(e).contains { $0.contains("_blenderkit_keys.scale(1.5000)") })

    let expected: [(TimelineAction, String, String?)] = [
        (.selectAll("INVERT"), "select_all('INVERT')", "Select All"),
        (.selectColumn("KEYS"), "select_column('KEYS')", "Select All"),
        (.selectLeftRight("RIGHT"), "select_leftright('RIGHT', extend=False)", "Select Left/Right"),
        (.selectLinked, "select_linked()", "Select Linked"),
        (.delete, "delete()", "Delete Keyframes"),
        (.clean(channels: true), "clean(True)", "Clean Keyframes"),
        (.copy, "copy()", "Copy Keyframes"),
        (.paste(flipped: true), "paste(flipped=True)", "Paste Keyframes"),
        (.snap("NEAREST_FRAME"), "snap('NEAREST_FRAME')", "Snap Keys"),
        (.mirror("CFRA"), "mirror('CFRA')", "Mirror Keys"),
        (.jumpToKeys, "frame_jump()", "Jump to Keyframes"),
        (.interpolation("ELASTIC"), "interpolation('ELASTIC')", "Set Keyframe Interpolation"),
        (.easing("EASE_IN_OUT"), "easing('EASE_IN_OUT')", "Set Keyframe Easing Type"),
        (.keyframeType("MOVING_HOLD"), "keyframe_type('MOVING_HOLD')", "Set Keyframe Type"),
        (.handleType("VECTOR"), "handle_type('VECTOR')", "Set Keyframe Handle Type"),
        (.insert("ALL"), "insert('ALL')", "Insert Keyframes"),
        (.markerAdd, "marker_add()", "Add Time Marker"),
        (.markerDelete, "marker_delete()", "Delete Markers"),
        (.markerSelectAll("SELECT"), "marker_select_all('SELECT')", "(De)select all Markers"),
        (.markerCameraBind, "marker_camera_bind()", "Bind Camera to Markers"),
        (.lockMarkers(true), "set_lock_markers(True)", "Lock Markers"),
    ]
    for (action, body, label) in expected {
        let command = BpyKeys.command(for: action)
        let mirrored = !(BpyKeys.isSelection(action) || action == .copy)
        e = runtime.evaluated.count
        q = runtime.queried.count
        editor.perform(action)
        let sent = mirrored ? runtime.evaluated.dropFirst(e) : runtime.queried.dropFirst(q)
        check("\(command.call): runs _blenderkit_keys.\(body)\(mirrored ? "" : " without a pass"), one step \(label ?? "none")",
              command.undo == label && sent.contains { $0.contains("_blenderkit_keys." + body) }
              && pushes(since: q) == (label.map { ["'\($0)'"] } ?? []),
              "\(command) \(pushes(since: q))")
    }
    e = runtime.evaluated.count
    q = runtime.queried.count
    editor.moveMarkers(by: 4, duplicate: false)
    editor.moveMarkers(by: 2, duplicate: true)
    editor.renameMarker("Hit's \"crash\"")
    let markerCalls = runtime.evaluated.dropFirst(e)
    check("marker moves and duplicates through the pass (a bound marker can switch the camera)",
          markerCalls.contains { $0.contains("marker_move(4)") } && markerCalls.contains { $0.contains("marker_duplicate(2)") },
          "\(markerCalls)")
    check("a rename, quotes and all, without it, one Rename Marker step",
          runtime.queried.dropFirst(q).contains { $0.contains("marker_rename(") && $0.contains("crash") }
          && pushes(since: q).last == "'Rename Marker'", "\(pushes(since: q))")
    q = runtime.queried.count
    scene.frameCurrent = 10
    editor.selectSide(of: 3, extend: true)
    check("Ctrl+Shift+click left of the current frame: Before Current Frame, extended",
          runtime.queried.dropFirst(q).contains { $0.contains("select_leftright('LEFT', extend=True)") })

    runtime.answer = { $0.contains("snap_state") ? "BK_KEYS_SNAP 0 FRAME 0 30.0" : "" }
    editor.refreshSnap()
    check("a drag asks for the scene's Snap first", editor.snap == TimelineSnap(on: false, element: "FRAME", absolute: false, fps: 30))
}

do {
    // The simulator's stand-in: no Timeline to borrow, said in words.
    final class Shim: BpyRuntime {
        let isReal = true
        let usesRealBlender = false
        let lastSyncDuration: TimeInterval = 0
        var sent = 0
        func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
        var versionBanner: String { "shim" }
        func evaluate(_ source: String, scene: BKScene) -> [BpyLine] { sent += 1; return [] }
        func query(_ source: String, scene: BKScene) -> [BpyLine] { sent += 1; return [] }
        func requestInterrupt() {}
    }
    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    let runtime = Shim()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let editor = TimelineKeyEditor()
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    editor.bind(scene: scene, session: session, bridge: bridge)
    editor.perform(.delete)
    check("in the simulator nothing is sent, and it says why",
          runtime.sent == 0 && session.console.contains { $0.text.contains("simulator") })
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
