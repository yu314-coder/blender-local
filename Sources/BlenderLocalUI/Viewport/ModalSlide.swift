import SwiftUI
import UIKit
import simd

// G pressed again during Move in a mesh's Edit Mode: Blender's Edge Slide, and
// where Edge Slide cannot slide the selection, Vertex Slide; where neither can,
// it stays a Move (TFM_MODAL_TRANSLATE in transform.cc, 5.2.1). G once more goes
// back to Move. The pointer steers it as Blender's does, typed numbers set the
// factor, and a click, Return or Space confirms it as the Edge menu's Edge
// Slide (or the Vertex menu's Slide Vertices): one operator the redo panel
// adjusts.
//
// The preview is the app's own, from what `_blenderkit_slide` reads out of
// Blender when the slide begins: both slides move each vertex in a straight
// line, linearly in the factor (measured in 5.2.1, within 6e-8), so Blender is
// asked once where +1 and -1 take every vertex and each frame mixes between.
// Vertex Slide is asked again only when the pointer swings to another edge.

/// G G's slide as it runs.
struct SlideDrive {
    enum Kind { case edge, vertex }

    /// A vertex the slide moves: its cage index, where it starts, and where a
    /// factor of +1 and -1 put it (object space).
    struct End {
        let index: Int
        let start: SIMD3<Float>
        let plus: SIMD3<Float>
        let minus: SIMD3<Float>
    }

    /// A selected vertex and the vertices at the other ends of its edges.
    struct Link {
        let position: SIMD3<Float>
        let neighbours: [SIMD3<Float>]
    }

    var kind: Kind
    let object: BKObject
    /// The cage as the slide began: what the preview moves.
    let mesh: MeshData
    let model: simd_float4x4
    /// Whether the commit sends `mirror=True` (LastOperator.mesh), which the
    /// probe sends too.
    let mirror: Bool
    var ends: [End]
    /// Edge Slide: the end whose line the pointer is measured along — the
    /// moved vertex nearest the pointer when the slide began, as Blender
    /// measures from the edge nearest the mouse.
    var active = 0
    /// Vertex Slide: the selected vertices, the one nearest the pointer, and
    /// the edge of it the pointer points along (an index into its
    /// neighbours) — the one most nearly the way the pointer has moved —
    /// with that edge's world direction: what the commit's
    /// `direction` says, so Blender slides each vertex along the same way.
    var links: [Link] = []
    var link = 0
    var neighbour: Int?
    var direction: SIMD3<Float>?
    var factor: Float = 0

    var mode: ModalTransformInput.Mode { kind == .edge ? .edgeSlide : .vertexSlide }

    /// Clamp, Blender's default for both: Edge Slide stays on the faces beside
    /// it (-1 to 1); Vertex Slide stays on its edge, and a negative factor
    /// moves nothing (measured).
    func clamped(_ f: Float) -> Float {
        kind == .edge ? min(max(f, -1), 1) : min(max(f, 0), 1)
    }
}

extension MetalViewportView.Coordinator {

    // MARK: beginning

    /// G during Move in a mesh's Edit Mode. False when it stays a Move.
    @discardableResult
    func modalSlide() -> Bool {
        guard var drive = modal, drive.input.mode == .translate, drive.slide == nil,
              let edit = drive.base.edit, drive.base.points == nil,
              let bridge = parent.bridge, bridge.usesRealBlender
        else { return false }
        // Blender puts the selection back before it slides.
        TransformGizmo.rollBack(drive.base)
        gizmoResult = nil
        showSnapMarker(nil, projection: nil)
        let mirror = parent.scene.active != nil
        let flag = mirror ? "True" : "False"
        var slide: SlideDrive?
        if let ends = Self.slideEnds(bridge.captureWithSelection(
            "import _blenderkit_slide\n_blenderkit_slide.edge(mirror=\(flag))"), mesh: edit.mesh) {
            var s = SlideDrive(kind: .edge, object: edit.object, mesh: edit.mesh, model: edit.model,
                               mirror: mirror, ends: ends)
            s.active = Self.nearest(ends.map(\.start), to: drive.lastHover ?? drive.start,
                                    model: edit.model, projection: drive.base.projection) ?? 0
            slide = s
        } else if let links = Self.slideLinks(bridge.captureWithSelection(
            "import _blenderkit_slide\n_blenderkit_slide.links()"), mesh: edit.mesh) {
            var s = SlideDrive(kind: .vertex, object: edit.object, mesh: edit.mesh, model: edit.model,
                               mirror: mirror, ends: [])
            s.links = links
            s.link = Self.nearest(links.map(\.position), to: drive.lastHover ?? drive.start,
                                  model: edit.model, projection: drive.base.projection) ?? 0
            slide = s
        }
        guard let slide else {
            // Neither slides this: it stays a Move, as in Blender.
            modalUpdate(presenting: true)
            return false
        }
        drive.input.switchMode(slide.mode)
        drive.slide = slide
        modal = drive
        gizmo = drive.base.invertingSnap(drive.snapInverted)
        modalUpdate(presenting: true)
        return true
    }

