import Foundation
import simd
import Observation

// The timeline's logic, on the Mac: the playback clock, Blender's frame rules,
// the summary of keys and the jumps, the mirror's buffers, and what the driver
// sends through the bridge — against a runtime that records what would reach
// Blender and answers a frame change the way the app's bridge does.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

print("Animation")

// MARK: - The playback clock

print("\n  playback keeps to real time, dropping frames rather than slowing down")
do {
    var clock = PlaybackClock(frame: 1, time: 100)
    let step1 = clock.step(at: 100 + 2.0 / 24, fps: 24, range: 1...250, loop: .infinite)
    check("two twenty-fourths of a second in, at 24 fps, is two frames on", step1 == .frame(3), "\(step1)")
    let step2 = clock.step(at: 100 + 10.5 / 24, fps: 24, range: 1...250, loop: .infinite)
    check("a refresh that comes late lands where time says, skipping the frames it missed",
          step2 == .frame(11), "\(step2)")
    let step3 = clock.step(at: 100 + 12.0 / 24, fps: 24, range: 1...250, loop: .infinite)
    check("a tick exactly on a frame boundary is that frame, not the one before", step3 == .frame(13), "\(step3)")
    var ntsc = PlaybackClock(frame: 1, time: 0)
    let rate = 30000.0 / 1001.0
    let atRate = ntsc.step(at: 100 / rate, fps: rate, range: 1...1000, loop: .infinite)
    let atThirty = ntsc.step(at: 100 / 30.0, fps: rate, range: 1...1000, loop: .infinite)
    check("the rate is fps / fps_base: 29.97 is not rounded to 30",
          atRate == .frame(101) && atThirty == .frame(100), "\(atRate) \(atThirty)")
}

print("\n  at the end of the range: Blender's playback_loop_mode")
func ending(_ loop: PlaybackLoopMode, reverse: Bool = false, from frame: Int = 249)
    -> (step: PlaybackClock.Step, clock: PlaybackClock) {
    var clock = PlaybackClock(frame: frame, time: 0, reverse: reverse)
    let step = clock.step(at: 2.0 / 24, fps: 24, range: 1...250, loop: loop)
    return (step, clock)
}
do {
    var (step, clock) = ending(.infinite)
    check("Infinite: after the last frame, back to the first", step == .frame(1), "\(step)")
    let on = clock.step(at: 5.0 / 24, fps: 24, range: 1...250, loop: .infinite)
    check("and on from there", on == .frame(4), "\(on)")
    check("Stop at End Frame stops on the last frame", ending(.stopEndFrame).step == .stop(250))
    check("Stop at Start Frame jumps back to the first and stops", ending(.stopStartFrame).step == .stop(1))
    check("Restore Frame stops where playback began", ending(.restore).step == .stop(249))
    (step, clock) = ending(.bounce)
    check("Bounce turns round at the last frame", step == .frame(250) && clock.reverse, "\(step)")
    let back = clock.step(at: 4.0 / 24, fps: 24, range: 1...250, loop: .bounce)
    check("and plays back down", back == .frame(248), "\(back)")
    (step, clock) = ending(.infinite, reverse: true, from: 2)
    check("backwards, Infinite goes from the first frame round to the last", step == .frame(250), "\(step)")
    (step, clock) = ending(.bounce, reverse: true, from: 2)
    check("backwards, Bounce turns round at the first frame", step == .frame(1) && !clock.reverse, "\(step)")
    var early = PlaybackClock(frame: 0, time: 0)
    let first = early.step(at: 0.01, fps: 24, range: 10...20, loop: .infinite)
    check("playing from before the range starts at the range", first == .frame(10), "\(first)")
}

// MARK: - Frame rules

