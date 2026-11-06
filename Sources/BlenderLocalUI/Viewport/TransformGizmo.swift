import Foundation
import simd
import CoreGraphics

/// Blender's transform gizmo, made grabbable.
///
/// On the desktop you transform by pressing `G`, then `X` to constrain the
/// axis, then typing a number — a modal flow with nothing on screen to take
/// hold of. None of that survives the trip to a tablet: there is no keyboard,
/// and a bare screen-plane drag is the one thing a mouse user almost never
/// wants.
///
/// So the gizmo *is* the interface here. Every axis shaft, every plane quad and
/// the centre are handles, and dragging one is constrained to exactly that axis
/// the way typing `G X` would be. The result is the same transform Blender
/// would apply, reached without a keystroke.
///
/// The geometry is rebuilt from scratch every frame and every hit-test. There
/// is exactly one gizmo, so nothing here is worth caching.
struct TransformGizmo {

    enum Mode: Equatable {
        case translate, rotate, scale

        /// What the undo entry is called: the step Blender's history records
        /// for `transform.translate`, `rotate` and `resize` (UndoStep, which
        /// the names check measures in Blender).
        var undoName: String {
            switch self {
            case .translate: return UndoStep.move
            case .rotate:    return UndoStep.rotate
            case .scale:     return UndoStep.resize
            }
        }
    }

    /// A grabbable part. `axis` and `plane` are indexed 0/1/2 = X/Y/Z; a plane
    /// is named for its *normal*, so `.plane(2)` is the XY plane, matching how
    /// Blender labels its plane handles.
    enum Handle: Equatable, Hashable {
        case axis(Int)
        case plane(Int)
        /// The view-aligned handle: the centre disc for move and scale, the
        /// outer ring for rotate.
        case screen
    }

    // Blender's theme axis colours, matching the ones the viewport grid uses.
    static let axisColours: [SIMD4<Float>] = [
        SIMD4(0.898, 0.282, 0.416, 1),
        SIMD4(0.482, 0.776, 0.161, 1),
        SIMD4(0.184, 0.514, 0.890, 1),
    ]
    /// Blender highlights the handle under the cursor in white.
    static let highlightColour = SIMD4<Float>(1, 1, 1, 1)
    static let screenColour = SIMD4<Float>(0.78, 0.78, 0.78, 1)

    /// On-screen size of the gizmo, in points. Blender's is a fixed pixel size
    /// regardless of zoom, which is what keeps it grabbable when you are nose
    /// to nose with the model.
    static let screenRadius: Float = 92
    /// How close a touch has to land. Generous, because a fingertip is about
    /// 44 points across and the shaft it is aiming at is three.
    static let grabSlop: CGFloat = 22
    /// Plane quads are about 26 points across, so they get a tighter radius
    /// than the shafts do.
    static let planeSlop: CGFloat = 16

    let mode: Mode
    let origin: SIMD3<Float>
    /// Unit axes in world space, X/Y/Z order.
    let axes: [SIMD3<Float>]
    /// Shaft length in world units, chosen so the gizmo covers `screenRadius`
    /// points on screen.
    let radius: Float

    // MARK: building

    /// What a rotation or a scale turns about: Blender's
    /// `tool_settings.transform_pivot_point`, mirrored onto `scene.tools`.
    /// Its default, and Blender's, is Median Point.
    ///
    /// Individual Origins has no single point, so it answers the median — which
    /// is where Blender draws the gizmo for it too — and `apply` turns each
    /// object about its own origin instead.
    static func pivot(of scene: BKScene, for transform: Mode? = nil) -> SIMD3<Float>? {
        let mode = scene.tools.pivot
        // Edit mode pivots on the selected vertices, not the object origin —
        // otherwise the gizmo sits somewhere you are not editing.
        //
        // And with no vertex selected there is no gizmo, as Blender draws
        // none. This fell through to the object branch below, so a drag in
        // Edit Mode with nothing selected moved the edited object and, with
        // proportional editing, pulled its neighbours, while the translate it
        // committed came back CANCELLED from Blender 5.2.1 and moved nothing
        // (round 2's review: 0.58 on the cube, 0.29 on its neighbour, then
        // both snapped back on release).
        if scene.mode == .edit {
            // A curve or a lattice pivots on its selected control points,
            // each where Blender's transform measures it from — a handle
            // whose knot is selected at its knot (`transformCentres`) — and
            // shows no gizmo with none selected, as for a mesh.
            if let (obj, cage) = scene.editedPoints {
                let points = cage.transformCentres(model: obj.modelMatrix)
                guard !points.isEmpty else { return nil }
                if mode == .cursor { return scene.cursor }
                // One point turned or scaled turns about itself, a lone
                // handle about its knot (`ControlCage.singlePoint`).
                if transform == .rotate || transform == .scale, let single = cage.singlePoint(model: obj.modelMatrix) {
                    return single
                }
                if mode == .boundingBoxCenter { return boundsCentre(points) }
                return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
            }
            if scene.active?.editsPoints == true { return nil }
            guard let obj = scene.active, !scene.editSelection.vertices.isEmpty else { return nil }
            let m = obj.modelMatrix
            // The mesh the drag moves (`editCage`), so the gizmo sits on the
            // vertices that will move and shows none for a selection of
            // vertices only the modifier stack made.
            let cage = obj.editCage.vertices
            let points = scene.editSelection.vertices.compactMap { i -> SIMD3<Float>? in
                guard i < cage.count else { return nil }
                return (m * SIMD4(cage[i].position, 1)).xyz
            }
            guard !points.isEmpty else { return nil }
            if mode == .cursor { return scene.cursor }
            if mode == .boundingBoxCenter { return boundsCentre(points) }
            // Active Element needs an active vertex, edge or face, which this
            // app's edit selection does not carry, and Individual Origins has
            // no single point. Both fall back to the median.
            return points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        }
        let targets = scene.objects.filter { scene.selection.contains($0.id) && $0.visible }
        guard !targets.isEmpty else { return nil }
        let median = targets.reduce(SIMD3<Float>.zero) { $0 + $1.location } / Float(targets.count)
        switch mode {
        case .cursor:
            return scene.cursor
        case .boundingBoxCenter:
            // The bounds of the objects' origins, not of their geometry:
            // Blender's calculateCenterBound takes min/max over the same
            // per-object centres the median averages.
            return boundsCentre(targets.map(\.location))
        case .activeElement:
            // The active object's origin, and the median when the active
            // object is not one of the visible selected ones.
            if let active = scene.active, targets.contains(where: { $0.id == active.id }) {
                return active.location
            }
            return median
        case .medianPoint, .individualOrigins:
            return median
        }
    }

    private static func boundsCentre(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        var lo = points[0], hi = points[0]
        for p in points {
            lo = min(lo, p)
            hi = max(hi, p)
        }
        return (lo + hi) * 0.5
    }

    /// World units per screen point at a given depth — the conversion that lets
    /// a pixel drag become a world-space distance.
    static func worldPerPoint(camera: ViewportCamera, at point: SIMD3<Float>, size: CGSize) -> Float {
        let h = max(Float(size.height), 1)
        // Orthographic has no depth falloff: the scale is fixed by the framing.
        let depth = camera.isOrthographic ? camera.distance
                                          : max(length(point - camera.eye), 0.01)
        return 2 * depth * tan(camera.fovY * 0.5) / h
    }

    static func make(mode: Mode, scene: BKScene, options: ViewportOptions,
                     camera: ViewportCamera, size: CGSize) -> TransformGizmo? {
        guard let origin = pivot(of: scene, for: mode),
              let m = orientationAxes(scene: scene, camera: camera) else { return nil }
        // Every handle follows Blender's Orientation, Scale's too, as
        // Blender's gizmo does (`calc_gizmo_stats` takes the scale slot,
        // which defaults to the main one). Scale used to be pinned to the
        // object's own axes, because a scale along a world axis of a turned
        // object has no exact loc/rot/scale; Blender's answer to that is
        // `TransMat3ToSize`, which the preview runs too (TransformOperation).
        let axes = [m.columns.0, m.columns.1, m.columns.2]
        let radius = screenRadius * worldPerPoint(camera: camera, at: origin, size: size)
        return TransformGizmo(mode: mode, origin: origin, axes: axes, radius: radius)
    }

    /// Blender's View orientation for the app's view: `rv3d->viewinv`'s axes,
    /// right, up and towards the eye.
    static func viewAxes(_ camera: ViewportCamera) -> simd_float3x3 {
        simd_float3x3(camera.right, camera.trueUp, simd_normalize(camera.eye - camera.target))
    }

