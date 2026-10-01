import Foundation
import simd

/// What the mirror does with the objects one pass pushed.
///
/// The `bk_sync_*` entry points only copy buffers out of Python; the decisions
/// live here so the host suites run the code the device runs. Twice a defect
/// sat in the entry points where no test could reach it: the merge dropped the
/// modifier stack of every object already on screen, and the evaluated mesh was
/// run through the Swift stack a second time. Both were measured on device and
/// neither was visible to a check that stopped at `Modifier.stack(from:)`.
public enum SceneMirror {

    /// The object one `sync_push` describes, and whether its geometry came
    /// back exactly as `previous` — the object of that name on screen when the
    /// pass began — already has it. Nil for a triangle naming a vertex that
    /// is not there.
    ///
    /// `kind` is the type, then flags: `|hidden` for an object the viewport
    /// does not draw, `|layerhidden` and `|disabled` for the two reasons the
    /// Outliner shows (Blender's `hide_get()` and `hide_viewport`), `|norender`
    /// for the Outliner's camera column, `|bounds=N` for a mesh sent as its
    /// bounding box, `|boundbox` for Display As Bounds. Read as flags rather than as a suffix, so one flag cannot
    /// hide another. The mesh is installed with `setEvaluatedMesh`: it is
    /// Blender's evaluated mesh, and the Swift stack never runs over it.
    public static func object(named name: String, kind: String,
                              matrix: UnsafeBufferPointer<Double>,
                              positions: UnsafeBufferPointer<Float>,
                              normals: UnsafeBufferPointer<Float>,
                              triangles: UnsafeBufferPointer<UInt32>,
                              colour: SIMD4<Float>?,
                              previous: BKObject?) -> (object: BKObject, unchanged: Bool)? {
        guard matrix.count == 16, normals.count == positions.count,
              positions.count % 3 == 0, triangles.count % 3 == 0
        else { return nil }
        // Blender's own primitive kind is not available here, so the object
        // records what it was told; the renderer only needs the geometry.
        let obj = BKObject(name: name, kind: PrimitiveKind(rawValue: kind) ?? .cube)
        let flags = kind.components(separatedBy: "|")
        obj.blenderType = flags[0]
        obj.visible = !flags.contains("hidden")
        obj.hiddenInViewLayer = flags.contains("layerhidden")
        obj.disabledInViewports = flags.contains("disabled")
        obj.hideRender = flags.contains("norender")
        obj.displaysBounds = flags.contains("boundbox")
        obj.undrawnVertexCount = undrawnVertexCount(flags)
        obj.symmetry = symmetry(flags)

        var unchanged = false
        if let old = previous, old.isMirrored,
           old.evaluatedBase.matches(positions: positions, normals: normals, triangles: triangles) {
            // The same geometry as last time. Reusing it skips the edge
            // hashing and, in the merge, the GPU upload.
            obj.setEvaluatedMesh(old.evaluatedBase)
            unchanged = true
        } else {
            let count = positions.count / 3
            // Match Blender's 32-bit triangle indices without truncation.
            guard count <= Int(UInt32.max) else { return nil }
            var vertices: [MeshVertex] = []
            vertices.reserveCapacity(count)
            for v in 0..<count {
                let i = v * 3
                vertices.append(MeshVertex(SIMD3(positions[i], positions[i + 1], positions[i + 2]),
                                           SIMD3(normals[i], normals[i + 1], normals[i + 2])))
            }
            for t in triangles where Int(t) >= count { return nil }
            obj.setEvaluatedMesh(MeshData(vertices: vertices, indices: Array(triangles)))
        }

        // Blender's matrix_world is row-major; simd_float4x4 takes columns.
        var m = simd_float4x4()
        for c in 0..<4 {
            m[c] = SIMD4(Float(matrix[c]), Float(matrix[4 + c]),
                         Float(matrix[8 + c]), Float(matrix[12 + c]))
        }
        obj.setMirroredTransform(m)
        if let colour { obj.color = colour }
        return (obj, unchanged)
    }

    /// The `|mirror=xyzt` flag: the mesh's symmetry as Blender holds it
    /// (`_blenderkit_sync._symmetry`). No flag is no axis — a mesh with all
    /// four off, or an object that is not a mesh.
    public static func symmetry(_ flags: [String]) -> MeshSymmetry {
        for flag in flags where flag.hasPrefix("mirror=") {
            return MeshSymmetry(flag: String(flag.dropFirst("mirror=".count)))
        }
        return MeshSymmetry()
    }