print("\n  Blender's frame rules, as measured in 5.2.1")
do {
    let a = FrameRange.settingStart(300, end: 250)
    check("a start past the end takes the end with it", a.start == 300 && a.end == 300, "\(a)")
    let b = FrameRange.settingEnd(-5, start: 1)
    check("an end below 0 is 0, and takes the start with it", b.start == 0 && b.end == 0, "\(b)")
    let c = FrameRange.settingEnd(10, start: 20)
    check("an end before the start takes the start with it", c.start == 10 && c.end == 10, "\(c)")
    check("a negative frame is frame 0, and past the end is still a frame",
          FrameRange.current(-3) == 0 && FrameRange.current(400) == 400)
    let scene = BKScene(startupFile: false)
    scene.frameStart = 1
    scene.frameEnd = 100
    check("playback runs over the scene range", scene.playbackRange == 1...100)
    scene.animation.usePreviewRange = true
    scene.animation.previewStart = 20
    scene.animation.previewEnd = 40
    check("or the preview range when it is on", scene.playbackRange == 20...40)
}

// MARK: - The summary and the jumps

print("\n  the timeline's summary, and the jumps that step through it")
func keyed(_ name: String, _ frames: [Float], selected: [Bool] = [], in scene: BKScene, pick: Bool) -> BKObject {
    let object = BKObject(name: name, kind: .cube)
    object.mirroredKeys = frames.enumerated().map {
        TimelineKey(frame: $0.element, selected: $0.offset < selected.count && selected[$0.offset])
    }
    scene.objects.append(object)
    if pick { scene.selection.insert(object.id) }
    return object
}
do {
    let scene = BKScene(startupFile: false)
    let a = keyed("A", [1, 10], in: scene, pick: true)
    _ = keyed("B", [5, 10.004], selected: [false, true], in: scene, pick: false)
    scene.animation.sceneKeys = [TimelineKey(frame: 30)]
    check("Only Show Selected: the selection's keys and the scene's",
          scene.timelineKeys.map(\.frame) == [1, 10, 30], "\(scene.timelineKeys)")
    scene.animation.onlySelectedKeys = false
    check("with it off, everyone's", scene.timelineKeys.map(\.frame) == [1, 5, 10, 30], "\(scene.timelineKeys)")
    check("keys within a hundredth of a frame are one column, selected if either is",
          scene.timelineKeys.first { $0.frame == 10 }?.selected == true)
    scene.animation.onlySelectedKeys = true
    scene.frameCurrent = 10
    check("Next Keyframe from a keyed frame goes on past it", scene.keyframeJumpTarget(next: true) == 30)
    check("Previous Keyframe goes back past it", scene.keyframeJumpTarget(next: false) == 1)
    scene.frameCurrent = 30
    check("there is nothing after the last", scene.keyframeJumpTarget(next: true) == nil)
    a.mirroredKeys = [TimelineKey(frame: 4.4)]
    scene.frameCurrent = 4
    scene.animation.subframe = 0.4
    check("a jump that landed on a subframe does not find the same key again",
          scene.keyframeJumpTarget(next: true) == 30 && scene.keyframeJumpTarget(next: false) == nil)

    let simulator = BKScene()
    let cube = simulator.objects[0]
    simulator.frameCurrent = 5
    simulator.insertKeyframe()
    check("in the simulator, where nothing is mirrored, the shim's keys are the timeline's",
          cube.timelineKeys.map(\.frame) == [5] && simulator.timelineKeys.map(\.frame) == [5])
    cube.location = SIMD3(1, 0, 0)
    simulator.insertKeyframe()
    check("and keying a frame again replaces its key there too",
          cube.animation.channels["location"]?.keys.count == 1
            && cube.animation.channels["location"]?.keys[5] == [1, 0, 0])
}

// MARK: - The mirror

