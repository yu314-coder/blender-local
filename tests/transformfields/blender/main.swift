import Foundation
import simd

// The Transform fields (Properties ▸ Object, the N panel's Item tab), both
// halves, against desktop Blender:
//
//   dump                  the strings the fields send — Object ▸ Parent, to
//                         build the scene, and one field edit per field of
//                         every object — for verify.py to run.
//   dump <passes.json>    what the app's own `_blenderkit_sync.push_local`
//                         sent before and after each edit, replayed through the
//                         Swift the device runs (`SceneMirror.carryChannels`,
//                         `TransformFieldEdit`) and held to Blender: the fields
//                         show Blender's own channels, an edit writes that one
//                         field and nothing else, and the viewport's preview is
//                         where Blender then puts the object and its children.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// The scene verify.py builds, each object with the rotation mode it gets.
let modes: [(name: String, mode: TransformChannels.RotationMode)] = [
    ("Parent", .euler("XYZ")), ("Child", .euler("XYZ")), ("Grandchild", .euler("XYZ")),
    ("Holder", .euler("XYZ")), ("Quat", .quaternion), ("Delta", .euler("ZXY")),
    ("AxisAngle", .axisAngle), ("Mirror", .euler("XYZ")),
]

/// What each field is set to: a value no channel of the scene already has.
func target(_ group: TransformChannels.Group) -> Float {
    group == .scale ? 1.3 : 0.7
}

func dump() {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
    emit("PARENT", LastOperator.parent(keepTransform: false).executedPython)
    emit("PARENT_KEEP", LastOperator.parent(keepTransform: true).executedPython)
    for (name, mode) in modes {
        // The values do not matter to the string, only that the field changed.
        let blank = TransformChannels(location: .zero, rotationMode: mode, rotation: .zero, scale: .zero)
        for group in TransformChannels.Group.allCases {
            for axis in blank.axes(group).indices {
                let edited = blank.setting(group, axis: axis, to: target(group))
                emit("EDIT|\(name)|\(group.rawValue)|\(axis)", blank.python(writing: edited, to: name) ?? "")
            }
        }
    }
    print(out.joined(separator: "\n#--\n"))
}

// MARK: - the replay

struct State: Decodable {
    let channels: [Double]
    let local: [Double]
    let matrix: [Double]
    let parent: String?
    /// Blender's RNA, read independently of `field_channels`.
    let location: [Double]
    let rotation_mode: String
    let rotation: [Double]
    let scale: [Double]
}
struct Edit: Decodable {
    let python: String
    let error: String?
    let matrices: [String: [Double]]
    let channels: [Double]
}
struct Run: Decodable {
    let before: [String: State]
    let edits: [String: Edit]
    let order: [String]
}

/// The scene as the mirror builds it from what `push_local` sent.
func mirrored(_ run: Run) -> BKScene {
    let scene = BKScene(startupFile: false)
    var pass: [BKObject] = []
    for name in run.order {
        guard let state = run.before[name] else { continue }
        let made = state.matrix.withUnsafeBufferPointer { m in
            [Float]().withUnsafeBufferPointer { empty in
                [UInt32]().withUnsafeBufferPointer { none in
                    SceneMirror.object(named: name, kind: "MESH", matrix: m, positions: empty,
                                       normals: empty, triangles: none, colour: nil, previous: nil)
                }
            }
        }!
        pass.append(made.object)
        _ = SceneMirror.carryLocal(state.local, named: name, pass: pass, screen: [])
        _ = SceneMirror.carryChannels(state.channels, named: name, pass: pass, screen: [])
        _ = SceneMirror.carryRelations(parent: state.parent ?? "", dependencies: state.parent.map { [$0] } ?? [],
                                       named: name, pass: pass)
    }
    scene.objects = pass
    return scene
}

func matrix(_ rowMajor: [Double]) -> simd_float4x4 {
    var m = simd_float4x4()
    for c in 0..<4 {
        m[c] = SIMD4(Float(rowMajor[c]), Float(rowMajor[4 + c]), Float(rowMajor[8 + c]), Float(rowMajor[12 + c]))
    }
    return m
}

func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    (0..<4).map { abs(a[$0] - b[$0]).max() }.max() ?? .infinity
}

func close(_ a: [Float], _ b: [Double], _ tolerance: Float = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - Float($1)) <= tolerance * max(1, abs($0)) }
}

