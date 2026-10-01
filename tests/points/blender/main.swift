import Foundation
import CoreGraphics
import simd

// Edit Mode on curves and lattices, both halves.
//
//   dump <cages.json>     the control points Blender handed over for the
//                         fixtures (fixtures.py), read through the Swift the
//                         device runs (`SceneMirror.carryPoints`), then every
//                         string the 3D View sends for them: Edit Curve and
//                         Edit Lattice, a tap on a knot and on a handle, a box,
//                         a gizmo drag's frames and its commit (from a real
//                         `TransformGizmo` session), the Curve and Lattice
//                         menus, the Data tab's fields and Add ▸ Lattice —
//                         for a headless Blender to run (verify.py).
//   dump <replay.json>    what Blender's `_blenderkit_points.push` handed over
//                         after each of those, read back through the Swift
//                         again and held to what Blender says it holds.

var failures = 0
/// To stderr: in `dump` stdout carries the blocks Blender runs.
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    let line = ok ? "  PASS  \(label)\n" : "  FAIL  \(label)  \(detail())\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if !ok { failures += 1 }
}

/// Records what reaches the interpreter, as a device's runtime receives it.
final class RecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = false
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}

/// The same, answering as the device's runtime does (`usesRealBlender`):
/// what a command sends on the device, the selection pushed in front of it
/// included.
final class DeviceRecordingRuntime: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        return []
    }
}

struct CageJSON: Decodable {
    let type: String
    let positions: [Float]
    let flags: [UInt8]
    let lines: [UInt32]
    let matrix: [Double]
    let record: String
}

func matrix(_ values: [Double]) -> simd_float4x4 {
    var m = simd_float4x4()
    for c in 0..<4 {
        m[c] = SIMD4(Float(values[c]), Float(values[4 + c]), Float(values[8 + c]), Float(values[12 + c]))
    }
    return m
}

/// An object as the mirror makes it: its type, Blender's matrix, and the
/// points and settings `sync_points` carried, through `carryPoints`.
func mirrored(_ name: String, _ json: CageJSON) -> BKObject {
    let object = BKObject(name: name, kind: .cube)
    object.blenderType = json.type
    object.setMirroredTransform(matrix(json.matrix))
    let carried = SceneMirror.carryPoints(record: json.record, positions: json.positions, flags: json.flags,
                                          lines: json.lines, named: name, pass: [object], screen: [])
    check("\(name): Blender's points read through carryPoints", carried && object.controlCage != nil)
    return object
}

func list(_ s: Set<Int>) -> String { s.sorted().map(String.init).joined(separator: ",") }