print("\n  what _blenderkit_anim hands over, applied to the display cache")
func applyKeys(_ names: [String], _ counts: [UInt32], _ frames: [Float], _ selected: [UInt8],
               sceneFrames: [Float] = [], sceneSelected: [UInt8] = [], to scene: BKScene) -> Bool {
    counts.withUnsafeBufferPointer { c in
        frames.withUnsafeBufferPointer { f in
            selected.withUnsafeBufferPointer { s in
                sceneFrames.withUnsafeBufferPointer { sf in
                    sceneSelected.withUnsafeBufferPointer { ss in
                        AnimationMirror.applyKeys(names: names, counts: c, frames: f, selected: s,
                                                  sceneFrames: sf, sceneSelected: ss, to: scene)
                    }
                }
            }
        }
    }
}
do {
    let scene = BKScene(startupFile: false)
    let m1 = BKObject(name: "M1", kind: .cube)
    let m2 = BKObject(name: "M2", kind: .cube)
    scene.objects = [m1, m2]

    let state = AnimationMirror.State(start: 10, end: 120, current: 42, subframe: 0.25, fps: 29.97,
                                      usePreviewRange: true, previewStart: 20, previewEnd: 60,
                                      autoKey: true, autoKeyReplace: false, onlyInsertAvailable: false,
                                      onlySelectedKeys: false, loopMode: .bounce)
    AnimationMirror.apply(state, to: scene)
    check("the scene state applies", AnimationMirror.state(of: scene) == state)
    var redrawn = false
    withObservationTracking {
        _ = scene.frameStart; _ = scene.frameEnd; _ = scene.frameCurrent; _ = scene.animation
    } onChange: { redrawn = true }
    AnimationMirror.apply(state, to: scene)
    check("and the same state again changes nothing, so redraws nothing", !redrawn)

    check("a key report applies",
          applyKeys(["M1", "M2"], [2, 1], [1, 10, 5], [1, 0, 0], sceneFrames: [30], sceneSelected: [1], to: scene))
    check("each object gets its columns",
          m1.mirroredKeys == [TimelineKey(frame: 1, selected: true), TimelineKey(frame: 10)]
            && m2.mirroredKeys == [TimelineKey(frame: 5)], "\(String(describing: m1.mirroredKeys))")
    check("and the scene its own", scene.animation.sceneKeys == [TimelineKey(frame: 30, selected: true)])
    _ = applyKeys(["M2"], [1], [7], [0], to: scene)
    check("an object the next report leaves out has no keys any more",
          m1.mirroredKeys == [] && m2.mirroredKeys == [TimelineKey(frame: 7)])
    check("a report whose counts do not add up is refused, changing nothing",
          !applyKeys(["M1"], [3], [1, 2], [0, 0], to: scene) && m1.mirroredKeys == [])
    check("names arrive joined by NUL bytes",
          Array("M1\u{0}M2".utf8).withUnsafeBufferPointer { AnimationMirror.names($0) } == ["M1", "M2"])
    check("and no bytes are no names", [UInt8]().withUnsafeBufferPointer { AnimationMirror.names($0) } == [])

    // Row-major, as Blender writes matrix_world: the translation is the last column.
    let matrix: [Double] = [1, 0, 0, 3, 0, 1, 0, 4, 0, 0, 1, 5, 0, 0, 0, 1]
    var moved = matrix.withUnsafeBufferPointer {
        AnimationMirror.applyFrame(12, subframe: 0, names: ["M1"], matrices: $0, to: scene)
    }
    check("a frame change sets the frame and moves the object it names",
          moved == 1 && scene.frameCurrent == 12 && m1.modelMatrix.columns.3 == SIMD4(3, 4, 5, 1),
          "\(moved) \(scene.frameCurrent) \(m1.modelMatrix.columns.3)")
    check("the panels' location follows the matrix", m1.location == SIMD3(3, 4, 5))
    check("the object it does not name is untouched", m2.mirroredTransform == nil)
    moved = matrix.withUnsafeBufferPointer {
        AnimationMirror.applyFrame(13, subframe: 0, names: ["M1"], matrices: $0, to: scene)
    }
    check("a matrix that did not change moves nothing", moved == 0 && scene.frameCurrent == 13)
    check("a buffer that is not sixteen doubles a name is refused",
          [Double](repeating: 0, count: 15).withUnsafeBufferPointer {
              AnimationMirror.applyFrame(1, subframe: 0, names: ["M1"], matrices: $0, to: scene)
          } == -1)

    let deformed = BKObject(name: "Deformed", kind: .cube)
    deformed.setMirroredMesh(MeshBuilder.make(.cube))
    scene.objects.append(deformed)
    let base = deformed.mesh
    let positions = base.vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }
    let normals = base.vertices.flatMap { [$0.normal.x, $0.normal.y, $0.normal.z] }
    func mesh(_ p: [Float], _ n: [Float], _ t: [UInt32], _ name: String = "Deformed") -> Int {
        p.withUnsafeBufferPointer { pp in
            n.withUnsafeBufferPointer { nn in
                t.withUnsafeBufferPointer { tt in
                    AnimationMirror.applyMesh(named: name, positions: pp, normals: nn, triangles: tt, to: scene)
                }
            }
        }
    }
    let version = deformed.meshVersion
    check("a mesh that came back as it was is not replaced, so not uploaded again",
          mesh(positions, normals, base.indices) == 0 && deformed.meshVersion == version)
    var raised = positions
    for i in stride(from: 2, to: raised.count, by: 3) { raised[i] += 1 }
    check("a deformed one is", mesh(raised, normals, base.indices) == 1 && deformed.meshVersion == version + 1)
    check("with its vertices moved",
          deformed.mesh.vertices[0].position.z == base.vertices[0].position.z + 1)
    check("and its edges kept rather than rebuilt: a deformation cannot change them",
          deformed.mesh.edges == base.edges)
    check("a changed topology is built afresh",
          mesh(Array(raised.prefix(9)), Array(normals.prefix(9)), [0, 1, 2]) == 1
            && deformed.mesh.vertices.count == 3)
    check("an index past the vertices is refused",
          mesh(Array(raised.prefix(9)), Array(normals.prefix(9)), [0, 1, 9]) == -1)
    check("and so is an object that is not there", mesh(positions, normals, base.indices, "Nobody") == -1)

    AnimationMirror.notice("once", on: scene)
    let first = scene.animation.notice?.id
    AnimationMirror.notice("once", on: scene)
    check("the same report twice is two notices, so the second still shows",
          scene.animation.notice?.id != first && scene.animation.notice?.text == "once")

    let shimObject = BKObject(name: "S", kind: .cube)
    shimObject.animation.insert(path: "scale", frame: 3, value: .one)
    shimObject.animation.insert(path: "location", frame: 8, value: .one)
    shimObject.animation.insert(path: "location", frame: 1, value: .zero)
    check("the shim's channels read back as path:frames lines, for _blenderkit_anim",
          AnimationMirror.channels(of: shimObject) == "location:1,8\nscale:3",
          AnimationMirror.channels(of: shimObject))
}

