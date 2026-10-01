import Foundation
import simd

/// Object-mode operators from Blender's Object menu that need real mesh work.
///
/// Everything here changes geometry or transforms for real; menu entries with
/// no implementation behind them are drawn disabled in the UI rather than
/// calling into this file.
public extension BKScene {

    // MARK: Snap  (VIEW3D_MT_snap)

    /// One point onto the grid, as view3d_snap.cc rounds it:
    /// `gridf * floorf(0.5f + v / gridf)`, so halves go up. `rounded()` sends
    /// them away from zero, which put -0.5 on -1 where Blender puts it on 0.
    static func onGrid(_ p: SIMD3<Float>, _ step: Float) -> SIMD3<Float> {
        SIMD3((0.5 + p.x / step).rounded(.down) * step,
              (0.5 + p.y / step).rounded(.down) * step,
              (0.5 + p.z / step).rounded(.down) * step)
    }

    /// `bpy.ops.view3d.snap_selected_to_grid()`.
    func snapSelectionToGrid(increment: Float = 1) {
        for obj in objects where selection.contains(obj.id) {
            obj.location = Self.onGrid(obj.location, increment)
        }
    }

    /// `bpy.ops.view3d.snap_cursor_to_grid()`.
    func snapCursorToGrid(increment: Float = 1) {
        cursor = Self.onGrid(cursor, increment)
    }

    /// `bpy.ops.view3d.snap_selected_to_active()`: every selected object onto
    /// the active one's origin. False, as Blender cancels, with no active.
    @discardableResult
    func snapSelectionToActive() -> Bool {
        guard let target = active?.location else { return false }
        for obj in objects where selection.contains(obj.id) { obj.location = target }
        return true
    }

    /// `bpy.ops.view3d.snap_cursor_to_active()`.
    @discardableResult
    func snapCursorToActive() -> Bool {
        guard let target = active?.location else { return false }
        cursor = target
        return true
    }

    /// `bpy.ops.view3d.snap_selected_to_cursor()`.
    func snapSelectionToCursor(keepOffset: Bool) {
        let targets = objects.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        if keepOffset {
            // Blender moves the selection as a group, preserving relative
            // positions, by shifting its median onto the cursor.
            let median = targets.reduce(SIMD3<Float>.zero) { $0 + $1.location } / Float(targets.count)
            let delta = cursor - median
            targets.forEach { $0.location += delta }
        } else {
            targets.forEach { $0.location = cursor }
        }
    }

    /// `bpy.ops.view3d.snap_cursor_to_selected()`.
    func snapCursorToSelection() {
        let targets = objects.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        cursor = targets.reduce(SIMD3<Float>.zero) { $0 + $1.location } / Float(targets.count)
    }

    // MARK: Mirror  (VIEW3D_MT_mirror)

    /// `bpy.ops.transform.mirror(constraint_axis=…)` — Blender mirrors by
    /// negating scale on the axis, which is why a mirrored object shows a
    /// negative scale in the sidebar.
    func mirrorSelection(axis: Int) {
        for obj in objects where selection.contains(obj.id) {
            obj.scale[axis] *= -1
        }
    }

    // MARK: Shading  (object.shade_smooth / shade_flat)

    /// The simulator's `object.shade_smooth` / `shade_flat`
    /// (`bk_scene_object_shade`). Smooth shading averages normals across every
    /// face meeting at a vertex; flat gives each face its own. The primitives
    /// are built flat-shaded with duplicated corners, so smoothing welds them
    /// first. Returns how many objects it shaded.
    ///
    /// On the mesh the modifier stack runs over (`editCage`), installed once:
    /// this took `obj.mesh`, the stack's output, and `setMirroredMesh` ran the
    /// stack over it again — a cube under Mirror X went from 24 base / 48
    /// shown to 48 / 96 (round 3's review; tests/tools/main.swift).
    @discardableResult
    func setShading(smooth: Bool) -> Int {
        var shaded = 0
        for obj in objects where selection.contains(obj.id) {
            var mesh = obj.editCage
            ModifierStack.recomputeNormals(&mesh, welded: smooth)
            obj.installTransformed(mesh)
            shaded += 1
        }
        return shaded
    }

    // MARK: Join  (object.join)

