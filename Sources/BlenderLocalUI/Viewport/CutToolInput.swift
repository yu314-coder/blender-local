import SwiftUI
import MetalKit
import simd

/// What the Loop Cut tool remembers between one pointer move and the next:
/// the rings Blender has given for edges of the mesh as it is now, so moving
/// back and forth over a mesh asks once per edge.
struct LoopCutCache {
    var object: UUID?
    var revision = -1
    var rings: [Int: LoopCutRing] = [:]

    /// Forgets the rings unless they are about `object`'s mesh as the mirror
    /// last reported it (`editTopologyRevision`).
    mutating func reset(for object: BKObject) {
        if self.object != object.id || revision != object.editTopologyRevision {
            self.object = object.id
            revision = object.editTopologyRevision
            rings = [:]
        }
    }
}

/// The cage the Knife snaps to, kept while the mesh, its report and its
/// object's placement stay as they were (`knifeCage(for:)`), and where the
/// last tap snapped.
struct KnifeCageCache {
    var object: UUID?
    var revision = -1
    var key: [Float] = []
    var cage: KnifeCage?
    /// What the last Knife tap snapped to, for the DEBUG hook to print.
    var lastSnap: KnifeSnap.Snapped?
}

extension MetalViewportView.Coordinator {

    /// The cutting tool in hand, in Edit Mode, or nil.
    var cutTool: CutTool? {
        guard parent.scene.mode == .edit else { return nil }
        switch parent.tool {
        case .loopCut: return .loopCut
        case .knife:   return .knife
        default:       return nil
        }
    }