    /// The axes the gizmo is drawn on: Blender's matrix for the scene's
    /// orientation, which `_blenderkit_orient` reports (`scene.orientation`),
    /// the view's own for View, and Local from the active object's world
    /// matrix until Blender has answered. Nil — no gizmo — when Blender's
    /// matrix is not known yet or cannot be worked out here
    /// (`OrientationState.unavailable`): a gizmo on axes Blender would not
    /// use would commit something other than what it showed.
    static func orientationAxes(scene: BKScene, camera: ViewportCamera) -> simd_float3x3? {
        let state = scene.orientation
        guard state.unavailable == nil else { return nil }
        switch state.type {
        case .global?:
            return matrix_identity_float3x3
        case .view?:
            return viewAxes(camera)
        default:
            if let axes = state.axes { return axes }
            if state.type == .local, let active = scene.active {
                return OrientationBpy.localAxes(active.modelMatrix)
            }
            return nil
        }
    }

    // MARK: screen projection

    /// The view-projection frozen at one instant, so a drag stays anchored to
    /// the basis it started in even if the view moves under it.
    struct Projection {
        let matrix: simd_float4x4
        let size: CGSize

        init(camera: ViewportCamera, size: CGSize) {
            self.matrix = camera.viewProjection(aspect: Float(size.width / max(size.height, 1)))
            self.size = size
        }

