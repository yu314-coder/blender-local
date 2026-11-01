import SwiftUI
import MetalKit
import simd

/// Blender's L picks what is linked to the element under the pointer. The key
/// is a menu command (KeyboardCommands.swift) and the pointer is the 3D
/// View's, so the command posts this and the 3D View that has the pointer
/// answers (`selectLinkedUnderPointer`). `userInfo["deselect"]` is Shift+L.
enum SelectPickKeys {
    static let linked = Notification.Name("BlenderLocal.selectLinkedUnderPointer")
}

extension MetalViewportView.Coordinator {

    /// A tap or click with one of Blender's pick selections (SelectPick.swift):
    /// the element under `point` picked on the cage, named by Blender's index,
    /// and Blender's own operator run with it — Loop Select, Edge Ring Select,
    /// Pick Shortest Path or Select Linked, with Blender's redo panel. What is
    /// selected afterwards, and what is active, is what the mirror reads back.
    /// A tap on nothing changes nothing, as Blender's pick returns CANCELLED
    /// (or PASS_THROUGH) there. Returns the operator it ran.
    @discardableResult
    func selectPickTap(_ pick: SelectPick, shift: Bool, at point: CGPoint, size: CGSize) -> LastOperator? {
        guard let renderer, let bridge = parent.bridge, size.width > 0, size.height > 0 else { return nil }
        let scene = parent.scene
        if let refusal = pick.refusal(object: scene.active, usesRealBlender: bridge.usesRealBlender) {
            bridge.showReport(pick.operatorName, refusal)
            return nil
        }
        guard let object = scene.active, let topology = object.editTopology, topology.describes(object.editCage)
        else {
            bridge.showReport(pick.operatorName, "The viewport's mesh of \(scene.active?.name ?? "the object") "
                              + "does not line up with Blender's yet. Try again once it redraws.")
            return nil
        }
        let mode = scene.selectMode
        let pickMode = pick.pickMode(mode)
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        let hit = renderer.hitTestElement(ndc: ndc, aspect: Float(size.width / size.height), mode: pickMode,
                                          viewSize: SIMD2(Float(size.width), Float(size.height)))
        let cage = object.editCage
        guard let element = SelectPick.element(hit, mode: pickMode, cage: cage, topology: topology) else {
            return nil
        }
        // Ctrl+click with nothing selected: Blender's invoke selects the
        // element instead, as a Shift-less extend, and finishes
        // (`edbm_shortest_path_pick_invoke`: "If nothing is selected, let's
        // select the picked vertex/edge/face") — an undo step under the
        // operator's name.
        if pick == .path, scene.editSelection.vertices.isEmpty {
            let selection = editTapSelection(hit, action: .extend)
            bridge.run(Bpy.pushEditSelection(selection, mode: mode, of: object),
                       undo: pick.operatorName, quiet: true)
            return nil
        }
        var active: (vertex: Int?, face: Int?) = (nil, nil)
        if pick == .loop || pick == .ring, case .edge(let edge) = element {
            let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height)) * object.modelMatrix
            active = SelectPick.loopActive(edge: edge, at: point, mode: mode, cage: cage, topology: topology) {
                BoxSelect.project($0, viewProjection: vp, size: size)
            }
        }
        let op = LastOperator.pick(pick, element: element, shift: shift, mode: mode,
                                   counts: SelectPick.counts(topology),
                                   activeVertex: active.vertex, activeFace: active.face)
        return bridge.perform(op).succeeded ? op : nil
    }

    /// Blender's L (Select Linked under the pointer), and Shift+L its Deselect:
    /// at the last point a mouse, trackpad or Pencil hovered over this 3D
    /// View. Only the editing 3D View answers — the one the keys belong to —
    /// and without a pointer over it the key says so.
    func selectLinkedUnderPointer(deselect: Bool) {
        guard let view, view.window != nil, parent.onToggleEditing != nil, parent.scene.mode == .edit else { return }
        guard let point = lastPointer, view.bounds.width > 0 else {
            parent.bridge?.showReport(SelectPick.linked.operatorName,
                                      "L selects what is linked to the element under the pointer, and no "
                                      + "pointer is over the 3D View. Hover a mouse, trackpad or Pencil over the "
                                      + "mesh, or pick Select Linked in the Select menu and tap.")
            return
        }
        selectPickTap(.linked, shift: deselect, at: point, size: view.bounds.size)
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `-select-pick <tokens>`: Blender's pick selections and the Select
    /// menu's rows, driven through the calls a pointer, a finger and a key
    /// make — `meshEditTap` (the tap gesture's own path, keys included),
    /// `selectLinkedUnderPointer` (the L key's), the menu rows' `perform` /
    /// `run` — so what is tested is the controls' own path to Blender. Tokens,
    /// separated by `|`:
    ///
    /// - `tap:<p>`, `tap+alt:<p>`, `tap+ctrl+alt:<p>`, `tap+ctrl:<p>`, with
    ///   `+shift` too — a tap or a click with those keys held; `<p>` a
    ///   fraction of the view `x,y` or a place in the scene `@x,y,z`;
    /// - `pick:loop|ring|path|linked|none`, `shift:on|off` — the pick a
    ///   finger's tap makes, as the Select menu and the pick bar set it;
    /// - `hover:<p>`, `leave` — the pointer over the view, or gone;
    /// - `key:L`, `key:shift+L` — Blender's L, as the menu command posts it;
    /// - `menu:<token>` — a Select menu row (`SelectMenu.Command(token:)`);
    /// - `adjust:<key>=<value>` — the redo panel (`readjust`);
    /// - `view:<top|front|…|orbit:az,el,distance>` — the 3D View's view;
    /// - `undo`, `redo`, `mode:VERT|EDGE|FACE`, `state`, `pause:<seconds>`.
    ///
    /// `-select-pick-view` takes `-cut-view`'s values; `-select-pick-wait
    /// <name>` waits for an object of that name in Edit Mode. After each
    /// token it prints what Blender holds — counts, the active element and
    /// the selection order, read from Blender — beside what the viewport
    /// shows, the redo panel and the banner.
    func selectPickLaunchIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let spec = value("-select-pick") else { return }
        guard tries > 0 else { print("[bk] select-pick: never ready"); fflush(stdout); return }
        let waitFor = value("-select-pick-wait")
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              parent.scene.mode == .edit,
              waitFor.map({ name in parent.scene.active?.name == name }) ?? true
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.selectPickLaunchIfRequested(tries: tries - 1) }
            return
        }
        if let name = value("-select-pick-view") { aimForPick(name) }
        let tokens = spec.split(separator: "|").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.selectPickToken(tokens, 0, pick: self.parent.pick, shift: self.parent.pickShift,
                                 view: view, bridge: bridge)
        }
    }

    /// `top`, `front`, … (a viewpoint, framed on everything) or
    /// `orbit:<azimuth>,<elevation>,<distance>`.
    private func aimForPick(_ name: String) {
        if let viewpoint = ViewportCamera.Viewpoint(rawValue: name) {
            parent.camera.snap(to: viewpoint)
            parent.camera.frameAll(parent.scene.objects)
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

    private func pickPoint(_ text: String, size: CGSize) -> CGPoint? {
        if text.hasPrefix("@") {
            let xyz = text.dropFirst().split(separator: ",").compactMap { Float($0) }
            guard xyz.count == 3 else { return nil }
            let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height))
            return BoxSelect.project(SIMD3(xyz[0], xyz[1], xyz[2]), viewProjection: vp, size: size)
        }
        let xy = text.split(separator: ",").compactMap { Double($0) }
        return xy.count == 2 ? CGPoint(x: CGFloat(xy[0]) * size.width, y: CGFloat(xy[1]) * size.height) : nil
    }

    /// What Blender holds: counts of selected vertices, edges and faces, the
    /// active element and the selection order, read from Blender.
    private func blenderSelection(_ bridge: BpyBridge) -> String {
        bridge.capture("""
            import bmesh
            _bk_o = bpy.context.view_layer.objects.active
            _bk_b = bmesh.from_edit_mesh(_bk_o.data)
            for _bk_s in (_bk_b.verts, _bk_b.edges, _bk_b.faces):
                _bk_s.index_update()
            def _bk_n(e):
                return type(e).__name__[2].lower() + str(e.index)
            _bk_h = [_bk_n(e) for e in _bk_b.select_history]
            _bk_f = _bk_b.faces.active
            print('%dv/%de/%df of %d/%d/%d, active %s, order %s, active face %s' % (
                sum(v.select for v in _bk_b.verts), sum(e.select for e in _bk_b.edges),
                sum(f.select for f in _bk_b.faces), len(_bk_b.verts), len(_bk_b.edges), len(_bk_b.faces),
                _bk_h[-1] if _bk_h else '-', _bk_h[-6:], ('f%d' % _bk_f.index) if _bk_f is not None and _bk_f.select else '-'))
            """)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    /// What the viewport shows: the selection's counts (faces as Blender's
    /// polygons) and the selection order it holds.
    private func shownSelection() -> String {
        let s = parent.scene.editSelection
        let topology = parent.scene.active?.editTopology
        let faces = Set(s.faces.compactMap { f -> Int? in
            guard let topology, f < topology.trianglePolygons.count else { return nil }
            return Int(topology.trianglePolygons[f])
        }).count
        func name(_ e: EditElement) -> String {
            switch e {
            case .vertex(let i): return "v\(i)"
            case .edge(let i):   return "e\(i)"
            case .face(let i):   return "f\(i)"
            }
        }
        let order = s.history.suffix(6).map(name)
        return "\(s.vertices.count)v/\(s.edges.count)e/\(faces)f, active \(s.active.map(name) ?? "-"), "
            + "order \(order), active face \(s.activeFace.map { "f\($0)" } ?? "-")"
    }

    private func selectPickToken(_ tokens: [String], _ index: Int, pick: SelectPick?, shift: Bool,
                                 view: MTKView, bridge: BpyBridge) {
        guard index < tokens.count else { print("[bk] select-pick: done"); fflush(stdout); return }
        let token = tokens[index]
        var pick = pick, shift = shift
        // Every SwiftUI update hands the coordinator the workspace's own
        // values; the hook's are put back before each token.
        parent.pick = pick
        parent.pickShift = shift
        let size = view.bounds.size
        var said = ""
        var delay = 0.5
        bridge.dismissReport(bridge.report?.id ?? -1)
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let head = parts[0], tail = parts.count > 1 ? parts[1] : ""
        switch head {
        case _ where head == "tap" || head.hasPrefix("tap+"):
            guard let p = pickPoint(tail, size: size) else { said = "bad point"; break }
            var keys: UIKeyModifierFlags = []
            for key in head.split(separator: "+").dropFirst() {
                switch key {
                case "shift": keys.insert(.shift)
                case "ctrl":  keys.insert(.control)
                case "alt":   keys.insert(.alternate)
                case "cmd":   keys.insert(.command)
                default: break
                }
            }
            let before = bridge.adjustableGeneration
            meshEditTap(at: p, size: size, modifiers: keys)
            said = "tap at (\(Int(p.x)), \(Int(p.y))) with [\(head.split(separator: "+").dropFirst().joined(separator: "+"))]"
            if bridge.adjustableGeneration != before, let op = bridge.adjustable {
                said += "; ran \(op.python.replacingOccurrences(of: "\n", with: " ⏎ "))"
            }
        case "pick":
            pick = SelectPick(rawValue: tail)
            parent.pick = pick
            said = "a tap makes \(pick?.operatorName ?? "an ordinary select")"
        case "shift":
            shift = tail == "on"
            parent.pickShift = shift
            said = "Shift variant \(shift ? "on" : "off")"
        case "hover":
            guard let p = pickPoint(tail, size: size) else { said = "bad point"; break }
            lastPointer = p
            said = "pointer at (\(Int(p.x)), \(Int(p.y)))"
        case "leave":
            lastPointer = nil
            said = "pointer gone"
        case "key":
            let deselect = tail.lowercased().hasPrefix("shift")
            NotificationCenter.default.post(name: SelectPickKeys.linked, object: nil,
                                            userInfo: ["deselect": deselect])
            said = "posted \(deselect ? "Shift+L" : "L")"
        case "menu":
            guard let command = SelectMenu.Command(token: tail) else { said = "no such row"; break }
            // As LayoutWorkspace.select sends a row: with where the view looks.
            let look = SelectMenu.ViewDirection(forward: simd_normalize(parent.camera.target - parent.camera.eye),
                                                up: parent.camera.trueUp)
            switch command.action(editing: parent.scene.mode == .edit, view: look,
                                  selectMode: parent.scene.selectMode) {
            case .run(let python, let undo): bridge.run(python, undo: undo)
            case .perform(let op):          bridge.perform(op)
            }
            said = "pressed \(tail)"
        case "adjust":
            let pair = tail.split(separator: "=").map(String.init)
            if pair.count == 2, let v = Double(pair[1]), var op = bridge.adjustable {
                op[pair[0]] = v
                said = bridge.readjust(op).map { "re-ran \($0.python.replacingOccurrences(of: "\n", with: " ⏎ "))" }
                    ?? "REFUSED"
            } else { said = "no adjustable operator" }
        case "undo": bridge.debugSession.performUndo(); said = "undo"
        case "redo": bridge.debugSession.performRedo(); said = "redo"
        case "mode":
            if let mode = MeshSelectMode.allCases.first(where: { $0.bpyType == tail }) {
                bridge.run(Bpy.setSelectMode(mode))
                parent.scene.selectMode = mode
                said = "select mode \(mode.bpyType)"
            }
        case "view":
            aimForPick(tail)
            said = "view \(tail)"
            delay = 1.0
        case "pause":
            delay = Double(tail) ?? 0.5
            said = "waiting \(delay) s"
        case "state": break
        default: said = "no such token"
        }
        // A tap is pushed with the next command; read Blender after the
        // mirror has had it, and say whether one is still waiting.
        let pending = parent.scene.editSelectionPending ? " (a tap waiting to be pushed)" : ""
        print("[bk] select-pick \(token): \(said)")
        print("[bk]   Blender: \(blenderSelection(bridge)); viewport: \(shownSelection())\(pending)")
        print("[bk]   redo panel: \(bridge.adjustable.map { $0.name + " [" + $0.parameters.map { "\($0.label) \($0.display)" }.joined(separator: ", ") + "]" } ?? "none"); banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.selectPickToken(tokens, index + 1, pick: pick, shift: shift, view: view, bridge: bridge)
        }
    }
}
#endif