    /// The simulator's `object.join` (`bk_scene_join_selected`): every
    /// selected mesh merged into the active object, each brought into the
    /// active object's local space first — which is what makes the result sit
    /// exactly where the originals were. Returns how many objects it merged.
    ///
    /// What is joined is each object's own mesh, not what its modifiers make
    /// of it, and the active object's stack then runs over the result once.
    /// Measured in desktop 5.2.1: a cube under Mirror (8 base, 16 shown)
    /// joined with one under Subdivision (8, 26) holds 16 vertices, keeps its
    /// Mirror and shows 32. This joined the stacks' outputs and ran the
    /// target's stack over that again (round 3's review).
    @discardableResult
    func joinSelection() -> Int {
        guard let target = active else { return 0 }
        let sources = objects.filter { selection.contains($0.id) && $0.id != target.id }
        guard !sources.isEmpty else { return 0 }

        let intoLocal = target.modelMatrix.inverse
        var mesh = target.editCage
        for source in sources {
            let toTarget = intoLocal * source.modelMatrix
            let base = UInt32(mesh.vertices.count)
            let own = source.editCage
            // 32-bit indices cap the result; stop rather than corrupt it.
            guard mesh.vertices.count + own.vertices.count <= Int(UInt32.max) else { break }
            for v in own.vertices {
                let p = (toTarget * SIMD4(v.position, 1)).xyz
                let n = normalize((toTarget * SIMD4(v.normal, 0)).xyz)
                mesh.vertices.append(MeshVertex(p, n, v.uv))
            }
            mesh.indices += own.indices.map { $0 + base }
        }
        var joined = MeshData(vertices: mesh.vertices, indices: mesh.indices)
        ModifierStack.recomputeNormals(&joined, welded: false)
        target.installTransformed(joined)
        for source in sources {
            objects.removeAll { $0.id == source.id }
            selection.remove(source.id)
        }
        selection = [target.id]
        activeID = target.id
        return sources.count
    }

    /// The simulator's UV projections (`bk_scene_uv_project`): `smart` and
    /// `unwrap`, `cube`, `cylinder`, `sphere`. Returns the UV count and the
    /// average stretch, or nil for a kind it does not model.
    ///
    /// Projected onto the object's own mesh (`editCage`) and installed once,
    /// as Blender's UV operators write `object.data`: this projected the
    /// stack's output and ran the stack over it again, a Mirror X cube going
    /// from 24 / 48 to 48 / 96 (round 3's review).
    func projectUVs(of target: BKObject, kind: String) -> (count: Int, stretch: Float)? {
        var mesh = target.editCage
        let uvs: [SIMD2<Float>]
        switch kind {
        case "smart", "unwrap": uvs = UVUnwrap.smartProject(mesh)
        case "cube":            uvs = UVUnwrap.cubeProject(mesh)
        case "cylinder":        uvs = UVUnwrap.cylinderProject(mesh)
        case "sphere":          uvs = UVUnwrap.sphereProject(mesh)
        default: return nil
        }
        mesh.applyUVs(uvs)
        target.installTransformed(mesh)
        return (uvs.count, UVUnwrap.averageStretch(mesh, uvs: uvs))
    }

    // MARK: Copy / Paste

    /// Blender's Copy Objects / Paste Objects, held in memory for the session.
    func copySelection() {
        clipboard = objects.filter { selection.contains($0.id) }.map { $0.snapshotState() }
    }

    @discardableResult
    func pasteClipboard() -> Int {
        guard !clipboard.isEmpty else { return 0 }
        var pasted: [UUID] = []
        for state in clipboard {
            let obj = BKObject(name: uniqueName(state.name),
                               kind: PrimitiveKind(rawValue: state.kind) ?? .cube,
                               location: SIMD3(state.location[0], state.location[1], state.location[2]),
                               rotation: SIMD3(state.rotation[0], state.rotation[1], state.rotation[2]),
                               scale: SIMD3(state.scale[0], state.scale[1], state.scale[2]))
            obj.modifiers = state.modifiers
            if state.color.count >= 4 {
                obj.color = SIMD4(state.color[0], state.color[1], state.color[2], state.color[3])
            }
            if let display = state.overlayDisplay {
                obj.install(display.withDataName(uniqueDataName(display.dataName,
                                                                type: display.blenderType)))
            }
            objects.append(obj)
            pasted.append(obj.id)
        }
        selection = Set(pasted)
        activeID = pasted.last
        return pasted.count
    }
}

public extension BKObject {
    /// The object's state, used by copy/paste and by the undo snapshot.
    func snapshotState() -> ObjectState {
        ObjectState(name: name,
                    kind: kind.rawValue,
                    location: [location.x, location.y, location.z],
                    rotation: [rotation.x, rotation.y, rotation.z],
                    scale: [scale.x, scale.y, scale.z],
                    color: [color.x, color.y, color.z, color.w],
                    visible: visible,
                    modifiers: modifiers)
            .carryingDisplay(of: self)
    }
}

// MARK: - The simulator's edit-mode operators

