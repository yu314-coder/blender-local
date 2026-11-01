import Foundation
import simd

/// The 3D cursor as Blender holds it, and the toolbar's Cursor tool settings
/// for the mode Blender is in: what `_blenderkit_cursor.record` hands over
/// every mirroring pass. The location is also in the tool report
/// (`BKScene.cursor`); the rotation and the settings are only here.
public struct CursorState: Equatable, Sendable {
    public var location: SIMD3<Float>
    /// `View3DCursor::rotation()`: the rotation as a unit quaternion, from
    /// whichever of its three forms the rotation mode keeps.
    public var rotation: simd_quatf
    /// `rotation_mode`: XYZ, … , QUATERNION or AXIS_ANGLE.
    public var rotationMode: String
    /// Surface Project (`use_depth`).
    public var surfaceProject: Bool
    public var orientation: CursorTool.Orientation

    public init(location: SIMD3<Float> = .zero, rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                rotationMode: String = "XYZ", surfaceProject: Bool = true,
                orientation: CursorTool.Orientation = .view) {
        self.location = location; self.rotation = rotation; self.rotationMode = rotationMode
        self.surfaceProject = surfaceProject; self.orientation = orientation
    }

    /// Whether the record carried the tool's settings: a pass that could not
    /// reach Blender's workspace (off the main thread) sends the cursor alone,
    /// and the settings shown stay what Blender last said.
    public var settingsKnown = true

    /// `loc=x,y,z;quat=w,x,y,z;mode=XYZ[;depth=1;orient=VIEW]`; nil for
    /// anything else, numbers that are not finite included.
    public init?(record: String) {
        var fields: [String: String] = [:]
        for part in record.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            fields[pair[0]] = pair[1]
        }
        func numbers(_ key: String, _ n: Int) -> [Float]? {
            guard let values = fields[key]?.split(separator: ",").compactMap({ Float($0) }),
                  values.count == n, values.allSatisfy(\.isFinite) else { return nil }
            return values
        }
        guard let loc = numbers("loc", 3), let q = numbers("quat", 4),
              let mode = fields["mode"], !mode.isEmpty else { return nil }
        let rotation = simd_quatf(ix: q[1], iy: q[2], iz: q[3], r: q[0])
        guard fields["depth"] != nil || fields["orient"] != nil else {
            self.init(location: SIMD3(loc[0], loc[1], loc[2]), rotation: rotation, rotationMode: mode)
            settingsKnown = false
            return
        }
        guard let depth = fields["depth"], depth == "0" || depth == "1",
              let orientation = fields["orient"].flatMap(CursorTool.Orientation.init(rawValue:))
        else { return nil }
        self.init(location: SIMD3(loc[0], loc[1], loc[2]), rotation: rotation,
                  rotationMode: mode, surfaceProject: depth == "1", orientation: orientation)
    }

    /// This record onto what the scene shows: the settings kept from `shown`
    /// when the record could not read them.
    public func merged(onto shown: CursorState) -> CursorState {
        guard !settingsKnown else { return self }
        var out = self
        out.surfaceProject = shown.surfaceProject
        out.orientation = shown.orientation
        out.settingsKnown = true
        return out
    }
}

/// The toolbar's Cursor: a tap places the 3D cursor where Blender's Cursor
/// tool would put it, a drag moves it as the tool's drag does.
///
/// Blender's click is `view3d.cursor3d`, which has an invoke and no exec: in
/// a Blender without a window it answers PASS_THROUGH and moves nothing
/// (round 3's review, under the borrowed 3D View). The app ports the invoke
/// (`_blenderkit_cursor.place`) and supplies the two things only a drawn 3D
/// View has, worked out on the mirror — Blender's evaluated meshes as the
/// 3D View draws them:
///
///   * Surface Project's depth: `ED_view3d_autodist` reads the depth buffer
///     at the pointer's pixel, and only where nothing is drawn there the
///     nearest depth within 2, then 4 pixels (`depthHit`);
///   * the Geometry orientation's face: `snap_object_project_view3d_ex` with
///     SCE_SNAP_TO_FACE on the final geometry — the nearest triangle, two
///     sided, its normal the triangle's in the object's space carried out by
///     the inverse transpose (`register_result_raycast`) — skipping objects
///     drawn as wire or bounds (`raycast_obj_fn`) (`surfaceHit`).
///
/// The drag is the tool's `transform.translate(cursor_transform=True)`, which
/// runs headless given its value (measured in desktop 5.2.1: the cursor at
/// (1, 2, 3) went to (2, 2, 3) with `value=(1, 0, 0)`, the cube left alone),
/// previewed and snapped here as a gizmo move is (`dragTarget`).
public enum CursorTool {