        func project(_ world: SIMD3<Float>) -> CGPoint? {
            let clip = matrix * SIMD4(world, 1)
            guard clip.w > 1e-5 else { return nil }   // behind the eye
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * size.width,
                           y: CGFloat(1 - (ndc.y * 0.5 + 0.5)) * size.height)
        }
    }

    // MARK: hit testing

    /// Where each mode's handles sit along a shaft, as a fraction of `radius`.
    private var shaftRange: (ClosedRange<Float>) { 0.16...1.0 }
    private var planeOffset: Float { 0.42 }
    private var planeHalf: Float { 0.14 }
    private var ringScale: Float { 0.95 }
    private var screenRingScale: Float { 1.18 }

    /// The handle under `point`, or nil. Closer handles win, and the compact
    /// ones (centre, planes) are tested first so a shaft crossing them cannot
    /// steal the touch.
    func hitTest(_ point: CGPoint, projection p: Projection) -> Handle? {
        guard let centre = p.project(origin) else { return nil }

        switch mode {
        case .translate, .scale:
            if distance(point, centre) < Self.grabSlop * 0.85 { return .screen }

            // A plane quad sits on top of two shafts, so raw distance would let
            // whichever shaft runs through it win every time and the plane would
            // be ungrabbable. Scoring each candidate against *its own* target
            // size instead — a fraction of its slop — keeps a small handle
            // competitive against a long one without letting it swallow the
            // shaft further out.
            var best: (Handle, CGFloat)?
            func offer(_ handle: Handle, _ d: CGFloat, _ slop: CGFloat) {
                guard d < slop else { return }
                let score = d / slop
                if best == nil || score < best!.1 { best = (handle, score) }
            }

            for i in 0..<3 {
                let (j, k) = ((i + 1) % 3, (i + 2) % 3)
                let c = origin + (axes[j] + axes[k]) * (radius * planeOffset)
                if let s = p.project(c) { offer(.plane(i), distance(point, s), Self.planeSlop) }
            }
            for i in 0..<3 {
                guard let a = p.project(origin + axes[i] * (radius * shaftRange.lowerBound)),
                      let b = p.project(origin + axes[i] * (radius * shaftRange.upperBound))
                else { continue }
                offer(.axis(i), distanceToSegment(point, a, b), Self.grabSlop)
            }
            return best?.0

        case .rotate:
            // Three rings can all pass within a few pixels of the same point, so
            // pick by measuring the real projected curve rather than by an
            // idealised screen-space radius.
            var best: (Handle, CGFloat)?
            for i in 0..<3 {
                let d = distanceToRing(point, axisIndex: i, scale: ringScale, projection: p)
                if d < Self.grabSlop, best == nil || d < best!.1 { best = (.axis(i), d) }
            }
            // The view-aligned ring sits outside them all.
            let outer = CGFloat(Self.screenRadius * screenRingScale)
            let dOuter = abs(distance(point, centre) - outer)
            if dOuter < Self.grabSlop, best == nil || dOuter < best!.1 { best = (.screen, dOuter) }
            return best?.0
        }
    }

    /// Points around one rotation ring, in world space.
    func ringPoints(axisIndex i: Int, scale: Float, segments: Int = 64) -> [SIMD3<Float>] {
        let n = axes[i]
        let u = axes[(i + 1) % 3], v = axes[(i + 2) % 3]
        _ = n
        return (0...segments).map { s in
            let t = Float(s) / Float(segments) * 2 * .pi
            return origin + (u * cos(t) + v * sin(t)) * (radius * scale)
        }
    }

    private func distanceToRing(_ point: CGPoint, axisIndex: Int, scale: Float,
                                projection p: Projection) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        var previous: CGPoint?
        for w in ringPoints(axisIndex: axisIndex, scale: scale, segments: 48) {
            guard let s = p.project(w) else { previous = nil; continue }
            if let a = previous { best = min(best, distanceToSegment(point, a, s)) }
            previous = s
        }
        return best
    }

    // MARK: dragging

    /// The transform captured at touch-down, so every frame recomputes the
    /// result from the original values instead of accumulating. Accumulating
    /// makes a slow drag and a fast one land in different places, and makes the
    /// transform impossible to back out of without undo.
    struct Session {
        let gizmo: TransformGizmo
        let handle: Handle
        let start: CGPoint
        let projection: Projection
        let eye: SIMD3<Float>
        let snapshot: [(object: BKObject, location: SIMD3<Float>,
                        rotation: SIMD3<Float>, scale: SIMD3<Float>)]
        /// Object mode with proportional editing on: the unselected objects
        /// it reaches, as they were at touch-down, and how much of the
        /// transform each gets. Blender moves them too, so the preview must.
        let neighbours: [(object: BKObject, pose: ObjectPose, factor: Float)]
        /// Object mode: everything carried through `parent` by what moves —
        /// the children, grandchildren and so on of the selection and of the
        /// neighbours — parents before their children. See `apply`.
        let followers: [Follower]
        /// Selected objects with a selected ancestor, which Blender deselects
        /// for the transform (BA_WAS_SEL, `set_trans_object_base_flags`) so
        /// they move only as their parent carries them. Empty for a turn or a
        /// scale about Individual Origins, which `transform_individual` runs
        /// one object at a time.
        let carriedOnly: Set<UUID>
        /// Set in edit mode: the mesh as it was at touch-down, and which of its
        /// vertices the drag moves. Non-nil means the drag edits geometry
        /// rather than moving the object that holds it.
        let edit: EditDrag?
        /// Set in a curve's or a lattice's Edit Mode: the drag moves its
        /// selected control points, previewed by Blender itself each frame
        /// (`_blenderkit_points.preview`), so `apply` and `rollBack` leave the
        /// display cache alone. See ControlPoints.swift.
        let points: PointDrag?
        /// Blender's proportional editing, captured with the drag: nil when it
        /// is off in this mode.
        let proportional: ProportionalEdit?
        /// Blender's pivot point, captured too — the committed operator has to
        /// turn about the same point the preview turned about.
        let pivot: TransformPivot
        /// The magnet, when it is on and something a drag honours is chosen.
        let snap: TransformSnap?
        /// Snap With's point at touch-down: what Grid lands on the grid.
        let snapSource: SIMD3<Float>
        /// Snapping to vertices, edges and faces: a move with the magnet on and
        /// one of them chosen. Tried before Grid and Increment, which apply
        /// only when it finds nothing, as in Blender.
        let geometry: GeometrySnapping?
        /// Blender's Auto Merge threshold while editing with it on: the
        /// scene's `double_threshold`, captured with the drag. See `AutoMerge`.
        let autoMerge: Float?
        /// Object mode with Affect Only Origins on: the origins move and the
        /// geometry stays where it is in the world, so the preview moves no
        /// target or neighbour — only what follows an origin (children).
        let originsOnly: Bool
        /// The scene's falloff, size and Connected Only as the drag began:
        /// where the redo panel's proportional rows start when the drag had
        /// proportional editing off.
        let proportionalDefaults: ProportionalEdit
        /// The orientation the drag is measured in, frozen with it: what the
        /// commit says, and what the preview turns its numbers back into.
        let frame: Frame
        /// Ctrl held: snapping the other way round from the scene's magnet
        /// (Blender's SNAP_INV_ON and SNAP_INV_OFF in the transform modal
        /// map, Ctrl's press and release). The other snapping is worked out
        /// the first time Ctrl asks for it (`SnapInversion`).
        var snapInversion: SnapInversion? = nil
        var snapInverted = false

        /// The magnet's snapping in effect now: the scene's, or with Ctrl
        /// held the other.
        var activeSnap: TransformSnap? {
            guard snapInverted, let snapInversion else { return snap }
            return snapInversion.inverted.snap
        }

        /// Snapping to vertices, edges and faces in effect now.
        var activeGeometry: GeometrySnapping? {
            guard snapInverted, let snapInversion else { return geometry }
            return snapInversion.inverted.geometry
        }

        /// The same drag with Ctrl held or let go.
        func invertingSnap(_ on: Bool) -> Session {
            var s = self
            s.snapInverted = on
            return s
        }

        /// Individual Origins, which no single `center_override` can express.
        /// Only in object mode: an edit-mode drag has no per-island origin to
        /// use, so it keeps the gizmo's own pivot.
        var usesIndividualOrigins: Bool { pivot == .individualOrigins && edit == nil && points == nil }

        /// The same drag held another way: G's X, Y and Z change the handle
        /// and the axes under a drag already running, and the first pointer
        /// to arrive moves where it started. What the drag found — the
        /// selection's places, its neighbours, the snap targets — stays as
        /// it was taken, as Blender keeps its TransData across them.
        func retargeted(handle: Handle? = nil, gizmo: TransformGizmo? = nil, frame: Frame? = nil,
                        start: CGPoint? = nil) -> Session {
            Session(gizmo: gizmo ?? self.gizmo, handle: handle ?? self.handle, start: start ?? self.start,
                    projection: projection, eye: eye, snapshot: snapshot, neighbours: neighbours,
                    followers: followers, carriedOnly: carriedOnly, edit: edit, points: points,
                    proportional: proportional, pivot: pivot, snap: snap, snapSource: snapSource,
                    geometry: geometry, autoMerge: autoMerge, originsOnly: originsOnly,
                    proportionalDefaults: proportionalDefaults, frame: frame ?? self.frame,
                    snapInversion: snapInversion, snapInverted: snapInverted)
        }
    }

    /// The snapping a drag would have with the magnet the other way round,
    /// for Ctrl held during it. Worked out once, the first time it is asked
    /// for, from what the drag took when it began: whatever moves is already
    /// left out of the targets, so the preview's moved geometry is never
    /// something to snap onto.
    final class SnapInversion {
        private let build: () -> (snap: TransformSnap?, geometry: GeometrySnapping?)
        private var built: (snap: TransformSnap?, geometry: GeometrySnapping?)?

        init(_ build: @escaping () -> (snap: TransformSnap?, geometry: GeometrySnapping?)) {
            self.build = build
        }

        var inverted: (snap: TransformSnap?, geometry: GeometrySnapping?) {
            if let built { return built }
            let b = build()
            built = b
            return b
        }
    }

    /// Blender's orientation for one drag.
    struct Frame {
        /// Nil for a custom orientation (Create Orientation's), sent as its
        /// matrix alone.
        let orientation: TransformOrientation?
        /// The gizmo's axes as the commit prints them, six places: what
        /// Blender multiplies the values by (`spacemtx`), and so what the
        /// preview does.
        let axes: simd_float3x3
        /// The view's, for the redo panel's View.
        let viewAxes: simd_float3x3
    }

    /// The curve or lattice a drag in its Edit Mode moves the points of, and
    /// the objects whose geometry follows them — a mesh under its Lattice
    /// modifier, a curve bevelled by this one — mirrored with every frame.
    struct PointDrag {
        let object: BKObject
        let followers: [String]
    }

    /// An object carried along by a moving ancestor.
    struct Follower {
        let object: BKObject
        let matrix: simd_float4x4
        /// Whether `matrix` was the mirror's `matrix_world`, which the
        /// roll-back puts back as it was, rather than the object's channels.
        let mirrored: Bool
        let pose: ObjectPose
        let parent: BKObject
    }

    /// What a move can snap onto, and what it snaps with.
    struct GeometrySnapping {
        let targets: GeometrySnap.Targets
        /// Where Snap With measures from. For Closest, every candidate — each
        /// moving object's bounding-box corners, or each selected vertex — and
        /// the one nearest the target moves onto it (snap_source_closest_fn);
        /// for the others, the one point.
        let sources: [SIMD3<Float>]
    }

    /// The edit-mode half of a session.
    struct EditDrag {
        let object: BKObject
        /// The object's `editCage` at touch-down: what the preview moves and
        /// what the roll-back puts back.
        let mesh: MeshData
        let vertices: Set<Int>
        /// The object's matrix at touch-down: the drag works in world space
        /// and the mesh does not.
        let model: simd_float4x4
        /// Every vertex's share of the transform — 1 for the selection, the
        /// proportional weight for the rest — measured once, from the mesh
        /// as it was, as Blender measures it once per transform.
        let factors: [Float]
        /// The object's Mirror modifiers with Clipping on: the commit keeps
        /// vertices from crossing their planes, so the preview does too.
        let clipping: [MirrorClip]
        /// Vertices Blender has hidden, which its transform leaves alone.
        var hidden: Set<Int> = []
        /// The mesh's X / Y / Z symmetry, as the mirror read it at
        /// touch-down: which vertices follow which. Nil with every axis
        /// off. Non-nil is also what makes the commit say `mirror=True`, so
        /// the preview and the commit mirror together or not at all.
        var symmetry: SymmetricEdit? = nil
    }

    /// `wireframe`: the viewport is in Wireframe shading, where Blender's
    /// factory settings have X-Ray on (`show_xray_wireframe`, measured True in
    /// 5.2.1 with `xray_alpha_wireframe` 0.0), and this app draws every edge.
    static func beginSession(handle: Handle, at point: CGPoint, gizmo: TransformGizmo,
                             scene: BKScene, camera: ViewportCamera, size: CGSize,
                             options: ViewportOptions = ViewportOptions(),
                             wireframe: Bool = false) -> Session {
        let targets = scene.objects.filter { scene.selection.contains($0.id) && $0.visible }
        // Blender's own tool settings, mirrored onto the scene — not a copy
        // kept in the interface. Captured now so a menu touched mid-drag
        // cannot change what the release commits.
        let tools = scene.tools
        let editing = scene.mode == .edit
        // The size as the commit prints it (five places), for the reason
        // `committed` gives.
        let proportional = tools.isProportional(editing: editing)
            ? ProportionalEdit(falloff: tools.falloff, size: (tools.size * 100_000).rounded() / 100_000,
                               connected: tools.connected)
            : nil

        var edit: EditDrag?
        var points: PointDrag?
        var sources: [SIMD3<Float>] = targets.map(\.location)
        if editing, let (obj, cage) = scene.editedPoints {
            let followers = scene.objects.filter { scene.dependents(of: [obj.id]).contains($0.id) && $0.id != obj.id }
            points = PointDrag(object: obj, followers: followers.map(\.name))
            sources = cage.transformCentres(model: obj.modelMatrix)
        } else if editing, let obj = scene.active, !obj.editsPoints, !scene.editSelection.vertices.isEmpty {
            // What the commit moves (`editCage`): the preview and the
            // roll-back install this, and installing the simulator's stack
            // output instead ran the stack over it again on every frame.
            let cage = obj.editCage
            let positions = cage.vertices.map(\.position)
            let model = obj.modelMatrix
            let selected = scene.editSelection.vertices.filter { $0 < positions.count }
            // Connected Only walks Blender's edges and polygons, which the
            // mirror describes when the viewport mesh is Blender's.
            let connectivity = proportional?.connected == true
                ? MeshConnectivity(mesh: cage, topology: obj.editTopology) : nil
            let hidden = obj.hiddenEditVertices
            // Blender's own edges, in its order, for Topology Mirror; the
            // simulator, which has no report, pairs by the triangles' edges.
            let known = obj.editTopology.flatMap { $0.describes(cage) ? $0 : nil }
            let edges = known.flatMap { $0.blenderEdges.isEmpty ? nil : $0.blenderEdges } ?? cage.edges
            // Blender pairs mirror images on its edit mesh's coordinates, and
            // `cage` is the evaluated mesh: under a SimpleDeform or a
            // Shrinkwrap shown in edit mode they differ, and pairing on what
            // is drawn found no image for a vertex Blender moved with its
            // image (EditTopology.blenderPositions).
            let blender = known.flatMap { $0.blenderPositions.count == positions.count ? $0.blenderPositions : nil }
            let symmetry = SymmetricEdit(positions: blender ?? positions, shown: blender == nil ? nil : positions,
                                         selected: selected, hidden: hidden,
                                         symmetry: obj.symmetry, proportional: proportional != nil,
                                         edges: edges)
            edit = EditDrag(object: obj, mesh: cage, vertices: selected, model: model,
                            factors: TransformOperation.vertexFactors(
                                positions: positions, selected: selected, model: model,
                                proportional: proportional, connectivity: connectivity,
                                hidden: hidden, symmetry: symmetry),
                            clipping: MirrorClip.clipping(obj.modifiers), hidden: hidden,
                            symmetry: symmetry)
            sources = selected.filter { $0 < positions.count }
                .map { (model * SIMD4(positions[$0], 1)).xyz }
        }

        let moving = Set(targets.map(\.id))
        // A turn or a scale about Individual Origins commits through
        // `transform_individual`, one object at a time; everything else is
        // one operator.
        let oneAtATime = edit == nil && points == nil && tools.pivot == .individualOrigins && gizmo.mode != .translate
        var neighbours: [(object: BKObject, pose: ObjectPose, factor: Float)] = []
        if edit == nil, points == nil, let proportional {
            // Every visible object the selection does not hold is in reach:
            // measured in 5.2.1, an unselected light, camera and empty moved
            // with the selected cube, and a hidden cube did not. Not the
            // selection's parents: measured, a parent 1 away stayed put on a
            // move of 1 at Linear size 3 (BA_TRANSFORM_PARENT). Its children
            // are, whatever `count_proportional_objects` says of
            // BA_TRANSFORM_CHILD: measured, a child 1 away moved 1.667 — its
            // parent's 1 and its own 0.667. `transform_individual` leaves
            // them out itself (`_in_reach`), so it does here too.
            var skip = scene.ancestors(of: moving)
            if oneAtATime { skip.formUnion(scene.carried(by: moving).map(\.object.id)) }
            let others = scene.objects.filter {
                !scene.selection.contains($0.id) && $0.visible && !skip.contains($0.id)
            }
            let factors = TransformOperation.objectFactors(selected: targets.map(\.location),
                                                           neighbours: others.map(\.location),
                                                           proportional: proportional)
            neighbours = zip(others, factors).filter { $0.1 > 0 }
                .map { ($0.0, ObjectPose($0.0), $0.1) }
        }
        // What moves carries its children (ObjectRelations.swift), so the
        // preview does too; see `apply`.
        var followers: [Follower] = []
        var carriedOnly: Set<UUID> = []
        // Affect Only Parents (`use_transform_skip_children`) leaves every
        // unselected child where it is, measured in 5.2.1: a parent moved by
        // 1, turned or scaled, and its child stayed at x = 3, where this
        // preview carried it to 4 and the commit put it back. A selected child
        // is part of the selection and still moves (measured: to 4).
        var stayed: Set<UUID> = []
        if edit == nil, points == nil {
            followers = scene.carried(by: moving.union(neighbours.map(\.object.id))).map { object, parent in
                Follower(object: object, matrix: object.modelMatrix,
                         mirrored: object.mirroredTransform != nil,
                         pose: ObjectPose(object), parent: parent)
            }
            if tools.affectOnlyParents {
                stayed = Set(followers.lazy.filter { !moving.contains($0.object.id) }.map(\.object.id))
                followers.removeAll { stayed.contains($0.object.id) }
            }
            if !oneAtATime {
                carriedOnly = moving.intersection(scene.carried(by: moving).map(\.object.id))
            }
        }
        let originsOnly = edit == nil && points == nil && tools.affectOnlyOrigins

        let median = sources.isEmpty ? gizmo.origin
                                     : sources.reduce(SIMD3<Float>.zero, +) / Float(sources.count)
        let snapSource: SIMD3<Float>
        switch tools.target {
        case .closest, .median:
            // Closest uses the median once the target is the grid
            // (snap_source_closest_fn).
            snapSource = median
        case .center:
            snapSource = gizmo.origin
        case .active:
            // The active object when it is part of the selection. An edit
            // selection here carries no active element, and Blender falls
            // back to the median without one.
            if edit == nil, points == nil, let active = scene.active, targets.contains(where: { $0.id == active.id }) {
                snapSource = active.location
            } else {
                snapSource = median
            }
        }

        let projection = Projection(camera: camera, size: size)
        // The magnet as the scene has it, and turned the other way for Ctrl
        // held during the drag (built only if Ctrl asks).
        func snapping(useSnap: Bool) -> (snap: TransformSnap?, geometry: GeometrySnapping?) {
            var tools = tools
            tools.useSnap = useSnap
            var geometry: GeometrySnapping?
            if gizmo.mode == .translate, tools.useSnap, !tools.elements.isDisjoint(with: GeometrySnap.honoured) {
                // Everything that moves is left out. In object mode that is the
                // selection and whatever moves with it — children, constraint
                // followers, objects whose modifiers read it (ObjectRelations) —
                // and with proportional editing everything it may pull along.
                // While editing it is every vertex with a share of the drag, and
                // the hidden; other objects stay in reach, selected or not, since
                // Blender's NOT_SELECTED applies in object mode only, unless
                // Target Selection leaves out the edited object or the rest.
                var excludedObjects: Set<UUID>
                if let points {
                    // The edited curve or lattice moves under the drag, and so
                    // does whatever follows it; the rest of the scene is in reach,
                    // unless Target Selection leaves it out.
                    excludedObjects = scene.dependents(of: [points.object.id]).union([points.object.id])
                    if !tools.snapNonEdited {
                        excludedObjects.formUnion(scene.objects.lazy.filter { $0 !== points.object }.map(\.id))
                    }
                } else if let edit {
                    excludedObjects = tools.snapSelf ? [] : [edit.object.id]
                    if !tools.snapNonEdited {
                        excludedObjects.formUnion(scene.objects.lazy.filter { $0 !== edit.object }.map(\.id))
                    }
                } else if originsOnly {
                    // Moving origins, Blender snaps onto anything, the selection's
                    // own geometry included (SCE_SNAP_TARGET_ALL for
                    // CTX_OBMODE_XFORM_OBDATA in 5.3's
                    // snap_target_select_from_spacetype_and_tool_settings: "allow
                    // snapping onto our own geometry", #69132). Read, not measured:
                    // a headless Blender has no 3D View to snap in.
                    excludedObjects = []
                } else {
                    excludedObjects = scene.selection.union(
                        scene.movedByObjectDrag(selection: moving, proportional: proportional != nil))
                    // A child Affect Only Parents keeps in place is locked there
                    // and loses BA_SNAP_FIX_DEPS_FIASCO (transform_convert_object.cc
                    // in 5.3), so it stays a target — unless something else it
                    // depends on moves it.
                    if !stayed.isEmpty {
                        let movingNames = Set(scene.objects.lazy.filter { excludedObjects.contains($0.id) }.map(\.name))
                        for object in scene.objects where stayed.contains(object.id) {
                            let others = object.dependencies.subtracting(object.parentName.map { [$0] } ?? [])
                            if others.isDisjoint(with: movingNames) { excludedObjects.remove(object.id) }
                        }
                    }
                }
                // A symmetry follower moves with the drag as well, so it is no
                // more a place to land than the vertices that move it.
                let edited = edit.map { e in
                    GeometrySnap.Edited(object: e.object,
                                        excluded: Set(e.factors.indices.filter { e.factors[$0] > 0 })
                                            .union(e.hidden).union(e.symmetry?.followerSet ?? []))
                }
                let view = GeometrySnap.View(viewProjection: projection.matrix,
                                             size: SIMD2(Float(size.width), Float(size.height)))
                let found = GeometrySnap.Targets(objects: scene.objects, view: view, elements: tools.elements,
                                                 excludedObjects: excludedObjects, edited: edited,
                                                 occlusion: !(options.xray || wireframe))
                // Closest tries each object's bound box corners — its origin
                // when only origins move (`snap_source_closest_fn` skips the box
                // for CTX_OBMODE_XFORM_OBDATA).
                let withPoints = tools.target == .closest
                    ? (edit == nil && points == nil
                        ? (originsOnly ? targets.map(\.location) : targets.flatMap(GeometrySnap.boxCorners))
                        : sources)
                    : [snapSource]
                if !found.isEmpty, !withPoints.isEmpty {
                    geometry = GeometrySnapping(targets: found, sources: withPoints)
                }
            }
            return (TransformSnap(tools: tools, step: options.snapIncrement), geometry)
        }
        let current = snapping(useSnap: tools.useSnap)
        let inversion = SnapInversion { snapping(useSnap: !tools.useSnap) }

        return Session(gizmo: gizmo, handle: handle, start: point,
                       projection: projection,
                       eye: camera.eye,
                       snapshot: targets.map { ($0, $0.location, $0.rotation, $0.scale) },
                       neighbours: neighbours,
                       followers: followers,
                       carriedOnly: carriedOnly,
                       edit: edit,
                       points: points,
                       proportional: proportional,
                       pivot: tools.pivot,
                       snap: current.snap,
                       snapSource: snapSource,
                       geometry: current.geometry,
                       autoMerge: editing && points == nil && tools.autoMerge ? tools.mergeThreshold : nil,
                       originsOnly: originsOnly,
                       proportionalDefaults: ProportionalEdit(
                           falloff: tools.falloff, size: (tools.size * 100_000).rounded() / 100_000,
                           connected: tools.connected),
                       frame: Frame(orientation: scene.orientation.type,
                                    axes: OrientationBpy.printed(simd_float3x3(gizmo.axes[0], gizmo.axes[1],
                                                                               gizmo.axes[2])),
                                    viewAxes: OrientationBpy.printed(viewAxes(camera))),
                       snapInversion: inversion)
    }

    /// What a drag to `point` amounts to. Reported in gizmo space, which is
    /// what the Python echo needs as well.
    enum Result: Equatable {
        case translate(SIMD3<Float>)
        case rotate(axis: SIMD3<Float>, angle: Float, axisIndex: Int?)
        case scale(SIMD3<Float>)
    }

    static func resolve(_ session: Session, at point: CGPoint) -> Result? {
        let g = session.gizmo
        let p = session.projection
        guard let centre = p.project(g.origin) else { return nil }

        switch g.mode {
        case .translate:
            switch session.handle {
            case .axis(let i):
                // Project the drag onto the axis as it appears on screen, then
                // convert back with the axis's own on-screen length. This is
                // what makes a shaft pointing nearly at the camera still
                // usable: it just needs a longer drag per world unit.
                guard let tip = p.project(g.origin + g.axes[i] * g.radius) else { return nil }
                let dir = CGPoint(x: tip.x - centre.x, y: tip.y - centre.y)
                let lengthPx = hypot(dir.x, dir.y)
                guard lengthPx > 1 else { return nil }
                let unit = CGPoint(x: dir.x / lengthPx, y: dir.y / lengthPx)
                let moved = CGPoint(x: point.x - session.start.x, y: point.y - session.start.y)
                let along = moved.x * unit.x + moved.y * unit.y
                let t = Float(along / lengthPx) * g.radius
                return .translate(g.axes[i] * t)

            case .plane(let i):
                // Intersecting the touch ray with the handle's plane tracks the
                // finger exactly, which a screen-space approximation does not.
                guard let a = g.planeHit(session.start, normal: g.axes[i], session: session),
                      let b = g.planeHit(point, normal: g.axes[i], session: session)
                else { return nil }
                return .translate(b - a)

            case .screen:
                // The view plane: the same drag Blender gives you for a bare G.
                let n = normalize(session.eye - g.origin)
                guard let a = g.planeHit(session.start, normal: n, session: session),
                      let b = g.planeHit(point, normal: n, session: session)
                else { return nil }
                return .translate(b - a)
            }

        case .rotate:
            let a0 = atan2(session.start.y - centre.y, session.start.x - centre.x)
            let a1 = atan2(point.y - centre.y, point.x - centre.x)
            var delta = Float(a1 - a0)
            // Keep the angle continuous across the ±pi seam.
            while delta >  Float.pi { delta -= 2 * .pi }
            while delta < -Float.pi { delta += 2 * .pi }

            switch session.handle {
            case .axis(let i):
                // Screen Y runs down, so a clockwise screen sweep is a positive
                // rotation about an axis pointing away from the eye and a
                // negative one about an axis pointing at it.
                let facing = dot(g.axes[i], normalize(session.eye - g.origin))
                return .rotate(axis: g.axes[i], angle: facing >= 0 ? -delta : delta, axisIndex: i)
            case .screen, .plane:
                let view = normalize(session.eye - g.origin)
                return .rotate(axis: view, angle: -delta, axisIndex: nil)
            }

        case .scale:
            // Scale reads as a ratio of distances from the centre, so releasing
            // where you started is exactly 1.0 and nothing drifts.
            let d0 = max(distance(session.start, centre), 8)
            let d1 = max(distance(point, centre), 1)
            switch session.handle {
            case .axis(let i):
                guard let tip = p.project(g.origin + g.axes[i] * g.radius) else { return nil }
                let dir = CGPoint(x: tip.x - centre.x, y: tip.y - centre.y)
                let lengthPx = hypot(dir.x, dir.y)
                guard lengthPx > 1 else { return nil }
                let unit = CGPoint(x: dir.x / lengthPx, y: dir.y / lengthPx)
                let p0 = (session.start.x - centre.x) * unit.x + (session.start.y - centre.y) * unit.y
                let p1 = (point.x - centre.x) * unit.x + (point.y - centre.y) * unit.y
                // Below the centre the projection flips sign; clamp so a drag
                // through the origin does not mirror the object.
                let f = Float(max(p1, 4) / max(p0, 4))
                var v = SIMD3<Float>(repeating: 1)
                v[i] = max(f, 0.001)
                return .scale(v)
            case .plane(let i):
                let f = Float(d1 / d0)
                var v = SIMD3<Float>(repeating: max(f, 0.001))
                v[i] = 1
                return .scale(v)
            case .screen:
                return .scale(SIMD3(repeating: max(Float(d1 / d0), 0.001)))
            }
        }
    }

    /// The touch ray, in world space.
    static func ray(_ point: CGPoint, projection: Projection)
        -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let size = projection.size
        guard size.width > 0, size.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               1 - Float(point.y / size.height) * 2)
        let inv = projection.matrix.inverse
        let near = inv * SIMD4(ndc.x, ndc.y, 0, 1)
        let far  = inv * SIMD4(ndc.x, ndc.y, 1, 1)
        guard abs(near.w) > 1e-6, abs(far.w) > 1e-6 else { return nil }
        let o = near.xyz / near.w
        return (o, normalize(far.xyz / far.w - o))
    }

    /// Where the touch ray meets a plane through the gizmo origin.
    private func planeHit(_ point: CGPoint, normal: SIMD3<Float>, session: Session) -> SIMD3<Float>? {
        guard let (o, d) = Self.ray(point, projection: session.projection) else { return nil }
        let denom = dot(d, normal)
        // A plane seen edge-on gives no usable intersection.
        guard abs(denom) > 1e-4 else { return nil }
        let t = dot(origin - o, normal) / denom
        guard t > 0 else { return nil }
        return o + d * t
    }

    // MARK: snapping

    /// The drag's result with Blender's magnet applied: what the preview
    /// shows and, because `python` is written from the same value, what the
    /// release commits. See `snapping` for the target it found.
    static func snapped(_ result: Result, session: Session, at point: CGPoint) -> Result {
        snapping(result, session: session, at: point).result
    }

    /// The same, with the vertex, edge or face it snapped to, for the view to
    /// show. A move tries geometry first (GeometrySnap) and falls back to Grid,
    /// then Increment, when nothing is in reach, as Blender's
    /// `applyTranslation` does; `TransformSnap` says which of those does what.
    static func snapping(_ result: Result, session: Session,
                         at point: CGPoint) -> (result: Result, target: GeometrySnap.Hit?) {
        let g = session.gizmo
        if case .translate = result, let geometry = session.activeGeometry,
           let hit = geometry.targets.find(SIMD2(Float(point.x), Float(point.y))),
           let source = GeometrySnap.closest(geometry.sources, to: hit.location) {
            let constraint: GeometrySnap.Constraint
            switch session.handle {
            case .axis(let i):  constraint = .axis(g.axes[i])
            case .plane(let i): constraint = .plane(normal: g.axes[i])
            case .screen:       constraint = .free
            }
            return (.translate(GeometrySnap.move(source, to: hit, constraint: constraint)), hit)
        }
        guard let snap = session.activeSnap else { return (result, nil) }
        switch result {
        case .translate(let delta):
            let constraint: TransformSnap.Constraint
            switch session.handle {
            case .axis(let i):  constraint = .axis(i)
            case .plane(let i): constraint = .plane(i)
            case .screen:       constraint = .free
            }
            return (.translate(snap.translate(delta, constraint: constraint, axes: g.axes,
                                             pivot: g.origin, source: session.snapSource,
                                             ray: ray(point, projection: session.projection),
                                             viewNormal: normalize(session.eye - g.origin))), nil)
        case .rotate(let axis, let angle, let index):
            return (.rotate(axis: axis, angle: snap.angle(angle), axisIndex: index), nil)
        case .scale(let factors):
            return (.scale(snap.factors(factors)), nil)
        }
    }

    // MARK: applying

    /// What `python` writes: four places, as Blender's Info log does.
    private static func printed(_ x: Float, places: Int = 4) -> Float {
        // In Double at six places: x × 10⁶ runs out of Float's 24 bits by 17.
        // Plus zero, so an axis move's other two read 0 rather than -0.
        places == 6 ? Float((Double(x) * 1_000_000).rounded() / 1_000_000) + 0
                    : (x * 10_000).rounded() / 10_000
    }

    /// A move that may snap to geometry is written to six places: rounded to
    /// four, a snapped vertex could stop up to 5e-5 per axis beside its
    /// target, and a snap is meant to make the two coincide.
    static func places(_ session: Session) -> Int { session.activeGeometry == nil ? 4 : 6 }

    /// A result as the commit spells it. The preview runs these numbers
    /// rather than the unrounded drag, so the two agree to the digit: a scale
    /// of 10 about a `center_override` printed 5e-5 off moved a vertex 5e-4
    /// away from where the preview had put it (measured against Blender
    /// 5.2.1 in scripts/run-tools-blender-check.sh).
    static func committed(_ result: Result, places: Int = 4) -> Result {
        func round3(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(printed(v.x), printed(v.y), printed(v.z)) }
        switch result {
        case .translate(let d):
            return .translate(SIMD3(printed(d.x, places: places), printed(d.y, places: places),
                                    printed(d.z, places: places)))
        case .rotate(let axis, let angle, let i): return .rotate(axis: axis, angle: printed(angle), axisIndex: i)
        case .scale(let f):                    return .scale(round3(f))
        }
    }

    /// The pivot as `center_override` spells it.
    static func committedPivot(_ session: Session) -> SIMD3<Float> {
        let p = session.gizmo.origin
        return SIMD3(printed(p.x), printed(p.y), printed(p.z))
    }

    /// The commit a result amounts to, as the values the redo panel shows:
    /// a move's in the orientation's axes, as Blender's exec takes them
    /// (`global_dir = spacemtx · values`, transform_mode_translate.cc), and a
    /// rotation about the orientation's axis. The view ring turns about the
    /// view's own axis, as an orientation whose Z is that axis — Blender has
    /// no axis called VIEW (`viewRotationArguments`).
    static func gizmoCommit(_ result: Result, session: Session, afterward: String? = nil) -> GizmoCommit {
        let frame = session.frame
        var orientation = frame.orientation
        var axes = frame.axes
        var viewAxes = frame.viewAxes
        let kind: GizmoCommit.Kind
        switch result {
        case .translate(let d):
            let inverse = abs(axes.determinant) > 1e-12 ? axes.inverse : axes.transpose
            kind = .translate(values: inverse * d, constraint: session.handle.constraintMask)
        case .rotate(let axis, let angle, let index):
            if let index {
                kind = .rotate(angle: angle, axis: index)
            } else {
                orientation = .view
                axes = OrientationBpy.printed(viewRotationMatrix(axis: axis))
                viewAxes = axes
                kind = .rotate(angle: angle, axis: 2)
            }
        case .scale(let f):
            kind = .resize(values: f, constraint: session.handle.constraintMask)
        }
        let tools = session.proportionalDefaults
        return GizmoCommit(kind: kind, orientation: orientation, axes: axes, viewAxes: viewAxes,
                           editing: session.edit != nil,
                           mirror: session.edit?.symmetry != nil,
                           proportional: session.proportional, proportionalDefaults: tools,
                           centre: committedPivot(session),
                           individualOrigins: session.usesIndividualOrigins,
                           places: places(session), afterward: afterward)
    }

    /// The commit as the operator the bridge performs, the redo panel adjusts
    /// and the Info log shows.
    static func commitOperator(_ result: Result, session: Session, afterward: String? = nil) -> LastOperator {
        var commit = gizmoCommit(result, session: session, afterward: afterward)
        if case .translate = commit.kind { commit.centre = nil }
        return .gizmo(commit)
    }

    /// The operator a result amounts to, as values — what the preview runs
    /// here. Built back from the numbers the commit prints, so the two agree
    /// to the digit: a scale of 10 about a `center_override` printed 5e-5 off
    /// moved a vertex 5e-4 away from where the preview had put it (measured
    /// against Blender 5.2.1 in scripts/run-tools-blender-check.sh).
    static func operation(_ result: Result, session: Session) -> TransformOperation {
        let pivot: TransformOperation.Pivot = session.usesIndividualOrigins
            ? .individualOrigins : .point(committedPivot(session))
        let commit = gizmoCommit(result, session: session)
        let op = LastOperator.gizmo(commit)
        switch commit.kind {
        case .translate:
            let values = LastOperator.committedValues(op) ?? .zero
            return TransformOperation(kind: .translate(commit.axes * values), pivot: pivot,
                                      proportional: session.proportional)
        case .rotate(_, let index):
            let angle = LastOperator.committedAngle(op) ?? 0
            let axis = [commit.axes.columns.0, commit.axes.columns.1, commit.axes.columns.2][index]
            return TransformOperation(kind: .rotate(axis: axis, angle: angle), pivot: pivot,
                                      proportional: session.proportional)
        case .resize:
            let values = LastOperator.committedValues(op) ?? SIMD3(repeating: 1)
            let orientation: TransformOperation.Orientation
            switch commit.orientation {
            case .global?: orientation = .global
            case .local?:  orientation = .local
            default:       orientation = .axes(commit.axes)
            }
            return TransformOperation(kind: .resize(values), pivot: pivot, orientation: orientation,
                                      proportional: session.proportional)
        }
    }

    /// Paints a result onto the display cache: the live preview.
    ///
    /// Snap the result first (`snapped`); this applies exactly what it is
    /// given, which is also exactly what `python` sends.
    static func apply(_ result: Result, session: Session) {
        // Blender previews a curve's or a lattice's points itself.
        guard session.points == nil else { return }
        let operation = operation(result, session: session)

        // Edit mode moves the geometry, not the object holding it.
        if let edit = session.edit {
            // The mirror left Blender nothing to transform: the commit comes
            // back CANCELLED and welds nothing either (SymmetricEdit.cancels).
            if edit.symmetry?.cancels == true {
                edit.object.installTransformed(edit.mesh)
                return
            }
            let moved = operation.apply(toVertices: edit.mesh.vertices.map(\.position),
                                        factors: edit.factors, selected: edit.vertices,
                                        model: edit.model, clipping: edit.clipping,
                                        hidden: edit.hidden, symmetry: edit.symmetry)
            var mesh = edit.mesh
            for i in mesh.vertices.indices { mesh.vertices[i].position = moved[i] }
            ModifierStack.recomputeNormals(&mesh, welded: true)
            // A flat face is drawn by its face's normal, which Blender sends
            // at the commit: until then it turns with the face.
            mesh.carryShading(from: edit.mesh)
            // Blender welds after the transform, not during, so each frame
            // welds a copy of the mesh as it was: merging the mesh itself
            // mid-drag would destroy vertices the rest of the drag needs.
            // With symmetry the followers weld as well: Blender tags them and
            // merges SELECT | TAG (special_aftertrans_update__mesh).
            if let threshold = session.autoMerge {
                let welded = edit.symmetry.map { edit.vertices.union($0.followerSet) } ?? edit.vertices
                mesh = AutoMerge.weld(mesh, moved: welded, threshold: threshold)
            }
            edit.object.installTransformed(mesh)
            return
        }

        let selected = session.snapshot.map {
            ObjectPose(location: $0.location, rotation: $0.rotation, scale: $0.scale)
        }
        let before = selected + session.neighbours.map(\.pose)
        let poses = operation.apply(to: before,
                                    factors: Array(repeating: 1, count: selected.count)
                                        + session.neighbours.map(\.factor),
                                    selectedLocations: selected.map(\.location))
        let objects = session.snapshot.map(\.object) + session.neighbours.map(\.object)
        // Affect Only Origins: measured in 5.2.1, a translate, rotate or
        // resize moved the origin and left the geometry's world position as
        // it was (min x -1.000 before and after), while the child followed
        // the origin to x = 4. So nothing selected is drawn moving, and the
        // children below still are.
        if !session.originsOnly {
            for (object, pose) in zip(objects, poses) { place(object, pose) }
        }
        guard !session.followers.isEmpty else { return }

        // A child's world matrix is its parent's times what parenting keeps
        // fixed, so each one carried moves by the change in its parent's
        // matrix, on top of any share of the move it has of its own. Measured
        // in 5.2.1 on a parent chain, a move of 1 and a turn of 0.6 at Linear
        // size 3: every object landed on (parent after × parent before⁻¹) ×
        // (its own share applied where it stood), parents first.
        var old: [UUID: simd_float4x4] = [:], new: [UUID: simd_float4x4] = [:]
        for (object, (pose, moved)) in zip(objects, zip(before, poses)) {
            old[object.id] = matrix(pose)
            new[object.id] = session.carriedOnly.contains(object.id) ? matrix(pose) : matrix(moved)
        }
        // With Affect Only Origins a selected child's geometry stays too,
        // though its origin is carried and carries its own children (measured
        // in 5.2.1: A and its child C selected, C's geometry stayed at 2.00,
        // its origin went 3 → 4 and C's unselected child followed to 3.00).
        let keepGeometry = session.originsOnly ? Set(session.snapshot.map(\.object.id)) : []
        for follower in session.followers {
            guard let parentBefore = old[follower.parent.id], let parentAfter = new[follower.parent.id]
            else { continue }
            let own = new[follower.object.id] ?? follower.matrix
            let carried = parentAfter * parentBefore.inverse * own
            if old[follower.object.id] == nil { old[follower.object.id] = follower.matrix }
            new[follower.object.id] = carried
            if !keepGeometry.contains(follower.object.id) { follower.object.setMirroredTransform(carried) }
        }
    }

    /// The matrix `modelMatrix` composes from an object's channels.
    private static func matrix(_ pose: ObjectPose) -> simd_float4x4 {
        simd_float4x4(translation: pose.location) * simd_float4x4(eulerXYZ: pose.rotation)
            * simd_float4x4(scale: pose.scale)
    }

    private static func place(_ object: BKObject, _ pose: ObjectPose) {
        // Only what changed: each write redraws every reader of the object.
        if object.location != pose.location { object.location = pose.location }
        if object.rotation != pose.rotation { object.rotation = pose.rotation }
        if object.scale != pose.scale { object.scale = pose.scale }
    }

    /// Puts everything back where the drag started.
    ///
    /// Used before committing through bpy: the live drag was a preview painted
    /// straight onto the display cache, and applying the operator on top of it
    /// would transform twice.
    static func rollBack(_ session: Session) {
        guard session.points == nil else { return }
        if let edit = session.edit {
            edit.object.installTransformed(edit.mesh)
            return
        }
        for entry in session.snapshot {
            place(entry.object, ObjectPose(location: entry.location, rotation: entry.rotation,
                                           scale: entry.scale))
        }
        for neighbour in session.neighbours { place(neighbour.object, neighbour.pose) }
        for follower in session.followers {
            if follower.mirrored {
                follower.object.setMirroredTransform(follower.matrix)
            } else {
                place(follower.object, follower.pose)
            }
        }
    }

    /// What the drag is doing, in Blender's own header wording.
    ///
    /// Blender writes `D: 0.4521 (0.4521) global X` across its header while a
    /// transform is live, and that readout is most of how you know a drag has
    /// taken hold at all — the object moving under a finger is ambiguous when
    /// the finger is covering it, and with a trackpad or a Pencil there is no
    /// contact to feel. Same wording here, so the habit carries over, and the
    /// distances are in the orientation's axes, as Blender's are.
    static func readout(_ result: Result, session: Session) -> String {
        let axisName: (Int) -> String = { ["X", "Y", "Z"][$0] }
        let space = (session.frame.orientation?.label ?? "custom").lowercased()
        switch result {
        case .translate(let world):
            let m = session.frame.axes
            let d = abs(m.determinant) > 1e-12 ? m.inverse * world : world
            switch session.handle {
            case .axis(let i):
                return String(format: "D: %.4f  along %@ %@", d[i], space, axisName(i))
            case .plane(let i):
                let shown = (0..<3).filter { $0 != i }
                return String(format: "D: %.4f, %.4f  in %@ %@%@ plane",
                              d[shown[0]], d[shown[1]], space,
                              axisName(shown[0]), axisName(shown[1]))
            case .screen:
                return String(format: "D: %.4f, %.4f, %.4f  %@", d.x, d.y, d.z, space)
            }
        case .rotate(_, let angle, let index):
            let degrees = angle * 180 / .pi
            guard let index else { return String(format: "Rot: %.2f°  view", degrees) }
            return String(format: "Rot: %.2f°  around %@ %@", degrees, space, axisName(index))
        case .scale(let f):
            switch session.handle {
            case .axis(let i):
                return String(format: "S: %.4f  along %@ %@", f[i], space, axisName(i))
            case .plane(let i):
                let shown = (0..<3).filter { $0 != i }
                return String(format: "S: %.4f, %.4f  in %@ %@%@ plane",
                              f[shown[0]], f[shown[1]], space,
                              axisName(shown[0]), axisName(shown[1]))
            case .screen:
                return String(format: "S: %.4f", f.x)
            }
        }
    }

    /// The call this drag commits, as the Info log shows it: what a curve's
    /// or a lattice's point drag previews each frame with, and what the
    /// release performs (`commitOperator`).
    static func python(_ result: Result, session: Session) -> String {
        commitOperator(result, session: session).python
    }

    /// The release: the preview rolled back, and the drag performed through
    /// Blender as the operator the redo panel then adjusts — undo and run
    /// again, as Blender's Adjust Last Operation does. With nothing for
    /// Blender to move, nothing is sent and the banner says why.
    @discardableResult
    static func commit(_ result: Result, session: Session, bridge: BpyBridge) -> BpyBridge.Outcome? {
        // A curve's or a lattice's points commit through their own drag
        // (`BpyBridge.commitPointDrag`), which Blender previewed frame by
        // frame; performed here, the call would run in Object Mode on the
        // object instead.
        guard session.points == nil else { return nil }
        rollBack(session)
        if let why = nothingToCommit(session) {
            bridge.showReport(session.gizmo.mode.undoName, why)
            return nil
        }
        // In edit mode the operator acts on Blender's *vertex* selection.
        // Whatever was tapped since Blender last reported its selection is
        // handed over by the bridge, in the same evaluation as the operator.
        let bare = commitOperator(result, session: session)
        let op = commitOperator(result, session: session, afterward: bridge.autoKeying(after: bare.python))
        return bridge.perform(op)
    }

    /// What a release says instead of committing, or nil to commit.
    ///
    /// With X, Y and Topology Mirror on, every selected vertex of Suzanne's
    /// ear became its own mirror's follower and Blender's translate moved 0
    /// vertices (measured in 5.2.1; `SymmetricEdit.cancels`). The preview
    /// shows that; sending the call anyway would put an undo step on the
    /// history for a command that changed nothing, with no word of why.
    static func nothingToCommit(_ session: Session) -> String? {
        guard session.edit?.symmetry?.cancels == true else { return nil }
        return "Nothing moved: with the mesh's mirror settings, every selected vertex is the mirror "
            + "image of another, so Blender has nothing left to transform. Select one side, or turn "
            + "an axis or Topology Mirror off."
    }

    /// A rotation about the view axis — the outer ring, or a free drag with
    /// the Rotate tool.
    ///
    /// Blender has no axis called VIEW to name: `orient_axis` is X, Y or Z, and
    /// `orient_axis='VIEW'` is a TypeError, which is what this used to send. So
    /// the view goes in the way Blender's own Info log writes a view rotation:
    /// as an orientation whose Z is the axis, rotated about Z. A headless
    /// Blender has no view of its own to take that orientation from, which is
    /// why it is spelled out rather than left to `orient_type='VIEW'` alone.
    ///
    /// The matrix's rows are the orientation's X, Y and Z, and the angle keeps
    /// its sign. Both were measured against the preview's rotation in Blender
    /// 5.2.1, in object and edit mode.
    static func viewRotationArguments(axis: SIMD3<Float>, angle: Float) -> [String] {
        let m = viewRotationMatrix(axis: axis)
        return [String(format: "value=%.4f", angle), "orient_axis='Z'", "orient_type='VIEW'",
                "orient_matrix=" + OrientationBpy.literal(m), "orient_matrix_type='VIEW'"]
    }

    /// The orientation a view-axis rotation is written in: Z the axis, X and
    /// Y any pair square to it.
    static func viewRotationMatrix(axis: SIMD3<Float>) -> simd_float3x3 {
        let z = normalize(axis)
        let helper: SIMD3<Float> = abs(z.z) < 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let x = normalize(cross(helper, z))
        let y = cross(z, x)
        return simd_float3x3(x, y, z)
    }
}

