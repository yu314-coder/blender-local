import Foundation
import simd

// Blender's collections, its Local View, and the commands the Outliner and
// Object ▸ Collection send (round 4, group 7).
//
// What these show is read back from Blender by the mirroring pass
// (`_blenderkit_collections.record`, `_blenderkit_sync._push_local_view`) and
// carried here whole (`SceneMirror.carryRecord`); nothing in the interface
// keeps a collection of its own. The Outliner used to draw one hard-coded row
// called "Collection" whatever the scene held (round 3's review, toolkit item
// 12), and Properties ▸ Object ▸ Relations a label saying the same.

/// The view layer's collection tree as Blender holds it.
public struct CollectionTree: Equatable, Sendable {

    /// One layer collection: the collection, and the view layer's own
    /// switches for it.
    public struct Entry: Equatable, Sendable, Identifiable {
        /// Blender's `session_uid`, which `object.move_to_collection` takes
        /// as `collection_uid`. Read fresh every pass.
        public let uid: Int
        /// "Scene Collection" for the scene's own (`BKE_collection_ui_name_get`).
        public let name: String
        public let depth: Int
        /// The uid of the collection it is inside; 0 for the scene's own.
        public let parent: Int
        /// The checkbox: Exclude from View Layer (`LayerCollection.exclude`).
        public let excluded: Bool
        /// The eye: the view layer's Hide in Viewport.
        public let hidden: Bool
        /// The arrow: not Disable Selection (`Collection.hide_select`).
        public let selectable: Bool
        /// The monitor: Disable in Viewports (`Collection.hide_viewport`).
        public let disabled: Bool
        /// The camera: not Disable in Renders.
        public let renders: Bool
        /// Blender's active collection, which new objects go into.
        public let active: Bool
        /// The objects directly in it, in the collection's order.
        public let objects: [String]
        /// Which instance of the collection this is: the uids from the Scene
        /// Collection's child down to it (empty for the Scene Collection).
        /// A collection linked into two parents has a layer collection under
        /// each, with one uid and its own Exclude, Hide in Viewport and
        /// active state; the uid alone made the Outliner list every
        /// instance's children under each and a toggle land on the first
        /// instance (round 4's review of group 7, measured).
        public internal(set) var path: [Int]

        /// The instance's key, unique in the tree: its path.
        public var id: String { path.isEmpty ? "scene" : path.map(String.init).joined(separator: "/") }
        public var isSceneCollection: Bool { depth == 0 }

        public init(uid: Int, name: String, depth: Int, parent: Int, excluded: Bool = false,
                    hidden: Bool = false, selectable: Bool = true, disabled: Bool = false,
                    renders: Bool = true, active: Bool = false, objects: [String] = [], path: [Int]? = nil) {
            self.uid = uid; self.name = name; self.depth = depth; self.parent = parent
            self.excluded = excluded; self.hidden = hidden; self.selectable = selectable
            self.disabled = disabled; self.renders = renders; self.active = active
            self.objects = objects
            // A path left out is worked out from the parents by the tree.
            self.path = path ?? (depth == 0 ? [] : [uid])
            pathGiven = path != nil || depth == 0
        }

        /// Whether the path was given, rather than stood in for until the
        /// tree works it out from the parents (every entry of a tree has one).
        var pathGiven: Bool
    }

    public let viewLayer: String
    /// Depth first in Blender's order, the scene's own collection first.
    public let entries: [Entry]

    public init(viewLayer: String, entries: [Entry]) {
        self.viewLayer = viewLayer
        // Entries made without a path (a tree where each collection has one
        // parent) get the chain of their parents' uids.
        var made = entries
        var pathOf: [Int: [Int]] = [:]
        for i in made.indices {
            if !made[i].pathGiven {
                let above = made[i].depth <= 1 ? [] : (pathOf[made[i].parent] ?? [made[i].parent])
                made[i].path = above + [made[i].uid]
                made[i].pathGiven = true
            }
            if pathOf[made[i].uid] == nil { pathOf[made[i].uid] = made[i].path }
        }
        self.entries = made
    }

