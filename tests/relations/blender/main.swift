import Foundation
import simd

// Round 4, group 7 — both halves.
//
//   dump                  every string the app sends for the Outliner's
//                         collections, Object ▸ Collection, the Object
//                         Constraints tab, the Object menu's new rows and Local
//                         View, as the controls send them (`BlenderCommand`s
//                         and `perform`'s body), with the undo history's push,
//                         rewind, undo and redo — for a headless Blender to run
//                         (verify.py). Collections are named by placeholder
//                         uids (900001 …) the verifier swaps for Blender's.
//   dump <passes.json>    what Blender's own `_blenderkit_sync.sync()` pushed
//                         after them, replayed through the Swift the device
//                         runs (`SceneMirror.object`, `carryRecord`, `merge`,
//                         `applyScene`, the Outliner's `outlinerTree`) and held
//                         to what Blender says it has.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

/// The tree the dump's commands are built from — the fixture verify.py makes,
/// with placeholder uids: the Scene Collection, Collection, Parts inside it,
/// and Inner inside Parts.
let fixture = CollectionTree(viewLayer: "ViewLayer", entries: [
    .init(uid: 900001, name: "Scene Collection", depth: 0, parent: 0),
    .init(uid: 900002, name: "Collection", depth: 1, parent: 900001),
    .init(uid: 900003, name: "Parts", depth: 2, parent: 900002),
    .init(uid: 900004, name: "Inner", depth: 3, parent: 900003),
])