extension TransformGizmo {
    /// Whether a drag that missed every handle began on what a transform tool
    /// moves: a selected object, or while editing a selected vertex or face.
    ///
    /// Blender's Move tool moves what you take hold of; a drag that starts on
    /// empty space does something else. Here that something else is orbiting,
    /// because one finger is the only orbit a tablet has. Before this, any
    /// drag anywhere with a transform tool and a selection moved the
    /// selection, and the view could not be turned at all.
    static func startsOnSelection(_ point: CGPoint, scene: BKScene,
                                  camera: ViewportCamera, size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               1 - Float(point.y / size.height) * 2)
        let (origin, direction) = camera.ray(atNDC: ndc, aspect: Float(size.width / size.height))

        if let (obj, cage) = scene.editedPoints {
            // A selected control point under the finger: points have no area.
            guard obj.visible else { return false }
            let projection = Projection(camera: camera, size: size)
            return cage.selectedWorld(model: obj.modelMatrix).contains {
                projection.project($0).map { distance($0, point) < grabSlop } ?? false
            }
        }
        if scene.mode == .edit {
            // A curve or a lattice with no points (all deleted) has nothing
            // to take hold of, and no mesh selection: never a mesh's drag.
            guard let obj = scene.active, obj.visible, !obj.editsPoints else { return false }
            let selection = scene.editSelection
            guard !selection.vertices.isEmpty || !selection.faces.isEmpty else { return false }
            let mesh = obj.editCage
            let model = obj.modelMatrix
            // Close enough to a selected vertex — they have no area to hit.
            let projection = Projection(camera: camera, size: size)
            for i in selection.vertices where i < mesh.vertices.count {
                if let p = projection.project((model * SIMD4(mesh.vertices[i].position, 1)).xyz),
                   distance(p, point) < grabSlop {
                    return true
                }
            }
            // Or on the nearest face under the touch, when that face is selected.
            let inverse = model.inverse
            let o = (inverse * SIMD4(origin, 1)).xyz
            let d = normalize((inverse * SIMD4(direction, 0)).xyz)
            var nearest: (t: Float, selected: Bool)?
            for tri in 0..<(mesh.indices.count / 3) {
                let corners = (0..<3).map { Int(mesh.indices[3 * tri + $0]) }
                guard let t = rayTriangle(o, d, mesh.vertices[corners[0]].position,
                                          mesh.vertices[corners[1]].position,
                                          mesh.vertices[corners[2]].position),
                      t > 0, nearest == nil || t < nearest!.t
                else { continue }
                nearest = (t, selection.faces.contains(tri)
                              || corners.allSatisfy { selection.vertices.contains($0) })
            }
            return nearest?.selected ?? false
        }

