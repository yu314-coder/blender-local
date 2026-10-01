import Foundation

// What else moves when an object moves: its children, and every object whose
// constraints, modifiers or drivers read it.
//
// A drag needs both halves. Blender leaves every such object out of the snap
// targets — `trans_object_base_deps_flag_finish` (transform_convert_object.cc)
// tags each base the transform reaches through the depsgraph with
// BA_SNAP_FIX_DEPS_FIASCO, and `snap_object_is_snappable`
// (transform_snap_object.cc) turns those away — because snapping onto
// something the same move then carries along would commit a position that is
// not on it. And the preview has to carry children along, since the commit
// does: measured in 5.2.1, `translate(value=(1,0,0))` on a parent alone moved
// its unselected child from x = 3 to x = 4.
//
// The mirror carries, per object, what it depends on
// (`_blenderkit_sync._relations`, which reads the parent, constraint and
// modifier pointers, Geometry Nodes inputs and node trees, drivers and a
// collection instance). Its closure over a moved set was held against
// Blender's own depsgraph in scripts/run-tools-blender-check.sh: the objects
// `depsgraph_update_post` reports updated when one object moves.

public extension SceneMirror {
    /// The object's parent and what it depends on, onto the object the pass
    /// just pushed. False when the pass holds no object of that name.
    @discardableResult
    static func carryRelations(parent: String?, dependencies: [String], named name: String,
                               pass: [BKObject]) -> Bool {
        let target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        guard let target else { return false }
        target.parentName = parent.flatMap { $0.isEmpty ? nil : $0 }
        target.dependencies = Set(dependencies).subtracting([name])
        return true
    }

    /// A curve's control points, onto the object the pass just pushed: what
    /// `_blenderkit_sync._push_knots` sends for a curve with no surface.
    @discardableResult
    static func carryKnots(_ values: [Float], named name: String, pass: [BKObject]) -> Bool {
        guard values.count % 3 == 0 else { return false }
        let target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        guard let target else { return false }
        target.snapPoints = stride(from: 0, to: values.count, by: 3).map {
            SIMD3(values[$0], values[$0 + 1], values[$0 + 2])
        }
        return true
    }
}

public extension BKScene {
    /// `moving` and every object that moves with it: whatever depends,
    /// directly or through others, on an object in the set.
    func dependents(of moving: Set<UUID>) -> Set<UUID> {
        guard !moving.isEmpty else { return [] }
        var users: [String: [BKObject]] = [:]
        for object in objects {
            for name in object.dependencies { users[name, default: []].append(object) }
        }
        var reached = moving
        var queue = objects.filter { moving.contains($0.id) }
        while let next = queue.popLast() {
            for user in users[next.name] ?? [] where reached.insert(user.id).inserted {
                queue.append(user)
            }
        }
        return reached
    }

    /// Every ancestor, through `parent`, of an object in `ids`.
    func ancestors(of ids: Set<UUID>) -> Set<UUID> {
        let byName = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var found: Set<UUID> = []
        for object in objects where ids.contains(object.id) {
            var next = object.parentName.flatMap { byName[$0] }
            while let parent = next, found.insert(parent.id).inserted {
                next = parent.parentName.flatMap { byName[$0] }
            }
        }
        return found
    }

    /// Every object with an ancestor in `movers`, each with its parent,
    /// parents before their children — the order a carried move has to be
    /// worked out in. An object in `movers` is listed too when an ancestor
    /// of it is.
    func carried(by movers: Set<UUID>) -> [(object: BKObject, parent: BKObject)] {
        guard !movers.isEmpty else { return [] }
        let byName = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [(object: BKObject, parent: BKObject, depth: Int)] = []
        for object in objects {
            guard let parent = object.parentName.flatMap({ byName[$0] }) else { continue }
            var seen: Set<UUID> = [object.id]
            var depth = 0, reached = false
            var next: BKObject? = parent
            while let ancestor = next, seen.insert(ancestor.id).inserted {
                depth += 1
                reached = reached || movers.contains(ancestor.id)
                next = ancestor.parentName.flatMap { byName[$0] }
            }
            if reached { found.append((object, parent, depth)) }
        }
        return found.sorted { $0.depth < $1.depth }.map { ($0.object, $0.parent) }
    }

    /// What an object-mode move of the selection leaves out of its snap
    /// targets: what `set_trans_object_base_flags` and, with proportional
    /// editing, `count_proportional_objects` flush the deps flag from.
    ///
    /// Proportional editing flushes from every visible object that is not
    /// selected and not a parent of the selection — whether or not its
    /// falloff reaches it: they all go into the transform's data with a
    /// weight, zero or not. So with it on, only the selection's ancestors
    /// that nothing moving reaches stay in reach.
    func movedByObjectDrag(selection: Set<UUID>, proportional: Bool) -> Set<UUID> {
        var sources = selection
        if proportional {
            let parents = ancestors(of: selection)
            for object in objects where object.visible && !parents.contains(object.id) {
                sources.insert(object.id)
            }
        }
        return dependents(of: sources)
    }
}

// MARK: - The Outliner's tree

/// One row of the Outliner's object tree: the object, how deep it sits under
/// its parents, and whether anything sits under it.
public struct OutlinerRow: Equatable {
    public let object: BKObject
    public let depth: Int
    public let hasChildren: Bool

    public static func == (a: OutlinerRow, b: OutlinerRow) -> Bool {
        a.object === b.object && a.depth == b.depth && a.hasChildren == b.hasChildren
    }
}

public extension BKScene {
    /// The objects as Blender's View Layer Outliner lists them, with Object
    /// Children on (its default): each child under its parent, a level
    /// deeper, parents in the order the scene lists them and children in
    /// theirs. The parent is the mirror's (`_blenderkit_sync._relations`,
    /// read after every command), so a Parent or Clear Parent shows here as
    /// soon as Blender has done it.
    ///
    /// An object whose parent the mirror does not hold is a root; a cycle,
    /// which Blender refuses ("Loop in parents") but a mirror could still be
    /// handed, is broken where it closes rather than looping. With a search
    /// the matches are listed flat, each at the top level.
    func outlinerRows(matching search: String = "") -> [OutlinerRow] {
        guard search.isEmpty else {
            return objects.filter { $0.name.localizedCaseInsensitiveContains(search) }
                .map { OutlinerRow(object: $0, depth: 0, hasChildren: false) }
        }
        let byName = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [ObjectIdentifier: [BKObject]] = [:]
        var roots: [BKObject] = []
        for object in objects {
            if let name = object.parentName, let parent = byName[name], parent !== object {
                children[ObjectIdentifier(parent), default: []].append(object)
            } else {
                roots.append(object)
            }
        }
        var rows: [OutlinerRow] = []
        var placed: Set<ObjectIdentifier> = []
        func visit(_ object: BKObject, _ depth: Int) {
            guard placed.insert(ObjectIdentifier(object)).inserted else { return }
            // Only the children listed under it here: in a loop, the one that
            // closes it is already above.
            let under = (children[ObjectIdentifier(object)] ?? [])
                .filter { !placed.contains(ObjectIdentifier($0)) }
            rows.append(OutlinerRow(object: object, depth: depth, hasChildren: !under.isEmpty))
            for child in under { visit(child, depth + 1) }
        }
        for root in roots { visit(root, 0) }
        // Whatever a cycle kept from every root: listed at the top, so no
        // object Blender has goes missing from the Outliner.
        for object in objects where !placed.contains(ObjectIdentifier(object)) { visit(object, 0) }
        return rows
    }
}