func dump() {
    var out: [String] = []
    func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
    func command(_ name: String, _ c: BlenderCommand) {
        emit(name, c.body)
        emit(name + "_CALL", c.call)
        emit(name + "_UNDO", c.undo ?? "")
    }
    func performed(_ name: String, _ op: LastOperator) {
        emit(name, BpyBridge.performBody(for: op, backup: false))
        emit(name + "_UNDO", op.name)
        emit(name + "_LINE", op.python.split(separator: "\n").last.map(String.init) ?? "")
    }
    emit("PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false,
                                           forceCheckpoints: false))
    emit("PUSH_REPLACE", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: true,
                                                   forceCheckpoints: false))
    emit("REWIND", BackendHistoryPython.rewind)
    emit("UNDO", BackendHistoryPython.step(-1))
    emit("REDO", BackendHistoryPython.step(1))

    // Collections.
    command("NEW_MASTER", CollectionsBpy.new(inside: 900001))
    command("NEW_COLLECTION", CollectionsBpy.new(inside: 900002))
    command("RENAME_PARTS", CollectionsBpy.rename(900003, from: "Parts", to: "Parts; renamed"))
    command("DELETE_PARTS", CollectionsBpy.delete(900003, hierarchy: false))
    command("DELETE_H_PARTS", CollectionsBpy.delete(900003, hierarchy: true))
    for toggle in CollectionsBpy.Toggle.allCases {
        for entry in [fixture.entry(900002)!, fixture.entry(900004)!] {
            command("TOGGLE_\(toggle.rawValue)_\(entry.uid)_OFF", CollectionsBpy.set(toggle, of: entry, in: fixture, on: false))
            command("TOGGLE_\(toggle.rawValue)_\(entry.uid)_ON", CollectionsBpy.set(toggle, of: entry, in: fixture, on: true))
        }
    }
    command("ACTIVE_PARTS", CollectionsBpy.setActive(fixture.entry(900003)!, in: fixture))
    command("ACTIVE_MASTER", CollectionsBpy.setActive(fixture.entry(900001)!, in: fixture))
    command("MOVE_PARTS", CollectionsBpy.move(to: 900003, link: false))
    command("MOVE_MASTER", CollectionsBpy.move(to: 900001, link: false))
    command("LINK_INNER", CollectionsBpy.move(to: 900004, link: true))
    command("MOVE_NEW", CollectionsBpy.move(to: 900002, link: false, newCollection: fixture.newName(inside: 900002)))
    command("LINK_NEW", CollectionsBpy.move(to: 900001, link: true, newCollection: "Linked"))
    emit("NEW_NAME_COLLECTION", fixture.newName(inside: 900002))
    emit("NEW_NAME_MASTER", fixture.newName(inside: 900001))

    // Constraints, on the active object Cube.
    for kind in ConstraintKind.allCases {
        command("CON_ADD_\(kind.rawValue)", ConstraintsBpy.add(kind.rawValue, to: "Cube"))
    }
    command("CON_ADD_ARMATURE", ConstraintsBpy.add("ARMATURE", to: "Cube"))
    command("CON_TARGET", ConstraintsBpy.setTarget("Sphere", of: "@CON@", on: "Cube"))
    command("CON_TARGET_NONE", ConstraintsBpy.setTarget(nil, of: "@CON@", on: "Cube"))
    command("CON_TARGET_SELF", ConstraintsBpy.setTarget("Cube", of: "@CON@", on: "Cube"))
    command("CON_INFLUENCE", ConstraintsBpy.set("influence", of: "@CON@", on: "Cube",
                                                to: ConstraintsBpy.literal(Float(0.5)), undo: "Influence"))
    command("CON_DISABLE", ConstraintsBpy.set("enabled", of: "@CON@", on: "Cube",
                                              to: ConstraintsBpy.literal(false), undo: "Enabled"))
    command("CON_ENABLE", ConstraintsBpy.set("enabled", of: "@CON@", on: "Cube",
                                             to: ConstraintsBpy.literal(true), undo: "Enabled"))
    command("CON_SET", ConstraintsBpy.set("@PROP@", of: "@CON@", on: "Cube", to: "@VALUE@", undo: "@PROP@"))
    command("CON_RENAME", ConstraintsBpy.set("name", of: "@CON@", on: "Cube", to: Bpy.quote("Renamed"), undo: "Name"))
    command("CON_REMOVE", ConstraintsBpy.remove("@CON@", of: "Cube"))
    command("CON_UP", ConstraintsBpy.move("@CON@", of: "Cube", by: -1))
    command("CON_DOWN", ConstraintsBpy.move("@CON@", of: "Cube", by: 1))
    command("CON_FIRST", ConstraintsBpy.move("@CON@", of: "Cube", to: 0))
    for operation in ConstraintsBpy.Operation.allCases {
        command("CON_OP_\(operation.rawValue)", ConstraintsBpy.operate(operation, on: "@CON@", of: "Cube"))
    }

    // The Object menu's rows.
    for (i, row) in LastOperator.mirrorRows.enumerated() {
        performed("MIRROR_\(i)", .mirror(axis: row.axis, local: row.local))
    }
    var mirrorAdjusted = LastOperator.mirror(axis: 0, local: false)
    mirrorAdjusted["constraint_axis.y"] = 1
    performed("MIRROR_XY", mirrorAdjusted)
    for (i, option) in LastOperator.mirrorOrientations.enumerated() {
        var op = LastOperator.mirror(axis: 0, local: false)
        op["orient_type"] = Double(i)
        performed("MIRROR_ORIENT_\(option.identifier)", op)
    }
    for type in LastOperator.makeLinksTypes {
        performed("LINKS_\(type.identifier)", .makeLinksData(type.identifier))
    }
    performed("COPY_UVS", .copyUVMaps())
    for row in LastOperator.SingleUser.allCases {
        performed("SINGLE_\(row.rawValue)", .makeSingleUser(row))
    }
    var singleAll = LastOperator.makeSingleUser(.objectData)
    singleAll["type"] = 1
    performed("SINGLE_ALL", singleAll)
    performed("MODCOPY", .copyModifiersToSelected())
    performed("RANDOMIZE", .randomizeTransform())
    var randomize = LastOperator.randomizeTransform()
    randomize["loc.x"] = 2
    randomize["loc.y"] = 1
    randomize["random_seed"] = 7
    randomize["rot.z"] = 0.5
    randomize["scale.x"] = 1.5
    performed("RANDOMIZE_SET", randomize)
    performed("ALIGN", .alignObjects())
    var alignX = LastOperator.alignObjects()
    alignX["align_axis.X"] = 1
    alignX["align_axis.Z"] = 1
    performed("ALIGN_XZ", alignX)
    var alignCursor = alignX
    alignCursor["relative_to"] = 1
    alignCursor["align_mode"] = 2
    performed("ALIGN_CURSOR", alignCursor)
    performed("CON_WITH_TARGETS", .addConstraintWithTargets("COPY_ROTATION"))
    performed("CON_COPY", .copyConstraintsToSelected())
    performed("CON_CLEAR", .clearObjectConstraints())

    // Local View.
    command("LOCAL", LocalViewBpy.toggle)
    command("LOCAL_REMOVE", LocalViewBpy.removeFrom)
    // What `BpyBridge.execute` sends while the mirror shows Local View: the
    // command inside `_blenderkit_localview.run` (`LocalViewBpy.scoped`),
    // and the bare command, as it went before, for the controls.
    func scoped(_ name: String, _ body: String) {
        emit(name, LocalViewBpy.scoped(BpyBridge.script(push: nil, discardBackup: false, body: body)))
        emit(name + "_BARE", body)
    }
    func scopedRun(_ name: String, _ python: String) { scoped(name, BpyModeGuard.wrap(python)) }
    func scopedPerform(_ name: String, _ op: LastOperator) {
        scoped(name, BpyBridge.performBody(for: op, backup: false))
    }
    func scopedSelect(_ name: String, _ c: SelectMenu.Command) {
        switch c.action(editing: false) {
        case .run(let python, _): scopedRun(name, python)
        case .perform(let op): scopedPerform(name, op)
        }
    }
    scopedSelect("LOCAL_SELECT_ALL", .all)
    scopedSelect("LOCAL_INVERT", .invert)
    emit("SELECT_ALL_PLAIN", Bpy.selectAll(editing: false))
    scopedSelect("LV_TYPE_MESH", .byType("MESH"))
    scopedSelect("LV_RANDOM", SelectMenu.Command(token: "object:random")!)
    scopedSelect("LV_PATTERN", .pattern("*"))
    scopedSelect("LV_GROUPED_TYPE", .grouped("TYPE"))
    scopedSelect("LV_LINKED_MATERIAL", .linked("MATERIAL"))
    scopedSelect("LV_MIRROR_SELECT", SelectMenu.Command(token: "object:mirror")!)
    scopedRun("LV_DELETE", Bpy.deleteSelected)
    scopedRun("LV_DUPLICATE", Bpy.duplicate)
    let identity = matrix_identity_float3x3
    // The gizmo's commits as `TransformGizmo.commitOperator` builds them for
    // an object drag: a Move along Z, a Rotate about Z, a Scale.
    let moveZ = LastOperator.gizmo(GizmoCommit(kind: .translate(values: SIMD3(0, 0, 1), constraint: "(False, False, True)"),
                                               orientation: .global, axes: identity, viewAxes: identity, editing: false))
    let rotateZ = LastOperator.gizmo(GizmoCommit(kind: .rotate(angle: 0.4, axis: 2), orientation: .global, axes: identity,
                                                 viewAxes: identity, editing: false, centre: SIMD3(0, 0, 0)))
    let scaleX = LastOperator.gizmo(GizmoCommit(kind: .resize(values: SIMD3(1.5, 1, 1), constraint: "(True, False, False)"),
                                                orientation: .global, axes: identity, viewAxes: identity, editing: false,
                                                centre: SIMD3(0, 0, 0)))
    scopedPerform("LV_GIZMO_MOVE", moveZ)
    scopedPerform("LV_GIZMO_ROTATE", rotateZ)
    scopedPerform("LV_GIZMO_SCALE", scaleX)
    scopedRun("LV_ROTATE", Bpy.rotate(0.4, axis: "Z"))
    scopedPerform("LV_MIRROR", .mirror(axis: 0, local: false))
    var randomizeLocal = LastOperator.randomizeTransform()
    randomizeLocal["loc.x"] = 2
    randomizeLocal["random_seed"] = 7
    scopedPerform("LV_RANDOMIZE", randomizeLocal)
    scoped("LV_MOVE_TO", CollectionsBpy.move(to: 900003, link: false).body)
    // The Operator Search's Run in Local View, as `bridge.run` sends it
    // (`OperatorCatalogue.runCommand`, `BpyModeGuard.wrap`, then the scope).
    scopedRun("LV_SEARCH_SELECT_ALL", OperatorCatalogue.runCommand(path: "object.select_all",
                                                                   json: "{\"action\":\"SELECT\"}"))
    scopedRun("LV_SEARCH_DELETE", OperatorCatalogue.runCommand(path: "object.delete", json: "{}"))
    scopedRun("LV_SEARCH_SPACE_TYPE", OperatorCatalogue.runCommand(path: "screen.space_type_set_or_cycle",
                                                                   json: "{\"space_type\":\"IMAGE_EDITOR\"}"))
    scopedRun("LV_SEARCH_CALL_MENU", OperatorCatalogue.runCommand(path: "wm.call_menu",
                                                                  json: "{\"name\":\"VIEW3D_MT_object\"}"))
    // The constrained drag's frames, by the strings the gizmo and the
    // Transform field send (`previewConstrainedDrag`): the gizmo's Move Z,
    // and the Location Z field set to 1 on a cube at the origin.
    emit("DRAG_GIZMO_MOVE_Z", moveZ.python)
    emit("DRAG_GIZMO_MOVE_Y", LastOperator.gizmo(GizmoCommit(kind: .translate(values: SIMD3(0, 1, 0),
                                                                                  constraint: "(False, True, False)"),
                                                               orientation: .global, axes: identity, viewAxes: identity,
                                                               editing: false)).python)
    let fieldCube = BKObject(name: "Cube", kind: .cube)
    fieldCube.channels = TransformChannels(location: .zero, eulerXYZ: .zero, scale: SIMD3(repeating: 1))
    let fieldScene = BKScene(startupFile: false)
    fieldScene.objects = [fieldCube]
    if var edit = TransformFieldEdit(object: fieldCube, scene: fieldScene) {
        edit.change(.location, axis: 2, to: 1)
        emit("DRAG_FIELD_LOC_Z", edit.python ?? "")
    }
    // A collection linked into two parents: Scene ▸ A ▸ C ▸ D and
    // Scene ▸ B ▸ C ▸ D, with placeholder uids 900010 A, 900011 B, 900012 C,
    // 900013 D; the instances as the record names them.
    let twoParents = CollectionTree(viewLayer: "ViewLayer", entries: [
        .init(uid: 900001, name: "Scene Collection", depth: 0, parent: 0),
        .init(uid: 900010, name: "A", depth: 1, parent: 900001, path: [900010]),
        .init(uid: 900012, name: "C", depth: 2, parent: 900010, path: [900010, 900012]),
        .init(uid: 900013, name: "D", depth: 3, parent: 900012, path: [900010, 900012, 900013]),
        .init(uid: 900011, name: "B", depth: 1, parent: 900001, path: [900011]),
        .init(uid: 900012, name: "C", depth: 2, parent: 900011, path: [900011, 900012]),
        .init(uid: 900013, name: "D", depth: 3, parent: 900012, path: [900011, 900012, 900013]),
    ])
    let bc = twoParents.entry(at: [900011, 900012])!
    command("TWO_EXCLUDE_BC", CollectionsBpy.set(.exclude, of: bc, in: twoParents, on: false))
    command("TWO_INCLUDE_BC", CollectionsBpy.set(.exclude, of: bc, in: twoParents, on: true))
    command("TWO_HIDE_BC", CollectionsBpy.set(.hide, of: bc, in: twoParents, on: false))
    command("TWO_ACTIVE_BC", CollectionsBpy.setActive(bc, in: twoParents))
    // An instancer moved and linked into what it instances.
    command("MOVE_INNER", CollectionsBpy.move(to: 900004, link: false))
    command("LINK_PARTS", CollectionsBpy.move(to: 900003, link: true))
    command("MOVE_NEW_PARTS", CollectionsBpy.move(to: 900003, link: false, newCollection: "Inside"))
    command("MOVE_COLLECTION", CollectionsBpy.move(to: 900002, link: false))
    emit("ADD_IN_LOCAL", BpyBridge.performBody(for: .addingIntoLocalView(.add(.cone, at: SIMD3(0, 4, 0))),
                                               backup: false))
    emit("ADD_PLAIN", BpyBridge.performBody(for: .add(.cone, at: SIMD3(0, -4, 0)), backup: false))
    print(out.joined(separator: "\n#--\n"))
}

