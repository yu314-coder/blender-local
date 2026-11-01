import Foundation
import simd

// The Swift half of round 4, group 7: Blender's collections in the Outliner
// and Object ▸ Collection, the Object Constraints tab, the Object menu's
// Mirror, Link/Transfer Data, Make Single User, Copy Modifiers to Selected
// Objects, Randomize Transform and Align Objects rows, and Local View — the
// records the mirror reads back, the trees and flags built from them, and the
// Python each control sends. What Blender makes of that Python is
// scripts/run-relations-blender-check.sh. Each group of checks has a control
// that has to fail.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}
func equal(_ label: String, _ got: String, _ want: String) {
    check(label, got == want, "\n        got  \(got)\n        want \(want)")
}

func escape(_ s: String) -> String {
    var t = s
    for (raw, esc) in [("%", "%25"), (";", "%3B"), ("|", "%7C"), ("=", "%3D"), ("\n", "%0A")] {
        t = t.replacingOccurrences(of: raw, with: esc)
    }
    return t
}
/// What `_blenderkit_collections._names` writes, then `_value`'s escape.
func names(_ list: [String]) -> String {
    escape(list.map { $0.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ",", with: "%2C") }
        .joined(separator: ","))
}

// --------------------------------------------------------------------------
print("the collection record")

let odd = "Odd, name; with | and = and 50%"
let record = [
    "kind=view_layer;name=ViewLayer",
    "kind=collection;uid=35;name=Scene Collection;depth=0;parent=0;exclude=0;hide=0;select=1;disabled=0;render=1;active=0;objects=" + names(["Light"]),
    "kind=collection;uid=114;name=Collection;depth=1;parent=35;exclude=0;hide=0;select=1;disabled=0;render=1;active=1;objects=" + names(["Cube", "Sphere", "Child"]),
    "kind=collection;uid=200;name=" + escape(odd) + ";depth=1;parent=35;exclude=1;hide=1;select=0;disabled=1;render=0;active=0;objects=" + names(["Sphere", odd]),
    "kind=collection;uid=201;name=Inner;depth=2;parent=200;exclude=0;hide=0;select=1;disabled=0;render=1;active=0;objects=",
].joined(separator: "|")
let tree = CollectionTree(record: record)
check("the record parses", tree != nil)
if let tree {
    check("the scene's own collection comes first, depth 0, named Scene Collection",
          tree.sceneCollection?.name == "Scene Collection" && tree.sceneCollection?.isSceneCollection == true)
    check("four collections, in Blender's depth-first order",
          tree.entries.map(\.uid) == [35, 114, 200, 201], "\(tree.entries.map(\.uid))")
    let oddEntry = tree.entry(200)
    equal("a name with the separators in it comes back whole", oddEntry?.name ?? "", odd)
    check("its objects come back whole, the comma and percent in one name kept",
          oddEntry?.objects == ["Sphere", odd], "\(oddEntry?.objects ?? [])")
    check("the toggles read as the record has them",
          oddEntry?.excluded == true && oddEntry?.hidden == true && oddEntry?.selectable == false
            && oddEntry?.disabled == true && oddEntry?.renders == false)
    check("the active collection is Collection", tree.active?.name == "Collection")
    check("Sphere is in Collection and in the odd one, Blender's order, the scene's own last",
          tree.collections(holding: "Sphere").map(\.uid) == [114, 200])
    check("Light is in the Scene Collection only", tree.collections(holding: "Light").map(\.uid) == [35])
    check("Inner is excluded by its parent", tree.isExcluded(201) && !tree.isExcluded(114))
    // BKE_collection_new_name_get.
    equal("a new collection in the scene's own is Collection N, one past its children",
          tree.newName(inside: 35), "Collection 3")
    equal("inside another, its name and the count", tree.newName(inside: 200), odd + " 2")
    equal("inside an empty one, 1", tree.newName(inside: 201), "Inner 1")
}
check("control: a record without the scene's own collection is refused",
      CollectionTree(record: "kind=view_layer;name=V|kind=collection;uid=1;name=A;depth=1;parent=0") == nil)
check("control: the record with its separators unescaped does not keep the name",
      CollectionTree(record: record.replacingOccurrences(of: escape(odd), with: odd))?.entry(200)?.name != odd)

// --------------------------------------------------------------------------
print("\nthe Outliner's tree")

