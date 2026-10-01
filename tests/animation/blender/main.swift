import Foundation
import simd
import CoreGraphics

// Two jobs, one binary, so the Swift is compiled once.
//
//   check dump            every string the timeline and the 3D View send for
//                         animation, printed for a headless Blender to run —
//                         produced by the calls the interface makes, through
//                         TimelineDriver and BpyBridge.run, not written out.
//   check replay <json>   Blender's own key reports and keyframe jumps, which
//                         verify.py wrote, put through the Swift that draws the
//                         timeline and steps its jump buttons.

let arguments = CommandLine.arguments

/// Records what reaches the interpreter, as a device's runtime would receive it.
final class RecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    var queries: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
    func query(_ source: String, scene: BKScene) -> [BpyLine] {
        queries.append(source)
        return []
    }
}

func dump() {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

    let scene = BKScene(startupFile: false)
    let undo = UndoStack()
    undo.seed(scene)
    let runtime = RecordingRuntime()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    let driver = TimelineDriver()
    driver.bind(scene: scene, session: session, bridge: bridge)

    /// What one interface action sent as a command: the last full evaluation.
    func sent(_ body: () -> Void) -> String {
        let before = runtime.sources.count
        body()
        return runtime.sources.count > before ? runtime.sources[runtime.sources.count - 1] : ""
    }
    /// What it sent as a quiet question — the ones that skip the mirror.
    func asked(_ body: () -> Void) -> String {
        let before = runtime.queries.count
        body()
        return runtime.queries.dropFirst(before)
            .last { !$0.contains("_bkui.checkpoint") } ?? ""
    }

    emit("INSERT", sent { driver.insertKeyframe() })
    emit("DELETE", sent { driver.deleteKeyframe() })
    emit("FRAME_SET", asked { driver.setFrame(6) })

    scene.frameStart = 1
    scene.frameEnd = 250
    emit("START_300", BpyAnimation.setFrameStart(300))
    let start = FrameRange.settingStart(300, end: 250)
    emit("START_300_EXPECT", "\(start.start) \(start.end)")
    emit("END_NEGATIVE", BpyAnimation.setFrameEnd(-5))
    let end = FrameRange.settingEnd(-5, start: 1)
    emit("END_NEGATIVE_EXPECT", "\(end.start) \(end.end)")
    scene.frameStart = 20
    scene.frameEnd = 30
    emit("END_BEFORE_START", BpyAnimation.setFrameEnd(10))
    let crossed = FrameRange.settingEnd(10, start: 20)
    emit("END_BEFORE_START_EXPECT", "\(crossed.start) \(crossed.end)")
    emit("CURRENT_NEGATIVE_EXPECT", "\(FrameRange.current(-3))")
    emit("PREVIEW_START_50", BpyAnimation.setPreviewStart(50))
    let previewPast = FrameRange.settingPreviewStart(50, end: 40)
    emit("PREVIEW_START_50_EXPECT", "\(previewPast.start) \(previewPast.end)")
    emit("PREVIEW_END_10", BpyAnimation.setPreviewEnd(10))
    let previewBefore = FrameRange.settingPreviewEnd(10, start: 30)
    emit("PREVIEW_END_10_EXPECT", "\(previewBefore.start) \(previewBefore.end)")
    let seeded = FrameRange.enablingPreview(start: 0, end: 0, sceneStart: 12, sceneEnd: 90)
    emit("PREVIEW_SEED_EXPECT", "\(seeded.start) \(seeded.end)")
    let kept = FrameRange.enablingPreview(start: 30, end: 40, sceneStart: 12, sceneEnd: 90)
    emit("PREVIEW_KEEP_EXPECT", "\(kept.start) \(kept.end)")
    scene.frameStart = 1
    scene.frameEnd = 250
    emit("DRIVER_START", sent { driver.setFrameStart(300) })

    emit("AUTOKEY_ON", asked { driver.setAutoKeying(true) })
    emit("AUTOKEY_REPLACE", asked { driver.setAutoKeyingReplace(true) })
    emit("AUTOKEY_ADD_REPLACE", asked { driver.setAutoKeyingReplace(false) })
    emit("ONLY_AVAILABLE_OFF", asked { driver.setOnlyInsertAvailable(false) })
    emit("ONLY_AVAILABLE_ON", asked { driver.setOnlyInsertAvailable(true) })
    emit("ONLY_SELECTED_OFF", asked { driver.setOnlySelectedKeys(false) })
    emit("LOOP_BOUNCE", asked { driver.setLoopMode(.bounce) })
    emit("PREVIEW_ON", sent { driver.setUsePreviewRange(true) })

    // The gizmo's transforms, through BpyBridge.run as the viewport sends
    // them, with the record button on and then off.
    let size = CGSize(width: 1000, height: 800)
    var camera = ViewportCamera()
    camera.azimuth = 0.9
    camera.elevation = 0.45
    camera.distance = 12
    let gizmoScene = BKScene(startupFile: false)
    let cube = gizmoScene.add(.cube)
    gizmoScene.selection = [cube.id]
    gizmoScene.activeID = cube.id
    func gizmoPython(_ mode: TransformGizmo.Mode, _ handle: TransformGizmo.Handle,
                     _ to: CGPoint) -> String {
        let g = TransformGizmo.make(mode: mode, scene: gizmoScene, options: ViewportOptions(),
                                    camera: camera, size: size)!
        let centre = TransformGizmo.Projection(camera: camera, size: size).project(g.origin)!
        let start = CGPoint(x: centre.x + 60, y: centre.y + 5)
        let session = TransformGizmo.beginSession(handle: handle, at: start, gizmo: g,
                                                  scene: gizmoScene, camera: camera, size: size)
        let result = TransformGizmo.resolve(session, at: CGPoint(x: start.x + to.x, y: start.y + to.y))!
        TransformGizmo.rollBack(session)
        return TransformGizmo.python(result, session: session)
    }
    let translate = gizmoPython(.translate, .axis(0), CGPoint(x: 80, y: 0))
    let rotateView = gizmoPython(.rotate, .screen, CGPoint(x: -40, y: 90))
    let resize = gizmoPython(.scale, .axis(0), CGPoint(x: 60, y: 0))

    scene.animation.autoKey = true
    emit("GIZMO_TRANSLATE", sent { bridge.run(translate, undo: "Move") })
    emit("GIZMO_ROTATE_VIEW", sent { bridge.run(rotateView, undo: "Rotate") })
    emit("GIZMO_RESIZE", sent { bridge.run(resize, undo: "Resize") })
    scene.animation.autoKey = false
    emit("GIZMO_TRANSLATE_OFF", sent { bridge.run(translate, undo: "Move") })
    emit("GIZMO_TRANSLATE_BARE", translate)

    print(out.joined(separator: "\n#--\n"))
}