// MARK: - Through the bridge

/// Records what reaches Blender, and answers a frame change as the app's
/// bridge would: by setting the frame.
final class ScriptedRuntime: BpyRuntime {
    let isReal: Bool
    let usesRealBlender: Bool
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    var queries: [String] = []
    var failFrames = false
    var fullMirror = false
    init(real: Bool = true, blender: Bool = true) {
        isReal = real
        usesRealBlender = blender
    }
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "scripted" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
    func query(_ source: String, scene: BKScene) -> [BpyLine] {
        queries.append(source)
        guard let call = source.range(of: "frame_set(") else { return [] }
        if failFrames { return [BpyLine(.error, "RuntimeError: the frame would not change")] }
        let digits = source[call.upperBound...].prefix { $0.isNumber || $0 == "-" }
        if let frame = Int(digits) { scene.frameCurrent = frame }
        return fullMirror ? [BpyLine(.output, BpyAnimation.fullMirrorMarker)] : []
    }
}

struct Rig {
    let scene: BKScene
    let undo: UndoStack
    let session: BpySession
    let bridge: BpyBridge
    let driver: TimelineDriver
}

func makeRig(_ runtime: BpyRuntime, startup: Bool = false) -> Rig {
    let scene = BKScene(startupFile: startup)
    let undo = UndoStack()
    undo.seed(scene)
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    let driver = TimelineDriver()
    driver.bind(scene: scene, session: session, bridge: bridge)
    return Rig(scene: scene, undo: undo, session: session, bridge: bridge, driver: driver)
}