    /// The record `_blenderkit_collections.record` writes. Nil for one that
    /// has no scene collection — a record the pass did not finish.
    public init?(record: String) {
        var layer = "ViewLayer"
        var found: [Entry] = []
        for chunk in record.split(separator: "|") {
            let f = Modifier.fields(chunk)
            switch f["kind"] {
            case "view_layer":
                layer = f["name"] ?? layer
            case "collection":
                guard let uid = f["uid"].flatMap({ Int($0) }), let name = f["name"],
                      let depth = f["depth"].flatMap({ Int($0) }) else { continue }
                func flag(_ key: String, _ fallback: Bool) -> Bool {
                    f[key].map { $0 == "1" } ?? fallback
                }
                // `path=1/2/3`; a record without one (an older stand-in) has
                // the tree work it out from the parents.
                let path = f["path"].map { $0.split(separator: "/").compactMap { Int($0) } }
                found.append(Entry(uid: uid, name: name, depth: depth,
                                   parent: f["parent"].flatMap { Int($0) } ?? 0,
                                   excluded: flag("exclude", false), hidden: flag("hide", false),
                                   selectable: flag("select", true), disabled: flag("disabled", false),
                                   renders: flag("render", true), active: flag("active", false),
                                   objects: Self.names(f["objects"] ?? ""),
                                   path: depth == 0 ? [] : path))
            default:
                continue
            }
        }
        guard found.first?.isSceneCollection == true else { return nil }
        self.init(viewLayer: layer, entries: found)
    }

    /// `A,B%2CC` — the names `_blenderkit_collections._names` joined, each
    /// with its own commas and percents escaped.
    static func names(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    public var sceneCollection: Entry? { entries.first }
    public var active: Entry? { entries.first { $0.active } }

    /// The first instance of the collection `uid`: its name, its own
    /// switches (Disable Selection, Disable in Renders) and its objects are
    /// the same in every instance.
    public func entry(_ uid: Int) -> Entry? { entries.first { $0.uid == uid } }

    /// The instance at `path` (`Entry.path`).
    public func entry(at path: [Int]) -> Entry? { entries.first { $0.path == path } }

    /// The child collections of the collection `uid` — `collection.children`,
    /// once each however many parents it has. What Move to Collection's menu
    /// and New Collection's name count.
    public func children(of uid: Int) -> [Entry] {
        var seen: Set<Int> = []
        return entries.filter { $0.parent == uid && !$0.isSceneCollection && seen.insert($0.uid).inserted }
    }

    /// The layer collections directly under the instance `entry`: what the
    /// Outliner lists under that row.
    public func children(of entry: Entry) -> [Entry] {
        entries.filter { !$0.isSceneCollection && $0.path.count == entry.path.count + 1
            && Array($0.path.dropLast()) == entry.path }
    }

    /// The collections `object` is directly in — `users_collection` within
    /// this view layer, each once — the scene's own last, as Blender lists it.
    public func collections(holding object: String) -> [Entry] {
        var seen: Set<Int> = []
        let found = entries.filter { $0.objects.contains(object) && seen.insert($0.uid).inserted }
        return found.filter { !$0.isSceneCollection } + found.filter(\.isSceneCollection)
    }

    /// Whether the instance `entry`, or one it is inside, is excluded:
    /// Blender greys the whole branch.
    public func isExcluded(_ entry: Entry) -> Bool {
        var path = entry.path
        while !path.isEmpty {
            if let e = self.entry(at: path), e.excluded { return true }
            path.removeLast()
        }
        return false
    }

    /// `isExcluded` for the first instance of `uid`.
    public func isExcluded(_ uid: Int) -> Bool {
        entry(uid).map(isExcluded) ?? false
    }

    /// `BKE_collection_new_name_get`: "Collection N" inside the scene's own
    /// collection, "<parent> N" inside another, N one more than it has
    /// children. What Blender's Move to New Collection proposes; Blender
    /// adds `.001` if the name is taken.
    public func newName(inside uid: Int) -> String {
        let count = children(of: uid).count + 1
        guard let parent = entry(uid), !parent.isSceneCollection else { return "Collection \(count)" }
        return "\(parent.name) \(count)"
    }
}

/// The borrowed 3D View's Local View, as the mirror read it.
public struct LocalViewState: Equatable, Sendable {
    public let objects: Set<String>
    public init(objects: Set<String>) { self.objects = objects }