func object(_ name: String, parent: String? = nil, visible: Bool = true) -> BKObject {
    let o = BKObject(name: name, kind: .cube)
    o.parentName = parent
    o.visible = visible
    return o
}
let scene = BKScene()
scene.objects = [object("Light"), object("Cube"), object("Sphere"), object("Child", parent: "Cube"), object(odd)]
scene.collections = tree
func describe(_ rows: [OutlinerTreeRow]) -> String {
    rows.map { row in
        let pad = String(repeating: ".", count: row.depth)
        switch row.item {
        case .collection(let e): return pad + "[" + e.name + "]"
        case .object(let o): return pad + o.name + (row.excluded ? "(x)" : "")
        }
    }.joined(separator: " ")
}
let rows = scene.outlinerTree()
equal("collections before objects, each object under every collection it is in, a child under its parent",
      describe(rows),
      "[Scene Collection] .[Collection] ..Cube ...Child ..Sphere .[\(odd)] ..[Inner] ..Sphere(x) ..\(odd)(x) .Light")
check("rows have distinct ids though Sphere is listed twice", Set(rows.map(\.id)).count == rows.count)
check("the excluded branch is greyed: the collection, its child collection and its two objects",
      rows.filter(\.excluded).count == 4, "\(rows.filter(\.excluded).count)")
equal("a folded collection lists nothing under it",
      describe(scene.outlinerTree(collapsed: [tree!.entry(114)!.id])),
      "[Scene Collection] .[Collection] .[\(odd)] ..[Inner] ..Sphere(x) ..\(odd)(x) .Light")
equal("a search lists the matching objects once each, flat", describe(scene.outlinerTree(matching: "sph")), "Sphere")
scene.collections = nil
equal("without a tree from Blender (the stand-in), the objects and their children, outside any collection",
      describe(scene.outlinerTree()), "Light Cube .Child Sphere \(odd)")
check("control: the old hard-coded row is gone — no row is called Collection without a tree",
      !scene.outlinerTree().contains { $0.entry?.name == "Collection" })
scene.collections = tree

// --------------------------------------------------------------------------
print("\nLocal View")

if case .some(.some(let state)) = LocalViewState.parse("active=1;objects=" + names(["Cube", odd])) {
    check("Local View's record names its objects, a separator in one kept", state.objects == ["Cube", odd])
} else { check("Local View's record parses", false) }
check("active=0 is outside Local View", LocalViewState.parse("active=0") == .some(nil))
check("control: a record without active is refused", LocalViewState.parse("objects=A") == nil)