print("\n  I and Alt I go through the bridge, one undo step each")
let device = ScriptedRuntime()
let rig = makeRig(device)
do {
    var sent = device.sources.count
    rig.driver.insertKeyframe()
    check("I is one evaluation", device.sources.count - sent == 1, "\(device.sources.count - sent)")
    check("of the module's keyframe_insert", device.sources.last == BpyAnimation.insertKeyframe,
          device.sources.last ?? "")
    check("recorded as the undo step Blender names after its operator",
          device.queries.contains { $0.contains("\"Insert Keyframe\"") })
    check("logged in the Info log as the Python that ran",
          Array(rig.session.infoLog.suffix(2)) == ["import _blenderkit_anim", "_blenderkit_anim.keyframe_insert()"],
          "\(rig.session.infoLog)")
    check("and never echoed into the console", !rig.session.console.contains { $0.kind == .input })
    sent = device.sources.count
    rig.driver.deleteKeyframe()
    check("Alt I is one evaluation of keyframe_delete_v3d",
          device.sources.count - sent == 1 && device.sources.last == BpyAnimation.deleteKeyframe)
    check("recorded as Delete Keyframe", device.queries.contains { $0.contains("\"Delete Keyframe\"") })
}

print("\n  a frame change is a question, not a command: no mirroring pass, no undo step")
do {
    let sources = device.sources.count
    let queries = device.queries.count
    let revision = rig.session.backendRevision
    rig.driver.setFrame(24)
    check("one question", device.queries.count - queries == 1 && device.sources.count == sources)
    check("of frame_set", device.queries.last == BpyAnimation.frameSet(24), device.queries.last ?? "")
    check("which changes the frame", rig.scene.frameCurrent == 24)
    check("and records no undo step", rig.session.backendRevision == revision)

    var scheduled: [() -> Void] = []
    rig.driver.schedule = { scheduled.append($0) }
    let before = device.queries.count
    for frame in 30...40 { rig.driver.requestFrame(frame) }
    check("a scrub's requests wait for the run loop, as one", scheduled.count == 1 && device.queries.count == before)
    scheduled.forEach { $0() }
    check("and only the latest reaches Blender",
          device.queries.count - before == 1 && device.queries.last == BpyAnimation.frameSet(40))

    device.fullMirror = true
    let beforeFull = device.sources.count
    let revisionBefore = rig.session.backendRevision
    rig.driver.setFrame(50)
    device.fullMirror = false
    check("a frame that changes which objects show is followed by a whole mirror",
          device.queries.last == BpyAnimation.fullMirror, device.queries.last ?? "")
    check("asked as a question, so it is not an edit and records nothing",
          device.sources.count == beforeFull && rig.session.backendRevision == revisionBefore)
}

print("\n  the frame range, and the settings")
do {
    rig.scene.frameStart = 1
    rig.scene.frameEnd = 250
    let sent = device.sources.count
    rig.driver.setFrameStart(300)
    check("Start past End: one command, and both fields show what Blender keeps",
          device.sources.count - sent == 1 && device.sources.last == BpyAnimation.setFrameStart(300)
            && rig.scene.frameStart == 300 && rig.scene.frameEnd == 300)
    check("as an undo step named for the field", device.queries.contains { $0.contains("\"Start Frame\"") })
    rig.driver.setAutoKeying(true)
    check("the record button shows at once, and tells Blender quietly",
          rig.scene.animation.autoKey && device.queries.last == BpyAnimation.setAutoKeying(on: true))
    rig.driver.setAutoKeying(false)
}

