import SwiftUI
import MetalKit
import simd

/// Hosts the Metal view and maps touch and Apple Pencil onto Blender's verbs.
///
/// Blender navigates with a three-button mouse and a numpad, neither of which
/// exists here. Rather than mode-switching, input is split by *what is
/// touching the screen*:
///
/// - **Finger** navigates — one finger orbits (middle-drag), two pan
///   (shift+middle-drag), pinch dollies (scroll wheel).
/// - **Pencil** acts — a drag runs the active tool, a tap selects, and hovering
///   highlights what is under the tip before committing to anything.
///
/// Both are live at once, so the view can be orbited with the off hand while
/// the Pencil stays on the model. Pressure scales the transform: light contact
/// is precise, firm contact is fast.
struct MetalViewportView: UIViewRepresentable {
    var scene: BKScene
    @Binding var camera: ViewportCamera
    /// The active toolbar tool. With Tweak selected a drag orbits the view;
    /// with Move/Rotate/Scale a drag that starts on the selection transforms
    /// it instead, which is how Blender's toolbar tools behave.
    var tool: ActiveTool = .select
    var shading: ViewportShading = .solid
    var options = ViewportOptions()
    /// What a tap does to the existing selection — the five buttons at the left
    /// of the tool-settings row. Without this they set state nothing read.
    var selectAction: SelectAction = .set
    /// Circle select's radius in view points: Blender's tool setting, whose
    /// default is 25 (`view3d.select_circle`'s `radius`, measured in 5.2.1).
    var circleRadius: CGFloat = 25
    /// What a Box, Circle or Lasso drag does to the selection when no Shift or
    /// Ctrl is held: the select tool's mode in the Select menu, Blender's
    /// tool-header buttons. Taps keep `selectAction`.
    var regionAction: SelectAction = .set
    /// Where interface actions go. A drag previews locally and commits through
    /// here on release; a tap goes straight through.
    var bridge: BpyBridge?
    /// Raised when a tap selects or clears the selection, so the Tools tab can
    /// log the equivalent Python.
    var onSelectionChange: (BKObject?) -> Void
    /// Raised once a transform drag ends, with the Python that performs it.
    var onTransform: (String) -> Void = { _ in }
    /// Raised once a gizmo drag ends, with the name of the step to record, so
    /// a drag can be undone as one action rather than a hundred frames.
    var onCommit: (String) -> Void = { _ in }
    /// Raised by an Apple Pencil barrel double-tap, to advance the toolbar.
    var onCycleTool: () -> Void = {}
    /// Tab, as in Blender: in and out of mesh editing. Nil where Tab means
    /// nothing — the Scripting tab's preview — which also leaves the keyboard
    /// with whatever had it.
    var onToggleEditing: (() -> Void)? = nil
    /// Raised once a sculpt stroke ends — the finger lifts, or a single dab —
    /// with the object it changed, so the stroke can be kept.
    var onStrokeEnd: (BKObject) -> Void = { _ in }