    /// G during a slide: back to Move, from the same start.
    func modalLeaveSlide() {
        guard var drive = modal, drive.slide != nil else { return }
        TransformGizmo.rollBack(drive.base)
        drive.slide = nil
        drive.input.switchMode(.translate)
        modal = drive
        gizmo = drive.base.invertingSnap(drive.snapInverted)
        modalUpdate(presenting: true)
    }

    // MARK: steering

    /// The slide to the pointer, or to the typed factor, shown.
    func slideUpdate() {
        guard var drive = modal, var slide = drive.slide else { return }
        let projection = drive.base.projection
        let model = slide.model
        func screen(_ local: SIMD3<Float>) -> CGPoint? {
            projection.project((model * SIMD4(local, 1)).xyz)
        }
        let moved = CGPoint(x: drive.pointer.x - drive.start.x, y: drive.pointer.y - drive.start.y)
        var factor: Float = 0
        switch slide.kind {
        case .edge:
            // Blender's InputCustomRatio between the active vertex's two ends:
            // the pointer moving the whole way from the -1 end to the +1 end
            // on screen is a factor of 2. With the ends one point on screen
            // (a loop seen end on), Blender measures along the view's
            // vertical instead.
            let end = slide.ends[slide.active]
            var dir = CGPoint(x: 0, y: -100)
            if let a = screen(end.minus), let b = screen(end.plus) {
                let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
                if d.x * d.x + d.y * d.y >= 0.1 { dir = d }
            }
            factor = Float(2 * (moved.x * dir.x + moved.y * dir.y) / (dir.x * dir.x + dir.y * dir.y))
        case .vertex:
            // The edge is the one pointing most nearly the way the pointer has
            // moved since the slide began, as Blender's
            // calcVertSlideMouseActiveEdges picks it (the mouse's travel from
            // where it started against each edge, in the view's plane). Before
            // the pointer has moved, the first edge.
            let link = slide.links[slide.link]
            guard let v = screen(link.position) else { break }
            let toward = moved
            let reach = hypot(toward.x, toward.y)
            var best = slide.neighbour
            if reach > 2 || best == nil {
                var bestDot = -CGFloat.infinity
                for (k, n) in link.neighbours.enumerated() {
                    guard let s = screen(n) else { continue }
                    let e = CGPoint(x: s.x - v.x, y: s.y - v.y)
                    let length = hypot(e.x, e.y)
                    guard length > 0.5 else { continue }
                    let dot = reach > 2 ? (e.x * toward.x + e.y * toward.y) / (length * reach) : 0
                    if dot > bestDot { bestDot = dot; best = k }
                }
            }
            guard let chosen = best else { break }
            if chosen != slide.neighbour {
                let m3 = simd_float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
                let direction = simd_normalize(m3 * (link.neighbours[chosen] - link.position))
                // Where Blender takes each selected vertex that way.
                let printed = Self.vector(direction)
                guard let bridge = parent.bridge,
                      let ends = Self.slideEnds(bridge.captureWithSelection(
                          "import _blenderkit_slide\n_blenderkit_slide.vertex(\(printed), mirror=\(slide.mirror ? "True" : "False"))"),
                          mesh: slide.mesh)
                else { break }
                slide.ends = ends
                slide.neighbour = chosen
                slide.direction = direction
            }
            if let s = screen(link.neighbours[chosen]) {
                let e = CGPoint(x: s.x - v.x, y: s.y - v.y)
                let length2 = e.x * e.x + e.y * e.y
                if length2 > 0.25 { factor = Float((moved.x * e.x + moved.y * e.y) / length2) }
            }
        }
        if let typed = drive.input.values { factor = Float(typed[0]) }
        factor = slide.clamped(factor)
        slide.factor = factor
        drive.slide = slide
        modal = drive

        var mesh = slide.mesh
        for end in slide.ends where end.index < mesh.vertices.count {
            mesh.vertices[end.index].position = factor >= 0
                ? simd_mix(end.start, end.plus, SIMD3(repeating: factor))
                : simd_mix(end.start, end.minus, SIMD3(repeating: -factor))
        }
        ModifierStack.recomputeNormals(&mesh, welded: true)
        mesh.carryShading(from: slide.mesh)
        slide.object.installTransformed(mesh)

        let shown = drive.input.shownValues
        parent.scene.transformReadout = shown.isEmpty
            ? String(format: "%@: %.4f", slide.mode.label, factor)
            : "\(slide.mode.label): " + shown.joined(separator: " | ")
        modalLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        ModalTransformState.shared.show(.init(mode: slide.mode, constraint: .none,
                                              typing: drive.input.isTyping), owner: self)
    }