func push(_ name: String, _ kind: String, at x: Double = 0) -> BKObject {
    let matrix: [Double] = [1, 0, 0, x, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
    let normals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
    let tris: [UInt32] = [0, 1, 2]
    return matrix.withUnsafeBufferPointer { m in
        positions.withUnsafeBufferPointer { p in
            normals.withUnsafeBufferPointer { n in
                tris.withUnsafeBufferPointer { t in
                    SceneMirror.object(named: name, kind: kind, matrix: m, positions: p, normals: n,
                                       triangles: t, colour: nil, previous: nil)!.object
                }
            }
        }
    }
}
let outside = push("Sphere", "MESH|hidden|notlocal")
check("|notlocal: not drawn, and outside Local View", !outside.visible && outside.outsideLocalView)
let hiddenToo = push("Hidden", "MESH|hidden|layerhidden|notlocal")
check("hidden by H and outside Local View: both said", hiddenToo.hiddenInViewLayer && hiddenToo.outsideLocalView)
let inside = push("Cube", "MESH")
check("control: an object in Local View is drawn", inside.visible && !inside.outsideLocalView)

// The scene-wide records, carried until the pass ends.
let carried = SceneMirror.carryRecord(kind: "localview", name: "", record: "active=1;objects=Cube",
                                      pass: [], screen: [])
check("a Local View record is held for the pass's end",
      carried == .scene(.localView(LocalViewState(objects: ["Cube"]))))
let held = BKScene()
SceneMirror.applyScene([.localView(LocalViewState(objects: ["Cube"])), .collections(tree!)], to: held)
check("and put on the scene with the tree", held.localView?.objects == ["Cube"] && held.collections == tree)
SceneMirror.applyScene([.localView(nil)], to: held)
check("leaving Local View clears it", held.localView == nil)
check("control: a kind the interface does not take fails, which Python hears as a ValueError",
      SceneMirror.carryRecord(kind: "nonsense", name: "", record: "", pass: [], screen: []) == .failure)

// Blender's framing, measured in desktop 5.2.1: a 2 m cube at the origin,
// the borrowed region 1574 × 954, lens 50 (Blender's viewport angle
// 2·atan(0.72) across the wider side) — view distance 3.2081.
let aspect: Float = 1574.0 / 954.0
let fovY = 2 * atan(0.72 / aspect)
if let framed = LocalViewFraming.frame(lo: SIMD3(-1, -1, -1), hi: SIMD3(1, 1, 1), fovY: fovY,
                                       aspect: aspect, clipStart: 0.01) {
    check("Local View frames a 2 m cube 3.2081 away, as Blender's view did",
          abs(framed.distance - 3.2081) < 0.001, "\(framed.distance)")
    check("about the middle of its box", framed.centre == .zero)
    // Without the aspect (fitting the wider side), as the app's Frame
    // Selected does: the control.
    let wide = 1.4 / (0.72 as Float)
    check("control: fitting the wider side instead would stand at 1.944", abs(framed.distance - wide) > 1)
}
if let tall = LocalViewFraming.frame(lo: SIMD3(-1, -1, -1), hi: SIMD3(1, 1, 1), fovY: 2 * atan(0.72),
                                     aspect: 0.5, clipStart: 0.01) {
    check("in a tall view the narrower, horizontal angle decides",
          abs(tall.distance - 1.4 / (0.72 * 0.5)) < 0.001, "\(tall.distance)")
}
check("an empty box leaves the view alone", LocalViewFraming.frame(lo: SIMD3(repeating: 1), hi: SIMD3(repeating: -1),
                                                                    fovY: 0.7, aspect: 1, clipStart: 0.01) == nil)

// --------------------------------------------------------------------------
print("\nconstraints")

let conRecord = [
    "kind=COPY_LOCATION;name=" + escape("Copy; Location") + ";label=Copy Location;enabled=1;influence=0.5;active=1;valid=1;expanded=1;target=Sphere;target_type=MESH;use_x=1;use_y=0;use_z=1;invert_x=0;invert_y=0;invert_z=0;use_offset=0;options.target_space=WORLD:World Space,LOCAL:Local Space;target_space=WORLD;options.owner_space=WORLD:World Space,LOCAL:Local Space;owner_space=LOCAL",
    "kind=TRACK_TO;name=Track To;label=Track To;enabled=0;influence=1.0;active=0;valid=0;expanded=1;target=;target_type=;options.track_axis=TRACK_X:X,TRACK_NEGATIVE_Z:-Z;track_axis=TRACK_NEGATIVE_Z",
    "kind=ARMATURE;name=Armature;label=Armature;enabled=1;influence=1.0;active=0;valid=0;expanded=1",
    "kind=CHILD_OF;name=Child Of;label=Child Of;enabled=1;influence=1.0;active=0;valid=1;expanded=1;unread=1",
].joined(separator: "|")
let stack = ObjectConstraint.stack(from: conRecord)
check("four constraints, top first", stack.map(\.kind) == ["COPY_LOCATION", "TRACK_TO", "ARMATURE", "CHILD_OF"])
if stack.count == 4 {
    equal("a name with a separator comes back whole", stack[0].name, "Copy; Location")
    check("Enabled, Influence, Active and the axes read as sent",
          stack[0].enabled && stack[0].influence == 0.5 && stack[0].active
            && stack[0].bool("use_x") == true && stack[0].bool("use_y") == false)
    equal("the target", stack[0].target ?? "", "Sphere")
    check("no target is nil", stack[1].target == nil)
    equal("an enum shows the item's name", stack[1].label(of: "track_axis"), "-Z")
    equal("and offers this Blender's items", stack[0].options("owner_space").map(\.label).joined(separator: ","),
          "World Space,Local Space")
    check("disabled and invalid read as sent", !stack[1].enabled && !stack[1].valid)
    check("modelled types get rows; Armature does not; an unread Child Of does not",
          stack[0].isModelled && stack[1].isModelled && !stack[2].isModelled && !stack[3].isModelled)
}
check("an empty record is no constraints", ObjectConstraint.stack(from: "").isEmpty)
let carrier = BKObject(name: "Cube", kind: .cube)
check("constraints go onto the object the pass just pushed",
      SceneMirror.carryRecord(kind: "constraints", name: "Cube", record: conRecord, pass: [carrier], screen: []) == .object
        && carrier.constraints.count == 4)
check("control: a pass that did not push the name fails",
      SceneMirror.carryRecord(kind: "constraints", name: "Nope", record: conRecord, pass: [carrier], screen: []) == .failure)

// The merge carries them, and Local View's flag, onto an object already on
// screen — the merge drops `fresh`, as it used to drop the modifier stack.
let onScreen = BKScene()
let old = BKObject(name: "Cube", kind: .cube)
onScreen.objects = [old]
let fresh = push("Cube", "MESH|hidden|notlocal")
fresh.constraints = stack
SceneMirror.merge([fresh], into: onScreen, unchanged: [], selection: [], active: nil)
check("the merge keeps the object and takes its constraints and Local View's flag",
      onScreen.objects.first === old && old.constraints == stack && old.outsideLocalView && !old.visible)

equal("Add Object Constraint's menu lists 27 types, Blender's object types",
      "\(ConstraintMenu.types.count)", "27")
check("control: no bone-only type in it", !ConstraintMenu.types.contains { $0.id == "IK" || $0.id == "SPLINE_IK" })

// The commands.
let add = ConstraintsBpy.add("COPY_LOCATION", to: "Cube")
equal("Add logs Blender's operator", add.call, "bpy.ops.object.constraint_add(type='COPY_LOCATION')")
check("and runs the guarded module call, its step Add Constraint",
      add.body.contains("_blenderkit_constraints.add(\"Cube\", 'COPY_LOCATION')") && add.undo == "Add Constraint")
let del = ConstraintsBpy.remove("Copy Location", of: "Cube")
equal("Delete", del.call, "bpy.ops.constraint.delete(constraint=\"Copy Location\", owner='OBJECT')")
check("its step Delete Constraint", del.undo == "Delete Constraint")
check("Up and Down are Move Constraint Up and Down",
      ConstraintsBpy.move("A", of: "Cube", by: -1).undo == "Move Constraint Up"
        && ConstraintsBpy.move("A", of: "Cube", by: 1).call.contains("constraint.move_down("))
equal("Move to Last", ConstraintsBpy.move("A", of: "Cube", to: 3).call,
      "bpy.ops.constraint.move_to_index(constraint=\"A\", owner='OBJECT', index=3)")
let influence = ConstraintsBpy.set("influence", of: "A", on: "Cube", to: ConstraintsBpy.literal(Float(0.25)),
                                   undo: "Influence")
equal("Influence writes the property", influence.call, "bpy.data.objects[\"Cube\"].constraints[\"A\"].influence = 0.25")
check("through set_value, its step Influence",
      influence.body.contains("set_value(\"Cube\", \"A\", 'influence', 0.25)") && influence.undo == "Influence")
equal("a target", ConstraintsBpy.setTarget("Sphere", of: "A", on: "Cube").call,
      "bpy.data.objects[\"Cube\"].constraints[\"A\"].target = bpy.data.objects[\"Sphere\"]")
equal("no target", ConstraintsBpy.setTarget(nil, of: "A", on: "Cube").call,
      "bpy.data.objects[\"Cube\"].constraints[\"A\"].target = None")
equal("Set Inverse", ConstraintsBpy.operate(.setInverse, on: "Child Of", of: "Cube").call,
      "bpy.ops.constraint.childof_set_inverse(constraint=\"Child Of\", owner='OBJECT')")
check("Animate Path's step is the operator's name, Auto Animate Path",
      ConstraintsBpy.operate(.animatePath, on: "F", of: "C").undo == "Auto Animate Path")

// --------------------------------------------------------------------------
print("\nthe collection commands")

if let tree {
    let collection = tree.entry(114)!, inner = tree.entry(201)!
    equal("a nested layer collection's path goes through its parents", CollectionsBpy.layerPath(inner, in: tree),
          "bpy.context.view_layer.layer_collection.children[\"\(odd.replacingOccurrences(of: "\"", with: "\\\""))\"].children[\"Inner\"]")
    let exclude = CollectionsBpy.set(.exclude, of: collection, in: tree, on: false)
    equal("unticking the checkbox excludes", exclude.call,
          "bpy.context.view_layer.layer_collection.children[\"Collection\"].exclude = True")
    check("through set_exclude(True), its step Exclude from View Layer",
          exclude.body.contains("set_exclude(114, True, path=[114])") && exclude.undo == "Exclude from View Layer")
    let eyeOpen = CollectionsBpy.set(.hide, of: collection, in: tree, on: true)
    check("opening the eye clears Hide in Viewport",
          eyeOpen.body.contains("set_hide(114, False, path=[114])") && eyeOpen.undo == "Hide in Viewport")
    let arrowOff = CollectionsBpy.set(.selectable, of: collection, in: tree, on: false)
    check("turning the arrow off sets Disable Selection",
          arrowOff.call.hasSuffix(".hide_select = True") && arrowOff.body.contains("set_selectable(114, False)")
            && arrowOff.undo == "Disable Selection")
    let cameraOff = CollectionsBpy.set(.render, of: collection, in: tree, on: false)
    check("turning the camera off sets Disable in Renders",
          cameraOff.call.hasSuffix(".hide_render = True") && cameraOff.body.contains("set_render(114, False)")
            && cameraOff.undo == "Disable in Renders")
    check("control: the checkbox's sense is the property's opposite",
          !CollectionsBpy.set(.exclude, of: collection, in: tree, on: true).body.contains("True)"))
    let move = CollectionsBpy.move(to: 114, link: false)
    equal("Move to Collection drives collection_uid", move.call, "bpy.ops.object.move_to_collection(collection_uid=114)")
    check("its step Move to Collection", move.undo == "Move to Collection")
    let linkNew = CollectionsBpy.move(to: 35, link: true, newCollection: "Parts")
    equal("Link to New Collection drives is_new and the name", linkNew.call,
          "bpy.ops.object.link_to_collection(collection_uid=35, is_new=True, new_collection_name=\"Parts\")")
    check("its step Link to Collection", linkNew.undo == "Link to Collection")
    check("New Collection's step", CollectionsBpy.new(inside: 35).undo == "New Collection")
    check("Delete and Delete Hierarchy",
          CollectionsBpy.delete(114, hierarchy: false).undo == "Delete"
            && CollectionsBpy.delete(114, hierarchy: true).body.contains("hierarchy=True")
            && CollectionsBpy.delete(114, hierarchy: true).undo == "Delete Hierarchy")
    check("a tap on a collection makes no undo step", CollectionsBpy.setActive(collection, in: tree).undo == nil)
}
check("Local View's steps are the operators' names",
      LocalViewBpy.toggle.undo == "Local View" && LocalViewBpy.removeFrom.undo == "Remove from Local View")