    /// The `|bounds=N` flag: the mirror sent the object's bounding box because
    /// its N vertices are past the viewport's limit.
    public static func undrawnVertexCount(_ flags: [String]) -> Int? {
        for flag in flags where flag.hasPrefix("bounds=") {
            return Int(flag.dropFirst("bounds=".count))
        }
        return nil
    }

    /// A pushed edge list, checked: two indices per edge, each naming one of
    /// the object's vertices. Nil for anything else — an index past the end
    /// would be read by the GPU as whatever memory follows the buffer.
    public static func edges(_ values: UnsafeBufferPointer<UInt32>, vertexCount: Int) -> [UInt32]? {
        guard values.count % 2 == 0 else { return nil }
        for v in values where Int(v) >= vertexCount { return nil }
        return Array(values)
    }

    /// What `sync_local` does with an object's own channels: during a pass,
    /// they go on the object the pass just pushed; outside one — a frame
    /// change, from `_blenderkit_anim.push_frame` — on the object of that
    /// name on screen. 1 when carried, 0 when a frame change names an object
    /// the screen does not hold, -1 for anything else.
    ///
    /// The 0 is `AnimationMirror.applyFrame`'s rule for a matrix, which skips
    /// a name it does not know. Returning -1 there, as `bk_sync_local` first did, became
    /// a ValueError in Python, raised out of `push_frame` before `anim_frame`
    /// was sent: measured in desktop Blender 5.2.1 with a stub that raised as
    /// the device did, a keyed object not yet mirrored made `frame_set(10)`
    /// raise and no frame reached the timeline, not even the other keyed
    /// cube's — which stops playback a frame behind Blender. A pass that did
    /// not push the name is still -1: there it is a mirroring bug.
    ///
    /// Channels that are not finite are carried as unknown (nil), so the
    /// Apply menu offers every row rather than grey one out: Blender holds a
    /// NaN location or rotation when a script sets one (measured in 5.2.1),
    /// and that is no reason to refuse the object.
    ///
    /// Outside a pass the name is looked up through `index`, which the frame
    /// path shares (`frameIndex`): one dictionary per frame, as `applyFrame`
    /// builds, rather than a walk of the screen per moved object. That walk
    /// cost 10.3 ms a frame with 1,000 keyed objects and 88 ms with 3,000
    /// (round 2's review, swiftc -O on this Mac), the whole of a quarter of a
    /// 24 fps frame and twice a full one.
    @discardableResult
    public static func carryLocal(_ values: [Double], named name: String,
                                  pass: [BKObject]?, screen: [BKObject],
                                  index: ObjectNameIndex = ObjectNameIndex()) -> Int {
        guard values.count == 10 else { return -1 }
        let target: BKObject?
        if let pass {
            target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        } else {
            target = index.object(named: name, in: screen)
        }
        guard let target else { return pass == nil ? 0 : -1 }
        target.localTransform = LocalTransform(values)
        return 1
    }

    /// What `sync_channels` does with the channels the Transform fields show
    /// and write (`TransformChannels`): `carryLocal`'s rule — onto the object
    /// the pass pushed, or outside a pass onto the one on screen, 0 for a
    /// frame change naming an object the screen does not hold, -1 for anything
    /// else. Eleven numbers that do not describe channels (an unknown rotation
    /// mode) arrive as unknown, which the fields say rather than guess at.
    @discardableResult
    public static func carryChannels(_ values: [Double], named name: String,
                                     pass: [BKObject]?, screen: [BKObject],
                                     index: ObjectNameIndex = ObjectNameIndex()) -> Int {
        guard values.count == 11 else { return -1 }
        let target: BKObject?
        if let pass {
            target = pass.last?.name == name ? pass.last : pass.last { $0.name == name }
        } else {
            target = index.object(named: name, in: screen)
        }
        guard let target else { return pass == nil ? 0 : -1 }
        let channels = TransformChannels(values)
        // Every frame of playback sends these for each keyed object; a field
        // that reads them redraws only when they changed.
        if target.channels != channels { target.channels = channels }
        return 1
    }

    /// The name lookup one frame change shares: its `sync_local` calls, its
    /// `anim_mesh` calls and nothing else. Dropped when the frame's
    /// `anim_frame` arrives and when a mirroring pass begins or ends, so it
    /// never outlives the objects it was built from by more than one frame.
    nonisolated(unsafe) public static let frameIndex = ObjectNameIndex()