func dump(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let cages = try? JSONDecoder().decode([String: CageJSON].self, from: data) else {
        print("  FAIL  cannot read \(path)")
        exit(1)
    }
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

    let circle = mirrored("Circle", cages["Circle"]!)
    let bez = mirrored("Bez", cages["Bez"]!)
    let path3 = mirrored("Path", cages["Path"]!)
    let lattice = mirrored("Lattice", cages["Lattice"]!)
    let free = mirrored("Free", cages["Free"]!)
    let cube = BKObject(name: "Cube", kind: .cube)
    // What `_blenderkit_sync._relations` reports for a cube under a Lattice
    // modifier, and for an empty on Bez by Follow Path (verify.py holds both
    // to that).
    cube.dependencies = ["Lattice"]
    let rider = BKObject(name: "Rider", kind: .cube)
    rider.blenderType = "EMPTY"
    rider.dependencies = ["Bez"]
    let scene = BKScene(startupFile: false)
    scene.objects = [cube, circle, bez, path3, lattice, free, rider]

    // The cages as parsed, against what Blender's numbering says.
    let c = circle.controlCage!
    check("Circle: 4 Bézier points are 12 entries, 8 handle lines", c.count == 12 && c.lines.count == 16)
    check("Circle: entry 3 a left handle, 4 a knot, 5 a right handle, Auto",
          c.part(3) == .leftHandle && c.part(4) == .point && c.part(5) == .rightHandle
          && c.handleType(3) == .auto && c.handleType(4) == nil)
    check("Bez: Aligned handles", bez.controlCage!.handleType(0) == .aligned)
    check("Path: 5 polygon points, 4 lines", path3.controlCage!.count == 5
          && (0..<5).allSatisfy { path3.controlCage!.isPolygonPoint($0) } && path3.controlCage!.lines.count == 8)
    check("Lattice: 12 points, 20 lines, a lattice", lattice.controlCage!.count == 12
          && lattice.controlCage!.lines.count == 40 && lattice.controlCage!.isLattice)
    check("Edit Mode selects everything on entry, and the Swift says so", c.selected.count == 12)
    if case .curve(let s)? = circle.dataSettings {
        check("Circle's settings: 3D, 12, no bevel, Full, 1 spline of 4, cyclic",
              s.dimensions == "3D" && s.resolutionU == 12 && s.bevelDepth == 0 && s.bevelResolution == 4
              && s.fillMode == "FULL" && s.splines == 1 && s.points == 4 && s.cyclicSplines == 1, "\(s)")
    } else { check("Circle's settings parse", false) }
    if case .lattice(let s)? = lattice.dataSettings {
        check("Lattice's settings: 3 x 2 x 2, BSpline", s.pointsU == 3 && s.pointsV == 2 && s.pointsW == 2
              && s.interpolation == ["KEY_BSPLINE", "KEY_BSPLINE", "KEY_BSPLINE"], "\(s)")
    } else { check("Lattice's settings parse", false) }

    // The bridge the menus and the Data tab go through, recording.
    let undo = UndoStack()
    undo.seed(scene)
    let runtime = RecordingRuntime()
    let session = BpySession(runtime: runtime)
    session.bind(scene: scene, undo: undo)
    let bridge = BpyBridge(session: session, scene: scene, undo: undo)
    func sent(_ action: () -> Void) -> String {
        let before = runtime.sources.count
        action()
        return runtime.sources.count > before ? runtime.sources[runtime.sources.count - 1] : ""
    }

    emit("ENTER_EDIT", sent { bridge.run(Bpy.setMode(.edit), undo: "Toggle Edit Mode") })
    emit("TOGGLE_EDIT", sent { bridge.run(Bpy.toggleEditMode, undo: "Toggle Edit Mode") })
    emit("LEAVE_EDIT", sent { bridge.run(Bpy.setMode(.object), undo: "Toggle Edit Mode") })
    emit("SCULPT_MODE", sent { bridge.run(Bpy.setMode(.sculpt), undo: "Sculpt Mode") })

    // A tap and a box, from above, in a 1000 x 800 view.
    let size = CGSize(width: 1000, height: 800)
    var camera = ViewportCamera()
    camera.snap(to: .top)
    camera.target = SIMD3(2, 0, 0)
    camera.distance = 8
    let vp = camera.viewProjection(aspect: Float(size.width / size.height))
    let model = circle.modelMatrix
    let screen = c.screenPoints(model: model, viewProjection: vp, size: size)
    // A knot: the finger lands 3 points right of it and 2 above.
    let knot = screen[4]!
    let hitKnot = c.pick(at: CGPoint(x: knot.x + 3, y: knot.y - 2), model: model, viewProjection: vp,
                         size: size, radius: 22)
    check("a tap beside a knot picks the knot", hitKnot == 4, "\(String(describing: hitKnot))")
    let afterKnot = SelectAction.set.apply(c.selected, hit: c.tapped(4))
    check("a knot takes both its handles", afterKnot == [3, 4, 5], list(afterKnot))
    emit("TAP_KNOT", BpyBridge.selectionScript(PointsBpy.select(afterKnot, object: "Circle")))
    emit("TAP_KNOT_EXPECT", list(afterKnot))
    let handle = screen[8]!
    let hitHandle = c.pick(at: handle, model: model, viewProjection: vp, size: size, radius: 22)
    check("a tap on a right handle picks it", hitHandle == 8, "\(String(describing: hitHandle))")
    let afterHandle = SelectAction.extend.apply(afterKnot, hit: c.tapped(8))
    check("Shift and a handle adds the handle alone", afterHandle == [3, 4, 5, 8], list(afterHandle))
    emit("TAP_HANDLE", BpyBridge.selectionScript(PointsBpy.select(afterHandle, object: "Circle")))
    emit("TAP_HANDLE_EXPECT", list(afterHandle))
    let nowhere = c.pick(at: CGPoint(x: 20, y: 20), model: model, viewProjection: vp, size: size, radius: 22)
    check("a tap on nothing picks nothing", nowhere == nil)

    // A box over the circle's right half (x > its centre on screen).
    let centre = BoxSelect.project(SIMD3(2, 0, 0), viewProjection: vp, size: size)!
    let box = SelectionRegion.box(CGRect(x: centre.x + 5, y: 0, width: size.width - centre.x - 5, height: size.height))
    let inside = c.inside(box, model: model, viewProjection: vp, size: size)
    let expected = Set((0..<12).filter { i in screen[i].map { $0.x >= centre.x + 5 } ?? false })
    check("the box takes each point inside by itself", inside == expected && !inside.isEmpty, list(inside))
    emit("BOX", sent { bridge.run(PointsBpy.select(SelectAction.set.applyRegion(afterHandle, inside: inside),
                                                    object: "Circle"), undo: "Box Select", quiet: true) })
    emit("BOX_EXPECT", list(inside))

    // The gizmo, on the knot selection: a real session, as the viewport
    // begins one, and the calls its frames and its release send.
    func cageSelecting(_ cage: ControlCage, _ chosen: Set<Int>) -> ControlCage {
        var copy = cage
        for i in copy.flags.indices {
            copy.flags[i] = chosen.contains(i) ? copy.flags[i] | ControlCage.selectedFlag
                                               : copy.flags[i] & ~ControlCage.selectedFlag
        }
        return copy
    }
    scene.activeID = circle.id
    scene.selection = [circle.id]
    scene.setMode(.edit)
    circle.controlCage = cageSelecting(c, [3, 4, 5])
    let options = ViewportOptions()
    func gizmoSession(_ mode: TransformGizmo.Mode, _ handle: TransformGizmo.Handle) -> TransformGizmo.Session? {
        guard let g = TransformGizmo.make(mode: mode, scene: scene, options: options, camera: camera, size: size)
        else { return nil }
        return TransformGizmo.beginSession(handle: handle, at: CGPoint(x: 500, y: 400), gizmo: g, scene: scene,
                                           camera: camera, size: size, options: options)
    }
    // A tapped knot is measured at the knot, three times: the gizmo sits on
    // it. Whether that is where Blender itself turns is verify.py's to say,
    // by Blender's own turn (TURN_PIVOT is only printed).
    let pivot = TransformGizmo.pivot(of: scene)
    let knotWorld = (model * SIMD4(c.positions[4], 1)).xyz
    check("the gizmo sits on the tapped knot", pivot.map { simd_distance($0, knotWorld) < 1e-5 } ?? false,
          "\(String(describing: pivot)) vs \(knotWorld)")
    let median = pivot ?? knotWorld
    guard let move = gizmoSession(.translate, .axis(2)) else {
        check("a move session begins on the points", false)
        print(out.joined(separator: "\n#--\n"))
        return
    }
    check("the session is a points drag of Circle, with no mesh edit and no objects", move.points?.object === circle
          && move.edit == nil && move.neighbours.isEmpty && move.followers.isEmpty)
    let frames: [SIMD3<Float>] = [SIMD3(0, 0, 0.25), SIMD3(0, 0, 0.5), SIMD3(0, 0, 0.75)]
    emit("DRAG_BEGIN", PointsBpy.beginDrag(object: "Circle", followers: move.points!.followers))
    for (k, d) in frames.enumerated() {
        emit("DRAG_FRAME_\(k)", sent { _ = bridge.previewPointDrag(TransformGizmo.python(.translate(d), session: move),
                                                                   undo: "Move") })
    }
    emit("DRAG_COMMIT", sent { bridge.commitPointDrag(TransformGizmo.python(.translate(frames[2]), session: move),
                                                      undo: "Move") })
    emit("DRAG_CANCEL", PointsBpy.cancel)

    guard let turn = gizmoSession(.rotate, .axis(2)) else {
        check("a rotate session begins on the points", false)
        print(out.joined(separator: "\n#--\n"))
        return
    }
    let turnCall = TransformGizmo.python(.rotate(axis: SIMD3(0, 0, 1), angle: 0.6, axisIndex: 2), session: turn)
    check("a turn sends the median as its centre", turnCall.contains("center_override="), turnCall)
    emit("TURN_BEGIN", PointsBpy.beginDrag(object: "Circle", followers: []))
    emit("TURN_FRAME", sent { _ = bridge.previewPointDrag(turnCall, undo: "Rotate") })
    emit("TURN_COMMIT", sent { bridge.commitPointDrag(turnCall, undo: "Rotate") })
    // The point the turn's `center_override` names, for verify.py to hold to
    // the point Blender's own turn of the tapped knot pivots on.
    let turned = turn.gizmo.origin
    emit("TURN_PIVOT", "\(turned.x),\(turned.y),\(turned.z)")
    if let stretch = gizmoSession(.scale, .axis(0)) {
        let call = TransformGizmo.python(.scale(SIMD3(1.5, 1, 1)), session: stretch)
        check("a scale is in the object's axes, about the median", call.contains("orient_type='LOCAL'")
              && call.contains("center_override="), call)
        emit("SCALE_BEGIN", PointsBpy.beginDrag(object: "Circle", followers: []))
        emit("SCALE_FRAME", sent { _ = bridge.previewPointDrag(call, undo: "Resize") })
        emit("SCALE_COMMIT", sent { bridge.commitPointDrag(call, undo: "Resize") })
    } else {
        check("a scale session begins on the points", false)
    }

    // Free's asymmetric handles: the turn each selection and pivot commits,
    // for verify.py to hold to Blender's own turn of the same selection
    // (`transform.rotate` with no centre, under a VIEW_3D override). A half
    // turn: in the 3D View Blender turns the other way about Z from the call
    // without one (the view's axis sign), and half a turn either way lands
    // every point in the same place, so only the pivot can differ.
    let fc = free.controlCage!
    check("Free: 2 Bézier points, Free handles", fc.count == 6 && fc.handleType(0) == .free)
    scene.activeID = free.id
    scene.selection = [free.id]
    let freeCases: [(Set<Int>, TransformPivot, String)] = [
        ([0, 1, 2], .medianPoint, "MEDIAN_POINT"), ([0], .medianPoint, "MEDIAN_POINT"),
        ([0, 1], .medianPoint, "MEDIAN_POINT"), ([2, 3], .medianPoint, "MEDIAN_POINT"),
        ([0, 1, 2, 5], .medianPoint, "MEDIAN_POINT"), ([0, 1, 2, 5], .boundingBoxCenter, "BOUNDING_BOX_CENTER"),
        ([0, 1, 2, 3, 4, 5], .medianPoint, "MEDIAN_POINT"), ([0, 1, 2, 3, 4, 5], .boundingBoxCenter, "BOUNDING_BOX_CENTER"),
    ]
    for (k, (chosen, setting, identifier)) in freeCases.enumerated() {
        free.controlCage = cageSelecting(fc, chosen)
        scene.tools.pivot = setting
        guard let spin = gizmoSession(.rotate, .axis(2)) else {
            check("Free case \(k): a rotate session begins", false)
            continue
        }
        emit("FREE_\(k)_SELECT", PointsBpy.select(chosen, object: "Free"))
        emit("FREE_\(k)_PIVOT", identifier)
        emit("FREE_\(k)_TURN", TransformGizmo.python(.rotate(axis: SIMD3(0, 0, 1), angle: .pi, axisIndex: 2),
                                                      session: spin))
    }
    emit("FREE_CASES", "\(freeCases.count)")
    scene.tools.pivot = .medianPoint
    free.controlCage = fc

    // Bez's first knot, tapped and moved: the empty riding Bez by Follow Path
    // follows the drag, by its matrix.
    scene.activeID = bez.id
    scene.selection = [bez.id]
    bez.controlCage = cageSelecting(bez.controlCage!, [0, 1, 2])
    if let carry = gizmoSession(.translate, .axis(2)) {
        check("the rider on Bez follows Bez's drag", carry.points?.followers == ["Rider"],
              "\(String(describing: carry.points?.followers))")
        emit("RIDER_SELECT", PointsBpy.select([0, 1, 2], object: "Bez"))
        emit("RIDER_BEGIN", PointsBpy.beginDrag(object: "Bez", followers: carry.points!.followers))
        emit("RIDER_FRAME", sent { _ = bridge.previewPointDrag(TransformGizmo.python(.translate(SIMD3(0, 0, 0.5)),
                                                                                      session: carry), undo: "Move") })
    } else {
        check("a move session begins on Bez", false)
    }

    // A curve with every point deleted, a tap on it, then Done: the tap is
    // no mesh selection, so Done is Done alone (no bmesh push in front).
    scene.activeID = circle.id
    scene.selection = [circle.id]
    let emptied = circle.controlCage
    circle.controlCage = nil
    scene.editSelection.vertices = [0]
    scene.editSelectionPending = true
    // On the device's runtime, where the pending selection is pushed: with no
    // undo label, so the history's own captures do not follow the command.
    let device = DeviceRecordingRuntime()
    let deviceSession = BpySession(runtime: device)
    deviceSession.bind(scene: scene, undo: UndoStack())
    BpyBridge(session: deviceSession, scene: scene, undo: UndoStack()).run(Bpy.setMode(.object))
    let done = device.sources.last ?? ""
    check("Done on an emptied curve sends no mesh selection", !done.contains("bmesh") && !done.contains("select_set"), done)
    emit("EMPTY_DONE", done)
    scene.editSelectionPending = false
    scene.editSelection.vertices = []
    circle.controlCage = emptied
    scene.setMode(.edit)

    // The lattice: its top layer boxed from the front, then moved up. The
    // cube under its modifier follows, frame by frame.
    scene.setMode(.object)
    scene.activeID = lattice.id
    scene.selection = [lattice.id]
    scene.setMode(.edit)
    var front = ViewportCamera()
    front.snap(to: .front)
    front.target = .zero
    front.distance = 10
    let fvp = front.viewProjection(aspect: Float(size.width / size.height))
    let top = BoxSelect.project(SIMD3(0, 0, 0.6), viewProjection: fvp, size: size)!
    let lc = lattice.controlCage!
    let layer = lc.inside(.box(CGRect(x: 0, y: 0, width: size.width, height: top.y)), model: lattice.modelMatrix,
                          viewProjection: fvp, size: size)
    let topIndices = Set(lc.positions.indices.filter { lc.positions[$0].z > 0 })
    check("a box over the lattice's top takes its top layer, front and back", layer == topIndices && layer.count == 6,
          list(layer))
    emit("LATTICE_BOX", sent { bridge.run(PointsBpy.select(SelectAction.set.applyRegion(lc.selected, inside: layer),
                                                            object: "Lattice"), undo: "Box Select", quiet: true) })
    emit("LATTICE_BOX_EXPECT", list(layer))
    lattice.controlCage = cageSelecting(lc, layer)
    guard let lift = gizmoSession(.translate, .axis(2)) else {
        check("a move session begins on the lattice", false)
        print(out.joined(separator: "\n#--\n"))
        return
    }
    check("the cube under the Lattice modifier follows the lattice's drag", lift.points?.followers == ["Cube"],
          "\(String(describing: lift.points?.followers))")
    emit("LATTICE_BEGIN", PointsBpy.beginDrag(object: "Lattice", followers: lift.points!.followers))
    emit("LATTICE_FRAME", sent { _ = bridge.previewPointDrag(TransformGizmo.python(.translate(SIMD3(0, 0, 0.1)),
                                                                                    session: lift), undo: "Move") })
    emit("LATTICE_COMMIT", sent { bridge.commitPointDrag(TransformGizmo.python(.translate(SIMD3(0, 0, 0.2)),
                                                                                session: lift), undo: "Move") })

    // The Curve and Lattice menus, as LayoutWorkspace runs them.
    func row(_ command: PointsBpy.Command) -> String {
        sent { bridge.run(command.python, undo: command.undo, executing: command.executed) }
    }
    emit("SUBDIVIDE", row(PointsBpy.subdivide(cuts: 1)))
    emit("SUBDIVIDE_2", row(PointsBpy.subdivide(cuts: 2)))
    emit("EXTRUDE", row(PointsBpy.extrude))
    emit("DELETE_VERT", row(PointsBpy.delete(segments: false)))
    emit("DELETE_SEGMENT", row(PointsBpy.delete(segments: true)))
    for type in PointsBpy.handleTypes {
        emit("HANDLE_" + type.identifier, row(PointsBpy.handleType(type.identifier)))
    }
    emit("CYCLIC", row(PointsBpy.toggleCyclic))
    emit("SWITCH", row(PointsBpy.switchDirection))
    emit("CURVE_ALL", sent { bridge.run(PointsBpy.selectAll("SELECT", lattice: false), undo: "Select All") })
    emit("CURVE_NONE", sent { bridge.run(PointsBpy.selectAll("DESELECT", lattice: false), undo: "Deselect") })
    emit("CURVE_INVERT", sent { bridge.run(PointsBpy.selectAll("INVERT", lattice: false), undo: "Invert Selection") })
    emit("LATTICE_ALL", sent { bridge.run(PointsBpy.selectAll("SELECT", lattice: true), undo: "Select All") })
    emit("MAKE_REGULAR", row(PointsBpy.makeRegular))
    emit("FLIP_U", row(PointsBpy.flip("U")))
    for what in Bpy.ShowHide.allCases {
        emit("CURVE_" + "\(what)".uppercased(), sent { bridge.run(PointsBpy.showHide(what), undo: "Hide") })
    }

    // The Data tab's fields, as PropertiesView sends them.
    func field(_ property: String, _ value: String, _ object: String) -> String {
        sent { bridge.run(PointsBpy.set(property, to: value, object: object), undo: property) }
    }
    emit("BEVEL_DEPTH", field("bevel_depth", "0.1", "Bez"))
    emit("BEVEL_RESOLUTION", field("bevel_resolution", "2", "Bez"))
    emit("EXTRUDE_DEPTH", field("extrude", "0.25", "Bez"))
    emit("FILL_HALF", field("fill_mode", "'HALF'", "Bez"))
    emit("DIMENSIONS_2D", field("dimensions", "'2D'", "Bez"))
    emit("RESOLUTION_U", field("resolution_u", "4", "Bez"))
    emit("LATTICE_U", field("points_u", "4", "Lattice"))
    emit("LATTICE_W", field("points_w", "3", "Lattice"))
    emit("LATTICE_LINEAR", field("interpolation_type_u", "'KEY_LINEAR'", "Lattice"))
    emit("LATTICE_OUTSIDE", field("use_outside", "True", "Lattice"))

    // Add ▸ Lattice, as `perform` sends it, and its redo panel's re-run.
    let add = LastOperator.add(.lattice, at: SIMD3(1, 2, 3))
    check("Add Lattice is object.add with the type", add.python.hasPrefix("bpy.ops.object.add(")
          && add.python.contains("type='LATTICE'") && add.name == "Add Lattice", add.python)
    emit("ADD_LATTICE", BpyBridge.performBody(for: add))
    var rerun = add
    rerun.subject = "@SUBJECT@"
    rerun["radius"] = 2
    emit("ADD_LATTICE_RERUN", rerun.rerunPython)

    print(out.joined(separator: "\n#--\n"))
}