// --------------------------------------------------------------------------
print("\na collection linked into two parents")

// Scene ▸ A ▸ C ▸ D and Scene ▸ B ▸ C ▸ D, Cube in D: the record desktop
// 5.2.1's `_blenderkit_collections.record` wrote for it (uids 10 A, 11 B,
// 12 C, 13 D), each layer collection with its path. Blender's Outliner lists
// C, D and Cube under A and again under B.
func entryLine(_ uid: Int, _ name: String, _ depth: Int, _ parent: Int, _ path: String, objects: [String] = [],
               exclude: Bool = false) -> String {
    "kind=collection;uid=\(uid);name=\(name);depth=\(depth);parent=\(parent);path=\(path);exclude=\(exclude ? 1 : 0);hide=0;select=1;disabled=0;render=1;active=0;objects=" + names(objects)
}
let twoRecord = ["kind=view_layer;name=ViewLayer",
                 "kind=collection;uid=1;name=Scene Collection;depth=0;parent=0;path=;exclude=0;hide=0;select=1;disabled=0;render=1;active=1;objects=",
                 entryLine(10, "A", 1, 1, "10"), entryLine(12, "C", 2, 10, "10/12"),
                 entryLine(13, "D", 3, 12, "10/12/13", objects: ["Cube"]),
                 entryLine(11, "B", 1, 1, "11"), entryLine(12, "C", 2, 11, "11/12", exclude: true),
                 entryLine(13, "D", 3, 12, "11/12/13", objects: ["Cube"])].joined(separator: "|")