    /// Which gizmo the active tool shows. Blender draws one only for the
    /// transform tools; Tweak deliberately shows none, so a one-finger drag
    /// anywhere still orbits.
    ///
    /// Blender's combined Transform tool stacks move, rotate and scale at three
    /// radii at once. That is not built here, so it shows the move gizmo.
    static func gizmoMode(for tool: ActiveTool, scene: BKScene) -> TransformGizmo.Mode? {
        guard scene.mode == .object || scene.mode == .edit else { return nil }
        // Keyed off the tool's role rather than a case list, so the toolbar
        // can grow without this needing to be extended each time.
        switch tool.transformRole {
        case .translate: return .translate
        case .rotate:    return .rotate
        case .scale:     return .scale
        case nil:        return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MTKView {
        // A subclass only so the view can take the keyboard: see ViewportMTKView.
        let view = ViewportMTKView()
        view.onTab = onToggleEditing
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        // BTheme.viewport (#3D3D3D) — the viewport must clear to the same grey
        // the surrounding chrome is themed against.
        view.clearColor = MTLClearColor(red: 0.239, green: 0.239, blue: 0.239, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isMultipleTouchEnabled = true

        if let device = view.device,
           let renderer = ViewportRenderer(device: device, scene: scene, camera: camera) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }

        // Finger drag orbits. A Pencil drag must never move the camera, so
        // pencil touches are excluded — but a Magic Keyboard trackpad sends
        // `.indirectPointer`, and listing only `.direct` meant a trackpad drag
        // did nothing whatsoever: no orbit, no transform, no gizmo.
        let orbit = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                   NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        view.addGestureRecognizer(orbit)

        // Trackpad two-finger scroll dollies, the way a scroll wheel does in
        // Blender. This arrives as a scroll event rather than as two touches,
        // so the two-finger pan recogniser below never sees it.
        let scroll = UIPanGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.maximumNumberOfTouches = 0   // scroll only, never a drag
        view.addGestureRecognizer(scroll)

        // Pencil drag runs the active tool.
        let pencilDrag = PencilPanGestureRecognizer(target: context.coordinator,
                                                    action: #selector(Coordinator.handlePencilDrag(_:)))
        view.addGestureRecognizer(pencilDrag)
        context.coordinator.pencilDrag = pencilDrag

        // Hover highlights what the tip is over, before it touches down.
        let hover = UIHoverGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleHover(_:)))
        view.addGestureRecognizer(hover)

        // Double-tap on the Pencil barrel cycles tools, the way Blender cycles
        // its toolbar. Respects the system preference: if the user has set
        // double-tap to something else, this stays out of the way.
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        view.addInteraction(pencil)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        // Pointer clicks should select too, not only direct taps.
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                 NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        // A tap must not fire while the user is starting a drag, from either
        // input.
        tap.require(toFail: orbit)
        tap.require(toFail: pencilDrag)
        view.addGestureRecognizer(tap)

        context.coordinator.view = view
        #if DEBUG
        context.coordinator.paintLaunchStrokeIfRequested()
        context.coordinator.regionSelectLaunchIfRequested()
        context.coordinator.sculptLaunchStrokeIfRequested()
        context.coordinator.standInDabLaunchIfRequested()
        #endif
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        #if DEBUG
        FocusLog.count("viewport update")
        #endif
        context.coordinator.parent = self
        (view as? ViewportMTKView)?.onTab = onToggleEditing
        context.coordinator.renderer?.camera = camera
        context.coordinator.renderer?.scene = scene
        context.coordinator.renderer?.shading = shading
        context.coordinator.renderer?.options = options
        context.coordinator.renderer?.gizmoMode = Self.gizmoMode(for: tool, scene: scene)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: MetalViewportView
        var renderer: ViewportRenderer?
        weak var view: MTKView?
        weak var pencilDrag: PencilPanGestureRecognizer?
        private var lastPan: CGPoint = .zero
        /// A Box, Circle or Lasso drag in progress: which tool, the points it
        /// has passed through, and the operation the keyboard asked for as it
        /// began.
        private var regionGesture: RegionGesture?
        private var lastPencilPan: CGPoint = .zero
        private var pinchStartDistance: Float = 0
        /// Non-nil for the length of a gizmo drag. While it is set, the drag
        /// belongs to the gizmo and neither the camera nor the free transform
        /// gets a look at it.
        private var gizmo: TransformGizmo.Session?
        private var gizmoResult: TransformGizmo.Result?
        /// What a move has snapped to, drawn over the view. A layer rather
        /// than the renderer's pass, so every workspace's 3D View has it.
        private var snapMarker: CAShapeLayer?
        /// The object a sculpt stroke in progress has changed, if any dab has
        /// landed yet.
        private var strokeObject: BKObject?
        /// Texture Paint's stroke in progress. See TexturePaintInput.swift.
        let texturePaintInput = TexturePaintInput()
        /// A stroke with Blender's own sculpt brush. See SculptStrokeInput.swift.
        let sculptInput = SculptStrokeInput()

        init(_ parent: MetalViewportView) { self.parent = parent }

        deinit {
            // A view torn down under a drag of a curve's or a lattice's points
            // (its workspace closed) cancels it, so the session is not left
            // holding every command (BpySession.pointDragOpen) for a lift that
            // will never come.
            if gizmo?.points != nil, Thread.isMainThread { parent.bridge?.cancelPointDrag() }
        }

        /// One finger: orbits with Tweak, and with a transform tool transforms
        /// what the drag started on — orbiting when it started on nothing.
        @objc func handleOrbit(_ g: UIPanGestureRecognizer) {
            let p = g.translation(in: g.view)
            defer { lastPan = p }
            if handleTexturePaint(g, pressure: 1) { return }
            if handleBlenderSculpt(g, pressure: 1) { return }

            if g.state == .began {
                lastPan = .zero
                if let view, beginRegion(at: g.location(in: view), modifiers: g.modifierFlags) {
                    return
                }
                if let view {
                    let point = g.location(in: view)
                    // A handle is always the gizmo's. Past the handles, only a
                    // drag that starts on the selection moves it; one that
                    // starts on empty space falls through to the camera below.
                    if !beginGizmoIfHit(at: point),
                       TransformGizmo.startsOnSelection(point, scene: parent.scene,
                                                        camera: parent.camera,
                                                        size: view.bounds.size) {
                        _ = beginFreeTransform(at: point)
                    }
                }
                return
            }

            // A select region owns the whole gesture: no orbit, no transform.
            if regionGesture != nil, let view {
                continueRegion(g, in: view)
                return
            }
            // A gizmo drag owns the gesture until the finger lifts: neither the
            // camera nor the unconstrained transform gets a look at it.
            if gizmo != nil {
                if let view, g.state == .changed { updateGizmo(to: g.location(in: view)) }
                if g.state == .ended || g.state == .cancelled || g.state == .failed { endGizmo() }
                return
            }
            // A stroke interrupted by the system is still a stroke that
            // happened, and what it changed has to be kept.
            if g.state == .cancelled || g.state == .failed {
                parent.scene.endViewportDrag(.brush)
                parent.scene.endViewportDrag(.orbit)
                finishStroke()
            }
            guard g.state == .changed || g.state == .ended else { lastPan = .zero; return }

            let dx = Float(p.x - lastPan.x)
            let dy = Float(p.y - lastPan.y)

            // Vertex and weight paint: a drag paints the attribute, not pixels.
            if parent.scene.mode == .vertexPaint || parent.scene.mode == .weightPaint {
                if g.state == .changed, let view {
                    vertexPaintDab(at: g.location(in: view), in: view)
                    parent.scene.beginViewportDrag(.brush,
                        parent.scene.mode == .vertexPaint ? "Vertex Paint" : "Weight Paint")
                } else if g.state == .ended || g.state == .cancelled {
                    parent.scene.endViewportDrag(.brush)
                }
                return
            }

            // Sculpt mode: a drag is a brush stroke, not a camera move —
            // unless the stand-in brush may not touch the mesh (Blender's, in
            // a 3D View without the bridge). Then the drag orbits, as a
            // refused gizmo drag does, and the refusal is said as it ends.
            let sculptRefusal = parent.scene.mode == .sculpt
                ? parent.scene.active?.standInSculptRefusal : nil
            if let sculptRefusal, g.state == .ended || g.state == .cancelled {
                noteSculptRefused(sculptRefusal)
            }
            if parent.scene.mode == .sculpt, sculptRefusal == nil {
                if g.state == .changed, let view {
                    if sculptDab(at: g.location(in: view), in: view, delta: SIMD2(dx, dy)),
                       strokeObject == nil {
                        strokeObject = parent.scene.active
                    }
                    parent.scene.beginViewportDrag(.brush,
                        "Sculpt  \(parent.scene.sculpt.brush.label)")
                } else if g.state == .ended {
                    parent.scene.endViewportDrag(.brush)
                    finishStroke()
                }
                return
            }

            // Anything that did not start a transform leaves the drag to the
            // camera, which is what Tweak does in Blender.
            //
            // That covers three cases. Tweak is the default tool, so this is
            // the drag the app opens on. A transform tool with *nothing
            // selected* gets here too: there is no pivot for a gizmo, so no
            // session could start, and falling through without orbiting left
            // the viewport completely dead to drags. And a transform tool whose
            // drag started on empty space rather than on the selection.
            if g.state == .changed {
                parent.camera.orbit(dx: dx * 0.008, dy: dy * 0.008)
                parent.scene.beginViewportDrag(.orbit, String(
                    format: "Orbit  %.0f°, %.0f°",
                    parent.camera.azimuth * 180 / .pi,
                    parent.camera.elevation * 180 / .pi))
            } else if g.state == .ended || g.state == .cancelled {
                parent.scene.endViewportDrag(.orbit)
            }
        }

        /// Hands a finished stroke to whoever keeps it.
        private func finishStroke() {
            guard let object = strokeObject else { return }
            strokeObject = nil
            parent.onStrokeEnd(object)
        }

        // MARK: Box, Circle and Lasso select

        struct RegionGesture {
            var tool: ActiveTool
            var points: [CGPoint]
            /// Shift or Ctrl held as the drag began, or nil for the tool
            /// setting (`parent.regionAction`).
            var action: SelectAction?
        }

        /// Starts a select region if the tool in hand draws one, here, in a
        /// mode that selects — objects, or elements while editing. Returns
        /// whether the drag is now the region's.
        func beginRegion(at point: CGPoint, modifiers: UIKeyModifierFlags) -> Bool {
            guard parent.tool.isRegionSelect,
                  parent.scene.mode == .object || parent.scene.mode == .edit else { return false }
            regionGesture = RegionGesture(
                tool: parent.tool, points: [point],
                action: SelectAction.forGesture(shift: modifiers.contains(.shift),
                                                control: modifiers.contains(.control)
                                                    || modifiers.contains(.command),
                                                circle: parent.tool == .circleSelect))
            showRegion()
            return true
        }

        /// Adds a point to the region. A lasso or circle keeps a point only
        /// once the drag has moved a little from the last one: a few hundred
        /// points is plenty of outline, and each is a test per element.
        func extendRegion(to point: CGPoint) {
            guard var gesture = regionGesture, let last = gesture.points.last else { return }
            let spacing: CGFloat = gesture.tool == .circleSelect ? max(2, parent.circleRadius / 4) : 2
            if gesture.tool == .boxSelect {
                gesture.points = [gesture.points[0], point]
            } else if hypot(point.x - last.x, point.y - last.y) >= spacing {
                gesture.points.append(point)
            } else { return }
            regionGesture = gesture
            showRegion()
        }

        /// The region the drag has made so far: exactly what is drawn, and
        /// exactly what `finishRegion` selects from.
        func currentRegion() -> SelectionRegion? {
            guard let gesture = regionGesture, let first = gesture.points.first else { return nil }
            switch gesture.tool {
            case .boxSelect:
                return .box(BoxSelect.rect(from: first, to: gesture.points.last ?? first))
            case .circleSelect:
                return .circle(path: gesture.points, radius: parent.circleRadius)
            default:
                return .lasso(gesture.points)
            }
        }

        private func showRegion() {
            guard let region = currentRegion() else { return }
            if case .box(let rect) = region {
                parent.scene.selectionBox = rect
            } else {
                parent.scene.selectionStroke = region
            }
        }

        private func continueRegion(_ g: UIGestureRecognizer, in view: MTKView) {
            switch g.state {
            case .changed:
                extendRegion(to: g.location(in: view))
            case .ended:
                extendRegion(to: g.location(in: view))
                finishRegion(in: view)
            case .cancelled, .failed:
                // Interrupted by the system: nothing was asked for.
                regionGesture = nil
                parent.scene.selectionBox = nil
                parent.scene.selectionStroke = nil
            default:
                break
            }
        }

        /// Selects what the region covers, and ends the gesture.
        ///
        /// Objects go through the bridge like every other selection, so the
        /// undo history sees one step rather than a silent change to the
        /// display cache — and so that on device bpy, not the cache, is what
        /// changed. While editing, the elements the pass picks are handed to
        /// Blender in the same way, as one "Box Select" / "Circle Select" /
        /// "Lasso Select" step, and what the viewport then shows selected is
        /// Blender's selection, read back by the mirror. Box select used to
        /// leave its elements on the display cache until the next command
        /// carried them over, so for a while the viewport showed a selection
        /// Blender did not hold.
        @discardableResult
        func finishRegion(in view: MTKView) -> SelectionRegion? {
            defer {
                regionGesture = nil
                parent.scene.selectionBox = nil
                parent.scene.selectionStroke = nil
            }
            guard let gesture = regionGesture, let region = currentRegion(), region.isUsable else { return nil }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let vp = parent.camera.viewProjection(aspect: Float(bounds.width / bounds.height))
            let action = gesture.action ?? parent.regionAction.forRegion(circle: gesture.tool == .circleSelect)
            // Blender's X-Ray, and Wireframe, where its X-Ray is on by default:
            // what the surface hides is selected too.
            let seeThrough = parent.options.xray || parent.shading == .wireframe

            // A curve's or a lattice's points: each inside the region, front
            // or back — Blender's box select tests their projection alone,
            // with no depth test (`nurbs_foreachScreenVert`,
            // `lattice_foreachScreenVert`).
            // By the object, not its points: a curve emptied in Edit Mode has
            // none, and is still no mesh (see `handleTap`).
            if parent.scene.mode == .edit, parent.scene.active?.editsPoints == true {
                // Blender's CANCELLED for a gesture that changes nothing.
                if let (object, next) = MetalViewportView.pointRegion(region, scene: parent.scene,
                                                                       camera: parent.camera, size: bounds.size,
                                                                       action: action) {
                    parent.bridge?.run(PointsBpy.select(next, object: object.name),
                                       undo: region.undoName, quiet: true)
                }
                return region
            }
            // Edit Mode with nothing active has no mesh to select on, and the
            // object-mode Python below is not what the header's mode asks for.
            if parent.scene.mode == .edit && parent.scene.active == nil {
                parent.bridge?.showReport(region.undoName, "No object is active, so Edit Mode has no mesh "
                                          + "to select on.")
                return nil
            }
            if parent.scene.mode == .edit, let object = parent.scene.active {
                // The pass and the push both work on a mesh's elements; a
                // curve's control points are neither.
                guard object.hasEditMode else {
                    parent.bridge?.showReport(region.undoName, "Selecting in Edit Mode works on meshes here, "
                                              + "and \(object.name) is not one.")
                    return nil
                }
                // A mesh drawn through a modifier that rebuilds it has no
                // vertex Blender would recognise, and the only push left
                // deselects everything first (`editRegionRefusal`, measured:
                // a Subdivision cube kept 0 of 8). Said, not done.
                if let bridge = parent.bridge, bridge.usesRealBlender, let refusal = object.editRegionRefusal() {
                    bridge.showReport(region.undoName, refusal)
                    return nil
                }
                let selection = object.regionSelection(region, mode: parent.scene.selectMode,
                                                       action: action,
                                                       current: parent.scene.editSelection,
                                                       viewProjection: vp, size: bounds.size,
                                                       seeThrough: seeThrough)
                // Blender's own gesture returns CANCELLED when it changes
                // nothing, and pushes no undo step; neither does this.
                let current = parent.scene.editSelection
                let unchanged: Bool
                switch parent.scene.selectMode {
                case .vertex: unchanged = selection.vertices == current.vertices
                case .edge:   unchanged = selection.edges == current.edges
                case .face:   unchanged = selection.faces == current.faces
                }
                if unchanged && !parent.scene.editSelectionPending { return region }
                if let bridge = parent.bridge, bridge.usesRealBlender {
                    bridge.run(Bpy.pushEditSelection(selection, mode: parent.scene.selectMode, of: object),
                               undo: region.undoName, quiet: true)
                } else {
                    // The simulator's stand-in reads the interface's selection.
                    parent.scene.editSelection = selection
                    parent.scene.editSelectionPending = true
                    parent.bridge?.noteSelectionChanged()
                }
                return region
            }

            let candidates = parent.scene.objects.map {
                (name: $0.name, origin: $0.modelMatrix.columns.3.xyz,
                 bounds: $0.worldBounds, visible: $0.visible)
            }
            var names = RegionSelect.objects(in: region, objects: candidates,
                                             viewProjection: vp, size: bounds.size)
            // Cameras, lights and empties are drawn as overlays; a box takes
            // one it covers any of, as it takes a mesh.
            if case .box(let rect) = region {
                names = names.includingObjectOverlays(in: rect, scene: parent.scene,
                                                      view: OverlayView(camera: parent.camera, size: bounds.size),
                                                      drawn: parent.options.showOverlays)
            }
            let hit = Set(parent.scene.objects.filter { names.contains($0.name) }.map(\.id))
            // Nothing to change is Blender's CANCELLED: no command, no step.
            guard action.applyRegion(parent.scene.selection, inside: hit) != parent.scene.selection
            else { return region }
            if let bridge = parent.bridge {
                bridge.run(SelectMenu.objectRegion(names, action: action), undo: region.undoName, quiet: true)
            } else {
                parent.scene.selection = action.applyRegion(parent.scene.selection, inside: hit)
                if let id = parent.scene.objects.first(where: { names.contains($0.name) })?.id,
                   parent.scene.selection.contains(id),
                   !(parent.scene.activeID.map(parent.scene.selection.contains) ?? false) {
                    parent.scene.activeID = id
                }
            }
            return region
        }

        /// Begin a transform that is not constrained to a handle.
        ///
        /// This used to be its own code path, moving `obj.location` directly.
        /// It moved the *object* — so in Edit Mode, dragging with the Move tool
        /// slid the whole mesh instead of the selected vertices, which is not
        /// what the Move tool means once you are editing points and faces.
        /// Running it through the gizmo's view-plane handle reuses the path
        /// that already knew about edit selections, proportional editing,
        /// snapping, the rollback and the operator to log.
        private func beginFreeTransform(at point: CGPoint) -> Bool {
            guard let view,
                  let mode = MetalViewportView.gizmoMode(for: parent.tool, scene: parent.scene)
            else { return false }
            guard let g = TransformGizmo.make(mode: mode, scene: parent.scene,
                                              options: parent.options,
                                              camera: parent.camera, size: view.bounds.size)
            else {
                // A transform tool with nothing to act on. The drag will orbit
                // instead, but silently orbiting when someone asked to move
                // reads as the Move tool being broken.
                parent.scene.beginViewportDrag(.orbit,
                    "Nothing selected — tap an object first")
                return false
            }
            gizmo = TransformGizmo.beginSession(handle: .screen, at: point, gizmo: g,
                                                scene: parent.scene, camera: parent.camera,
                                                size: view.bounds.size,
                                                options: parent.options,
                                                wireframe: parent.shading == .wireframe)
            gizmoResult = nil
            guard beginPointDragIfAny() else { return false }
            parent.scene.transformReadout = session_startReadout(for: .screen, mode: mode)
            parent.scene.clearViewportDrag()
            return true
        }

        /// How to end the readout the current trackpad scroll started, whichever
        /// kind of navigation it turned out to be.
        private var endScrollReadout: (() -> Void)?

        /// Trackpad two-finger scroll, read the way Blender reads a trackpad on
        /// a Mac: a plain swipe orbits, ⇧ pans, and ⌘ or ⌃ zooms. Pinch zooms
        /// as well, through the pinch recogniser.
        ///
        /// It used to zoom on every swipe, the way a mouse wheel does. But a
        /// trackpad is not a wheel: two fingers moving over a model mean turn
        /// it, and a pinch already means closer.
        @objc func handleScroll(_ g: UIPanGestureRecognizer) {
            // A stroke is aimed through the view it began in (the camera goes
            // to Blender with each chunk), so the view holds still under it,
            // as Blender's does while a brush is down.
            if sculptInput.isStroking { return }
            guard g.state == .changed || g.state == .began else {
                if g.state == .ended || g.state == .cancelled {
                    endScrollReadout?()
                    endScrollReadout = nil
                }
                return
            }
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            guard t != .zero else { return }
            let flags = g.modifierFlags
            let scene = parent.scene
            if flags.contains(.command) || flags.contains(.control) {
                // Scrolling up zooms in, matching the scroll wheel everywhere else.
                parent.camera.dolly(factor: 1 - Float(t.y) * 0.004)
                scene.beginViewportDrag(.zoom, String(format: "Zoom  %.2f m", parent.camera.distance))
                endScrollReadout = { scene.endViewportDrag(.zoom) }
            } else if flags.contains(.shift) {
                parent.camera.pan(dx: Float(t.x), dy: Float(t.y))
                scene.beginViewportDrag(.pan, "Pan")
                endScrollReadout = { scene.endViewportDrag(.pan) }
            } else {
                parent.camera.orbit(dx: Float(t.x) * 0.008, dy: Float(t.y) * 0.008)
                scene.beginViewportDrag(.orbit, String(
                    format: "Orbit  %.0f°, %.0f°",
                    parent.camera.azimuth * 180 / .pi,
                    parent.camera.elevation * 180 / .pi))
                endScrollReadout = { scene.endViewportDrag(.orbit) }
            }
        }

        /// One vertex-paint or weight-paint dab.
        ///
        /// Blender paints the *attribute* here, not a texture: the brush finds
        /// the surface under the touch and blends every vertex within its
        /// radius toward the brush value. That is why these modes need no UV
        /// unwrap, where texture paint does.
        func vertexPaintDab(at point: CGPoint, in view: MTKView) {
            guard let renderer, let obj = parent.scene.active, obj.visible else { return }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                                   1 - Float(point.y / bounds.height) * 2)
            guard let hit = renderer.surfaceHit(ndc: ndc,
                                                aspect: Float(bounds.width / bounds.height),
                                                on: obj) else { return }

            let settings = parent.scene.paint
            // The dab radius is a fraction of the object's own size, matching
            // how the sculpt brush is sized rather than the texture brush.
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in obj.mesh.vertices { lo = min(lo, v.position); hi = max(hi, v.position) }
            let radius = max(length(hi - lo) * 0.12, 0.05)
            let world = (obj.modelMatrix * SIMD4(hit.localPoint, 1)).xyz
            // The toolbar picks what the dab does, not just its colour.
            let op: VertexPaintOp
            switch parent.tool {
            case .paintBlur:    op = .blur
            case .paintAverage: op = .average
            default:            op = .draw
            }
            _ = obj.paintVertices(at: world, radius: radius, strength: settings.strength,
                                  op: op,
                                  colour: parent.scene.mode == .vertexPaint ? settings.colour : nil,
                                  weight: parent.scene.mode == .weightPaint ? settings.weight : nil,
                                  blend: settings.blend, falloff: settings.falloff)
        }

        /// One brush dab: ray-cast to the surface under the touch, then run the
        /// brush there. Blender does the same — the stroke follows the surface,
        /// so it works on whatever is under the cursor rather than a plane.
        ///
        /// Returns whether the brush touched the surface at all.
        @discardableResult
        func sculptDab(at point: CGPoint, in view: MTKView, delta: SIMD2<Float>) -> Bool {
            // Never over Blender's evaluated mesh: see `standInSculptRefusal`.
            guard let renderer, let obj = parent.scene.active, obj.visible,
                  obj.standInSculptRefusal == nil else { return false }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return false }

            let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                                   1 - Float(point.y / bounds.height) * 2)
            let aspect = Float(bounds.width / bounds.height)
            guard let hit = renderer.surfaceHit(ndc: ndc, aspect: aspect, on: obj) else { return false }