    /// `active=1;objects=A,B` — nil for `active=0`, outside Local View.
    public static func parse(_ record: String) -> LocalViewState?? {
        let f = Modifier.fields(Substring(record))
        guard let active = f["active"] else { return .none }
        if active != "1" { return .some(nil) }
        return .some(LocalViewState(objects: Set(CollectionTree.names(f["objects"] ?? ""))))
    }
}

/// Blender's local-view framing (`view3d_localview_init` with Frame Selected):
/// the view keeps its rotation, turns about the middle of the objects' box,
/// and stands back far enough for the box's largest side, with Blender's 1.4
/// margin, to fit the shorter side of the view
/// (`ED_view3d_radius_to_dist` with its aspect; `VIEW3D_MARGIN`), never
/// nearer than 1.5 times the clip start (`ED_view3d_dist_soft_min_get`).
/// Measured in desktop 5.2.1 through the borrowed view: a 2 m cube, region
/// 1574 × 954, lens 50 → view distance 3.2081, which this gives for that
/// view's angle (2·atan(0.72)) and aspect.
public enum LocalViewFraming {
    /// Blender's `VIEW3D_MARGIN`.
    public static let margin: Float = 1.4

    /// The types `BKE_object_boundbox_get` gives a box, of those the mirror
    /// sends geometry for.
    static let boxedTypes: Set<String> = ["MESH", "CURVE", "SURFACE", "FONT", "META", "LATTICE"]

    /// The world-space box one object adds to what Local View frames:
    /// Blender's `BKE_object_minmax` (object.cc). An object with a box — a
    /// mesh, a curve, a lattice — adds its box's two corners, min and max,
    /// each through its matrix (only those two, as Blender does). One without
    /// — an empty, a light, a camera — adds its location ± its scale, an
    /// empty's times its display size. The app used the object's world bounds,
    /// which for those is the location alone: round 4's review of group 7
    /// measured Local View on an empty or a point light framing the camera
    /// 0.075 m from it (the near limit), where Blender's borrowed view framed
    /// each at 3.2081, as for a 2 m cube.
    public static func box(of object: BKObject) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let m = object.modelMatrix
        if boxedTypes.contains(object.blenderType), !object.mesh.vertices.isEmpty {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in object.mesh.vertices {
                lo = simd_min(lo, v.position); hi = simd_max(hi, v.position)
            }
            let a = (m * SIMD4(lo, 1)), b = (m * SIMD4(hi, 1))
            let p = SIMD3(a.x, a.y, a.z), q = SIMD3(b.x, b.y, b.z)
            return (simd_min(p, q), simd_max(p, q))
        }
        var size = object.shownChannels?.scale ?? object.scale
        if case .empty(let empty)? = object.display { size *= empty.size }
        let at = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return (simd_min(at + size, at - size), simd_max(at + size, at - size))
    }

    /// The box Local View frames for `objects`, as `view3d_localview_init`
    /// gathers it; nil for none.
    public static func box(of objects: [BKObject]) -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard !objects.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for object in objects {
            let b = box(of: object)
            lo = simd_min(lo, b.lo); hi = simd_max(hi, b.hi)
        }
        return (lo, hi)
    }

    /// `fovY` is the view's vertical angle; `aspect` its width over height.
    /// Nil for an empty box, where Blender leaves the distance alone.
    public static func frame(lo: SIMD3<Float>, hi: SIMD3<Float>, fovY: Float, aspect: Float,
                             clipStart: Float) -> (centre: SIMD3<Float>, distance: Float)? {
        guard lo.x <= hi.x, lo.y <= hi.y, lo.z <= hi.z else { return nil }
        let box = hi - lo
        let size = max(box.x, max(box.y, box.z))
        let radius = size / 2 * margin
        // The narrower of the two angles: the vertical one for a wide view,
        // the horizontal one (tan scaled by the aspect) for a tall one.
        let halfTan = aspect >= 1 ? tan(fovY / 2) : tan(fovY / 2) * aspect
        guard halfTan > 0 else { return nil }
        let distance = max(radius / halfTan, clipStart * 1.5)
        return ((lo + hi) / 2, distance)
    }
}

// MARK: - The commands

/// One control's change: the Python the Info log shows (`call`), what runs
/// (`body`: the app's guard and the call), and the undo step's name.
public struct BlenderCommand: Equatable, Sendable {
    public let call: String
    public let body: String
    public let undo: String?

    public init(call: String, body: String, undo: String?) {
        self.call = call; self.body = body; self.undo = undo
    }
}

/// The Outliner's collection controls and Object ▸ Collection.
public enum CollectionsBpy {
    static let module = "import _blenderkit_collections"

    private static func command(_ call: String, _ guarded: String, undo: String?) -> BlenderCommand {
        BlenderCommand(call: call, body: module + "\n" + guarded, undo: undo)
    }