    /// Gives a pushed mesh with no faces Blender's edges. True when that
    /// changed the geometry, so the pass cannot treat the object as unchanged:
    /// its vertices can come back identical while its edges do not (an edge
    /// dissolved between two vertices that both stay).
    @discardableResult
    public static func installEdges(_ edges: [UInt32], on obj: BKObject) -> Bool {
        let mesh = obj.mesh
        guard mesh.indices.isEmpty, mesh.edges != edges else { return false }
        obj.setEvaluatedMesh(MeshData(vertices: mesh.vertices, wireEdges: edges))
        return true
    }

    /// Gives the mesh just pushed Blender's active UV map and its seams. True
    /// when that changed the mesh, so the pass cannot treat the object as
    /// unchanged; false when they are what it already had; nil for anything
    /// malformed.
    ///
    /// `triangleLoops` is the face corner (loop) behind each triangle corner,
    /// one per entry of the mesh's `indices`, and `loopUVs` a UV per loop — as
    /// Blender holds them, so no per-corner gather runs in Python; each
    /// corner's UV is picked out here. Empty loops mean no UV map. `seams` is
    /// the vertex pairs of the edges marked as seams.
    ///
    /// UVs change without the geometry changing — an unwrap moves no vertex —
    /// so the geometry's fast path cannot answer for them. What keeps it fast
    /// is that an unchanged map is compared straight from the buffers, with no
    /// allocation, and only a changed one is installed (which re-uploads that
    /// one object).
    @discardableResult
    public static func installUVs(mapName: String,
                                  triangleLoops: UnsafeBufferPointer<UInt32>,
                                  loopUVs: UnsafeBufferPointer<Float>,
                                  seams: UnsafeBufferPointer<UInt32>,
                                  on obj: BKObject) -> Bool? {
        let mesh = obj.mesh
        guard loopUVs.count % 2 == 0, seams.count % 2 == 0,
              triangleLoops.isEmpty || triangleLoops.count == mesh.indices.count
        else { return nil }
        let loopCount = loopUVs.count / 2
        for loop in triangleLoops where Int(loop) >= loopCount { return nil }
        for v in seams where Int(v) >= mesh.vertices.count { return nil }

        let name = triangleLoops.isEmpty ? "" : mapName
        if mesh.uvMapName == name, mesh.cornerLoops.elementsEqual(triangleLoops),
           mesh.seamEdges.elementsEqual(seams), mesh.cornerUVs.count == triangleLoops.count {
            var same = true
            for (corner, loop) in triangleLoops.enumerated() {
                let uv = mesh.cornerUVs[corner]
                if uv.x != loopUVs[2 * Int(loop)] || uv.y != loopUVs[2 * Int(loop) + 1] {
                    same = false
                    break
                }
            }
            if same { return false }
        }

        var updated = mesh
        updated.cornerLoops = Array(triangleLoops)
        updated.cornerUVs = triangleLoops.map { SIMD2(loopUVs[2 * Int($0)], loopUVs[2 * Int($0) + 1]) }
        updated.uvDiagonals = UVUnwrap.diagonals(cornerLoops: updated.cornerLoops)
        updated.uvMapName = name
        updated.seamEdges = Array(seams)
        obj.setEvaluatedMesh(updated)
        return true
    }