            let settings = parent.scene.sculpt
            var direction = hit.normal
            if settings.invert { direction = -direction }

            // Grab drags along the screen plane, so it needs the camera basis.
            let grab = parent.camera.right * (delta.x * parent.camera.distance * 0.002)
                     + parent.camera.trueUp * (-delta.y * parent.camera.distance * 0.002)
            // The brush works in the object's local space.
            let inv = obj.modelMatrix.inverse
            let localGrab = (inv * SIMD4(grab, 0)).xyz

            // Symmetry runs the same stroke on each mirrored copy of the hit
            // point, with the brush direction mirrored to match — otherwise the
            // reflected stroke would dig where the original raised.
            let localDirection = normalize((inv * SIMD4(direction, 0)).xyz)
            let centres = obj.symmetryPoints(hit.localPoint)
            let symmetry = obj.symmetry
            // The simulator's stand-in only: an approximation of Blender's
            // brushes, kept by `onStrokeEnd`. It runs over the mesh the
            // modifier stack runs over, installed once (`sculptStandIn`):
            // this took `obj.mesh`, the stack's output, and handed it to
            // `setMirroredMesh`, which ran the stack again on every dab.
            return obj.sculptStandIn { cage in
                var mesh = cage
                for centre in centres {
                    var d = localDirection
                    var g = localGrab
                    for axis in 0..<3 where symmetry[axis] && centre[axis] != hit.localPoint[axis] {
                        d[axis] = -d[axis]
                        g[axis] = -g[axis]
                    }
                    mesh = SculptEngine.stroke(mesh,
                                               at: centre,
                                               direction: d,
                                               brush: settings.brush,
                                               radius: settings.radius,
                                               strength: settings.strength * 0.35,
                                               grabDelta: g)
                }
                return mesh
            } == nil
        }

        /// A tap in Sculpt Mode that Blender's brush did not take: one dab of
        /// the stand-in brush, a stroke of its own — or, on Blender's mesh,
        /// the refusal. Returns whether a dab was installed.
        @discardableResult
        func standInSculptTap(at point: CGPoint, in view: MTKView) -> Bool {
            if let refusal = parent.scene.active?.standInSculptRefusal {
                noteSculptRefused(refusal)
                return false
            }
            guard let object = parent.scene.active,
                  sculptDab(at: point, in: view, delta: .zero) else { return false }
            parent.onStrokeEnd(object)
            return true
        }

        /// A sculpt drag or tap the stand-in brush refused — Blender's mesh,
        /// in a 3D View without the bridge to Blender's own brush — says why,
        /// once per gesture: on the banner where there is one, and in the log.
        func noteSculptRefused(_ refusal: String) {
            print("[bk] Sculpt refused: \(refusal)")
            fflush(stdout)
            parent.bridge?.showReport("Sculpt", refusal)
        }

        // MARK: gizmo drags

        /// What a tap on `hit` means, as Python.
        ///
        /// Blender has no single operator for "click this object in this mode",
        /// so the five selection modes come out as the data-level equivalent —
        /// which is what its own `view3d.select(mode=…)` does underneath.
        static func selectPython(_ hit: BKObject?, action: SelectAction) -> String {
            guard let hit else {
                // Clicking nothing clears only for Set, as everywhere else.
                return action == .set ? Bpy.deselectAll : "pass"
            }
            let name = Bpy.quote(hit.name)
            switch action {
            case .set:
                return Bpy.select(hit.name)
            case .extend:
                return """
                    bpy.data.objects[\(name)].select_set(True)
                    bpy.context.view_layer.objects.active = bpy.data.objects[\(name)]
                    """
            case .subtract:
                return "bpy.data.objects[\(name)].select_set(False)"
            case .difference:
                return """
                    _o = bpy.data.objects[\(name)]
                    _o.select_set(not _o.select_get())
                    """
            case .intersect:
                return """
                    for _o in list(bpy.data.objects):
                        if _o.name != \(name):
                            _o.select_set(False)
                    """
            }
        }

        /// The handle under a point, or nil. Rebuilt each call — the gizmo is a
        /// handful of vectors and the alternative is a cache to invalidate.
        private func gizmoHandle(at point: CGPoint) -> TransformGizmo.Handle? {
            guard parent.options.showGizmos, let view,
                  view.bounds.width > 0, view.bounds.height > 0,
                  let mode = MetalViewportView.gizmoMode(for: parent.tool, scene: parent.scene),
                  let g = TransformGizmo.make(mode: mode, scene: parent.scene,
                                              options: parent.options,
                                              camera: parent.camera, size: view.bounds.size)
            else { return nil }
            return g.hitTest(point, projection: TransformGizmo.Projection(camera: parent.camera,
                                                                          size: view.bounds.size))
        }

        /// True if the touch landed on a handle, in which case the drag is now
        /// the gizmo's.
        private func beginGizmoIfHit(at point: CGPoint) -> Bool {
            guard let view,
                  let mode = MetalViewportView.gizmoMode(for: parent.tool, scene: parent.scene),
                  let handle = gizmoHandle(at: point),
                  let g = TransformGizmo.make(mode: mode, scene: parent.scene,
                                              options: parent.options,
                                              camera: parent.camera, size: view.bounds.size)
            else { return false }
            gizmo = TransformGizmo.beginSession(handle: handle, at: point, gizmo: g,
                                                scene: parent.scene, camera: parent.camera,
                                                size: view.bounds.size,
                                                options: parent.options,
                                                wireframe: parent.shading == .wireframe)
            gizmoResult = nil
            // Refused: the banner says why, and the drag orbits as one on
            // nothing does.
            guard beginPointDragIfAny() else { return true }
            renderer?.gizmoHighlight = handle
            // Say the drag has taken hold before it has moved far enough to
            // show any change, which is exactly when it is least obvious.
            parent.scene.transformReadout = session_startReadout(for: handle,
                                                                 mode: mode)
            parent.scene.clearViewportDrag()
            return true
        }

        private func updateGizmo(to point: CGPoint) {
            guard let session = gizmo,
                  let raw = TransformGizmo.resolve(session, at: point) else { return }
            // Blender's magnet, from the scene's settings as the drag began.
            // The snapped value is both what is painted here and what
            // endGizmo commits: it used to round only the paint and send the
            // raw drag, so Blender moved off the grid and the mirror pulled
            // the object after it. A headless bpy cannot snap for us — its
            // exec path takes `value` as final (TransformSnap).
            let (result, target) = TransformGizmo.snapping(raw, session: session, at: point)
            if session.points != nil {
                // Blender previews a curve's or a lattice's points itself, by
                // the call the release commits; a value already shown is not
                // sent again.
                if result != gizmoResult, let bridge = parent.bridge,
                   !bridge.previewPointDrag(TransformGizmo.python(result, session: session),
                                            undo: session.gizmo.mode.undoName) {
                    abandonPointDrag()
                    return
                }
            } else {
                TransformGizmo.apply(result, session: session)
            }
            gizmoResult = result
            showSnapMarker(target, projection: session.projection)
            var readout = TransformGizmo.readout(result, session: session)
            // A finger covers the very point it is snapping near, and with it
            // the marker; the readout is not under it.
            if let target { readout += "  snap \(target.kind.label)" }
            parent.scene.transformReadout = readout
        }

        /// Draws Blender's symbol for the snap target, or clears it.
        private func showSnapMarker(_ target: GeometrySnap.Hit?, projection: TransformGizmo.Projection?) {
            guard let view else { return }
            let path = CGMutablePath()
            if let target, let projection, let centre = projection.project(target.location) {
                for stroke in TransformGizmo.snapMarker(target.kind, at: centre) {
                    path.addLines(between: stroke.points)
                    if stroke.closed { path.closeSubpath() }
                }
            }
            if snapMarker == nil, !path.isEmpty {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                // TH_ACTIVE, which Blender draws the target in.
                layer.strokeColor = UIColor(BTheme.active).cgColor
                layer.lineWidth = 1.5
                view.layer.addSublayer(layer)
                snapMarker = layer
            }
            guard let layer = snapMarker else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = view.bounds
            layer.path = path.isEmpty ? nil : path
            CATransaction.commit()
        }

        /// The readout at the moment of grabbing, before any movement.
        private func session_startReadout(for handle: TransformGizmo.Handle,
                                          mode: TransformGizmo.Mode) -> String {
            let verb = switch mode {
            case .translate: "Move"
            case .rotate:    "Rotate"
            case .scale:     "Scale"
            }
            switch handle {
            case .axis(let i):  return "\(verb)  along \(["X", "Y", "Z"][i])"
            case .plane(let i):
                let shown = (0..<3).filter { $0 != i }.map { ["X", "Y", "Z"][$0] }
                return "\(verb)  in \(shown.joined()) plane"
            case .screen:       return "\(verb)  view"
            }
        }

        /// Has Blender remember a curve's or a lattice's points before the
        /// drag that has just begun moves them. False when it refused — the
        /// banner says why — and the drag is dropped.
        private func beginPointDragIfAny() -> Bool {
            guard let session = gizmo, let points = session.points else { return true }
            guard let bridge = parent.bridge,
                  bridge.beginPointDrag(object: points.object.name, followers: points.followers,
                                        undo: session.gizmo.mode.undoName) else {
                gizmo = nil
                return false
            }
            return true
        }

        /// A point drag whose frame Blender refused: everything back as it
        /// was, and the gesture ends without a commit.
        private func abandonPointDrag() {
            parent.bridge?.cancelPointDrag()
            gizmo = nil
            gizmoResult = nil
            renderer?.gizmoHighlight = nil
            parent.scene.transformReadout = nil
            showSnapMarker(nil, projection: nil)
        }

        /// Ends a gizmo drag by handing the transform to Blender.
        ///
        /// The drag itself moved the display cache directly, because sending
        /// Python for every frame of a 60 fps gesture would not keep up. That
        /// makes the live drag a *preview*: on release the preview is rolled
        /// back to where the gesture started and the whole transform is applied
        /// once, through bpy, which is also exactly what Blender's Info log
        /// shows — one operator per gesture rather than one per frame.
        private func endGizmo() {
            defer {
                gizmo = nil
                gizmoResult = nil
                renderer?.gizmoHighlight = nil
                parent.scene.transformReadout = nil
                showSnapMarker(nil, projection: nil)
            }
            if let session = gizmo, session.points != nil, let bridge = parent.bridge {
                if let result = gizmoResult {
                    // The points go back where the drag found them and the
                    // previewed call runs once more, as the undo step.
                    bridge.commitPointDrag(TransformGizmo.python(result, session: session),
                                           undo: session.gizmo.mode.undoName)
                } else {
                    bridge.cancelPointDrag()
                }
                return
            }
            guard let session = gizmo, let result = gizmoResult else { return }
            let python = TransformGizmo.python(result, session: session)

            if let bridge = parent.bridge {
                TransformGizmo.rollBack(session)
                // The mirror left Blender nothing to transform: the preview
                // showed nothing move, and Blender would answer CANCELLED
                // having changed nothing — so nothing is sent, no empty step
                // is recorded, and the banner says why.
                if let why = TransformGizmo.nothingToCommit(session) {
                    bridge.showReport(session.gizmo.mode.undoName, why)
                    return
                }
                // In edit mode the operator acts on Blender's *vertex*
                // selection. Whatever was tapped since Blender last reported
                // its selection is handed over by the bridge, in the same
                // evaluation as the operator.
                bridge.run(python, undo: session.gizmo.mode.undoName)
            } else {
                parent.onTransform(python)
                parent.onCommit(session.gizmo.mode.undoName)
            }
        }

        @objc func handlePencilDrag(_ g: PencilPanGestureRecognizer) {
            let p = g.translation(in: g.view)
            if handleTexturePaint(g, pressure: g.pressure) { return }
            if handleBlenderSculpt(g, pressure: g.pressure) { return }

            if g.state == .began {
                lastPencilPan = .zero
                // The Pencil draws a lasso, a box or a circle stroke as a
                // finger does: the select tools are drags of their own.
                if let view, beginRegion(at: g.location(in: view), modifiers: g.modifierFlags) {
                    return
                }
                if let view, !beginGizmoIfHit(at: g.location(in: view)) {
                    _ = beginFreeTransform(at: g.location(in: view))
                }
                return
            }
            if regionGesture != nil, let view {
                continueRegion(g, in: view)
                return
            }
            if gizmo != nil {
                if let view, g.state == .changed { updateGizmo(to: g.location(in: view)) }
                if g.state == .ended || g.state == .cancelled || g.state == .failed { endGizmo() }
                return
            }
            guard g.state == .changed || g.state == .ended else { lastPencilPan = .zero; return }

            let dx = Float(p.x - lastPencilPan.x)
            let dy = Float(p.y - lastPencilPan.y)
            lastPencilPan = p

            // As above: no session means the camera takes the drag, whether
            // that is because Tweak is active or because nothing is selected
            // for a transform tool to act on.
            if g.state == .changed {
                parent.camera.orbit(dx: dx * 0.008, dy: dy * 0.008)
                parent.scene.beginViewportDrag(.orbit, String(
                    format: "Orbit  %.0f°, %.0f°",
                    parent.camera.azimuth * 180 / .pi,
                    parent.camera.elevation * 180 / .pi))
            } else if g.state == .ended || g.state == .cancelled {
                parent.scene.endViewportDrag(.orbit)
            }
        }

        /// Pencil hover: highlights the object under the tip without selecting
        /// it. Only fires on hardware that reports hover.
        @objc func handleHover(_ g: UIHoverGestureRecognizer) {
            guard let view, let renderer else { return }
            switch g.state {
            case .began, .changed:
                let point = g.location(in: view)
                let bounds = view.bounds
                guard bounds.width > 0, bounds.height > 0 else { return }
                // A handle under the tip lights up and suppresses the object
                // highlight, so it is obvious which of the two a touch will hit.
                renderer.gizmoHighlight = gizmoHandle(at: point)
                if renderer.gizmoHighlight != nil {
                    parent.scene.hoveredID = nil
                    return
                }
                let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                                       1 - Float(point.y / bounds.height) * 2)
                let hit = renderer.hitTest(ndc: ndc, aspect: Float(bounds.width / bounds.height))
                parent.scene.hoveredID = hit?.id
            default:
                parent.scene.hoveredID = nil
                renderer.gizmoHighlight = nil
            }
        }

        /// Barrel double-tap cycles the toolbar, matching the system setting.
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            parent.onCycleTool()
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            if sculptInput.isStroking { return }
            let p = g.translation(in: g.view)
            defer { lastPan = p }
            guard g.state == .changed else {
                lastPan = .zero
                if g.state == .ended || g.state == .cancelled { parent.scene.endViewportDrag(.pan) }
                return
            }
            parent.camera.pan(dx: Float(p.x - lastPan.x), dy: Float(p.y - lastPan.y))
            parent.scene.beginViewportDrag(.pan, "Pan")
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if sculptInput.isStroking { return }
            switch g.state {
            case .began:
                pinchStartDistance = parent.camera.distance
            case .changed:
                parent.camera.distance = min(max(pinchStartDistance / Float(g.scale), 0.4), 500)
                parent.scene.beginViewportDrag(.zoom,
                    String(format: "Zoom  %.2f m", parent.camera.distance))
            default:
                parent.scene.endViewportDrag(.zoom)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view, let renderer else { return }
            // A tap in the view gives it the keyboard back — after a sheet with
            // a text field, say — so Tab reaches it again.
            (view as? ViewportMTKView)?.takeKeyboard()
            let point = g.location(in: view)
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            // UIKit's origin is top-left; NDC is centre-origin with +Y up.
            let ndc = SIMD2<Float>(
                Float(point.x / bounds.width) * 2 - 1,
                1 - Float(point.y / bounds.height) * 2
            )
            let aspect = Float(bounds.width / bounds.height)

            if texturePaintTap(g) { return }
            if tapBlenderSculpt(at: point, in: view) { return }

            // Sculpt mode taps are dabs, not selections — and a dab is a whole
            // stroke of its own.
            if parent.scene.mode == .sculpt {
                standInSculptTap(at: point, in: view)
                return
            }

            // A curve's or a lattice's Edit Mode: a tap picks a control point
            // — the nearest within a fingertip, as Blender's click takes the
            // nearest — and Blender is told at once, so what lights up is
            // what it holds. A knot takes its handles with it
            // (`ControlCage.tapped`). By the object, not by its points: a
            // curve with every point deleted has none, and its tap fell into
            // the mesh branch below, which marked a mesh selection for the
            // next command to push — measured in 5.2.1, Done then failed with
            // "expected 'Mesh' type found 'Curve' instead" and stayed in Edit
            // Mode.
            if parent.scene.mode == .edit, parent.scene.active?.editsPoints == true {
                if let (object, next) = MetalViewportView.pointTap(at: point, scene: parent.scene,
                                                                    camera: parent.camera, size: bounds.size,
                                                                    action: parent.selectAction) {
                    parent.bridge?.select(PointsBpy.select(next, object: object.name))
                }
                return
            }

            // In edit mode a tap picks a mesh element, not an object.
            if parent.scene.mode == .edit {
                // The tap's pick reaches Blender the way a region's does
                // (`Bpy.pushEditSelection`), so it has the region's limit: a
                // mesh drawn through a modifier that rebuilds it has no vertex
                // Blender would recognise, and the push left is the one that
                // deselects everything first. Measured in 5.2.1 (round 3's
                // review): with all 8 of a cube's vertices selected, one tap
                // left 0 of 8 under a Subdivision Surface and 1 under a Mirror.
                // Said, not done, as Box, Circle and Lasso do.
                if let bridge = parent.bridge, bridge.usesRealBlender,
                   let refusal = parent.scene.active?.editRegionRefusal() {
                    bridge.showReport("Select", refusal)
                    return
                }
                let mode = parent.scene.selectMode
                let hit = renderer.hitTestElement(
                    ndc: ndc, aspect: aspect, mode: mode,
                    viewSize: SIMD2(Float(bounds.width), Float(bounds.height)))
                let action = parent.selectAction
                var selection = parent.scene.editSelection

                // Each component set is combined separately, so Extend on a
                // face selection grows the faces and the vertices they imply.
                // Numbered on the cage the tap picked on (`hitTestElement`).
                let cage = parent.scene.active?.editCage
                var hitVerts: Set<Int> = []
                if !hit.faces.isEmpty, let cage {
                    hitVerts = MeshEditor.vertices(of: hit.faces, in: cage)
                }
                if let v = hit.vertex { hitVerts = [v] }
                var hitEdges: Set<Int> = []
                if let e = hit.edge, let cage {
                    hitEdges = [e]
                    let base = e * 2
                    if base + 1 < cage.edges.count {
                        hitVerts = [Int(cage.edges[base]), Int(cage.edges[base + 1])]
                    }
                }
                selection.faces = action.apply(selection.faces, hit: hit.faces)
                selection.vertices = action.apply(selection.vertices, hit: hitVerts)
                selection.edges = action.apply(selection.edges, hit: hitEdges)
                parent.scene.editSelection = selection
                // Blender is told before the next command acts on it, in that
                // command's own evaluation, rather than paying a round trip per
                // tap.
                parent.scene.editSelectionPending = true
                parent.bridge?.noteSelectionChanged()
                return
            }

            let hit = renderer.hitTest(ndc: ndc, aspect: aspect)
            // Tell Blender, not just the display cache — once.
            //
            // A tap used to set `scene.selection` and only log the equivalent
            // Python, so bpy's own selection never changed: the next
            // `bpy.ops.transform.translate`, which acts on *Blender's*
            // selection, moved whatever was selected last, and the mirror put
            // the dragged object back where Blender still had it. Then for a
            // while the selection was sent twice, and every tap paid for two
            // full read-backs of the scene. `select` sends it once and reads
            // back only the selection.
            if let bridge = parent.bridge {
                bridge.select(Self.selectPython(hit, action: parent.selectAction))
            } else {
                let hitSet: Set<UUID> = hit.map { [$0.id] } ?? []
                let next = parent.selectAction.apply(parent.scene.selection, hit: hitSet)
                parent.scene.selection = next
                if let hit, next.contains(hit.id) { parent.scene.activeID = hit.id }
                parent.onSelectionChange(hit)
            }
        }
    }
}