    private func ndc(_ point: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        SIMD2(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
    }

    // MARK: Loop Cut

    /// How many cuts the next Loop Cut makes: one, every time. Blender marks
    /// `MESH_OT_loopcut`'s Number of Cuts and Smoothness PROP_SKIP_SAVE
    /// (measured in 5.2.1: `is_skip_save`), so its next Loop Cut starts at 1
    /// whatever the last one made — editmesh_loopcut.cc keeps it from
    /// starting "_very_ high poly meshes … (or worse crash)". The redo
    /// panel's count changes the cut it belongs to, not the next one.
    func loopCutCuts() -> Int { 1 }

    /// The Blender edge under `point` and Blender's ring through it, or the
    /// reason there is none. Blender picks the edge nearest the pointer in
    /// any select mode (`loopcut_mouse_move`), so this picks edges whatever
    /// the header's mode is.
    func loopCutRing(at point: CGPoint, size: CGSize) -> (edge: Int, ring: LoopCutRing)?? {
        guard let renderer, let bridge = parent.bridge, let object = parent.scene.active,
              size.width > 0, size.height > 0 else { return nil }
        if let refusal = CutTool.loopCut.refusal(object: object, usesRealBlender: bridge.usesRealBlender) {
            loopCutRefusal = refusal
            return nil
        }
        guard let topology = object.editTopology else {
            loopCutRefusal = "The viewport's mesh of \(object.name) does not line up with Blender's yet. "
                + "Try again once it redraws."
            return nil
        }
        let hit = renderer.hitTestElement(ndc: ndc(point, size), aspect: Float(size.width / size.height),
                                          mode: .edge, viewSize: SIMD2(Float(size.width), Float(size.height)))
        guard let drawn = hit.edge else { return .some(nil) }
        guard let edge = LoopCut.blenderEdge(drawn: drawn, cage: object.editCage, topology: topology) else {
            return .some(nil)
        }
        loopCutCache.reset(for: object)
        if let ring = loopCutCache.rings[edge] { return (edge, ring) }
        guard let answer = bridge.capture(LoopCut.ringQuery(edge)) else { return nil }
        if let refusal = LoopCutRing.refusal(json: answer) {
            loopCutRefusal = refusal
            return nil
        }
        guard let ring = LoopCutRing(json: answer), ring.vertexCount == object.editCage.vertices.count else {
            loopCutRefusal = "Blender's mesh of \(object.name) is not the one on screen yet. Try again once it redraws."
            return nil
        }
        // A pointer swept over a dense mesh asks about many edges; a ring can
        // be thousands of them, so the cache keeps the latest few hundred.
        if loopCutCache.rings.count >= 256 { loopCutCache.rings = [:] }
        loopCutCache.rings[edge] = ring
        return (edge, ring)
    }

    /// The preview for `ring` with `cuts` cuts, in world space.
    func loopCutPreview(_ ring: LoopCutRing, edge: Int, cuts: Int, on object: BKObject) -> CutPreview? {
        let cage = object.editCage
        guard let local = ring.preview(cuts: cuts, positions: cage.vertices.map(\.position)) else { return nil }
        let model = object.modelMatrix
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { (model * SIMD4(p, 1)).xyz }
        return CutPreview(kind: .loopCut, lines: local.lines.map(world), points: local.points.map(world),
                          object: object.id, cageVertexCount: cage.vertices.count, blenderEdge: edge, cuts: cuts,
                          topologyRevision: object.editTopologyRevision)
    }

    /// The pointer is over `point`: Blender's ring through the edge under
    /// it, drawn — or nothing, without a word, where there is no edge or
    /// Loop Cut cannot cut (a tap says why).
    func loopCutHover(at point: CGPoint, size: CGSize) {
        guard let object = parent.scene.active, let found = loopCutRing(at: point, size: size),
              let pair = found else {
            if parent.scene.cutPreview?.kind == .loopCut { parent.scene.cutPreview = nil }
            return
        }
        let (edge, ring) = pair
        let cuts = loopCutCuts()
        if let shown = parent.scene.cutPreview, shown.kind == .loopCut, shown.blenderEdge == edge,
           shown.cuts == cuts, shown.holds(for: object) { return }
        parent.scene.cutPreview = loopCutPreview(ring, edge: edge, cuts: cuts, on: object)
    }

    /// A tap or a click: on the edge whose ring is showing, the cut; on
    /// another edge, its ring (a finger has no hover, so its first tap is
    /// the preview and the second the cut); on nothing, the ring goes. A
    /// refusal is said on the banner. Returns the operator it ran, if it cut.
    @discardableResult
    func loopCutTap(at point: CGPoint, size: CGSize) -> LastOperator? {
        loopCutRefusal = nil
        guard let object = parent.scene.active, let found = loopCutRing(at: point, size: size) else {
            parent.scene.cutPreview = nil
            if let refusal = loopCutRefusal { parent.bridge?.showReport(CutTool.loopCut.label, refusal) }
            return nil
        }
        guard let pair = found else {
            parent.scene.cutPreview = nil
            return nil
        }
        let (edge, ring) = pair
        let cuts = loopCutCuts()
        if let shown = parent.scene.cutPreview, shown.kind == .loopCut, shown.blenderEdge == edge,
           shown.holds(for: object) {
            // The cut the preview showed: the same edge, the same count.
            let op = LastOperator.loopCutAndSlide(edge: edge, cuts: shown.cuts)
            parent.scene.cutPreview = nil
            let outcome = parent.bridge?.perform(op)
            loopCutCache.rings = [:]
            return outcome?.succeeded == true ? op : nil
        }
        parent.scene.cutPreview = loopCutPreview(ring, edge: edge, cuts: cuts, on: object)
        return nil
    }

    // MARK: Knife

    /// The cage the Knife snaps to on `object`: the mirror's, when its report
    /// describes the mesh on screen, or under a modifier that rebuilds the
    /// mesh Blender's own edit cage, asked once (`_blenderkit_knife.cage_json`)
    /// — Blender's knife snaps to the cage there, not to what the modifier
    /// draws. Nil when there is neither.
    func knifeCage(for object: BKObject) -> KnifeCage? {
        let cage = object.editCage
        var sum = SIMD3<Float>.zero
        for v in cage.vertices { sum += v.position }
        let m = object.modelMatrix
        let key = [Float(cage.vertices.count), Float(cage.indices.count), sum.x, sum.y, sum.z]
            + [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        if knifeCageCache.object == object.id, knifeCageCache.revision == object.editTopologyRevision,
           knifeCageCache.key == key {
            return knifeCageCache.cage
        }
        var made = KnifeCage(object: object)
        if made == nil, let bridge = parent.bridge, bridge.usesRealBlender,
           let answer = bridge.capture("import _blenderkit_knife\n_blenderkit_knife.cage_json()") {
            made = KnifeCage(json: answer)
        }
        let last = knifeCageCache.lastSnap
        knifeCageCache = KnifeCageCache(object: object.id, revision: object.editTopologyRevision, key: key,
                                        cage: made, lastSnap: last)
        return made
    }

    /// Where a tap at `point` puts the Knife's next point, snapped as
    /// Blender's knife snaps (`KnifeSnap`): onto an edge or a vertex of the
    /// face under it when near one, a point the path already has, the face
    /// where the line of sight meets it, or past the mesh at the depth of
    /// the object's middle.
    func knifeSnap(at point: CGPoint, size: CGSize, on object: BKObject) -> KnifeSnap.Snapped? {
        guard let renderer, size.width > 0, size.height > 0 else { return nil }
        let aspect = Float(size.width / size.height)
        let bounds = object.worldBounds
        let centre = (bounds.min + bounds.max) / 2
        let forward = simd_normalize(parent.camera.target - parent.camera.eye)
        if let cage = knifeCage(for: object) {
            let view = KnifeView(viewProjection: parent.camera.viewProjection(aspect: aspect),
                                 size: SIMD2(Float(size.width), Float(size.height)))
            let path = parent.scene.knifePath.flatMap { $0.object == object.id ? $0.points : nil } ?? []
            return KnifeSnap.snap(pointer: SIMD2(Float(point.x), Float(point.y)), view: view, cage: cage,
                                  path: path) { ray in
                KnifePath.point(ray: ray, surface: nil, centre: centre, forward: forward)
            }
        }
        // No cage to snap to (no report from Blender yet): the surface drawn.
        let n = ndc(point, size)
        let ray = parent.camera.ray(atNDC: n, aspect: aspect)
        let surface = renderer.surfaceHit(ndc: n, aspect: aspect, on: object)
            .map { (object.modelMatrix * SIMD4($0.localPoint, 1)).xyz }
        return KnifeSnap.Snapped(point: KnifePath.point(ray: ray, surface: surface, centre: centre, forward: forward),
                                 target: surface == nil ? .none : .face(-1))
    }

    func knifePoint(at point: CGPoint, size: CGSize, on object: BKObject) -> SIMD3<Float>? {
        knifeSnap(at: point, size: size, on: object)?.point
    }

    /// A tap with the Knife: one more point on the path, or the reason the
    /// Knife cannot cut here.
    @discardableResult
    func knifeTap(at point: CGPoint, size: CGSize) -> Bool {
        let scene = parent.scene
        if let refusal = CutTool.knife.refusal(object: scene.active, usesRealBlender: parent.bridge?.usesRealBlender ?? false) {
            parent.bridge?.showReport(CutTool.knife.label, refusal)
            return false
        }
        guard let object = scene.active, let snapped = knifeSnap(at: point, size: size, on: object) else { return false }
        knifeCageCache.lastSnap = snapped
        var path = scene.knifePath?.object == object.id ? scene.knifePath! : KnifePath(object: object.id)
        path.add(snapped.point)
        path.viewSize = SIMD2(Float(size.width), Float(size.height))
        scene.knifePath = path
        CutToolActions.showKnifePath(scene)
        return true
    }

    /// The pointer over the view with a path started: the segment the next
    /// tap would add, drawn from the last point, as Blender's Knife draws it.
    func knifeHover(at point: CGPoint?, size: CGSize) {
        let scene = parent.scene
        guard let path = scene.knifePath, let last = path.points.last, let object = scene.active,
              object.id == path.object else { return }
        CutToolActions.showKnifePath(scene)
        guard let point, let next = knifePoint(at: point, size: size, on: object),
              var preview = scene.cutPreview else { return }
        preview.lines += [last, next]
        scene.cutPreview = preview
    }
}

/// What the Knife's bar, the keyboard and the DEBUG hook share, so all three
/// run the same code.
enum CutToolActions {
    /// The path as the overlay draws it.
    static func showKnifePath(_ scene: BKScene) {
        guard let path = scene.knifePath, let object = scene.objects.first(where: { $0.id == path.object }) else {
            if scene.cutPreview?.kind == .knife { scene.cutPreview = nil }
            return
        }
        scene.cutPreview = CutPreview(kind: .knife, lines: path.lines, points: path.points, object: object.id,
                                      cageVertexCount: object.editCage.vertices.count)
    }

    /// Drops what the cutting tools show once it no longer applies: another
    /// tool picked, Edit Mode left, another object active. A knife path is
    /// Cancelled, as Blender's Knife is when the tool changes.
    static func keep(for tool: ActiveTool, scene: BKScene) {
        let editing = scene.mode == .edit
        if let path = scene.knifePath, !(editing && tool == .knife) || path.object != scene.activeID {
            knifeCancel(scene)
        }
        if scene.cutPreview?.kind == .loopCut, !(editing && tool == .loopCut) {
            scene.cutPreview = nil
        }
    }

    /// The Knife's Undo: the last point goes, and the path with it once it
    /// has none.
    static func knifeUndoPoint(_ scene: BKScene) {
        guard var path = scene.knifePath, !path.points.isEmpty else { return }
        path.points.removeLast()
        scene.knifePath = path.points.isEmpty ? nil : path
        showKnifePath(scene)
    }

    /// Cancel: the path goes and nothing is cut.
    static func knifeCancel(_ scene: BKScene) {
        scene.knifePath = nil
        if scene.cutPreview?.kind == .knife { scene.cutPreview = nil }
    }

    /// Confirm: Blender cuts along the path as the view shows it now
    /// (`LastOperator.knife`). The path stays when Blender refuses, so it can
    /// be fixed or cancelled. Returns the operator that ran, if it cut.
    @discardableResult
    static func knifeDone(scene: BKScene, camera: ViewportCamera, bridge: BpyBridge?) -> LastOperator? {
        guard let path = scene.knifePath else { return nil }
        guard path.canCut else {
            bridge?.showReport(CutTool.knife.label, "The Knife cuts between points: tap at least two.")
            return nil
        }
        if let refusal = CutTool.knife.refusal(object: scene.active, usesRealBlender: bridge?.usesRealBlender ?? false) {
            bridge?.showReport(CutTool.knife.label, refusal)
            return nil
        }
        guard scene.active?.id == path.object else {
            bridge?.showReport(CutTool.knife.label, "The knife path was drawn over another object. Cancel it and draw it again.")
            return nil
        }
        // The path as this view sees it (`KnifePath.cutPoints`): points that
        // landed on one line of sight are one point, as the overlay draws them.
        let size = path.viewSize ?? SIMD2(1000, 1000)
        let view = KnifeView(viewProjection: camera.viewProjection(aspect: size.x / max(size.y, 1)), size: size)
        let points = path.cutPoints(in: view)
        guard points.count >= 2 else {
            bridge?.showReport(CutTool.knife.label, "The knife path's points are on one line of sight from this "
                               + "view, so there is nothing between them to cut. Turn the view back to where the "
                               + "path was drawn, or tap another point.")
            return nil
        }
        let forward = simd_normalize(camera.target - camera.eye)
        let op = LastOperator.knife(path: points, eye: camera.eye, forward: forward, up: camera.trueUp,
                                    orthographic: camera.isOrthographic, cutThrough: scene.knifeCutThrough)
        guard let outcome = bridge?.perform(op), outcome.succeeded else { return nil }
        knifeCancel(scene)
        return op
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `-cut-ops <tokens>`: Loop Cut and the Knife, driven through the calls a
    /// pointer and a finger make — `loopCutHover`, `loopCutTap`, `knifeTap`,
    /// `knifeHover` and `CutToolActions` — so what is tested is the tools' own
    /// path to Blender. Tokens, separated by `|`:
    ///
    /// - `tool:loopCut`, `tool:knife`, `tool:select` — the tool in hand;
    /// - `hover:<p>` and `tap:<p>`, `<p>` a fraction of the view `x,y` or a
    ///   place in the scene `@x,y,z` where the camera shows it;
    /// - `through:on|off`, `undo-point`, `cancel`, `confirm` — the Knife's bar;
    /// - `ortho:on|off` — the view's projection, as numpad 5 switches it;
    /// - `orbit:<azimuth>,<elevation>,<distance>` — the view turned, between taps;
    /// - `adjust:<key>=<value>` — the redo panel (`readjust`);
    /// - `undo`, `redo` — the history, as the top bar's buttons;
    /// - `mode:VERT|EDGE|FACE`, `state`, `pause:<seconds>` (the app left idle).
    ///
    /// `-cut-view top|front|right|persp:<distance>|orbit:<azimuth>,<elevation>,<distance>`
    /// sets the view first; `-cut-wait <name>` waits for an object of that
    /// name in Edit Mode. A Loop Cut tap that cuts prints the previewed cut
    /// against the vertices Blender made; a Knife Confirm prints the vertices
    /// Blender made against the crossings the path's planes make with the
    /// mesh's edges, worked out from the mesh before the cut.
    func cutLaunchIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let spec = value("-cut-ops") else { return }
        guard tries > 0 else { print("[bk] cut-ops: never ready"); fflush(stdout); return }
        let waitFor = value("-cut-wait")
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              parent.scene.mode == .edit,
              waitFor.map({ name in parent.scene.active?.name == name }) ?? true
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.cutLaunchIfRequested(tries: tries - 1) }
            return
        }
        if let name = value("-cut-view") {
            if let viewpoint = ViewportCamera.Viewpoint(rawValue: name) {
                parent.camera.snap(to: viewpoint)
                parent.camera.frameAll(parent.scene.objects)
            } else if name.hasPrefix("persp:"), let d = Float(name.dropFirst("persp:".count)) {
                var camera = ViewportCamera()
                camera.distance = d
                parent.camera = camera
            } else if name.hasPrefix("orbit:") {
                let v = name.dropFirst("orbit:".count).split(separator: ",").compactMap { Float($0) }
                if v.count == 3 {
                    var camera = ViewportCamera()
                    camera.azimuth = v[0] * .pi / 180
                    camera.elevation = v[1] * .pi / 180
                    camera.distance = v[2]
                    parent.camera = camera
                }
            }
        }
        let tokens = spec.split(separator: "|").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.cutToken(tokens, 0, tool: nil, view: view, bridge: bridge)
        }
    }

    private func cutPoint(_ text: String, size: CGSize) -> CGPoint? {
        if text.hasPrefix("@") {
            let xyz = text.dropFirst().split(separator: ",").compactMap { Float($0) }
            guard xyz.count == 3 else { return nil }
            let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height))
            return BoxSelect.project(SIMD3(xyz[0], xyz[1], xyz[2]), viewProjection: vp, size: size)
        }
        let xy = text.split(separator: ",").compactMap { Double($0) }
        return xy.count == 2 ? CGPoint(x: CGFloat(xy[0]) * size.width, y: CGFloat(xy[1]) * size.height) : nil
    }

    /// The edit mesh's vertices in world space, read from Blender.
    private func blenderVertices(_ bridge: BpyBridge) -> [SIMD3<Float>] {
        let answer = bridge.capture("""
            import bmesh
            _bk_o = bpy.context.view_layer.objects.active
            _bk_m = _bk_o.matrix_world
            print(';'.join('%.6f,%.6f,%.6f' % tuple(_bk_m @ v.co) for v in bmesh.from_edit_mesh(_bk_o.data).verts))
            """) ?? ""
        return answer.split(separator: ";").compactMap { item in
            let c = item.split(separator: ",").compactMap { Float($0) }
            return c.count == 3 ? SIMD3(c[0], c[1], c[2]) : nil
        }
    }

    /// The edit mesh's face sizes, sorted: a split quad reads 4, 4 where a
    /// cut that stopped inside a face leaves a hexagon.
    private func faceSizes(_ bridge: BpyBridge) -> String {
        bridge.capture("""
            import bmesh
            print(sorted(len(f.verts) for f in bmesh.from_edit_mesh(bpy.context.view_layer.objects.active.data).faces))
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    private func counts(_ bridge: BpyBridge) -> String {
        bridge.capture("""
            import bmesh
            _bk_b = bmesh.from_edit_mesh(bpy.context.view_layer.objects.active.data)
            print('%d/%d/%d, %d selected, select mode %s' % (len(_bk_b.verts), len(_bk_b.edges), len(_bk_b.faces),
                  sum(v.select for v in _bk_b.verts), tuple(bpy.context.scene.tool_settings.mesh_select_mode)))
            """) ?? "?"
    }

    /// Each wanted point's distance to the nearest of `got`, the worst of them,
    /// and how many of `got` are near none.
    private func match(_ want: [SIMD3<Float>], _ got: [SIMD3<Float>]) -> String {
        guard !want.isEmpty, !got.isEmpty else { return "previewed \(want.count), made \(got.count)" }
        let worst = want.map { w in got.map { simd_distance($0, w) }.min() ?? .infinity }.max() ?? 0
        let stray = got.filter { g in (want.map { simd_distance($0, g) }.min() ?? .infinity) > 1e-3 }.count
        return "previewed \(want.count), made \(got.count), worst distance "
            + String(format: "%.2e", worst) + " m, \(stray) made where nothing was previewed"
    }

    /// `tool`: the one a `tool:` token picked, put back into `parent` before
    /// each token, since every SwiftUI update hands the coordinator the
    /// workspace's own tool; nil leaves the workspace's (`-object-ops
    /// tool:knife` picks it there, through `choose`).
    private func cutToken(_ tokens: [String], _ index: Int, tool picked: ActiveTool?, view: MTKView,
                          bridge: BpyBridge) {
        guard index < tokens.count else { print("[bk] cut-ops: done"); fflush(stdout); return }
        let token = tokens[index]
        var picked = picked
        if let picked { parent.tool = picked }
        let size = view.bounds.size
        var said = ""
        var delay = 0.5
        func tool(_ name: String) -> ActiveTool? { ActiveTool(rawValue: name) }
        switch token {
        case _ where token.hasPrefix("pause:"):
            delay = Double(token.dropFirst("pause:".count)) ?? 0.5
            said = "waiting \(delay) s, the app left idle"
        case _ where token.hasPrefix("tool:"):
            if let t = tool(String(token.dropFirst("tool:".count))) {
                parent.tool = t
                picked = t
                CutToolActions.keep(for: t, scene: parent.scene)
                said = "tool \(t.label)"
            }
        case _ where token.hasPrefix("hover:"):
            guard let p = cutPoint(String(token.dropFirst("hover:".count)), size: size) else { said = "bad point"; break }
            if parent.tool == .knife { knifeHover(at: p, size: size) } else { loopCutHover(at: p, size: size) }
            let preview = parent.scene.cutPreview
            said = "preview: " + (preview.map { "\($0.kind), Blender edge \($0.blenderEdge.map(String.init) ?? "-"), "
                + "\($0.lines.count / 2) lines, \($0.points.count) points, \($0.cuts) cut(s)" } ?? "none")
            if let edge = preview?.blenderEdge, let ring = loopCutCache.rings[edge] {
                said += "; ring \(ring.edges)"
            }
            // The Knife's next segment ends where a tap there would put the
            // point, snapped as the tap snaps it.
            if parent.tool == .knife, preview?.kind == .knife, parent.scene.knifePath?.points.isEmpty == false,
               let end = preview?.lines.last {
                said += String(format: "; next point at (%.6f, %.6f, %.6f)", end.x, end.y, end.z)
            }
        case _ where token.hasPrefix("tap:"):
            guard let p = cutPoint(String(token.dropFirst("tap:".count)), size: size) else { said = "bad point"; break }
            if parent.tool == .knife {
                let ok = knifeTap(at: p, size: size)
                said = ok ? "knife path \(parent.scene.knifePath?.points.count ?? 0) point(s)" : "refused"
                if ok, let snap = knifeCageCache.lastSnap {
                    said += String(format: ", snapped to %@ at (%.6f, %.6f, %.6f)", "\(snap.target)",
                                   snap.point.x, snap.point.y, snap.point.z)
                }
            } else {
                let before = parent.scene.cutPreview
                let vertices = before != nil ? blenderVertices(bridge) : []
                if let op = loopCutTap(at: p, size: size), let before {
                    let after = blenderVertices(bridge)
                    let made = after.filter { a in !vertices.contains { simd_distance($0, a) < 1e-5 } }
                    var want = before.points
                    for l in before.lines where !want.contains(where: { simd_distance($0, l) < 1e-6 }) { want.append(l) }
                    said = "cut: \(op.python.replacingOccurrences(of: "\n", with: " ⏎ ")); preview vs Blender: "
                        + match(want, made)
                } else {
                    let preview = parent.scene.cutPreview
                    said = "preview: " + (preview.map { "Blender edge \($0.blenderEdge.map(String.init) ?? "-"), "
                        + "\($0.lines.count / 2) lines, \($0.points.count) points" } ?? "none")
                    if let edge = preview?.blenderEdge, let ring = loopCutCache.rings[edge] { said += "; ring \(ring.edges)" }
                }
            }
        case "ortho:on", "ortho:off":
            parent.camera.isOrthographic = token == "ortho:on"
            said = parent.camera.isOrthographic ? "orthographic" : "perspective"
        case _ where token.hasPrefix("orbit:"):
            // The view turned between taps, as a two-finger drag turns it:
            // what puts two of a path's points on one line of sight.
            let v = token.dropFirst("orbit:".count).split(separator: ",").compactMap { Float($0) }
            if v.count == 3 {
                var camera = ViewportCamera()
                camera.azimuth = v[0] * .pi / 180
                camera.elevation = v[1] * .pi / 180
                camera.distance = v[2]
                parent.camera = camera
                let e = camera.eye
                said = String(format: "view from (%.3f, %.3f, %.3f)", e.x, e.y, e.z)
            } else { said = "bad orbit" }
        case "through:on", "through:off":
            parent.scene.knifeCutThrough = token == "through:on"
            said = "Cut Through \(parent.scene.knifeCutThrough ? "on" : "off")"
        case "undo-point":
            CutToolActions.knifeUndoPoint(parent.scene)
            said = "knife path \(parent.scene.knifePath?.points.count ?? 0) point(s)"
        case "cancel":
            CutToolActions.knifeCancel(parent.scene)
            said = "knife path \(parent.scene.knifePath == nil ? "gone" : "kept")"
        case "confirm":
            let camera = parent.camera
            // The path as Confirm cuts it from this view (`KnifePath.cutPoints`).
            let path = parent.scene.knifePath.map { knife -> [SIMD3<Float>] in
                let size = knife.viewSize ?? SIMD2(1000, 1000)
                return knife.cutPoints(in: KnifeView(viewProjection: camera.viewProjection(aspect: size.x / max(size.y, 1)),
                                                     size: size))
            } ?? []
            let through = parent.scene.knifeCutThrough
            let expected = knifeExpectation(path: path, camera: camera, through: through, bridge: bridge)
            let vertices = blenderVertices(bridge)
            let op = CutToolActions.knifeDone(scene: parent.scene, camera: camera, bridge: bridge)
            let made = blenderVertices(bridge).filter { a in !vertices.contains { simd_distance($0, a) < 1e-5 } }
            // A path point on a vertex the mesh had makes no new vertex.
            let expectedNew = expected.filter { e in !vertices.contains { simd_distance($0, e) < 1e-5 } }
            said = (op.map { "cut: " + $0.name + ", Cut Through " + (through ? "on" : "off") } ?? "NOT CUT")
                + "; path \(path.count) points; crossings vs Blender: " + match(expectedNew, made)
                + "; faces " + faceSizes(bridge)
                + "; knife path \(parent.scene.knifePath == nil ? "gone" : "kept")"
        case _ where token.hasPrefix("adjust:"):
            let pair = token.dropFirst("adjust:".count).split(separator: "=").map(String.init)
            if pair.count == 2, let v = Double(pair[1]), var op = bridge.adjustable {
                op[pair[0]] = v
                said = bridge.readjust(op).map { "re-ran \($0.python.replacingOccurrences(of: "\n", with: " ⏎ "))" }
                    ?? "REFUSED"
            } else { said = "no adjustable operator" }
        case "undo": bridge.debugSession.performUndo(); said = "undo"
        case "redo": bridge.debugSession.performRedo(); said = "redo"
        case _ where token.hasPrefix("mode:"):
            if let mode = MeshSelectMode.allCases.first(where: { $0.bpyType == token.dropFirst(5) }) {
                bridge.run(Bpy.setSelectMode(mode))
                parent.scene.selectMode = mode
                said = "select mode \(mode.bpyType)"
            }
        case "state": break
        default: said = "no such token"
        }
        print("[bk] cut-ops \(token): \(said)")
        print("[bk]   Blender: \(counts(bridge)); redo panel: \(bridge.adjustable.map { $0.name + " [" + $0.parameters.map { "\($0.label) \($0.display)" }.joined(separator: ", ") + "]" } ?? "none"); banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.cutToken(tokens, index + 1, tool: picked, view: view, bridge: bridge)
        }
    }

    /// Where Blender's Knife should put new vertices for `path` seen from
    /// `camera`: each edge of the mesh crossing the plane a segment and the
    /// lines of sight through its ends make, inside that wedge — on edges of
    /// faces the view faces unless `through` (exact for a convex mesh such
    /// as a cube, which is what this measures on). Worked out by Blender's
    /// own mathutils on the mesh before the cut, independently of the knife.
    private func knifeExpectation(path: [SIMD3<Float>], camera: ViewportCamera, through: Bool,
                                  bridge: BpyBridge) -> [SIMD3<Float>] {
        func v(_ p: SIMD3<Float>) -> String { "Vector((\(p.x), \(p.y), \(p.z)))" }
        let forward = simd_normalize(camera.target - camera.eye)
        let answer = bridge.capture("""
            import bmesh
            from mathutils import Vector
            _bk_o = bpy.context.view_layer.objects.active
            _bk_bm = bmesh.from_edit_mesh(_bk_o.data)
            _bk_mw = _bk_o.matrix_world
            _bk_eye = \(v(camera.eye)); _bk_f = \(v(forward)).normalized(); _bk_ortho = \(camera.isOrthographic ? "True" : "False")
            _bk_path = [\(path.map(v).joined(separator: ", "))]
            _bk_out = []
            def _bk_seen(f):
                c = _bk_mw @ f.calc_center_median(); n = (_bk_mw.to_3x3() @ f.normal).normalized()
                return n.dot(-_bk_f) > 0 if _bk_ortho else n.dot(_bk_eye - c) > 0
            for _bk_e in _bk_bm.edges:
                if not \(through ? "True" : "False") and not any(_bk_seen(f) for f in _bk_e.link_faces):
                    continue
                _bk_a = _bk_mw @ _bk_e.verts[0].co; _bk_b = _bk_mw @ _bk_e.verts[1].co
                for _bk_p, _bk_q in zip(_bk_path, _bk_path[1:]):
                    _bk_n = (_bk_q - _bk_p).cross(_bk_f) if _bk_ortho else (_bk_p - _bk_eye).cross(_bk_q - _bk_eye)
                    _bk_origin = _bk_p if _bk_ortho else _bk_eye
                    _bk_d = _bk_n.dot(_bk_b - _bk_a)
                    if abs(_bk_d) < 1e-12:
                        continue
                    _bk_t = _bk_n.dot(_bk_origin - _bk_a) / _bk_d
                    if not 1e-6 < _bk_t < 1 - 1e-6:
                        continue
                    _bk_x = _bk_a + (_bk_b - _bk_a) * _bk_t
                    if _bk_ortho:
                        _bk_u = (_bk_q - _bk_p) - _bk_f * (_bk_q - _bk_p).dot(_bk_f)
                        _bk_in = 0 <= (_bk_x - _bk_p).dot(_bk_u) / _bk_u.length_squared <= 1
                    else:
                        _bk_in = ((_bk_p - _bk_eye).cross(_bk_x - _bk_eye).dot(_bk_n) >= 0
                                  and (_bk_x - _bk_eye).cross(_bk_q - _bk_eye).dot(_bk_n) >= 0)
                    if _bk_in:
                        _bk_out.append('%.6f,%.6f,%.6f' % tuple(_bk_x))
            # A path point on the mesh is a vertex of the cut, as a click on a
            # face is: where its line of sight meets what the view sees, or
            # every face with Cut Through.
            from mathutils.bvhtree import BVHTree
            _bk_tree = BVHTree.FromBMesh(_bk_bm)
            _bk_inv = _bk_mw.inverted()
            for _bk_p in _bk_path:
                _bk_from = (_bk_p - _bk_f * 1e4) if _bk_ortho else _bk_eye
                _bk_dir = _bk_f if _bk_ortho else (_bk_p - _bk_eye).normalized()
                _bk_o2, _bk_d2 = _bk_inv @ _bk_from, (_bk_inv.to_3x3() @ _bk_dir).normalized()
                while True:
                    _bk_hit = _bk_tree.ray_cast(_bk_o2, _bk_d2)[0]
                    if _bk_hit is None:
                        break
                    _bk_out.append('%.6f,%.6f,%.6f' % tuple(_bk_mw @ _bk_hit))
                    if not \(through ? "True" : "False"):
                        break
                    _bk_o2 = _bk_hit + _bk_d2 * 1e-5
            print(';'.join(_bk_out))
            """) ?? ""
        return answer.split(separator: ";").compactMap { item in
            let c = item.split(separator: ",").compactMap { Float($0) }
            return c.count == 3 ? SIMD3(c[0], c[1], c[2]) : nil
        }
    }
}
#endif