        // A camera, light or empty is taken hold of by its lines, as a tap
        // takes it — unless a mesh face in front of them has the touch.
        if let picked = ObjectOverlayPicking.object(at: point, in: scene,
                                                    view: OverlayView(camera: camera, size: size)) {
            return scene.selection.contains(picked.id)
        }

        var nearest: (t: Float, object: BKObject)?
        for obj in scene.objects where obj.visible {
            let inverse = obj.modelMatrix.inverse
            let o = (inverse * SIMD4(origin, 1)).xyz
            let d = normalize((inverse * SIMD4(direction, 0)).xyz)
            let mesh = obj.mesh
            for tri in 0..<(mesh.indices.count / 3) {
                guard let t = rayTriangle(o, d,
                                          mesh.vertices[Int(mesh.indices[3 * tri])].position,
                                          mesh.vertices[Int(mesh.indices[3 * tri + 1])].position,
                                          mesh.vertices[Int(mesh.indices[3 * tri + 2])].position),
                      t > 0, nearest == nil || t < nearest!.t
                else { continue }
                nearest = (t, obj)
            }
        }
        guard let nearest else { return false }
        return scene.selection.contains(nearest.object.id)
    }

    /// Möller–Trumbore, two-sided, as the renderer's picking does it.
    private static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>,
                                    _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                    _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = cross(d, e2)
        let det = dot(e1, p)
        guard abs(det) > 1e-7 else { return nil }
        let invDet = 1 / det
        let t0 = o - a
        let u = dot(t0, p) * invDet
        guard u >= 0, u <= 1 else { return nil }
        let q = cross(t0, e1)
        let v = dot(d, q) * invDet
        guard v >= 0, u + v <= 1 else { return nil }
        return dot(e2, q) * invDet
    }
}