extension MetalViewportView {
    /// What a tap at `point` does in a curve's or a lattice's Edit Mode: the
    /// object and the selection it leaves, or nil when it changes nothing.
    /// The nearest visible point within a fingertip is picked, as Blender's
    /// click takes the nearest, and a knot takes its handles with it
    /// (`ControlCage.tapped`). The tap gesture and the `-points-ops` launch
    /// hook both come through here.
    static func pointTap(at point: CGPoint, scene: BKScene, camera: ViewportCamera, size: CGSize,
                         action: SelectAction) -> (object: BKObject, selection: Set<Int>)? {
        guard let (object, cage) = scene.editedPoints, size.width > 0, size.height > 0 else { return nil }
        let vp = camera.viewProjection(aspect: Float(size.width / size.height))
        let hit = cage.pick(at: point, model: object.modelMatrix, viewProjection: vp, size: size,
                            radius: TransformGizmo.grabSlop)
        let next = action.apply(cage.selected, hit: hit.map(cage.tapped) ?? [])
        return next == cage.selected ? nil : (object, next)
    }

    /// What a Box, Circle or Lasso does in a curve's or a lattice's Edit
    /// Mode: every visible point inside, front or back — Blender's box select
    /// tests their projection alone, with no depth test
    /// (`nurbs_foreachScreenVert`, `lattice_foreachScreenVert`). Nil when the
    /// selection would not change.
    static func pointRegion(_ region: SelectionRegion, scene: BKScene, camera: ViewportCamera, size: CGSize,
                            action: SelectAction) -> (object: BKObject, selection: Set<Int>)? {
        guard let (object, cage) = scene.editedPoints, size.width > 0, size.height > 0 else { return nil }
        let vp = camera.viewProjection(aspect: Float(size.width / size.height))
        let inside = cage.inside(region, model: object.modelMatrix, viewProjection: vp, size: size)
        let next = action.applyRegion(cage.selected, inside: inside)
        return next == cage.selected ? nil : (object, next)
    }
}