    /// The Outliner's New Collection (`outliner.collection_new`'s name), inside `parent`.
    public static func new(inside parent: Int) -> BlenderCommand {
        command("bpy.ops.outliner.collection_new(nested=True)",
                "_blenderkit_collections.new(\(parent))", undo: "New Collection")
    }

    /// A double-click rename, as the Outliner's object rename is ("Rename").
    /// The Info log's line names the collection by the name it had: keyed by
    /// the new one, as it was, a copy of it raised KeyError (round 4's review).
    public static func rename(_ uid: Int, from current: String, to name: String) -> BlenderCommand {
        command("bpy.data.collections[\(Bpy.quote(current))].name = \(Bpy.quote(name))",
                "_blenderkit_collections.rename(\(uid), \(Bpy.quote(name)))", undo: "Rename")
    }

    /// The Outliner's Delete and Delete Hierarchy (`outliner.delete`,
    /// `outliner.collection_hierarchy_delete`).
    public static func delete(_ uid: Int, hierarchy: Bool) -> BlenderCommand {
        command(hierarchy ? "bpy.ops.outliner.collection_hierarchy_delete()" : "bpy.ops.outliner.delete()",
                "_blenderkit_collections.delete(\(uid), hierarchy=\(hierarchy ? "True" : "False"))",
                undo: hierarchy ? "Delete Hierarchy" : "Delete")
    }

    /// The restriction toggles, by the property each writes and its name.
    public enum Toggle: String, CaseIterable, Sendable {
        case exclude, hide, selectable, render

        /// The property's name, which is its tooltip's title and the step.
        public var label: String {
            switch self {
            case .exclude:    return "Exclude from View Layer"
            case .hide:       return "Hide in Viewport"
            case .selectable: return "Disable Selection"
            case .render:     return "Disable in Renders"
            }
        }

        var function: String {
            switch self {
            case .exclude: return "set_exclude"
            case .hide: return "set_hide"
            case .selectable: return "set_selectable"
            case .render: return "set_render"
            }
        }

        /// The RNA write Blender's own button makes, for the Info log:
        /// `on` is the toggle's state as the Outliner draws it (checked,
        /// eye open, arrow on, camera on).
        func call(_ entry: CollectionTree.Entry, in tree: CollectionTree, on: Bool) -> String {
            let coll = "bpy.data.collections[\(Bpy.quote(entry.name))]"
            let layer = CollectionsBpy.layerPath(entry, in: tree)
            switch self {
            case .exclude:    return "\(layer).exclude = \(on ? "False" : "True")"
            case .hide:       return "\(layer).hide_viewport = \(on ? "False" : "True")"
            case .selectable: return "\(coll).hide_select = \(on ? "False" : "True")"
            case .render:     return "\(coll).hide_render = \(on ? "False" : "True")"
            }
        }
    }

    /// `bpy.context.view_layer.layer_collection.children["A"].children["B"]`:
    /// the layer collection's path through its parents, as Blender's Python
    /// tooltip gives it.
    public static func layerPath(_ entry: CollectionTree.Entry, in tree: CollectionTree) -> String {
        // The instance's own chain: a collection in two parents has a layer
        // collection under each.
        let chain = entry.path.map { tree.entry($0)?.name ?? "" }
        return "bpy.context.view_layer.layer_collection"
            + chain.map { ".children[\(Bpy.quote($0))]" }.joined()
    }

    /// `, path=[1, 2]`: which instance a layer collection's switch is for.
    static func pathArgument(_ entry: CollectionTree.Entry) -> String {
        ", path=[" + entry.path.map(String.init).joined(separator: ", ") + "]"
    }

    /// One toggle set so the Outliner draws it `on`: the checkbox ticked
    /// (included), the eye open, the arrow on, the camera on.
    public static func set(_ toggle: Toggle, of entry: CollectionTree.Entry, in tree: CollectionTree,
                           on: Bool) -> BlenderCommand {
        // The Python function takes the property's own sense: exclude and
        // hide are True when off; selectable and render are True when on.
        let value: Bool
        switch toggle {
        case .exclude, .hide: value = !on
        case .selectable, .render: value = on
        }
        // Exclude and the eye are the instance's (the layer collection's);
        // the arrow and the camera the collection's own, shared by them all.
        let path = toggle == .exclude || toggle == .hide ? pathArgument(entry) : ""
        return command(toggle.call(entry, in: tree, on: on),
                       "_blenderkit_collections.\(toggle.function)(\(entry.uid), \(value ? "True" : "False")\(path))",
                       undo: toggle.label)
    }