print("\n  playback")
do {
    var now = 1000.0
    rig.driver.now = { now }
    rig.scene.frameStart = 1
    rig.scene.frameEnd = 10
    rig.scene.frameCurrent = 1
    rig.scene.animation.fps = 24
    rig.scene.animation.loopMode = .infinite
    rig.driver.play()
    check("Play plays", rig.driver.isPlaying && !rig.driver.isPlayingReverse)
    now += 3.0 / 24
    rig.driver.tick()
    check("a refresh three frames later shows the fourth frame",
          rig.scene.frameCurrent == 4 && device.queries.last == BpyAnimation.frameSet(4))
    now += 20.0 / 24
    rig.driver.tick()
    check("past the end, it loops to the start", rig.scene.frameCurrent == 1, "\(rig.scene.frameCurrent)")
    rig.scene.transformReadout = "Move"
    let queries = device.queries.count
    now += 2.0 / 24
    rig.driver.tick()
    check("a drag in progress holds the frame", device.queries.count == queries)
    rig.scene.transformReadout = nil
    rig.driver.pause()
    check("Pause stops, on the frame it was at", !rig.driver.isPlaying && rig.scene.frameCurrent == 1)

    rig.scene.frameCurrent = 5
    rig.driver.play()
    now += 2.0 / 24
    rig.driver.tick()
    rig.driver.cancel()
    check("Esc cancels back to the frame playback began on", !rig.driver.isPlaying && rig.scene.frameCurrent == 5)

    rig.scene.frameEnd = 250
    rig.scene.frameCurrent = 1
    rig.driver.play()
    let sentFrames = rig.driver.framesSent
    now += 1.0
    rig.driver.tick()
    check("a second without a refresh sends one frame — the one a second on — not the 24 between",
          rig.driver.framesSent - sentFrames == 1 && rig.scene.frameCurrent == 25, "\(rig.scene.frameCurrent)")
    rig.driver.pause()

    rig.scene.animation.loopMode = .stopEndFrame
    rig.scene.frameCurrent = 248
    rig.driver.play()
    now += 5.0 / 24
    rig.driver.tick()
    check("Stop at End Frame ends playback on the last frame", !rig.driver.isPlaying && rig.scene.frameCurrent == 250)
    rig.scene.animation.loopMode = .infinite

    device.failFrames = true
    rig.driver.play()
    now += 2.0 / 24
    rig.driver.tick()
    device.failFrames = false
    check("a frame change that fails stops playback, rather than failing every refresh", !rig.driver.isPlaying)

    let target = BKObject(name: "K", kind: .cube)
    target.mirroredKeys = [TimelineKey(frame: 3), TimelineKey(frame: 7.5)]
    rig.scene.objects = [target]
    rig.scene.selection = [target.id]
    rig.scene.frameCurrent = 1
    check("Next Keyframe jumps", rig.driver.jumpToKeyframe(next: true) && device.queries.last == BpyAnimation.frameSet(3))
    _ = rig.driver.jumpToKeyframe(next: true)
    check("to a subframe key as a frame and a subframe",
          device.queries.last == BpyAnimation.frameSet(7, subframe: 0.5), device.queries.last ?? "")
    rig.scene.frameCurrent = 8
    check("and says there is nothing further", !rig.driver.jumpToKeyframe(next: true))
    rig.scene.frameStart = 1
    rig.scene.frameEnd = 100
    rig.scene.animation.usePreviewRange = true
    rig.scene.animation.previewStart = 20
    rig.scene.animation.previewEnd = 40
    rig.driver.jumpToEndpoint(end: true)
    check("Jump to Endpoint lands on the preview range's end", device.queries.last == BpyAnimation.frameSet(40))
    rig.scene.animation.usePreviewRange = false
    rig.scene.frameCurrent = 0
    rig.driver.offset(-1)
    check("and the arrow keys stop at frame 0", device.queries.last == BpyAnimation.frameSet(0))
}

print("\n  auto keying follows a gizmo transform, in the transform's own evaluation")
do {
    let translate = "bpy.ops.transform.translate(value=(1.0000, 0.0000, 0.0000), constraint_axis=(True, False, False))"
    rig.scene.animation.autoKey = true
    let sent = device.sources.count
    rig.bridge.run(translate, undo: "Move")
    check("one evaluation", device.sources.count - sent == 1)
    check("the transform, then the follow-up",
          device.sources.last == translate + "\n" + BpyAnimation.afterTransform("TRANSLATE"),
          device.sources.last ?? "")
    rig.bridge.run(Bpy.selectAll, undo: "Select All")
    check("nothing follows a command that is not a transform",
          !(device.sources.last ?? "").contains("after_transform"))
    rig.scene.animation.autoKey = false
    rig.bridge.run(translate, undo: "Move")
    check("and nothing follows a transform with the record button off", device.sources.last == translate)
    check("the gizmo's three transforms are told apart by their operators",
          BpyAnimation.transformMode(of: "bpy.ops.transform.rotate(value=0.5, orient_axis='Z')") == "ROTATE"
            && BpyAnimation.transformMode(of: "bpy.ops.transform.resize(value=(2, 1, 1))") == "RESIZE"
            && BpyAnimation.transformMode(of: translate) == "TRANSLATE"
            && BpyAnimation.transformMode(of: translate + "\nprint(1)") == nil)
}