// MARK: - the replay

struct Call: Decodable {
    let call: String
    let name: String
    let kind: String?
    let matrix: String?
    let positions: String?
    let normals: String?
    let triangles: String?
    let selected: Int?
    let active: Int?
    let edges: String?
    let record: String?
    let parent: String?
    let names: [String]?
    /// `sync_display`: an empty's, a light's or a camera's settings.
    let type: String?
    let data: String?
    /// `sync_channels`: the Transform fields' channels.
    let values: [Double]?
}
struct Truth: Decodable {
    let visible: Bool
    let local: Bool?
    let collections: [String]
    let constraints: [String]
    let matrix: [Double]
    let selected: Bool
}
struct Pass: Decodable {
    let name: String
    let calls: [Call]
    let blender: [String: Truth]
    /// Blender's Outliner as `outliner_tree` writes it, for the tree check.
    let tree: [String]
    let localView: [String]?
    let activeCollection: String
    /// Local View's framing as Blender did it: region size, the box, the
    /// distance it left the view at.
    let framing: [Double]?
    /// Local View entered with Frame Selected in the borrowed view: region
    /// size, the distance and the centre Blender left the view at, for the
    /// Swift to work out from the mirrored objects alone (`LocalViewFraming.box`).
    let framed: [Double]?
}