// MARK: - replay

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// One scene as `_blenderkit_anim.report` handed it over, with where
/// Blender's `screen.keyframe_jump` went from a given frame.
struct Scenario: Decodable {
    struct Report: Decodable {
        let names: [String]
        let counts: [UInt32]
        let frames: [Float]
        let selected: [UInt8]
        let sceneFrames: [Float]
        let sceneSelected: [UInt8]
    }
    let label: String
    let objects: [String]
    let selected: [String]
    let onlySelected: Bool
    let report: Report
    let startFrame: Float
    let next: [Float]
    let previous: [Float]
    let previousFrom: Float
}

func replay(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let scenarios = try? JSONDecoder().decode([Scenario].self, from: data)
    else {
        print("  FAIL  Blender's report could not be read from \(path)")
        exit(1)
    }
    print("\nthe timeline's jumps, from Blender's own keys, against Blender's own keyframe_jump")
    for scenario in scenarios {
        let scene = BKScene(startupFile: false)
        for name in scenario.objects {
            let object = BKObject(name: name, kind: .cube)
            scene.objects.append(object)
            if scenario.selected.contains(name) { scene.selection.insert(object.id) }
        }
        scene.animation.onlySelectedKeys = scenario.onlySelected
        let r = scenario.report
        let applied = r.counts.withUnsafeBufferPointer { counts in
            r.frames.withUnsafeBufferPointer { frames in
                r.selected.withUnsafeBufferPointer { selected in
                    r.sceneFrames.withUnsafeBufferPointer { sceneFrames in
                        r.sceneSelected.withUnsafeBufferPointer { sceneSelected in
                            AnimationMirror.applyKeys(names: r.names, counts: counts, frames: frames,
                                                      selected: selected, sceneFrames: sceneFrames,
                                                      sceneSelected: sceneSelected, to: scene)
                        }
                    }
                }
            }
        }
        check("\(scenario.label): the report applies", applied)

        func walk(from start: Float, next: Bool, steps: Int) -> [Float] {
            let whole = start.rounded(.down)
            scene.frameCurrent = Int(whole)
            scene.animation.subframe = start - whole
            var visited: [Float] = []
            for _ in 0..<steps {
                guard let target = scene.keyframeJumpTarget(next: next) else { break }
                let w = target.rounded(.down)
                scene.frameCurrent = Int(w)
                scene.animation.subframe = target - w
                visited.append(target)
            }
            return visited
        }
        func same(_ a: [Float], _ b: [Float]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
        }
        let forward = walk(from: scenario.startFrame, next: true, steps: 12)
        check("\(scenario.label): Next Keyframe visits what Blender's does",
              same(forward, scenario.next), "\(forward) vs Blender \(scenario.next)")
        let backward = walk(from: scenario.previousFrom, next: false, steps: 12)
        check("\(scenario.label): Previous Keyframe too",
              same(backward, scenario.previous), "\(backward) vs Blender \(scenario.previous)")
    }
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

switch arguments.dropFirst().first {
case "dump": dump()
case "replay" where arguments.count > 2: replay(arguments[2])
default:
    print("usage: check dump | check replay <mirror.json>")
    exit(2)
}