let twoTree = CollectionTree(record: twoRecord)!
let twoScene = BKScene()
twoScene.objects = [object("Cube")]
twoScene.collections = twoTree
let twoRows = twoScene.outlinerTree()
equal("each instance lists its own children: C, D and Cube under A and again under B, as Blender's Outliner",
      describe(twoRows), "[Scene Collection] .[A] ..[C] ...[D] ....Cube .[B] ..[C] ...[D] ....Cube(x)")
check("every row's id is distinct, for the Outliner's ForEach", Set(twoRows.map(\.id)).count == twoRows.count,
      "\(twoRows.map(\.id))")
check("B ▸ C's exclusion greys B ▸ C ▸ D and its Cube, and A's branch stays", twoRows.filter(\.excluded).count == 3
      && !twoTree.isExcluded(twoTree.entry(at: [10, 12, 13])!) && twoTree.isExcluded(twoTree.entry(at: [11, 12, 13])!))
let bc = twoTree.entry(at: [11, 12])!
let bcExclude = CollectionsBpy.set(.exclude, of: bc, in: twoTree, on: true)
check("B ▸ C's checkbox names its own instance: path [11, 12]",
      bcExclude.body.contains("set_exclude(12, False, path=[11, 12])"), bcExclude.body)
equal("and logs B ▸ C's layer collection", bcExclude.call,
      "bpy.context.view_layer.layer_collection.children[\"B\"].children[\"C\"].exclude = False")
check("the arrow is the collection's own, the same for both instances: no path",
      CollectionsBpy.set(.selectable, of: bc, in: twoTree, on: false).body.contains("set_selectable(12, False)"))
check("a tap on B ▸ C makes that instance active", CollectionsBpy.setActive(bc, in: twoTree).body
      .contains("set_active(12, path=[11, 12])"))
check("Relations ▸ Collection lists D once", twoTree.collections(holding: "Cube").map(\.name) == ["D"])
check("Move to Collection's menu lists C once under A", twoTree.children(of: 10).map(\.name) == ["C"]
      && twoTree.children(of: 12).map(\.name) == ["D"])
equal("New Collection inside C counts C's one child", twoTree.newName(inside: 12), "C 2")
check("folding A folds A alone", describe(twoScene.outlinerTree(collapsed: [twoTree.entry(at: [10])!.id]))
      == "[Scene Collection] .[A] .[B] ..[C] ...[D] ....Cube(x)")