func values<T>(_ base64: String?, as: T.Type) -> [T] {
    guard let base64, let data = Data(base64Encoded: base64) else { return [] }
    return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
}

func replay(_ pass: Pass, onto scene: BKScene) {
    let previous = Dictionary(scene.objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var pending: [BKObject] = []
    var selection: Set<UUID> = []
    var active: UUID?
    var records: [SceneMirror.SceneRecord] = []
    var refused: [String] = []
    for call in pass.calls {
        switch call.call {
        case "push":
            let matrix = values(call.matrix, as: Double.self)
            let positions = values(call.positions, as: Float.self)
            let normals = values(call.normals, as: Float.self)
            let triangles = values(call.triangles, as: UInt32.self)
            let made = matrix.withUnsafeBufferPointer { m in
                positions.withUnsafeBufferPointer { p in
                    normals.withUnsafeBufferPointer { n in
                        triangles.withUnsafeBufferPointer { t in
                            SceneMirror.object(named: call.name, kind: call.kind ?? "MESH", matrix: m,
                                               positions: p, normals: n, triangles: t, colour: nil,
                                               previous: previous[call.name])
                        }
                    }
                }
            }
            guard let made else { refused.append(call.name); continue }
            pending.append(made.object)
            if call.selected == 1 { selection.insert(made.object.id) }
            if call.active == 1 { active = made.object.id }
        case "relations":
            _ = SceneMirror.carryRelations(parent: call.parent, dependencies: call.names ?? [],
                                           named: call.name, pass: pending)
        case "display":
            // As `bk_sync_display` takes it: onto the object just pushed.
            if let display = ObjectDisplay(type: call.type ?? "", dataName: call.data ?? "",
                                           record: call.record ?? ""),
               let target = pending.last(where: { $0.name == call.name }) {
                target.display = display
            }
        case "channels":
            _ = SceneMirror.carryChannels(call.values ?? [], named: call.name, pass: pending, screen: [])
        case "record":
            switch SceneMirror.carryRecord(kind: call.kind ?? "", name: call.name, record: call.record ?? "",
                                           pass: pending, screen: []) {
            case .failure: refused.append("\(call.kind ?? "?") record of \(call.name)")
            case .object: break
            case .scene(let record): records.append(record)
            }
        default:
            break
        }
    }
    check("\(pass.name): every record Blender's sync pushed is taken", refused.isEmpty,
          refused.joined(separator: ", "))
    SceneMirror.merge(pending, into: scene, unchanged: [], selection: selection, active: active)
    SceneMirror.applyScene(records, to: scene)
}

func outline(_ scene: BKScene) -> [String] {
    scene.outlinerTree().map { row in
        let pad = String(repeating: ".", count: row.depth)
        switch row.item {
        case .collection(let e):
            return pad + "[" + e.name + (e.excluded ? " excl" : "") + (e.hidden ? " hid" : "")
                + (e.selectable ? "" : " unsel") + (e.renders ? "" : " norender") + "]"
        case .object(let o): return pad + o.name
        }
    }
}

func replayAll(_ path: String) -> Int32 {
    let passes = try! JSONDecoder().decode([Pass].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var scene = BKScene(startupFile: false)
    scene.objects = []
    for pass in passes {
        print("\n\(pass.name)")
        if pass.name.hasPrefix("new:") {
            scene = BKScene(startupFile: false)
            scene.objects = []
        }
        replay(pass, onto: scene)
        check("\(pass.name): the objects on screen are Blender's", Set(scene.objects.map(\.name)) == Set(pass.blender.keys),
              "\(scene.objects.map(\.name).sorted()) vs \(pass.blender.keys.sorted())")
        let shown = outline(scene)
        check("\(pass.name): the Outliner's tree is Blender's", shown == pass.tree,
              "\n        app     \(shown)\n        Blender \(pass.tree)")
        check("\(pass.name): the active collection is Blender's, \(pass.activeCollection)",
              (scene.collections?.active?.name ?? "") == pass.activeCollection,
              scene.collections?.active?.name ?? "none")
        let local = pass.localView.map(Set.init)
        check("\(pass.name): Local View is Blender's", scene.localView?.objects == local,
              "\(scene.localView?.objects.sorted() ?? []) vs \(pass.localView ?? [])")
        for (name, truth) in pass.blender.sorted(by: { $0.key < $1.key }) {
            guard let o = scene.objects.first(where: { $0.name == name }) else { continue }
            let drawn = truth.visible && (truth.local ?? true)
            check("\(pass.name): \(name) is \(drawn ? "drawn" : "not drawn"), as Blender draws it",
                  o.visible == drawn && o.outsideLocalView == (truth.local == false),
                  "visible \(o.visible), outside local view \(o.outsideLocalView)")
            let shownIn = scene.collections?.collections(holding: name).map(\.name) ?? []
            check("\(pass.name): Relations ▸ Collection shows \(name) in \(truth.collections)",
                  Set(shownIn) == Set(truth.collections), "\(shownIn)")
            let cons = o.constraints.map { "\($0.name):\($0.kind):\($0.enabled ? 1 : 0):"
                + LastOperator.number(Double($0.influence)) + ":" + ($0.target ?? "") }
            check("\(pass.name): \(name)'s constraints are Blender's", cons == truth.constraints,
                  "\n        app     \(cons)\n        Blender \(truth.constraints)")
            // The matrix the viewport draws with — the constrained one.
            let m = o.modelMatrix
            var gap: Double = 0
            for r in 0..<4 { for c in 0..<4 { gap = max(gap, abs(Double(m[c][r]) - truth.matrix[r * 4 + c])) } }
            check("\(pass.name): \(name) is drawn where Blender evaluates it", gap < 1e-5, "\(gap)")
            check("\(pass.name): \(name)'s selection is Blender's",
                  scene.selection.contains(o.id) == truth.selected)
        }
        if let f = pass.framed, f.count == 6, let held = scene.localView?.objects {
            // winx, winy, Blender's view distance, the centre it turned about.
            let aspect = Float(f[0] / f[1])
            let fovY = 2 * atan(0.72 / max(aspect, 1))
            let box = LocalViewFraming.box(of: scene.objects.filter { held.contains($0.name) })
            let framed = box.flatMap { LocalViewFraming.frame(lo: $0.lo, hi: $0.hi, fovY: fovY, aspect: aspect,
                                                              clipStart: 0.01) }
            check("\(pass.name): Local View frames it as Blender did, \(f[2]) away",
                  framed.map { abs(Double($0.distance) - f[2]) < 1e-3 } ?? false, "\(framed?.distance ?? -1)")
            let centre = framed?.centre ?? SIMD3(repeating: .nan)
            check("\(pass.name): about the centre Blender turned about",
                  abs(Double(centre.x) - f[3]) < 1e-4 && abs(Double(centre.y) - f[4]) < 1e-4
                    && abs(Double(centre.z) - f[5]) < 1e-4, "\(centre) vs \(f[3...5])")
            // The control: the objects' world bounds, which the app framed
            // by before (`BKObject.worldBounds`).
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for o in scene.objects where held.contains(o.name) {
                lo = simd_min(lo, o.worldBounds.min); hi = simd_max(hi, o.worldBounds.max)
            }
            let old = LocalViewFraming.frame(lo: lo, hi: hi, fovY: fovY, aspect: aspect, clipStart: 0.01)
            if !scene.objects.contains(where: { held.contains($0.name) && $0.blenderType == "MESH" }) {
                check("\(pass.name): control: the world bounds frame it elsewhere",
                      old.map { abs(Double($0.distance) - f[2]) > 0.5 } ?? true, "\(old?.distance ?? -1)")
            }
        }
        if let f = pass.framing, f.count == 9 {
            // winx, winy, lo xyz, hi xyz, Blender's view distance.
            let aspect = Float(f[0] / f[1])
            let fovY = 2 * atan(0.72 / max(aspect, 1))
            let framed = LocalViewFraming.frame(lo: SIMD3(Float(f[2]), Float(f[3]), Float(f[4])),
                                                hi: SIMD3(Float(f[5]), Float(f[6]), Float(f[7])),
                                                fovY: fovY, aspect: aspect, clipStart: 0.01)
            check("\(pass.name): Local View's framing is Blender's, \(f[8])",
                  framed.map { abs(Double($0.distance) - f[8]) < 1e-3 } ?? false, "\(framed?.distance ?? -1)")
        }
    }
    // The checks above can fail: a pass replayed without one of its records
    // is not Blender's.
    print("\ncontrols")
    func without(_ pass: Pass, _ kind: String) -> BKScene {
        let s = BKScene(startupFile: false)
        s.objects = []
        let calls = pass.calls.filter { !($0.call == "record" && $0.kind == kind) }
        replay(Pass(name: "control: \(pass.name) without its \(kind) record", calls: calls, blender: pass.blender,
                    tree: pass.tree, localView: pass.localView, activeCollection: pass.activeCollection,
                    framing: nil, framed: nil), onto: s)
        return s
    }
    if let pass = passes.first(where: { $0.tree.filter { $0.contains("[") }.count > 2 }) {
        check("control: without the collections record the Outliner's tree is not Blender's",
              outline(without(pass, "collections")) != pass.tree)
    }
    if let pass = passes.first(where: { $0.localView != nil }) {
        check("control: without the localview record Local View is not Blender's",
              without(pass, "localview").localView?.objects != pass.localView.map(Set.init))
    }
    if let pass = passes.first(where: { $0.blender.values.contains { !$0.constraints.isEmpty } }) {
        let s = without(pass, "constraints")
        check("control: without the constraints record the tab shows none",
              s.objects.allSatisfy { $0.constraints.isEmpty })
    }
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.count > 1 {
    exit(replayAll(CommandLine.arguments[1]))
}
dump()