    /// The map Blender's UV Editor draws when it is not the one the pushed
    /// mesh carries: the object's own mesh, before its modifiers, as a mesh of
    /// its own that only the UV Editor reads (`BKObject.uvLayout`). Nil for
    /// anything malformed.
    ///
    /// The pushed mesh is Blender's evaluated one, and its UVs are the ones
    /// the viewport textures it with. Blender's UV Editor draws the mesh's own
    /// map, and the modified one only in its opt-in Modified Edges overlay.
    /// Drawn from the evaluated mesh, a cube unwrapped to 24 corners showed 96
    /// through a level-1 Subdivision and 384 through level 2, and a Mirror
    /// with Mirror U added a flipped copy of every island (round 2's review,
    /// measured in 5.2.1).
    public static func uvLayout(mapName: String,
                                positions: UnsafeBufferPointer<Float>,
                                triangles: UnsafeBufferPointer<UInt32>,
                                triangleLoops: UnsafeBufferPointer<UInt32>,
                                loopUVs: UnsafeBufferPointer<Float>,
                                seams: UnsafeBufferPointer<UInt32>) -> MeshData? {
        guard positions.count % 3 == 0, triangles.count % 3 == 0 else { return nil }
        let count = positions.count / 3
        for t in triangles where Int(t) >= count { return nil }
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(count)
        for v in 0..<count {
            vertices.append(MeshVertex(SIMD3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]),
                                       SIMD3(0, 0, 1)))
        }
        let holder = BKObject(name: "", kind: .cube)
        holder.setEvaluatedMesh(MeshData(vertices: vertices, indices: Array(triangles)))
        guard installUVs(mapName: mapName, triangleLoops: triangleLoops, loopUVs: loopUVs,
                         seams: seams, on: holder) != nil
        else { return nil }
        return holder.mesh
    }

    /// The pass's stack, keeping the identity each modifier already had on
    /// screen. Every record parses to new `Modifier` values with new ids, so
    /// without this each mirroring pass replaced every row of the Modifiers
    /// panel with a new one — a drag on a row's number would lose its draft to
    /// any pass that ran under it.
    public static func keepingIdentity(_ fresh: [Modifier], from old: [Modifier]) -> [Modifier] {
        var byName: [String: Modifier] = [:]
        for m in old { byName[m.name] = m }
        return fresh.map { m in
            // The type as well as the kind: every type the panel has no
            // settings for is `.other`, and a Hook replaced by a Wireframe of
            // the same name is a different row.
            guard let before = byName[m.name], before.kind == m.kind,
                  before.blenderType == m.blenderType else { return m }
            var kept = m
            kept.id = before.id
            return kept
        }
    }

    /// Reconciles one pass against what is already on screen, instead of
    /// replacing it.
    ///
    /// The mirror carries what Blender owns: geometry, the world matrix, the
    /// selection, the object colour, render visibility and mesh symmetry.
    /// Everything else on a BKObject is the app's own — the material and
    /// shader graph the Shading tab edits, the painted texture, vertex colours
    /// and weights, keyframes. None of that has anywhere to live in bpy, so a
    /// wholesale swap threw it away: on device every mirror runs after every
    /// operation, which meant painting something and then moving anything
    /// silently reverted the paint. Each tab's work destroyed the others'.
    ///
    /// Matching on name is what Blender itself guarantees — object names are
    /// unique within a file — and it also keeps the object's identity, so the
    /// selection, the outliner's expansion and anything else holding an id
    /// survives a sync too.
    ///
    /// `unchanged` names the objects whose geometry came back exactly as it
    /// was; their meshes are not reinstalled, since installing one bumps its
    /// version and a new version is a GPU re-upload.
    public static func merge(_ pending: [BKObject], into scene: BKScene,
                             unchanged: Set<String>,
                             selection: Set<UUID>, active: UUID?) {
        var existing: [String: BKObject] = [:]
        for obj in scene.objects { existing[obj.name] = obj }

        var idRemap: [UUID: UUID] = [:]
        var merged: [BKObject] = []
        merged.reserveCapacity(pending.count)

        for fresh in pending {
            guard let old = existing[fresh.name] else {
                merged.append(fresh)
                continue
            }
            idRemap[fresh.id] = old.id

            // What Blender just told us, onto the object that was already there.
            old.blenderType = fresh.blenderType
            old.visible = fresh.visible
            old.hiddenInViewLayer = fresh.hiddenInViewLayer
            old.disabledInViewports = fresh.disabledInViewports
            old.hideRender = fresh.hideRender
            // Blender's, from the flags: the header's toggles write it there
            // and show it from here.
            old.symmetry = fresh.symmetry
            old.display = fresh.display
            // An object that is not drawn arrives without its geometry: the
            // sync sends it as its origin alone (`_push_placeholder`), and
            // that one vertex is not its mesh. Installed, it cost the app's
            // own per-vertex layers below, which bpy has no copy of and cannot
            // send back: a cube with 8 painted colours and 8 weights, a
            // `MESH|hidden|layerhidden` pass (what H sends) and the whole cube
            // again (Alt+H) came out with 0 and 0. So it keeps the mesh it
            // was last drawn with until a pass draws it again. That is what
            // Blender holds: a cube under a level-1 Subdivision evaluated to
            // 26 vertices before H, while hidden and after Alt+H (5.2.1,
            // measured), and the N panel's Dimensions are read from it.
            if fresh.visible {
                old.undrawnVertexCount = fresh.undrawnVertexCount
                if !unchanged.contains(fresh.name) {
                    old.setEvaluatedMesh(fresh.evaluatedBase)
                    old.editTopology = nil
                }
                // Sent every pass it differs from the drawn mesh's map, so an
                // object whose modifiers stopped changing it loses it here.
                old.uvLayout = fresh.uvLayout
            }
            // The stack travels on `fresh`, which this loop throws away for any
            // object already on screen — so for those the Modifiers panel never
            // saw a modifier added after they first appeared. It is set after
            // the mesh, and `rebuildMesh` leaves an evaluated mesh alone.
            old.modifiers = keepingIdentity(fresh.modifiers, from: old.modifiers)
            if let m = fresh.mirroredTransform, old.mirroredTransform != m {
                old.setMirroredTransform(m)
            }
            // Like the stack: it travels on `fresh`, so an object already on
            // screen kept the channels it first arrived with, and Apply's rows
            // answered for a transform the object no longer had.
            old.localTransform = fresh.localTransform
            // What the Transform fields show, which travels on `fresh` for the
            // same reason; set only when it changed, since the fields observe it.
            if old.channels != fresh.channels { old.channels = fresh.channels }
            old.color = fresh.color
            // Travels on `fresh` like the stack; an object kept from before
            // would otherwise keep the parent it first arrived with. Set only
            // when it changed: Properties ▸ Object ▸ Relations observes it.
            if old.parentName != fresh.parentName { old.parentName = fresh.parentName }
            old.dependencies = fresh.dependencies
            old.snapPoints = fresh.snapPoints
            old.displaysBounds = fresh.displaysBounds
            // A curve's or a lattice's points and settings travel on `fresh`
            // too (`carryPoints`); kept from before, Edit Mode would show
            // points Blender no longer has, and Done would leave them drawn.
            if old.controlCage != fresh.controlCage { old.controlCage = fresh.controlCage }
            if old.dataSettings != fresh.dataSettings { old.dataSettings = fresh.dataSettings }
            // A mesh's vertex groups and shape keys (`carryGroups`): kept from
            // before, the Data tab would go on listing a group a script
            // removed, and its buttons would name it.
            if old.meshGroups != fresh.meshGroups { old.meshGroups = fresh.meshGroups }

            // Per-vertex layers only survive a mesh whose vertex count still
            // matches; a script that subdivided the mesh invalidated them.
            let n = old.mesh.vertices.count
            if old.vertexColours.count != n { old.vertexColours = [] }
            if old.vertexWeights.count != n { old.vertexWeights = [] }

            merged.append(old)
        }

        scene.objects = merged
        scene.selection = Set(selection.map { idRemap[$0] ?? $0 })
        scene.activeID = active.map { idRemap[$0] ?? $0 }
    }
}