func replay(_ path: String) -> Int32 {
    let run = try! JSONDecoder().decode(Run.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

    print("\n== the fields show what Blender holds ==")
    let scene = mirrored(run)
    for object in scene.objects {
        guard let truth = run.before[object.name], let shown = object.shownChannels else {
            check("\(object.name): the fields have channels to show", false); continue
        }
        check("\(object.name): Location shows Blender's location \(truth.location)",
              close(shown.values(.location), truth.location), "\(shown.values(.location))")
        let mode = modes.first { $0.name == object.name }!.mode
        check("\(object.name): Rotation is \(shown.rotationMode.label), Blender's \(truth.rotation_mode)",
              shown.rotationMode == mode)
        check("\(object.name): Rotation shows Blender's \(shown.rotationMode.property) \(truth.rotation)",
              close(shown.values(.rotation), truth.rotation), "\(shown.values(.rotation))")
        check("\(object.name): Scale shows Blender's scale \(truth.scale)",
              close(shown.values(.scale), truth.scale), "\(shown.values(.scale))")
    }
    // The review's case: what the fields used to show for the child.
    if let child = scene.objects.first(where: { $0.name == "Child" }) {
        check("Child: the decomposition of matrix_world the fields used to show is not its location",
              distance(simd_float4x4(translation: child.location), simd_float4x4(translation: SIMD3(0, 3, 0))) > 1,
              "\(child.location)")
        check("Child: the field shows (0, 3, 0), as Blender's N panel does",
              child.shownChannels.map { close($0.values(.location), [0, 3, 0]) } ?? false)
    }

    print("\n== each field writes itself and nothing else, and the preview is where Blender puts it ==")
    for (name, _) in modes {
        guard let before = run.before[name], let c0 = TransformChannels(before.channels) else {
            check("\(name): pushed channels", false); continue
        }
        for group in TransformChannels.Group.allCases {
            for axis in c0.axes(group).indices {
                let key = "\(name)|\(group.rawValue)|\(axis)"
                let label = "\(name) \(group.title) \(c0.axes(group)[axis])"
                guard let edit = run.edits[key] else { check("\(label): ran", false); continue }
                let c1 = c0.setting(group, axis: axis, to: target(group))
                check("\(label): the app's string from Blender's channels is the one Blender ran",
                      c0.python(writing: c1, to: name) == edit.python,
                      "\(c0.python(writing: c1, to: name) ?? "nil") vs \(edit.python)")
                check("\(label): Blender took it", edit.error == nil, edit.error ?? "")
                guard let after = TransformChannels(edit.channels) else {
                    check("\(label): channels after", false); continue
                }
                check("\(label): Blender then holds the field's value, every other field unchanged",
                      after == c1, "\(after) vs \(c1)")

                // The preview, on a scene freshly mirrored from before the edit.
                let fresh = mirrored(run)
                guard let object = fresh.objects.first(where: { $0.name == name }),
                      var preview = TransformFieldEdit(object: object, scene: fresh) else {
                    check("\(label): an edit can start", false); continue
                }
                let drawnBefore = Dictionary(fresh.objects.map { ($0.name, $0.modelMatrix) },
                                             uniquingKeysWith: { a, _ in a })
                preview.change(group, axis: axis, to: target(group))
                let worst = fresh.objects.map { o -> (String, Float) in
                    (o.name, distance(o.modelMatrix, matrix(edit.matrices[o.name] ?? [])))
                }.max { $0.1 < $1.1 }!
                check("\(label): every object is previewed where Blender put it (worst \(worst.0), \(worst.1))",
                      worst.1 < 2e-4)
                preview.rollBackDrawing()
                let restored = fresh.objects.allSatisfy { drawnBefore[$0.name] == $0.modelMatrix }
                check("\(label): and the roll-back draws everything where it was", restored)
            }
        }
    }

    // The review's numbers: Z nudged on the child moves it that far, not 3.16 m.
    if let before = run.before["Child"], let c0 = TransformChannels(before.channels) {
        let scene = mirrored(run)
        let child = scene.objects.first { $0.name == "Child" }!
        var e = TransformFieldEdit(object: child, scene: scene)!
        e.change(.location, axis: 2, to: c0.location.z + 0.01)
        let moved = simd_distance(child.modelMatrix.columns.3, matrix(before.matrix).columns.3)
        check("Child: a nudge of 0.01 in Z moves it 0.01 m (was 3.16 m)", abs(moved - 0.01) < 1e-5, "\(moved)")
        check("Child: and writes Z alone", e.python == "bpy.data.objects[\(Bpy.quote("Child"))].location[2] = \(c0.location.z + 0.01)",
              e.python ?? "nil")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.count > 1 {
    exit(replay(CommandLine.arguments[1]))
}
dump()