// MARK: - the replay

struct Replay: Decodable {
    let name: String
    let object: String
    let type: String
    let record: String
    let positions: [Float]
    let flags: [UInt8]
    let lines: [UInt32]
    /// What Blender holds selected, by the cage's numbering, read in verify.py.
    let selected: [Int]
    /// Blender's positions for the same points, in its own space.
    let blender: [Float]
}

func replay(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let passes = try? JSONDecoder().decode([Replay].self, from: data) else {
        print("  FAIL  cannot read \(path)")
        exit(1)
    }
    for pass in passes {
        let object = BKObject(name: pass.object, kind: .cube)
        object.blenderType = pass.type
        // Outside a pass, as a tap's and a drag's frames are: onto the
        // object on screen.
        let carried = SceneMirror.carryPoints(record: pass.record, positions: pass.positions, flags: pass.flags,
                                              lines: pass.lines, named: pass.object, pass: nil, screen: [object])
        guard carried, let cage = object.controlCage else {
            check("\(pass.name): the points reach the object on screen", pass.flags.isEmpty && carried
                  && object.controlCage == nil)
            continue
        }
        check("\(pass.name): what the viewport shows selected is what Blender holds",
              cage.selected == Set(pass.selected), "\(list(cage.selected)) vs \(pass.selected)")
        let worst = zip(cage.positions.flatMap { [$0.x, $0.y, $0.z] }, pass.blender).map { abs($0 - $1) }.max() ?? 0
        check("\(pass.name): every point where Blender has it", cage.count * 3 == pass.blender.count && worst == 0,
              "worst \(worst)")
        check("\(pass.name): the settings parse", object.dataSettings != nil, pass.record)
    }
}

let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "replay" {
    replay(arguments[2])
} else if arguments.count > 1 {
    dump(arguments[1])
}
if failures > 0 {
    FileHandle.standardError.write("\(failures) failed\n".data(using: .utf8)!)
    exit(1)
}