public extension BKScene {
    /// What Knife Project can cut the active object with, as its menu lists
    /// them: every other visible mesh, curve or text object the mirror holds.
    /// Curves and text cut as well as meshes do (measured in 5.2.1: a Bézier
    /// circle and the default text both cut a plane). A wire circle — the
    /// default Add ▸ Circle — is in this list only because the mirror carries
    /// objects with no faces; it used to drop them.
    var knifeProjectCutters: [BKObject] {
        objects.filter {
            $0.id != activeID && $0.visible && ["MESH", "CURVE", "FONT"].contains($0.blenderType)
        }
    }
}

/// Objects on screen by name, built once and asked many times.
///
/// Gives what `screen.first { $0.name == name }` gives — the first object of
/// that name — for the price of one dictionary per build. It rebuilds by
/// itself when the screen's count changes or a hit no longer carries the name
/// it was filed under (renamed since), and otherwise lives until
/// `invalidate()`; `SceneMirror.frameIndex` is invalidated once a frame.
public final class ObjectNameIndex {
    private var byName: [String: BKObject] = [:]
    private var builtCount = -1

    public init() {}

    public func invalidate() {
        byName.removeAll(keepingCapacity: true)
        builtCount = -1
    }

    public func object(named name: String, in screen: [BKObject]) -> BKObject? {
        if builtCount != screen.count { rebuild(screen) }
        guard let hit = byName[name] else { return nil }
        if hit.name == name { return hit }
        rebuild(screen)
        return byName[name]
    }

    private func rebuild(_ screen: [BKObject]) {
        byName.removeAll(keepingCapacity: true)
        for object in screen where byName[object.name] == nil {
            byName[object.name] = object
        }
        builtCount = screen.count
    }
}