// The control: the same record with its paths left out, as the uid alone
// had it — B ▸ C's children are then found under A ▸ C's path.
let noPaths = twoRecord.split(separator: "|").map { chunk in
    chunk.split(separator: ";").filter { !$0.hasPrefix("path=") }.joined(separator: ";")
}.joined(separator: "|")
let lost = BKScene()
lost.objects = [object("Cube")]
lost.collections = CollectionTree(record: noPaths)
check("control: without the paths the tree is not Blender's", describe(lost.outlinerTree()) != describe(twoRows),
      describe(lost.outlinerTree()))

equal("Rename logs the collection by the name it had", CollectionsBpy.rename(12, from: "C", to: "Wheels").call,
      "bpy.data.collections[\"C\"].name = \"Wheels\"")

// --------------------------------------------------------------------------
print("\nLocal View's commands and framing")

let wrapped = LocalViewBpy.scoped("x = 1\nprint(\"a\\\\b\")\n")
check("a 3D View command in Local View runs inside _blenderkit_localview.run, in the interpreter's globals",
      wrapped.hasPrefix("import _blenderkit_localview as _bk_lv\n_bk_lv.run(") && wrapped.hasSuffix(", globals())"))
let quoted = String(wrapped.dropFirst("import _blenderkit_localview as _bk_lv\n_bk_lv.run(".count).dropLast(", globals())".count))
check("the source it runs is the command's, character for character",
      (try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))) == "x = 1\nprint(\"a\\\\b\")\n", quoted)

// BKE_object_minmax: an object with no box adds its location ± its scale.
func shown(_ name: String, kind: String, at p: SIMD3<Double>, scale: Double = 1) -> BKObject {
    let matrix: [Double] = [scale, 0, 0, p.x, 0, scale, 0, p.y, 0, 0, scale, p.z, 0, 0, 0, 1]
    let positions: [Float] = [0, 0, 0]
    let normals: [Float] = [0, 0, 1]
    let tris: [UInt32] = []
    return matrix.withUnsafeBufferPointer { m in
        positions.withUnsafeBufferPointer { q in
            normals.withUnsafeBufferPointer { n in
                tris.withUnsafeBufferPointer { t in
                    SceneMirror.object(named: name, kind: kind, matrix: m, positions: q, normals: n,
                                       triangles: t, colour: nil, previous: nil)!.object
                }
            }
        }
    }
}
let empty = shown("Empty", kind: "EMPTY", at: SIMD3(1, 2, 3))
let lamp = shown("Light", kind: "LIGHT", at: SIMD3(4, 0, 0))
for obj in [empty, lamp] {
    let box = LocalViewFraming.box(of: obj)
    check("\(obj.blenderType) alone: its location ± its scale", box.lo == obj.modelMatrix.columns.3.xyz - 1
          && box.hi == obj.modelMatrix.columns.3.xyz + 1, "\(box)")
    let framed = LocalViewFraming.frame(lo: box.lo, hi: box.hi, fovY: fovY, aspect: aspect, clipStart: 0.05)
    check("framed 3.2081 away, as Blender's borrowed view framed an empty and a point light",
          framed.map { abs($0.distance - 3.2081) < 0.001 } ?? false, "\(framed?.distance ?? -1)")
    // The control: the world bounds, which are the location alone for it.
    let b = obj.worldBounds
    let old = LocalViewFraming.frame(lo: b.min, hi: b.max, fovY: fovY, aspect: aspect, clipStart: 0.05)
    check("control: its world bounds frame it 0.075 m away, the near limit",
          old.map { abs($0.distance - 0.075) < 1e-4 } ?? false, "\(old?.distance ?? -1)")
}
let big = shown("Big", kind: "EMPTY", at: .zero, scale: 2)
check("the empty's scale counts (and its display size, 1 here)",
      LocalViewFraming.box(of: big).hi == SIMD3(repeating: 2), "\(LocalViewFraming.box(of: big))")
let turned = BKObject(name: "Turned", kind: .cube)
turned.setMirroredTransform(simd_float4x4(simd_quatf(angle: .pi / 4, axis: SIMD3(0, 0, 1))))
let tb = LocalViewFraming.box(of: turned)
let spanX: Float = tb.hi.x - tb.lo.x
let spanY: Float = tb.hi.y - tb.lo.y
let diagonal: Float = 2 * Float(2).squareRoot()
check("a mesh adds its box's min and max corners through its matrix, only those two (Blender's rule)",
      abs(spanX) < 1e-4 && abs(spanY - diagonal) < 1e-4, "\(tb)")
let worldSpan: Float = turned.worldBounds.max.x - turned.worldBounds.min.x
check("control: its world bounds are wider than those two corners", worldSpan > 2.8, "\(worldSpan)")

// --------------------------------------------------------------------------
print("\na constrained drag holds everything else")