    // MARK: ending

    /// A click, Return or Space during a slide: the preview put back and the
    /// slide performed through Blender, as the menu's row performs it. A
    /// factor of 0 commits nothing, as a Move that went nowhere does not.
    func slideConfirm() {
        guard let drive = modal, let slide = drive.slide else { return }
        TransformGizmo.rollBack(drive.base)
        gizmoResult = nil
        endGizmo()
        let scene = parent.scene
        if slide.factor != 0, let bridge = parent.bridge {
            var op = LastOperator.mesh(slide.kind == .edge ? .edgeSlide : .slideVertices,
                                       spinningAround: scene.active?.location,
                                       symmetry: scene.active?.symmetry)
            op["value"] = Double(slide.factor)
            if slide.kind == .vertex, let direction = slide.direction {
                // The edge the pointer chose, which the panel's six axes
                // cannot say: kept fixed, so a redo slides along it again.
                op.parameters.removeAll { $0.key == "direction" }
                op.fixedArguments.append("direction=\(Self.vector(direction))")
            }
            _ = bridge.perform(op)
        }
    }

    // MARK: reading Blender's answers

    /// Six places, as the commit's other vectors.
    static func vector(_ v: SIMD3<Float>) -> String {
        String(format: "(%.6f, %.6f, %.6f)", v.x, v.y, v.z)
    }

    /// The moved vertex (or selected vertex) nearest `point` on screen.
    static func nearest(_ positions: [SIMD3<Float>], to point: CGPoint, model: simd_float4x4,
                        projection: TransformGizmo.Projection) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in positions.enumerated() {
            guard let s = projection.project((model * SIMD4(p, 1)).xyz) else { continue }
            let d = hypot(s.x - point.x, s.y - point.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    /// `_blenderkit_slide`'s ends, if they describe this cage: the same
    /// vertex count, and every start where the cage has that vertex — else
    /// the cage is not Blender's mesh vertex for vertex (a modifier shown on
    /// it) and there is nothing to preview with.
    static func slideEnds(_ answer: String?, mesh: MeshData) -> [SlideDrive.End]? {
        guard let line = answer?.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["kind"] is String,
              let count = json["count"] as? Int, count == mesh.vertices.count,
              let rows = json["v"] as? [[Any]], !rows.isEmpty
        else { return nil }
        var ends: [SlideDrive.End] = []
        for row in rows {
            guard row.count == 4, let i = row[0] as? Int, i >= 0, i < count,
                  let s = point(row[1]), let p = point(row[2]), let m = point(row[3]),
                  simd_distance(s, mesh.vertices[i].position) < 1e-4
            else { return nil }
            ends.append(.init(index: i, start: s, plus: p, minus: m))
        }
        return ends
    }

    /// `_blenderkit_slide.links()`: the selected vertices and their edges.
    static func slideLinks(_ answer: String?, mesh: MeshData) -> [SlideDrive.Link]? {
        guard let line = answer?.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["kind"] is String,
              let count = json["count"] as? Int, count == mesh.vertices.count,
              let rows = json["links"] as? [[Any]], !rows.isEmpty
        else { return nil }
        var links: [SlideDrive.Link] = []
        for row in rows {
            guard row.count == 3, let i = row[0] as? Int, i >= 0, i < count, let p = point(row[1]),
                  simd_distance(p, mesh.vertices[i].position) < 1e-4,
                  let others = row[2] as? [Any]
            else { return nil }
            let neighbours = others.compactMap(point)
            if !neighbours.isEmpty { links.append(.init(position: p, neighbours: neighbours)) }
        }
        return links.isEmpty ? nil : links
    }

    private static func point(_ any: Any) -> SIMD3<Float>? {
        guard let a = any as? [Any], a.count == 3 else { return nil }
        let n = a.compactMap { ($0 as? NSNumber)?.floatValue }
        return n.count == 3 ? SIMD3(n[0], n[1], n[2]) : nil
    }
}