    /// A tap on a collection row: Blender's active collection. No undo step,
    /// as a tap on an object row makes none.
    public static func setActive(_ entry: CollectionTree.Entry, in tree: CollectionTree) -> BlenderCommand {
        command("bpy.context.view_layer.active_layer_collection = " + layerPath(entry, in: tree),
                "_blenderkit_collections.set_active(\(entry.uid)\(pathArgument(entry)))", undo: nil)
    }

    /// Object ▸ Collection ▸ Move to Collection (M) and Link to Collection
    /// (Shift+M): into `uid`, or into a new collection inside it called
    /// `newCollection`. Their steps are the operators' names.
    public static func move(to uid: Int, link: Bool, newCollection: String? = nil) -> BlenderCommand {
        let op = link ? "link_to_collection" : "move_to_collection"
        var args = "collection_uid=\(uid)"
        var guarded = "_blenderkit_collections.move(\(uid), link=\(link ? "True" : "False")"
        if let newCollection {
            args += ", is_new=True, new_collection_name=\(Bpy.quote(newCollection))"
            guarded += ", new_collection=\(Bpy.quote(newCollection))"
        }
        return command("bpy.ops.object.\(op)(\(args))", guarded + ")",
                       undo: link ? "Link to Collection" : "Move to Collection")
    }
}

/// View ▸ Local View: Toggle Local View (numpad /) and Remove from Local View,
/// through the borrowed 3D View (`_blenderkit_localview`). Each is an undo
/// step of the operator's name, as Blender's history has it — which is also
/// what keeps an Undo of a later change from ending Local View.
public enum LocalViewBpy {
    public static let toggle = BlenderCommand(
        call: "bpy.ops.view3d.localview()",
        body: "import _blenderkit_localview\n_blenderkit_localview.toggle()",
        undo: "Local View")

    public static let removeFrom = BlenderCommand(
        call: "bpy.ops.view3d.localview_remove_from()",
        body: "import _blenderkit_localview\n_blenderkit_localview.remove_from()",
        undo: "Remove from Local View")

    /// A command of the 3D View's — a menu row, a key, the gizmo's commit,
    /// the redo panel's re-run — as `BpyBridge.execute` sends it while Blender
    /// is in Local View: run in the interpreter's own globals inside
    /// `_blenderkit_localview.scope`, which in Object Mode puts it under the
    /// borrowed view, as Blender's own 3D View runs it there. Every Object
    /// Mode command acts only on what Local View holds then — Select ▸ All
    /// and Invert used to be the only two that did (round 4's review of group
    /// 7: Select by Type, Random, Pattern, Grouped, Linked and Mirror selected
    /// objects not drawn, and Delete, the gizmo, Mirror, Randomize and Move to
    /// Collection acted on them).
    public static func scoped(_ source: String) -> String {
        "import _blenderkit_localview as _bk_lv\n_bk_lv.run(\(Bpy.quote(source)), globals())"
    }
}

public extension LastOperator {
    /// An add made while Blender is in Local View, followed by what Blender's
    /// Add does there from its 3D View: the new object joins Local View
    /// (`_blenderkit_localview.include_active`). Without it a cube added in
    /// Local View was not drawn — it is outside the view, as one a script
    /// adds is in Blender. Only adds (`removeCreated`); a duplicate keeps the
    /// original's bits by itself (measured in 5.2.1).
    static func addingIntoLocalView(_ op: LastOperator) -> LastOperator {
        guard op.restoration == .removeCreated else { return op }
        var made = op
        let include = "import _blenderkit_localview\n_blenderkit_localview.include_active()"
        made.followUp = [op.followUp, include].compactMap { $0 }.joined(separator: "\n")
        return made
    }
}

public extension BpyBridge {
    /// Runs one command: its body, logged as its call, its undo step named.
    @discardableResult
    func run(_ command: BlenderCommand) -> Outcome {
        run(command.call, undo: command.undo, executing: command.body)
    }
}

// MARK: - The Outliner's tree

/// One row of the Outliner's View Layer tree: a collection, or an object in
/// one, how deep it sits, and whether an excluded collection above it greys it.
public struct OutlinerTreeRow: Equatable, Identifiable {
    public enum Item: Equatable {
        case collection(CollectionTree.Entry)
        case object(BKObject)