/// The viewport's Metal view, able to take the keyboard.
///
/// For one key: Tab. The 3D View's other keys are menu commands, but iPadOS can
/// use Tab to move keyboard focus between controls, and on the running app Tab
/// never reached its menu command while G and 7 did. A key command on the first
/// responder can ask for priority over that system behaviour, so the view takes
/// the keyboard while it is on screen and has something for Tab to do.
final class ViewportMTKView: MTKView {
    /// Nil where Tab means nothing, which also leaves the keyboard alone.
    var onTab: (() -> Void)?

    override var canBecomeFirstResponder: Bool { onTab != nil }

    override var keyCommands: [UIKeyCommand]? {
        guard onTab != nil else { return nil }
        let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabPressed))
        tab.wantsPriorityOverSystemBehavior = true
        return [tab]
    }

    @objc private func tabPressed() { onTab?() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { takeKeyboard() }
    }

    func takeKeyboard() {
        guard onTab != nil, window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }
}

/// Whether a text field or text view has the keyboard, anywhere in the window.
///
/// The 3D View's commands are bare letters — G, R, S, X — and a letter typed
/// into a field has to be a letter. SwiftUI has no app-wide answer to "is
/// something being typed into", so this counts UIKit's own editing
/// notifications, which every SwiftUI text field and search field sends.
@MainActor @Observable
final class TextEntryFocus {
    static let shared = TextEntryFocus()