public extension BKScene {
    /// The simulator's `bpy.ops.mesh.*` operators, dispatched by name from
    /// `bk_scene_mesh_op`: 0 when done, a count where the operator has one,
    /// -1 outside Edit Mode, -2 for a name the stand-in does not model.
    func editMeshOperator(_ name: String, amount: Double) -> Int32 {
        guard mode == .edit, let obj = active else { return -1 }
        let scene = self
        let faces = scene.editSelection.faces
        // Blender's edit operators work on the edit mesh, which the modifier
        // stack runs over: the cage (`editCage`), installed back once. These
        // took `cage`, the stack's output, and `setMirroredMesh` ran the
        // stack over it again: measured with a cube under Mirror X, Smooth
        // Vertices went 24 / 48 to 48 / 96 and a Shade Smooth after it to
        // 96 / 192 (round 2's review).
        let cage = obj.editCage
        switch name {
        case "extrude":
            let (mesh, next) = MeshEditor.extrude(cage, faces: faces,
                                                  distance: Float(amount == 0 ? 0.4 : amount))
            obj.installTransformed(mesh)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: mesh)
        case "inset":
            let (mesh, next) = MeshEditor.inset(cage, faces: faces,
                                                thickness: Float(amount == 0 ? 0.3 : amount))
            obj.installTransformed(mesh)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: mesh)
        case "subdivide":
            let (mesh, next) = MeshEditor.subdivide(cage, faces: faces)
            obj.installTransformed(mesh)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: mesh)
        case "delete":
            obj.installTransformed(MeshEditor.deleteFaces(cage, faces: faces))
            scene.editSelection.clear()

        // The operators below back the shim's `bpy.ops.mesh.*` under Blender's own
        // names. They are the simulator's stand-in for Blender, not a second
        // implementation the interface talks to: the app only ever speaks bpy, and
        // on device these are replaced wholesale by the real module.
        case "extrude_individual":
            let (mesh, next) = MeshEditor.extrudeIndividual(cage, faces: faces,
                                                            distance: Float(amount == 0 ? 0.3 : amount))
            obj.installTransformed(mesh)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: mesh)
        case "poke":
            let (mesh, next) = MeshEditor.pokeFaces(cage, faces: faces)
            obj.installTransformed(mesh)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: mesh)
        case "flip_normals":
            obj.installTransformed(MeshEditor.flipNormals(cage, faces: faces))
        case "normals_make_consistent":
            var mesh = cage
            ModifierStack.recomputeNormals(&mesh, welded: true)
            obj.installTransformed(mesh)
        case "remove_doubles":
            let (mesh, merged) = MeshEditor.mergeByDistance(cage,
                                                            vertices: scene.editSelection.vertices,
                                                            threshold: Float(amount == 0 ? 0.0001 : amount))
            obj.installTransformed(mesh)
            scene.editSelection.clear()
            return Int32(merged)
        case "vertices_smooth":
            obj.installTransformed(MeshEditor.smoothVertices(cage,
                                                          vertices: scene.editSelection.vertices,
                                                          factor: Float(amount == 0 ? 0.5 : amount)))
        case "vertex_random":
            obj.installTransformed(MeshEditor.randomize(cage,
                                                     vertices: scene.editSelection.vertices,
                                                     amount: Float(amount == 0 ? 0.08 : amount)))
        // Zero means zero for these three, as it does in Blender: no default
        // stands in for it.
        case "shrink_fatten":
            obj.installTransformed(MeshEditor.shrinkFatten(cage,
                                                        vertices: scene.editSelection.vertices,
                                                        offset: Float(amount)))
        case "push_pull":
            obj.installTransformed(MeshEditor.pushPull(cage,
                                                    vertices: scene.editSelection.vertices,
                                                    distance: Float(amount)))
        case "tosphere":
            obj.installTransformed(MeshEditor.toSphere(cage,
                                                    vertices: scene.editSelection.vertices,
                                                    factor: Float(amount)))
        case "delete_verts":
            obj.installTransformed(MeshEditor.deleteVertices(cage,
                                                          vertices: scene.editSelection.vertices))
            scene.editSelection.clear()
        case "delete_edges":
            obj.installTransformed(MeshEditor.deleteEdges(cage, edges: scene.editSelection.edges))
            scene.editSelection.clear()
        case "select_random":
            let ratio = amount == 0 ? 0.5 : amount
            let count = cage.indices.count / 3
            let next = Set((0..<count).filter { _ in Double.random(in: 0...1) < ratio })
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: cage)
            return Int32(next.count)
        case "select_linked":
            let next = MeshEditor.selectLinked(cage, from: faces)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: cage)
            return Int32(next.count)
        case "select_more":
            let next = MeshEditor.growSelection(cage, faces: faces)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: cage)
            return Int32(next.count)
        case "select_less":
            let next = MeshEditor.shrinkSelection(cage, faces: faces)
            scene.editSelection.faces = next
            scene.editSelection.vertices = MeshEditor.vertices(of: next, in: cage)
            return Int32(next.count)
        case "shade_smooth", "shade_flat":
            var mesh = cage
            ModifierStack.recomputeNormals(&mesh, welded: name == "shade_smooth")
            obj.installTransformed(mesh)
        default:
            return -2
        }
        return 0
    }

    /// The simulator's `mesh.select_all`: every element of the cage, or none.
    /// Returns the faces selected.
    @discardableResult
    func selectAllEditElements(_ select: Bool) -> Int {
        guard let obj = active else { return 0 }
        var selection = EditSelection()
        // The cage's elements, which is what the edit selection numbers.
        let cage = obj.editCage
        if select {
            selection.vertices = Set(cage.vertices.indices)
            selection.faces = Set(0..<(cage.indices.count / 3))
            selection.edges = Set(0..<(cage.edges.count / 2))
        }
        editSelection = selection
        return selection.faces.count
    }
}