        public static func == (a: Item, b: Item) -> Bool {
            switch (a, b) {
            case (.collection(let x), .collection(let y)): return x == y
            case (.object(let x), .object(let y)): return x === y
            default: return false
            }
        }
    }

    public let item: Item
    public let depth: Int
    /// The collection the row is in; a collection row's own uid. Zero when
    /// Blender sent no tree (the simulator's stand-in).
    public let collection: Int
    /// Inside a collection excluded from the view layer: Blender greys the
    /// whole branch and its objects are not in the view layer.
    public let excluded: Bool
    /// Whether anything is listed under it (the disclosure triangle).
    public let hasChildren: Bool

    /// The collection instance the row is under, or the row's own
    /// (`Entry.id`); "" without a tree from Blender.
    public internal(set) var collectionKey = ""

    /// Unique in the tree: a collection linked into two parents, and the
    /// objects in it, are listed once under each.
    public var id: String {
        switch item {
        case .collection(let e): return "c\(e.id)"
        case .object(let o): return "o\(collectionKey)-\(o.id.uuidString)"
        }
    }

    public var object: BKObject? {
        if case .object(let o) = item { return o }
        return nil
    }

    public var entry: CollectionTree.Entry? {
        if case .collection(let e) = item { return e }
        return nil
    }
}

public extension BKScene {
    /// The Outliner's View Layer tree, as Blender's Outliner lists it with
    /// its default filters: each collection, its child collections before
    /// its objects, and each object under every collection it is in — with
    /// Object Children on, a child under its parent when the parent is in the
    /// same collection. Folded collections (`collapsed`, by `Entry.id`: each
    /// instance of a collection in two parents folds by itself, as each is
    /// its own tree element in Blender's Outliner) list nothing under them.
    /// With a search the matching objects are listed flat, once each.
    /// Without a tree from Blender, the objects and their children as
    /// `outlinerRows` has them, outside any collection.
    func outlinerTree(matching search: String = "", collapsed: Set<String> = []) -> [OutlinerTreeRow] {
        guard search.isEmpty, let tree = collections, let root = tree.sceneCollection else {
            return outlinerRows(matching: search).map {
                OutlinerTreeRow(item: .object($0.object), depth: $0.depth, collection: 0,
                                excluded: false, hasChildren: $0.hasChildren)
            }
        }
        let byName = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [OutlinerTreeRow] = []
        func visit(_ entry: CollectionTree.Entry, excludedAbove: Bool) {
            let excluded = excludedAbove || entry.excluded
            let members = entry.objects.compactMap { byName[$0] }
            // This instance's own children: a collection linked into two
            // parents is listed under each, each with what is under it there.
            let children = tree.children(of: entry)
            rows.append(OutlinerTreeRow(item: .collection(entry), depth: entry.depth, collection: entry.uid,
                                        excluded: excluded,
                                        hasChildren: !members.isEmpty || !children.isEmpty,
                                        collectionKey: entry.id))
            guard !collapsed.contains(entry.id) else { return }
            for child in children { visit(child, excludedAbove: excluded) }
            // Object Children: a child under its parent when both are here.
            let here = Set(members.map(ObjectIdentifier.init))
            var under: [ObjectIdentifier: [BKObject]] = [:]
            var roots: [BKObject] = []
            for object in members {
                if let name = object.parentName, let parent = byName[name], parent !== object,
                   here.contains(ObjectIdentifier(parent)) {
                    under[ObjectIdentifier(parent), default: []].append(object)
                } else {
                    roots.append(object)
                }
            }
            var placed: Set<ObjectIdentifier> = []
            func place(_ object: BKObject, _ depth: Int) {
                guard placed.insert(ObjectIdentifier(object)).inserted else { return }
                let kids = (under[ObjectIdentifier(object)] ?? []).filter { !placed.contains(ObjectIdentifier($0)) }
                rows.append(OutlinerTreeRow(item: .object(object), depth: depth, collection: entry.uid,
                                            excluded: excluded, hasChildren: !kids.isEmpty,
                                            collectionKey: entry.id))
                for kid in kids { place(kid, depth + 1) }
            }
            for object in roots { place(object, entry.depth + 1) }
            // A parent loop Blender refuses but a mirror could be handed:
            // nothing in the collection goes unlisted.
            for object in members where !placed.contains(ObjectIdentifier(object)) {
                place(object, entry.depth + 1)
            }
        }
        visit(root, excludedAbove: false)
        return rows
    }
}