    private(set) var isEditing = false
    /// Counted rather than flagged: moving from one field to another can
    /// announce the new field before the old one has finished.
    @ObservationIgnored private var editors = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let changes: [(Notification.Name, Int)] = [
            (UITextField.textDidBeginEditingNotification, 1),
            (UITextView.textDidBeginEditingNotification, 1),
            (UITextField.textDidEndEditingNotification, -1),
            (UITextView.textDidEndEditingNotification, -1),
        ]
        for (name, step) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.count(step) }
            })
        }
    }

    private func count(_ step: Int) {
        editors = max(0, editors + step)
        if (editors > 0) != isEditing { isEditing = editors > 0 }
    }
}

#if DEBUG
extension MetalViewportView.Coordinator {
    /// `-region-select <gestures>`: Box, Circle and Lasso drags, made through
    /// the three calls a finger's drag makes — `beginRegion`, `extendRegion`,
    /// `finishRegion` — so what is tested is the gesture's own path to
    /// Blender, not a stand-in for it.
    ///
    /// Gestures are separated by `|`, each `tool:x,y;x,y;…[:radius][+extend|+subtract|+intersect]`
    /// with the points as fractions of the view (`box:0.3,0.3;0.7,0.7`,
    /// `circle:0.4,0.5;0.6,0.5:30`, `lasso:0.3,0.3;0.7,0.3;0.5,0.8`).
    /// `-region-mode edit` waits for Blender's edit mode (a `-eval64` script
    /// puts it there), `-region-wait <name>` for an object of that name, and
    /// `-region-view top` snaps the view to Blender's Top and frames the scene
    /// first, and `-region-view persp:8` puts the opening perspective view 8
    /// from the origin. After each gesture it prints what Blender holds,
    /// read back from Blender, beside what the viewport shows.
    func regionSelectLaunchIfRequested(tries: Int = 120) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let spec = value("-region-select") else { return }
        guard tries > 0 else {
            print("[bk] region-select: never ready (mode \(parent.scene.mode.bpyMode))"); fflush(stdout)
            return
        }
        let wantEdit = value("-region-mode") == "edit"
        // `-region-wait <name>`: until the `-eval64` script has made the
        // object of that name, the scene on screen is the one the app opened.
        let waitFor = value("-region-wait")
        guard let view, view.bounds.width > 0, let bridge = parent.bridge, !bridge.isRunningScript,
              !parent.scene.objects.isEmpty, !wantEdit || parent.scene.mode == .edit,
              waitFor.map({ name in parent.scene.objects.contains { $0.name == name } }) ?? true
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.regionSelectLaunchIfRequested(tries: tries - 1) }
            return
        }
        if let name = value("-region-view") {
            if let viewpoint = ViewportCamera.Viewpoint(rawValue: name) {
                parent.camera.snap(to: viewpoint)
                parent.camera.frameAll(parent.scene.objects)
            } else if name.hasPrefix("persp:"), let distance = Float(name.dropFirst("persp:".count)) {
                // `persp:<distance>`: the opening view, in perspective, that
                // far from the origin — a floor larger than the view then
                // reaches behind the eye, which framing would undo.
                var camera = ViewportCamera()
                camera.distance = distance
                parent.camera = camera
            }
        }
        let gestures = spec.split(separator: "|").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.regionLaunchGesture(gestures, index: 0, in: view, bridge: bridge)
        }
    }

    private func regionLaunchGesture(_ gestures: [String], index: Int, in view: MTKView, bridge: BpyBridge) {
        guard index < gestures.count else {
            print("[bk] region-select: done"); fflush(stdout)
            return
        }
        var text = gestures[index]
        // `mode:VERT|EDGE|FACE` sets the select mode as the header's buttons
        // do (Blender's `mesh_select_mode`, then the interface's), and `none`
        // deselects as Select ▸ None does, between gestures.
        if text.hasPrefix("mode:") || text == "none" {
            if text == "none" {
                bridge.run(Bpy.deselectAll(editing: parent.scene.mode == .edit), undo: "Deselect")
            } else if let mode = MeshSelectMode.allCases.first(where: { $0.bpyType == text.dropFirst(5) }) {
                bridge.run(Bpy.setSelectMode(mode))
                parent.scene.selectMode = mode
            }
            print("[bk] region-select \(text): Blender's select mode \(parent.scene.selectMode.bpyType)")
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.regionLaunchGesture(gestures, index: index + 1, in: view, bridge: bridge)
            }
            return
        }
        var modifiers: UIKeyModifierFlags = []
        if text.hasSuffix("+extend") { modifiers = .shift; text.removeLast("+extend".count) }
        if text.hasSuffix("+subtract") { modifiers = .control; text.removeLast("+subtract".count) }
        if text.hasSuffix("+intersect") { modifiers = [.shift, .control]; text.removeLast("+intersect".count) }
        let parts = text.split(separator: ":").map(String.init)
        let tools: [String: ActiveTool] = ["box": .boxSelect, "circle": .circleSelect, "lasso": .lassoSelect]
        guard parts.count >= 2, let tool = tools[parts[0]] else {
            print("[bk] region-select: cannot read \(gestures[index])"); fflush(stdout)
            return
        }
        let size = view.bounds.size
        // A point is a fraction of the view, `x,y`, or a place in the scene,
        // `@x,y,z`, where the camera shows it.
        let vp = parent.camera.viewProjection(aspect: Float(size.width / size.height))
        let points = parts[1].split(separator: ";").compactMap { pair -> CGPoint? in
            if pair.hasPrefix("@") {
                let xyz = pair.dropFirst().split(separator: ",").compactMap { Float($0) }
                guard xyz.count == 3 else { return nil }
                return BoxSelect.project(SIMD3(xyz[0], xyz[1], xyz[2]), viewProjection: vp, size: size)
            }
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? CGPoint(x: CGFloat(xy[0]) * size.width, y: CGFloat(xy[1]) * size.height) : nil
        }
        if parts.count >= 3, let r = Double(parts[2]) { parent.circleRadius = CGFloat(r) }
        let previousTool = parent.tool
        parent.tool = tool
        let editing = parent.scene.mode == .edit
        let mode = parent.scene.selectMode
        guard let first = points.first, beginRegion(at: first, modifiers: modifiers) else {
            print("[bk] region-select: \(parts[0]) did not start (tool \(tool), mode \(parent.scene.mode))")
            fflush(stdout)
            parent.tool = previousTool
            return
        }
        // A lasso and a circle are drawn through every point; a box from the
        // first to the last, with the points between standing in for the drag.
        var stroke = points.dropFirst().map { $0 }
        if tool != .boxSelect, stroke.count >= 1 {
            // Fill in the drag between the given corners, as a finger's
            // samples would.
            var dense: [CGPoint] = []
            var from = first
            for to in stroke {
                let steps = max(1, Int(hypot(to.x - from.x, to.y - from.y) / 3))
                for k in 1...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    dense.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                }
                from = to
            }
            stroke = dense
        }
        for p in stroke { extendRegion(to: p) }
        let shown = parent.scene.selectionStroke ?? parent.scene.selectionBox.map { SelectionRegion.box($0) }
        let drawn = currentRegion()
        let seeThrough = parent.options.xray || parent.shading == .wireframe
        // The shape the overlay shades — `SelectionStrokeOverlay.shaded`, the
        // path its Canvas fills — against the region the pass selects from,
        // sampled over the region's bounds. Samples within a point of the
        // outline are left out: there antialiasing decides, not the shape.
        // `shown == used` alone only says the overlay and the commit read
        // the same gesture state, which they always do.
        var overlay = "overlay: nothing drawn"
        if let shown, let (area, style) = SelectionStrokeOverlay.shaded(shown) {
            let b = shown.bounds.insetBy(dx: -4, dy: -4)
            let step = max(2, (b.width * b.height / 20_000).squareRoot())
            var sampled = 0, differ = 0
            var y = b.minY
            while y <= b.maxY {
                var x = b.minX
                while x <= b.maxX {
                    let p = CGPoint(x: x, y: y)
                    let inside = shown.contains(p)
                    let onOutline = [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)]
                        .contains { shown.contains(CGPoint(x: p.x + $0.x, y: p.y + $0.y)) != inside }
                    if !onOutline {
                        sampled += 1
                        if area.contains(p, eoFill: style.isEOFilled) != inside { differ += 1 }
                    }
                    x += step
                }
                y += step
            }
            overlay = "overlay shades the selected region: \(differ) of \(sampled) samples differ"
        }
        // The pass's own answer for the same region, before the gesture sends
        // anything, so the print can say whether Blender now holds it.
        var picked: EditSelection?
        let gestureAction = regionGesture?.action
            ?? parent.regionAction.forRegion(circle: regionGesture?.tool == .circleSelect)
        if editing, let object = parent.scene.active, let drawn {
            let bounds = view.bounds
            let vp = parent.camera.viewProjection(aspect: Float(bounds.width / bounds.height))
            picked = object.regionSelection(drawn, mode: mode, action: gestureAction,
                                            current: parent.scene.editSelection,
                                            viewProjection: vp, size: bounds.size, seeThrough: seeThrough)
        }
        let reportBefore = bridge.report?.id
        let used = finishRegion(in: view)
        parent.tool = previousTool
        // A refused gesture sends nothing and says why in a new banner.
        let refused = used == nil && bridge.report != nil && bridge.report?.id != reportBefore
        let preview = refused ? "refused, nothing sent"
            : shown == used ? "gesture state == commit" : "GESTURE STATE DIFFERS FROM COMMIT"
        let banner = bridge.report.map { "\($0.operation): \($0.message)" } ?? "none"
        if editing {
            let answer = bridge.capture("""
                import bmesh
                _bm = bmesh.from_edit_mesh(bpy.context.object.data)
                print(sum(v.select for v in _bm.verts), sum(e.select for e in _bm.edges), sum(f.select for f in _bm.faces))
                print(','.join(str(v.index) for v in _bm.verts if v.select))
                print(','.join('%d-%d' % tuple(sorted(v.index for v in e.verts)) for e in _bm.edges if e.select))
                print(','.join(str(f.index) for f in _bm.faces if f.select))
                """) ?? "?"
            let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            func field(_ i: Int) -> [String] {
                (lines.count > i ? lines[i] : "").split(separator: ",").map(String.init)
            }
            // Vertices by index, edges by their two ends, faces as Blender's
            // polygons — the viewport's selections put in Blender's terms.
            let blender = (Set(field(1).compactMap { Int($0) }), Set(field(2)), Set(field(3).compactMap { Int($0) }))
            func terms(_ sel: EditSelection) -> (Set<Int>, Set<String>, Set<Int>) {
                guard let object = parent.scene.active else { return ([], [], []) }
                let cage = object.editCage
                let edges = Set(sel.edges.compactMap { e -> String? in
                    guard 2 * e + 1 < cage.edges.count else { return nil }
                    let a = Int(cage.edges[2 * e]), b = Int(cage.edges[2 * e + 1])
                    return "\(min(a, b))-\(max(a, b))"
                })
                let faces = Set(sel.faces.compactMap { object.editTopology?.trianglePolygons[safe: $0].map(Int.init) })
                return (sel.vertices, edges, faces)
            }
            func agree(_ a: (Set<Int>, Set<String>, Set<Int>), _ b: (Set<Int>, Set<String>, Set<Int>)) -> String {
                [a.0 == b.0 ? "v" : "V≠", a.1 == b.1 ? "e" : "E≠", a.2 == b.2 ? "f" : "F≠"].joined(separator: " ")
            }
            let viewport = terms(parent.scene.editSelection)
            let pass = picked.map(terms)
            let camera = parent.camera
            print("[bk] region-select \(gestures[index]) (\(mode.bpyType), x-ray \(seeThrough), "
                  + "\(gestureAction.label), \(camera.isOrthographic ? "ortho" : "persp") view at "
                  + String(format: "%.1f", camera.distance) + "): \(preview); \(overlay); "
                  + (pass.map { "pass picked \($0.0.count)v/\($0.1.count)e/\($0.2.count)f; " } ?? "")
                  + "Blender holds \(lines.first ?? "?") (v/e/f); the viewport shows "
                  + "\(viewport.0.count)v/\(viewport.1.count)e/\(viewport.2.count)f; "
                  + "pass vs Blender [\(pass.map { agree($0, blender) } ?? "-")], "
                  + "viewport vs Blender [\(agree(viewport, blender))]; banner: \(banner)")
        } else {
            let answer = bridge.capture(
                "print(','.join(sorted(o.name for o in bpy.context.view_layer.objects if o.select_get())))") ?? "?"
            let shownNames = parent.scene.objects.filter { parent.scene.selection.contains($0.id) }.map(\.name).sorted()
            print("[bk] region-select \(gestures[index]) (objects): \(preview); Blender holds [\(answer)], "
                  + "the viewport shows [\(shownNames.joined(separator: ","))] — "
                  + (answer == shownNames.joined(separator: ",") ? "the same" : "DIFFERENT")
                  + "; banner: \(bridge.report.map { "\($0.operation): \($0.message)" } ?? "none")")
        }
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.regionLaunchGesture(gestures, index: index + 1, in: view, bridge: bridge)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