print("\n  with no Python at all, the Swift model is the scene")
do {
    let stub = makeRig(StubBpyRuntime(), startup: true)
    let cube = stub.scene.objects[0]
    stub.driver.setFrame(1)
    stub.driver.insertKeyframe()
    stub.driver.setFrame(10)
    cube.location = SIMD3(0, 0, 4)
    stub.driver.insertKeyframe()
    stub.driver.setFrame(1)
    check("frames change, and evaluate the Swift keys", stub.scene.frameCurrent == 1 && cube.location == .zero,
          "\(cube.location)")
    stub.driver.setFrame(10)
    check("both ways", cube.location.z == 4, "\(cube.location)")
    check("keys are logged as Blender's operator", stub.session.infoLog.contains("bpy.ops.anim.keyframe_insert()"))
    check("and no auto keying follow-up can be sent where there is no Python",
          Bpy.autoKeying(after: "bpy.ops.transform.translate(value=(1, 0, 0))", scene: stub.scene,
                         interpreter: false).isEmpty)
}

// MARK: - Cost

print("\n  the Swift half of a frame change")
do {
    let scene = BKScene(startupFile: false)
    for i in 0..<200 { scene.objects.append(BKObject(name: "H\(i)", kind: .cube)) }
    let names = scene.objects.map(\.name)
    var matrices: [Double] = []
    for i in 0..<200 { matrices += [1, 0, 0, Double(i), 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }
    var started = Date()
    for frame in 0..<120 {
        for i in 0..<200 { matrices[i * 16 + 7] = Double(frame) * 0.01 }
        _ = matrices.withUnsafeBufferPointer {
            AnimationMirror.applyFrame(frame, subframe: 0, names: names, matrices: $0, to: scene)
        }
    }
    let moving = Date().timeIntervalSince(started) / 120 * 1000
    print(String(format: "        moving 200 objects: %.3f ms a frame", moving))
    check("moving 200 objects takes under a quarter of a 60 Hz refresh", moving < 16.7 / 4, "\(moving) ms")

    // A 150 x 150 grid deforming every frame: 22,500 vertices.
    let side = 150
    var vertices: [MeshVertex] = []
    var indices: [UInt32] = []
    for y in 0..<side {
        for x in 0..<side {
            vertices.append(MeshVertex(SIMD3(Float(x), Float(y), 0), SIMD3(0, 0, 1)))
        }
    }
    for y in 0..<(side - 1) {
        for x in 0..<(side - 1) {
            let i = UInt32(y * side + x)
            indices += [i, i + 1, i + UInt32(side), i + 1, i + UInt32(side) + 1, i + UInt32(side)]
        }
    }
    let grid = BKObject(name: "Grid", kind: .grid)
    grid.setMirroredMesh(MeshData(vertices: vertices, indices: indices))
    scene.objects.append(grid)
    var positions = vertices.flatMap { [$0.position.x, $0.position.y, $0.position.z] }
    let normals = vertices.flatMap { [$0.normal.x, $0.normal.y, $0.normal.z] }
    started = Date()
    for frame in 0..<30 {
        for i in stride(from: 2, to: positions.count, by: 3) { positions[i] = Float(frame) * 0.01 }
        _ = positions.withUnsafeBufferPointer { p in
            normals.withUnsafeBufferPointer { n in
                indices.withUnsafeBufferPointer { t in
                    AnimationMirror.applyMesh(named: "Grid", positions: p, normals: n, triangles: t, to: scene)
                }
            }
        }
    }
    let deforming = Date().timeIntervalSince(started) / 30 * 1000
    print(String(format: "        deforming a 22,500-vertex mesh: %.3f ms a frame", deforming))
    check("a deforming mesh of that size fits in a 24 fps frame with room to spare", deforming < 41.7 / 4,
          "\(deforming) ms")
}

// MARK: - The preview range, scrubbing, and undo in the simulator

print("\n  the preview range, as Blender 5.2.1 keeps it")
do {
    let a = FrameRange.settingPreviewStart(50, end: 40)
    check("a preview start past its end takes the end with it", a.start == 50 && a.end == 50, "\(a)")
    let b = FrameRange.settingPreviewEnd(10, start: 30)
    check("an end before its start takes the start with it", b.start == 10 && b.end == 10, "\(b)")
    check("and a preview range may start before frame 0",
          FrameRange.settingPreviewStart(-20, end: 40).start == -20)
    let seeded = FrameRange.enablingPreview(start: 0, end: 0, sceneStart: 12, sceneEnd: 90)
    let kept = FrameRange.enablingPreview(start: 30, end: 40, sceneStart: 12, sceneEnd: 90)
    check("switched on with none set it takes the scene range, and one that was set is kept",
          seeded.start == 12 && seeded.end == 90 && kept.start == 30 && kept.end == 40)

    let previewRig = makeRig(ScriptedRuntime())
    previewRig.scene.frameStart = 12
    previewRig.scene.frameEnd = 90
    previewRig.driver.setUsePreviewRange(true)
    check("the toggle shows at once the range Blender will have",
          previewRig.scene.animation.usePreviewRange
            && previewRig.scene.animation.previewStart == 12 && previewRig.scene.animation.previewEnd == 90,
          "\(previewRig.scene.animation)")
    previewRig.driver.setPreviewStart(95)
    check("and the preview Start field keeps Blender's rule",
          previewRig.scene.animation.previewStart == 95 && previewRig.scene.animation.previewEnd == 95)
}

print("\n  scrubbing while playing")
do {
    let scrubRig = makeRig(ScriptedRuntime())
    var clockNow = 50.0
    scrubRig.driver.now = { clockNow }
    scrubRig.driver.schedule = { $0() }
    scrubRig.scene.frameStart = 1
    scrubRig.scene.frameEnd = 250
    scrubRig.scene.frameCurrent = 1
    scrubRig.driver.play()
    clockNow += 3.0 / 24
    scrubRig.driver.tick()
    scrubRig.driver.scrub(to: 100)
    check("a scrub moves the frame", scrubRig.scene.frameCurrent == 100, "\(scrubRig.scene.frameCurrent)")
    clockNow += 2.0 / 24
    scrubRig.driver.tick()
    check("and playback carries on from where the playhead was put",
          scrubRig.driver.isPlaying && scrubRig.scene.frameCurrent == 102, "\(scrubRig.scene.frameCurrent)")
    scrubRig.driver.pause()
}

print("\n  in the simulator, an undo keeps the keys it does not undo")
do {
    let stub = makeRig(StubBpyRuntime(), startup: true)
    stub.driver.insertKeyframe()
    stub.driver.setFrame(10)
    stub.scene.objects[0].location = SIMD3(0, 0, 4)
    stub.driver.insertKeyframe()
    stub.session.performUndo()
    check("undoing the second key leaves the first",
          stub.scene.objects.first?.animation.keyedFrames == [1],
          "\(String(describing: stub.scene.objects.first?.animation.keyedFrames))")
    stub.session.performRedo()
    check("and redo brings the second back", stub.scene.objects.first?.animation.keyedFrames == [1, 10])
    stub.scene.frameStart = 5
    stub.scene.frameEnd = 60
    stub.session.log("bpy.context.scene.frame_end = 60")
    stub.scene.frameEnd = 80
    stub.session.performUndo()
    check("and the frame range comes back with the step",
          stub.scene.frameStart == 1 && stub.scene.frameEnd == 250,
          "\(stub.scene.frameStart)...\(stub.scene.frameEnd)")
    let saved = try? JSONEncoder().encode(stub.scene.snapshot())
    let reread = saved.flatMap { try? JSONDecoder().decode(SceneSnapshot.self, from: $0) }
    check("and a saved scene keeps its keys and its range",
          reread?.objects.first?.animation?.keyedFrames == [1, 10] && reread?.frameEnd == 250,
          "\(String(describing: reread?.objects.first?.animation?.keyedFrames))")
    let old = Data(#"{"version":1,"objects":[],"selection":[]}"#.utf8)
    check("while a file saved before either existed still opens",
          (try? JSONDecoder().decode(SceneSnapshot.self, from: old)) != nil)
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