extension TransformGizmo {
    /// `ED_view3d_cursor_snap_draw_util`'s size: 2.5 × the theme's vertex size
    /// of 3, in points as the app takes Blender's pixels.
    static let snapMarkerRadius: CGFloat = 7.5

    /// Blender's symbol for what a move has snapped to (`cursor_point_draw`
    /// in view3d_cursor_snap.cc), as strokes in view coordinates: a square on
    /// a vertex, a bow tie on an edge, a triangle on an edge's centre, a
    /// circle on a face, a circle with a dot on a face's centre, and a circle
    /// with a cross on a loose vertex or an empty's origin. Blender draws them
    /// facing the view, so they are flat here too; y is flipped, since
    /// Blender's is up and a view's is down.
    static func snapMarker(_ kind: GeometrySnap.Kind, at c: CGPoint,
                           radius r: CGFloat = snapMarkerRadius) -> [(points: [CGPoint], closed: Bool)] {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y - y * r) }
        func circle(_ scale: CGFloat = 1) -> (points: [CGPoint], closed: Bool) {
            ((0..<24).map { i in
                let a = CGFloat(i) / 24 * 2 * .pi
                return at(cos(a) * scale, sin(a) * scale)
            }, true)
        }
        switch kind {
        case .point:
            return [circle(), ([at(-1, -1), at(1, 1)], false), ([at(-1, 1), at(1, -1)], false)]
        case .vertex:
            return [([at(-1, -1), at(-1, 1), at(1, 1), at(1, -1)], true)]
        case .edgeMidpoint:
            return [([at(-1, -1), at(0, 0.866), at(1, -1)], true)]
        case .edge:
            return [([at(-1, -1), at(1, 1), at(-1, 1), at(1, -1)], true)]
        case .faceMidpoint:
            // Blender's dot is one GL point; a small ring reads the same.
            return [circle(), circle(0.2)]
        case .face:
            return [circle()]
        }
    }
}

extension TransformGizmo.Handle {
    /// Blender writes the constraint as a three-bool tuple in its Info log.
    var constraintMask: String {
        switch self {
        case .axis(let i):  return "(\(i == 0 ? "True" : "False"), \(i == 1 ? "True" : "False"), \(i == 2 ? "True" : "False"))"
        case .plane(let i): return "(\(i == 0 ? "False" : "True"), \(i == 1 ? "False" : "True"), \(i == 2 ? "False" : "True"))"
        case .screen:       return "(False, False, False)"
        }
    }
}

// MARK: - small geometry helpers

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let vx = b.x - a.x, vy = b.y - a.y
    let lengthSquared = vx * vx + vy * vy
    guard lengthSquared > 1e-6 else { return distance(p, a) }
    let t = max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared))
    return distance(p, CGPoint(x: a.x + vx * t, y: a.y + vy * t))
}