final class DeviceRecorder: BpyRuntime {
    let isReal = true
    let usesRealBlender = true
    let lastSyncDuration: TimeInterval = 0
    var sources: [String] = []
    func introspect(_ path: String) -> [(name: String, callable: Bool)]? { nil }
    var versionBanner: String { "recording" }
    func evaluate(_ source: String, scene: BKScene) -> [BpyLine] {
        sources.append(source)
        // What Blender prints for a frame that ran (`previewConstrainedDrag`).
        return source.contains("drag_frame(") ? [BpyLine(.output, "ok")] : []
    }
}
let recorder = DeviceRecorder()
let holdSession = BpySession(runtime: recorder)
let holdScene = BKScene(startupFile: false)
holdSession.bind(scene: holdScene, undo: UndoStack())
let holdBridge = BpyBridge(session: holdSession, scene: holdScene, undo: UndoStack())
check("no hold before a drag", !holdBridge.constrainedDragOpen && holdSession.gestureHold == nil)
check("a constrained drag begins, and holds", holdBridge.beginConstrainedDrag() && holdBridge.constrainedDragOpen
      && holdSession.gestureHold == BpySession.constrainedDragOpenMessage
      && recorder.sources.last?.contains("drag_begin()") == true)
var sentBefore = recorder.sources.count
let tab = holdBridge.run(Bpy.toggleEditMode, undo: "Edit Mode")
check("a command mid-drag is refused, in words, and reaches nothing", !tab.succeeded
      && tab.error == BpySession.constrainedDragOpenMessage && recorder.sources.count == sentBefore, "\(tab)")
holdSession.performUndo()
holdSession.performRedo()
check("Undo and Redo mid-drag reach nothing, and say why", recorder.sources.count == sentBefore
      && holdSession.console.last?.text == BpySession.constrainedDragOpenMessage)
check("a frame still runs", holdBridge.previewConstrainedDrag("pass") && recorder.sources.count == sentBefore + 1)
holdBridge.endConstrainedDrag()
check("the end lets go, after Blender's channels are put back", !holdBridge.constrainedDragOpen
      && holdSession.gestureHold == nil && recorder.sources.last?.contains("drag_end()") == true)
sentBefore = recorder.sources.count
let after = holdBridge.run("bpy.ops.transform.translate(value=(0, 0, 1))", undo: "Move")
check("and the commit runs", after.succeeded && recorder.sources.count > sentBefore)
_ = holdBridge.beginConstrainedDrag()
sentBefore = recorder.sources.count
check("a drag begun over one whose end never came ends it first",
      holdBridge.beginConstrainedDrag() && recorder.sources.dropFirst(sentBefore).first?.contains("drag_end()") == true
      && holdBridge.constrainedDragOpen)
holdBridge.endConstrainedDrag()

// A Transform field's edit of a constrained object, through the type the
// fields run (`TransformFieldDrag`): Blender previews it and the hold lasts
// until the commit, which then writes once.
let constrained = BKObject(name: "Cube", kind: .cube)
constrained.channels = TransformChannels(location: .zero, eulerXYZ: .zero, scale: SIMD3(repeating: 1))
constrained.constraints = stack.filter { $0.kind == "COPY_LOCATION" }
holdScene.objects = [constrained]
let field = TransformFieldDrag()
sentBefore = recorder.sources.count
field.change(.location, axis: 2, to: 1, of: constrained, in: holdScene, bridge: holdBridge)
check("a field of a constrained object: Blender previews it, and the session is held",
      field.constrainedPreview && holdBridge.constrainedDragOpen
      && recorder.sources.dropFirst(sentBefore).contains { $0.contains("drag_frame(") && $0.contains("location") })
field.commit(.location, bridge: holdBridge)
check("its commit ends the preview and the hold, then writes once",
      !holdBridge.constrainedDragOpen && field.edit == nil
      && recorder.sources.dropFirst(sentBefore).contains { $0.contains("drag_end()") }
      && recorder.sources.dropFirst(sentBefore).filter { $0.contains(".location") && !$0.contains("drag_frame(") }.count == 1,
      recorder.sources.dropFirst(sentBefore).map { String($0.prefix(60)) }.joined(separator: " / "))
let plain = BKObject(name: "Plain", kind: .cube)
plain.channels = TransformChannels(location: .zero, eulerXYZ: .zero, scale: SIMD3(repeating: 1))
holdScene.objects = [plain]
field.change(.location, axis: 0, to: 2, of: plain, in: holdScene, bridge: holdBridge)
check("control: one with no constraint previews alone, holding nothing",
      !field.constrainedPreview && !holdBridge.constrainedDragOpen)
field.commit(.location, bridge: holdBridge)

// In Local View the bridge runs the 3D View's commands inside the scope.
holdScene.localView = LocalViewState(objects: ["Plain"])
sentBefore = recorder.sources.count
_ = holdBridge.run(Bpy.deleteSelected, undo: "Delete")
check("in Local View a command goes through _blenderkit_localview.run",
      recorder.sources.dropFirst(sentBefore).first?.contains("_bk_lv.run(") == true)