    /// `VIEW3D_OT_cursor3d`'s Orientation, by its RNA names.
    public enum Orientation: String, CaseIterable, Identifiable, Sendable {
        case none = "NONE", view = "VIEW", transform = "XFORM", geometry = "GEOM"
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .none:      return "None"
            case .view:      return "View"
            case .transform: return "Transform"
            case .geometry:  return "Geometry"
            }
        }
    }

    /// The tool's two settings, as the toolbar's Cursor draws them
    /// (`_defs_view3d_generic.cursor`: `use_depth` and `orientation`).
    public static let surfaceProjectLabel = "Surface Project"
    public static let orientationLabel = "Orientation"

    /// The view a tap is made in: the app's camera, in Blender's terms.
    public struct View: Equatable, Sendable {
        public var eye: SIMD3<Float>
        public var forward: SIMD3<Float>
        public var up: SIMD3<Float>
        public var orthographic: Bool
        /// The orbit pivot: Blender's view location (`-rv3d->ofs`).
        public var center: SIMD3<Float>
        /// One of the six numpad views (`RV3D_VIEW_IS_AXIS`).
        public var axisAligned: Bool

        public init(eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, orthographic: Bool,
                    center: SIMD3<Float>, axisAligned: Bool = false) {
            self.eye = eye; self.forward = forward; self.up = up; self.orthographic = orthographic
            self.center = center; self.axisAligned = axisAligned
        }
    }

    /// Where a ray meets a face, as Blender's snapping reports it.
    public struct Surface: Equatable, Sendable {
        public var location: SIMD3<Float>
        /// Unit length, world space: the triangle's normal in the object's
        /// space through the inverse transpose of its matrix — so a mirrored
        /// object's normal is not turned round as a world-space cross product
        /// would turn it.
        public var normal: SIMD3<Float>
        /// The object's world axes, scale included (`obmat[0..2]`), which the
        /// Geometry orientation rolls the cursor's X to.
        public var axes: simd_float3x3
        public var object: String
    }

    /// The objects whose surfaces Blender's ray meets: drawn, with triangles,
    /// not displayed as wire or bounds, not sent as their bounding box.
    static func surfaced(_ objects: [BKObject]) -> [BKObject] {
        objects.filter { o in
            o.visible && !o.displaysBounds && !o.displaysWire && o.undrawnVertexCount == nil
                && ["MESH", "CURVE", "SURFACE", "FONT", "META"].contains(o.blenderType)
                && !o.mesh.indices.isEmpty
        }
    }

    /// The pointer's line of sight through `pointer` (view points from the
    /// top left), from the near plane: `GeometrySnap.View.ray` worked in
    /// double. The float inverse of a projection whose far plane is 10⁵ times
    /// its near one turned the line by up to 1e-5 — 0.1 mm at 10 m, measured
    /// against Blender's own tool — which double does not.
    public static func ray(_ view: GeometrySnap.View, _ pointer: SIMD2<Float>)
        -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard view.size.x > 0, view.size.y > 0 else { return nil }
        let m = view.viewProjection
        let d = simd_double4x4(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
                                         SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3))).inverse
        let x = Double(pointer.x) / Double(view.size.x) * 2 - 1
        let y = 1 - Double(pointer.y) / Double(view.size.y) * 2
        let near = d * SIMD4<Double>(x, y, 0, 1), far = d * SIMD4<Double>(x, y, 1, 1)
        guard abs(near.w) > 1e-12, abs(far.w) > 1e-12 else { return nil }
        let o = SIMD3<Double>(near.x, near.y, near.z) / near.w
        let f = SIMD3<Double>(far.x, far.y, far.z) / far.w
        let dir = f - o
        guard simd_length_squared(dir) > 0, o.x.isFinite, dir.x.isFinite else { return nil }
        return (SIMD3<Float>(o), SIMD3<Float>(simd_normalize(dir)))
    }

    /// One object's triangles in world space, gathered once per tap.
    struct Body {
        let object: BKObject
        let world: [SIMD3<Float>]
        let lo: SIMD3<Float>, hi: SIMD3<Float>
        /// The first index (of three) of each triangle to try, or nil for all.
        var candidates: [Int]?

        init?(_ object: BKObject) {
            let m = object.modelMatrix
            let mesh = object.mesh
            let count = mesh.vertices.count
            // An index past the vertices would read outside them.
            guard count > 0, mesh.indices.allSatisfy({ Int($0) < count }) else { return nil }
            world = mesh.vertices.map { (m * SIMD4($0.position, 1)).xyz }
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in world { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            self.object = object
            self.lo = lo; self.hi = hi
        }

        /// Only the triangles whose screen box overlaps `window` (view points),
        /// and every one with a corner behind the eye, which a box cannot be
        /// drawn for: Surface Project's margin casts up to 81 rays around one
        /// pointer, and each would otherwise try every triangle of a mesh of a
        /// million.
        mutating func narrow(to window: (lo: SIMD2<Float>, hi: SIMD2<Float>), view: GeometrySnap.View) {
            let screen = world.map { view.project($0) }
            let indices = object.mesh.indices
            var keep: [Int] = []
            var t = 0
            while t + 2 < indices.count {
                if let a = screen[Int(indices[t])], let b = screen[Int(indices[t + 1])], let c = screen[Int(indices[t + 2])] {
                    let tlo = simd_min(a, simd_min(b, c)), thi = simd_max(a, simd_max(b, c))
                    if tlo.x <= window.hi.x && thi.x >= window.lo.x && tlo.y <= window.hi.y && thi.y >= window.lo.y {
                        keep.append(t)
                    }
                } else {
                    keep.append(t)
                }
                t += 3
            }
            candidates = keep
        }
    }

    static func bodies(_ objects: [BKObject]) -> [Body] { surfaced(objects).compactMap(Body.init) }

    /// The nearest face along `ray` (from the near plane), or nil.
    public static func surfaceHit(objects: [BKObject],
                                  ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> Surface? {
        surfaceHit(bodies: bodies(objects), ray: ray)
    }

    static func surfaceHit(bodies: [Body], ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> Surface? {
        var best: (t: Float, body: Int, triangle: Int)?
        for (b, body) in bodies.enumerated() {
            guard let entry = GeometrySnap.rayBox(ray, body.lo, body.hi), best == nil || entry < best!.t else { continue }
            let indices = body.object.mesh.indices
            func test(_ t: Int) {
                let i = Int(indices[t]), j = Int(indices[t + 1]), k = Int(indices[t + 2])
                if let d = MeshPicker.rayTriangle(ray.origin, ray.direction, body.world[i], body.world[j], body.world[k]),
                   d >= 0, best == nil || d < best!.t {
                    best = (d, b, t)
                }
            }
            if let candidates = body.candidates {
                for t in candidates { test(t) }
            } else {
                var t = 0
                while t + 2 < indices.count { test(t); t += 3 }
            }
        }
        guard let best else { return nil }
        let object = bodies[best.body].object
        let mesh = object.mesh
        let a = mesh.vertices[Int(mesh.indices[best.triangle])].position
        let b = mesh.vertices[Int(mesh.indices[best.triangle + 1])].position
        let c = mesh.vertices[Int(mesh.indices[best.triangle + 2])].position
        let m = object.modelMatrix
        let linear = simd_float3x3(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)
        // `normal_tri_v3` in the object's space, then
        // `transpose(invert(float3x3(obmat)))` and normalized.
        let local = simd_cross(b - a, c - a)
        guard abs(linear.determinant) > 1e-20, simd_length(local) > 0 else { return nil }
        let n = simd_normalize(linear.inverse.transpose * simd_normalize(local))
        return Surface(location: ray.origin + ray.direction * best.t, normal: n, axes: linear, object: object.name)
    }

    /// The pixels `view_autodist_depth_margin` reads around the pointer, in
    /// the view's points (y down): for margin 0 the pixel itself, otherwise
    /// `BLI_rcti_init_pt_radius`'s rectangle from x − m to x + m with its far
    /// edges left out (`view3d_depths_rect_create`) — 2m pixels a side, one
    /// more left of the pointer than right, and on Blender's y, which points
    /// up, one more below than above.
    static func marginOffsets(_ margin: Int) -> [SIMD2<Float>] {
        guard margin > 0 else { return [.zero] }
        var out: [SIMD2<Float>] = []
        for dy in (1 - margin)...margin {
            for dx in -margin...(margin - 1) { out.append(SIMD2(Float(dx), Float(dy))) }
        }
        return out
    }

    /// What Surface Project reads at `pointer` (view points from the top
    /// left): where the drawn surfaces meet the pointer's line of sight, or —
    /// only when nothing is drawn exactly there — the nearest depth within 2,
    /// then 4 points of it, put on the pointer's own line
    /// (`ED_view3d_autodist`'s margins 0, 2, 4, `view_autodist_depth_margin`,
    /// `ED_view3d_unproject_v3` at the pixel). Nil when nothing is drawn
    /// within 4 points. Measured against Blender's own tool with its depth
    /// buffer redrawn for every click: within 1.1 mm (the depth buffer's
    /// float) at 532 of 534 pixels — the two left are a wire object's.
    public static func depthHit(objects: [BKObject], view: GeometrySnap.View, pointer: SIMD2<Float>,
                                forward: SIMD3<Float>) -> SIMD3<Float>? {
        guard let centre = ray(view, pointer) else { return nil }
        let window = (lo: pointer - SIMD2(repeating: 5), hi: pointer + SIMD2(repeating: 5))
        let bodies = bodies(objects).map { body -> Body in
            var narrowed = body
            narrowed.narrow(to: window, view: view)
            return narrowed
        }
        guard !bodies.isEmpty else { return nil }
        // The view depth of what is drawn at `p`, measured from the near plane.
        func depth(_ p: SIMD2<Float>) -> Float? {
            guard let line = ray(view, p), let hit = surfaceHit(bodies: bodies, ray: line) else { return nil }
            return simd_dot(hit.location - centre.origin, forward)
        }
        for margin in [0, 2, 4] {
            var nearest: Float?
            for offset in marginOffsets(margin) {
                if let d = depth(pointer + offset), nearest == nil || d < nearest! { nearest = d }
            }
            if let nearest {
                // On the pointer's own line, at that depth along the view.
                let along = simd_dot(centre.direction, forward)
                guard abs(along) > 1e-9 else { return nil }
                return centre.origin + centre.direction * (nearest / along)
            }
        }
        return nil
    }

    /// Why the Geometry orientation cannot follow the face a tap met, or nil.
    ///
    /// In Edit Mode Blender's Cursor snaps to the edited object's final mesh
    /// (SNAP_GEOM_FINAL; `data_for_snap` casts at the edit mesh where the final
    /// mesh is its BMesh wrapper). That is the mesh the mirror holds — the
    /// edit mesh, or what a Mirror, an Array and the like make of it, which
    /// round 4's review measured Blender's own tool meeting on the copy —
    /// except under a Subdivision Surface evaluated last, whose final mesh is
    /// the one before it (`BKObject.finalGeometryRefusal`). Measured in desktop
    /// 5.2.1 under one, the cursor turned to the cage's face, 0.24 m from the
    /// subdivided surface the 3D View draws and the mirror holds. There the
    /// tap says so instead of guessing. Surface Project and the other
    /// orientations read the drawn surface, as Blender's depth buffer does,
    /// and still place.
    public static func geometryRefusal(_ surface: Surface?, orientation: Orientation,
                                       edited: BKObject?) -> String? {
        guard orientation == .geometry, let surface, let edited, surface.object == edited.name else { return nil }
        return edited.finalGeometryRefusal(what: "the face the Geometry orientation turns the cursor to",
                                           toDo: "orient the cursor to a face here")
    }

    /// What a Cursor drag may snap to: every object, as Blender's cursor
    /// transform snaps with no exclusion (CTX_CURSOR leaves the targets
    /// SCE_SNAP_TARGET_ALL, transform_snap.cc) — but the object being edited
    /// left out where Blender snaps to a mesh of it the mirror does not hold
    /// (`finalGeometryRefusal`: the cursor's transform has no T_EDIT, so it
    /// snaps to the final geometry, SNAP_GEOM_FINAL). With the reason, for
    /// the drag's readout.
    public static func dragExcluded(edited: BKObject?) -> (ids: Set<UUID>, reason: String?) {
        guard let edited, let why = edited.finalGeometryRefusal(what: "its vertices, edges and faces",
                                                                toDo: "snap the cursor to it")
        else { return ([], nil) }
        return ([edited.id], why)
    }

    /// Six significant places past float precision: what the call carries.
    static func number(_ v: Float) -> String {
        let text = String(format: "%.9g", Double(v))
        return text == "-0" ? "0" : text
    }

    static func vector(_ p: SIMD3<Float>) -> String { "(\(number(p.x)), \(number(p.y)), \(number(p.z)))" }

    /// Whether every number a call would carry is finite: a non-finite one
    /// would be Python's `nan`, which is not a literal.
    static func finite(_ values: [SIMD3<Float>]) -> Bool {
        values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    }

    /// The point of the pointer's line of sight `ray` the call carries: as
    /// far along it as the view's centre is, at least a metre. The ray's own
    /// origin is on the near plane, a centimetre from the eye, and the
    /// direction Python takes from the eye to it lost 5e-5 of its angle to
    /// float rounding — 0.6 mm at 11 m, measured against Blender's own tool
    /// (its `ED_view3d_win_to_vector` keeps the direction whole).
    public static func linePoint(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                 center: SIMD3<Float>) -> SIMD3<Float> {
        ray.origin + ray.direction * max(1, abs(simd_dot(center - ray.origin, ray.direction)))
    }

    /// The call a tap makes: Blender's Cursor tool clicked with the pointer's
    /// line of sight through `point` (`linePoint`). Nil when the view or a
    /// hit is not a number.
    public static func placePython(view: View, point: SIMD3<Float>, depth: SIMD3<Float>?,
                                   surface: Surface?) -> String? {
        var values = [view.eye, view.forward, view.up, view.center, point]
        if let depth { values.append(depth) }
        if let surface {
            values += [surface.location, surface.normal, surface.axes.columns.0, surface.axes.columns.1,
                       surface.axes.columns.2]
        }
        guard finite(values) else { return nil }
        var args = "eye=\(vector(view.eye)), forward=\(vector(view.forward)), up=\(vector(view.up)), "
            + "ortho=\(view.orthographic ? "True" : "False"), point=\(vector(point)), "
            + "center=\(vector(view.center)), axis_view=\(view.axisAligned ? "True" : "False")"
        args += ", depth=" + (depth.map(vector) ?? "None")
        if let surface {
            args += ", surface=(\(vector(surface.location)), \(vector(surface.normal)), "
                + "\(vector(surface.axes.columns.0)), \(vector(surface.axes.columns.1)), "
                + "\(vector(surface.axes.columns.2)))"
        } else {
            args += ", surface=None"
        }
        return "import _blenderkit_cursor\n_blenderkit_cursor.place(\(args))"
    }

    /// The tool header's Surface Project or Orientation, written where
    /// Blender's toolbar keeps them (the workspace tool for the mode).
    public static func settingsPython(surfaceProject: Bool? = nil, orientation: Orientation? = nil) -> String {
        var args: [String] = []
        if let surfaceProject { args.append("use_depth=\(surfaceProject ? "True" : "False")") }
        if let orientation { args.append("orientation='\(orientation.rawValue)'") }
        return "import _blenderkit_cursor\n_blenderkit_cursor.set_settings(\(args.joined(separator: ", ")))"
    }

    // MARK: the drag

    /// `ED_view3d_win_to_3d`: the point under `pointer` on the plane through
    /// `depth` facing the view.
    public static func winTo3D(depth: SIMD3<Float>, view: GeometrySnap.View, pointer: SIMD2<Float>,
                               eye: SIMD3<Float>, forward: SIMD3<Float>, orthographic: Bool) -> SIMD3<Float>? {
        guard let ray = ray(view, pointer) else { return nil }
        if orthographic {
            return ray.origin + ray.direction * simd_dot(depth - ray.origin, ray.direction)
        }
        let along = simd_dot(ray.direction, forward)
        guard abs(along) > 1e-12 else { return nil }
        return eye + ray.direction * abs(simd_dot(depth - eye, forward) / along)
    }

    /// Where a drag that began with the cursor at `start` puts it with the
    /// pointer at `pointer`: moved in the view's plane through it, as
    /// `transform.translate` moves the cursor (`convertViewVec` at its depth),
    /// or onto what the snap found there.
    public static func dragTarget(start: SIMD3<Float>, pointer: SIMD2<Float>, view: GeometrySnap.View,
                                  eye: SIMD3<Float>, forward: SIMD3<Float>, orthographic: Bool,
                                  snap: GeometrySnap.Targets?) -> (location: SIMD3<Float>, hit: GeometrySnap.Hit?)? {
        if let snap, let hit = snap.find(pointer) {
            // `move` answers the move, not the place: the cursor goes by it.
            // (The first build here put the cursor at the move itself — in the
            // app a drag snapped to a vertex left it 0.94 m from the origin,
            // on no vertex.)
            return (start + GeometrySnap.move(start, to: hit, constraint: .free), hit)
        }
        guard let p = winTo3D(depth: start, view: view, pointer: pointer, eye: eye, forward: forward,
                              orthographic: orthographic) else { return nil }
        return (p, nil)
    }

    /// The drag's commit: Blender's own operator moving the cursor by what
    /// the drag previewed, its undo step Blender's ("Move"). With the
    /// scene's snapping on, Blender's own call would snap in a window; the
    /// value here is already where the snap put it, so it goes with
    /// `snap=False` and lands exactly there.
    public static func dragPython(from start: SIMD3<Float>, to end: SIMD3<Float>) -> String? {
        let d = end - start
        guard finite([start, end]) else { return nil }
        return "bpy.ops.transform.translate(value=\(vector(d)), orient_type='GLOBAL', snap=False, "
            + "cursor_transform=True, release_confirm=True)"
    }

    /// The drag's undo step: `transform.translate`'s name.
    public static let dragUndo = UndoStep.move

    /// What the drag's readout says while snapping is on with Snap Target
    /// elements the drag does not follow, or nil. It snaps to vertices,
    /// edges, edge centres, faces and face centres (`GeometrySnap.honoured`);
    /// Blender's translate would also step by Increment or Grid and peel to
    /// Volume, and with Increment alone — Blender's factory setting — the
    /// drag moved freely and said nothing (round 4's review).
    public static func snapNote(elements: Set<SnapElement>) -> String? {
        let unfollowed = SnapElement.allCases.filter { elements.contains($0) && !GeometrySnap.honoured.contains($0) }
        guard !unfollowed.isEmpty else { return nil }
        let names = unfollowed.map(\.label)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "(Snap Target \(list) " + (names.count == 1 ? "does" : "do") + " not move the cursor here)"
    }
}

public extension BKObject {
    /// Why, in Edit Mode, Blender's snapping to this object's final geometry
    /// (SNAP_GEOM_FINAL: the Cursor's Geometry orientation and its drag) meets
    /// a mesh the app cannot follow, in words — or nil when it meets the mesh
    /// the mirror holds.
    ///
    /// The mirror holds Blender's evaluated mesh as the 3D View draws it. A
    /// Subdivision Surface that Blender evaluates last returns its input as
    /// the final mesh and subdivides only for whoever asks
    /// (`subdiv_cache_mesh_wrapper_settings`, MOD_subsurf.cc), and Edit Mode's
    /// snapping reads that final mesh as it is
    /// (`BKE_object_get_editmesh_eval_final`). So there, and only there,
    /// Blender's snap meets a mesh the viewport does not draw
    /// (`subdividesLastInEditMode`). Under any other stack the final mesh is
    /// the mirror's: round 4's review measured Blender's own Geometry click
    /// turning the cursor to a Mirror's and an Array's copy, which the app
    /// had refused because those modifiers rebuild the edit mesh
    /// (`editRegionRefusal`, the rule for picking Blender's elements, not
    /// for snapping).
    func finalGeometryRefusal(what: String, toDo: String) -> String? {
        guard subdividesLastInEditMode else { return nil }
        let modifier = modifiers.last { $0.kind == .subdivision && $0.showInViewport }?.name
        return "In Edit Mode Blender snaps to \(name) before its Subdivision Surface"
            + (modifier.map { " \($0)" } ?? "") + " subdivides it, which is not the mesh the viewport draws, so "
            + "\(what) cannot be followed here. Turn off the modifier's Edit Mode display, or apply it, to \(toDo)."
    }
}

/// The 3D cursor as Blender's overlay draws it (overlay_cursor.hh, the shapes
/// in overlay_shape.cc): its own three axes, turned by the cursor's rotation
/// (`from_loc_rot_scale(location, rotation(), scale * widget_unit)`), and a
/// circle facing the viewer. The app drew three world-aligned lines instead,
/// so Orientation's View, Transform and Geometry all looked the same and the
/// crosshair showed a cursor Blender did not hold (round 4's review).
///
/// Each axis runs from 0.25 to 1 widget unit either side of the cursor: the
/// outer 0.85–1 in the theme's axis colour (darker on the negative side,
/// `get_color_blend_shade_3fv(axis, TH_WHITE, 0.25, -60)`), the rest in the
/// 3D View's View Overlay colour (black in the default theme, read in desktop
/// 5.2.1). The circle is 12 segments of radius half a unit, white and red in
/// turn. A widget unit is 20 points, the app taking Blender's pixel as a point
/// as its other overlays do (`OverlayView.pixelSize`).
public enum CursorGlyph {
    public static let widgetUnit: Float = 20

    /// Blender's default theme: `axis_x`, `axis_y`, `axis_z`
    /// (userdef_default_theme.c), 0–255.
    static let axisColours: [SIMD3<Float>] = [SIMD3(255, 51, 82), SIMD3(139, 220, 0), SIMD3(40, 144, 255)]
    static let viewOverlay = SIMD4<Float>(0, 0, 0, 1)

    /// `get_color_blend_shade_3fv(colour, TH_WHITE, 0.25, -60)`, as 0–1.
    static func negative(_ c: SIMD3<Float>) -> SIMD4<Float> {
        func channel(_ v: Float) -> Float { min(max(-60 + (0.75 * v + 0.25 * 255).rounded(.down), 0), 255) / 255 }
        return SIMD4(channel(c.x), channel(c.y), channel(c.z), 1)
    }

    /// Line segments, two vertices each with a colour, in world space.
    public static func lines(location: SIMD3<Float>, rotation: simd_quatf, view: OverlayView)
        -> [(position: SIMD3<Float>, colour: SIMD4<Float>)] {
        let unit = view.worldPerPoint(at: location) * widgetUnit
        guard unit.isFinite, unit > 0 else { return [] }
        let q = simd_normalize(rotation)
        var out: [(position: SIMD3<Float>, colour: SIMD4<Float>)] = []
        func segment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ colour: SIMD4<Float>) {
            out.append((a, colour)); out.append((b, colour))
        }
        for i in 0..<3 {
            var axis = SIMD3<Float>(repeating: 0)
            axis[i] = 1
            let d = q.act(axis) * unit
            let positive = SIMD4(axisColours[i] / 255, 1)
            segment(location + d, location + d * 0.85, positive)
            segment(location + d * 0.85, location + d * 0.25, viewOverlay)
            segment(location - d, location - d * 0.85, negative(axisColours[i]))
            segment(location - d * 0.85, location - d * 0.25, viewOverlay)
        }
        // The circle, in the view's plane through the cursor.
        let radius: Float = 0.5 * widgetUnit
        let red = SIMD4<Float>(1, 0, 0, 1), white = SIMD4<Float>(1, 1, 1, 1)
        for i in 0..<12 {
            let a0 = 2 * Float.pi * Float(i) / 12, a1 = 2 * Float.pi * Float(i + 1) / 12
            segment(view.screenSpace(location, SIMD2(cos(a0), sin(a0)) * radius),
                    view.screenSpace(location, SIMD2(cos(a1), sin(a1)) * radius), i % 2 == 0 ? white : red)
        }
        return out
    }

    /// The cursor's rotation as a unit quaternion, for a drawing: what the
    /// mirror read from Blender (`CursorState.rotation`), the identity while
    /// none has been read.
    public static func rotation(_ state: CursorState) -> simd_quatf {
        let q = state.rotation
        return q.vector.x.isFinite && simd_length(q.vector) > 0 ? simd_normalize(q) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
}