holdScene.localView = nil
sentBefore = recorder.sources.count
_ = holdBridge.run(Bpy.deleteSelected, undo: "Delete")
check("control: outside it the command goes as it always did",
      recorder.sources.dropFirst(sentBefore).first.map { !$0.contains("_bk_lv") } ?? false)

// --------------------------------------------------------------------------
print("\nthe Object menu's rows")

func line(_ op: LastOperator) -> String { op.python.split(separator: "\n").last.map(String.init) ?? "" }
equal("X Global", line(.mirror(axis: 0, local: false)),
      "bpy.ops.transform.mirror(orient_type='GLOBAL', constraint_axis=(True, False, False))")
equal("Z Local", line(.mirror(axis: 2, local: true)),
      "bpy.ops.transform.mirror(orient_type='LOCAL', constraint_axis=(False, False, True))")
var adjusted = LastOperator.mirror(axis: 0, local: false)
adjusted["constraint_axis.y"] = 1
adjusted["orient_type"] = 1
equal("the panel's Y toggle and Local compose into the one tuple", line(adjusted),
      "bpy.ops.transform.mirror(orient_type='LOCAL', constraint_axis=(True, True, False))")
check("Mirror's panel is Orientation and Constraint Axis X, Y, Z",
      LastOperator.mirror(axis: 0, local: false).parameters.map(\.label) == ["Orientation", "X", "Y", "Z"])
check("control: a vector of numbers still composes as numbers",
      line(.randomizeTransform()).contains("loc=(0, 0, 0)") && line(.randomizeTransform()).contains("scale=(1, 1, 1)"))
equal("Randomize Transform's call, in its panel's order", line(.randomizeTransform()),
      "bpy.ops.object.randomize_transform(random_seed=0, use_delta=False, use_loc=True, loc=(0, 0, 0), use_rot=True, rot=(0, 0, 0), use_scale=True, scale_even=False, scale=(1, 1, 1))")
equal("Align Objects, no axis on", line(.alignObjects()),
      "bpy.ops.object.align(bb_quality=True, align_mode='OPT_2', relative_to='OPT_4', align_axis=set())")
var alignX = LastOperator.alignObjects()
alignX["align_axis.X"] = 1
check("with X on", line(alignX).hasSuffix("align_axis={'X'})"), line(alignX))
equal("Link Object Data", line(.makeLinksData("OBDATA")), "bpy.ops.object.make_links_data(type='OBDATA')")
equal("Copy Modifiers", line(.makeLinksData("MODIFIERS")), "bpy.ops.object.make_links_data(type='MODIFIERS')")
equal("Make Single User ▸ Object & Data", line(.makeSingleUser(.objectData)),
      "bpy.ops.object.make_single_user(type='SELECTED_OBJECTS', object=True, obdata=True, material=False, animation=False, obdata_animation=False)")
equal("Copy Modifiers to Selected Objects", line(.copyModifiersToSelected()),
      "bpy.ops.object.modifiers_copy_to_selected()")
check("every row's title is its operator's name, which is also its step",
      [LastOperator.mirror(axis: 0, local: false).name, LastOperator.makeLinksData("OBDATA").name,
       LastOperator.makeSingleUser(.object).name, LastOperator.copyModifiersToSelected().name,
       LastOperator.randomizeTransform().name, LastOperator.alignObjects().name]
        == ["Mirror", "Link/Transfer Data", "Make Single User", "Copy Modifiers to Selected Objects",
            "Randomize Transform", "Align Objects"])
check("each is undone through Blender's undo, as the other Object rows are",
      [LastOperator.mirror(axis: 0, local: false), .makeLinksData("OBDATA"), .makeSingleUser(.object),
       .copyModifiersToSelected(), .randomizeTransform(), .alignObjects()]
        .allSatisfy { $0.restoration == .throughBlenderUndo })
check("Make Single User's lead refuses an empty selection only for Selected Objects",
      LastOperator.makeSingleUser(.object).executedPython.contains("if 'SELECTED_OBJECTS' == 'SELECTED_OBJECTS'"))
equal("Link/Transfer Data lists Blender's eleven types", "\(LastOperator.makeLinksTypes.count)", "11")
equal("Mirror's rows", LastOperator.mirrorRows.map(\.label).joined(separator: ","),
      "X Global,Y Global,Z Global,X Local,Y Local,Z Local")

let addInLocal = LastOperator.addingIntoLocalView(.add(.cube, at: .zero))
check("an add made in Local View is followed by include_active, as Blender's Add joins the view",
      addInLocal.python.hasSuffix("_blenderkit_localview.include_active()"), addInLocal.python)
check("control: a mesh operator is left alone",
      !LastOperator.addingIntoLocalView(.mesh(.bevel)).python.contains("include_active"))

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
