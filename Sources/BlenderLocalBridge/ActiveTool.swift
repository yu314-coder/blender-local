import Foundation

/// Blender's active tool, chosen in the toolbar (the T-panel).
///
/// The list and its grouping come from Blender's own tool registry — the
/// `_tools` table on the VIEW_3D `ToolSelectPanelHelper`, read out of
/// Blender 5.2.1 rather than from memory. Which tools appear depends on the
/// mode, so Sculpt shows brushes where Object shows transforms.
public enum ActiveTool: String, CaseIterable, Identifiable {
    // Generic, present in every mode.
    case select, boxSelect, circleSelect, lassoSelect
    case cursor
    case move, rotate, scale, transform
    case annotate, measure

    // Add Primitive, which Blender offers in Object, Edit and Sculpt.
    case addCube, addCone, addCylinder, addUVSphere, addIcoSphere

    // Edit Mesh.
    case extrudeRegion, insetFaces, bevel, loopCut, knife, polyBuild, spin
    case smoothTool, randomize, edgeSlide, shrinkFatten, shear, ripRegion

    // Sculpt: the toolbar here is the brush list.
    case sculptDraw, sculptInflate, sculptSmooth, sculptFlatten, sculptGrab, sculptPinch
    case boxMask, boxHide, boxFaceSet, meshFilter, lineProject

    // Vertex / Weight / Texture paint.
    case paintDraw, paintBlur, paintAverage, paintSmear
    case gradient, sampleWeight, paintFill, paintClone

    public var id: String { rawValue }

    /// Tools with behaviour behind them. The rest are drawn disabled, the way
    /// Blender greys out what does not apply, rather than looking live and
    /// doing nothing when tapped.
    public var isImplemented: Bool {
        switch self {
        case .select, .move, .rotate, .scale, .transform:
            return true
        // Circle and Lasso waited on "a screen-space selection pass". Box
        // select had one for objects; `RegionSelect` is one for all three,
        // elements included, and hides what the surface hides unless X-Ray is
        // on, as Blender's selection buffer does.
        case .boxSelect, .circleSelect, .lassoSelect:
            return true
        case .addCube, .addCone, .addCylinder, .addUVSphere, .addIcoSphere:
            return true
        case .extrudeRegion, .insetFaces, .smoothTool, .randomize:
            return true
        // Bevel was greyed out with "needs a half-edge mesh structure". That
        // was true when the app had its own Swift mesh engine; Blender's own
        // BMesh has been doing the work for a while, and the Mesh menu has
        // been offering the same operator all along. Measured in Blender
        // 5.2.1 in background mode: bevel takes a cube from 8 vertices to 56.
        case .bevel:
            return true
        // Spin: measured taking a cube from 8 vertices to 56 in Blender 5.2.1
        // without a window. Its axis and centre are redo-panel fields here,
        // because Blender's own choice — the view axis — needs a view.
        case .spin:
            return true
        case .sculptDraw, .sculptInflate, .sculptSmooth, .sculptFlatten,
             .sculptGrab, .sculptPinch:
            return true
        // Smear waited on "stroke history to smear along". Texture Paint's
        // strokes have it: each dab knows where the last one was.
        case .paintDraw, .paintBlur, .paintAverage, .paintSmear:
            return true
        default:
            return false
        }
    }

    /// Why a tool is unavailable, shown as its tooltip.
    public var requirement: String {
        switch self {
        case .cursor:      return "Needs a placeable 3D cursor gizmo"
        case .annotate:    return "Needs grease-pencil strokes"
        case .measure:     return "Needs a ruler gizmo"
        // Measured, not assumed. In Blender 5.2.1 without a window:
        // `knife_tool`, `transform.shear` and `rip_move` fail their poll
        // outright; `loopcut_slide` with its defaults returns CANCELLED and
        // changes nothing, because it wants a modal drag in a viewport to say
        // where the cut goes. Given an edge index instead, `loopcut` and
        // `loopcut_slide` segfault Blender in `loopcut_init` when the context
        // has no 3D View (5.2.1, 2026-10-02), so `_blenderkit_context` refuses
        // both outside one (`NEEDS_VIEW`). None of that is about the mesh
        // structure — Blender's BMesh is right there and bevel uses it.
        case .loopCut, .ripRegion:
            return "Blender runs this one modally, in a window it does not have here"
        // `edge_slide` is not one of them, as this once said. Given a value
        // it slides without a window: `edge_slide(value=0.5)` moved an
        // 11-vertex loop of a 10 × 10 grid by half its 0.2 spacing. Called
        // with no value it returns FINISHED and moves nothing (the value is 0),
        // and on a selection that is not a loop — a whole cube — CANCELLED.
        // What needs the window is the tool: a drag that picks the side and
        // the distance from where the finger goes.
        case .edgeSlide:
            return "Blender slides from a drag in a window it does not have here. "
                + "Mesh ▸ Edge ▸ Edge Slide takes the distance as a Factor instead"
        // `knife_project` does run, with a view aimed for it: see
        // `LastOperator.knifeProject`.
        case .knife:
            return "Blender runs the drawn knife modally, in a window it does not have here. "
                + "Mesh ▸ Cut and Divide ▸ Knife Project cuts with another object's outline instead"
        case .shear:
            return "Blender refuses this one without a viewport context"
        case .polyBuild, .shrinkFatten:
            return "Not wired up yet — Blender can do it"
        case .boxMask, .boxHide, .boxFaceSet, .meshFilter, .lineProject:
            return "Needs per-vertex masks and face sets"
        case .gradient:     return "Needs a gradient stroke gizmo"
        case .sampleWeight: return "Needs an eyedropper"
        case .paintFill:    return "Needs a flood fill across UV islands"
        case .paintClone:   return "Needs a clone source offset"
        default:            return ""
        }
    }

    public var label: String {
        switch self {
        case .select:        return "Tweak"
        case .boxSelect:     return "Select Box"
        case .circleSelect:  return "Select Circle"
        case .lassoSelect:   return "Select Lasso"
        case .cursor:        return "Cursor"
        case .move:          return "Move"
        case .rotate:        return "Rotate"
        case .scale:         return "Scale"
        case .transform:     return "Transform"
        case .annotate:      return "Annotate"
        case .measure:       return "Measure"
        case .addCube:       return "Add Cube"
        case .addCone:       return "Add Cone"
        case .addCylinder:   return "Add Cylinder"
        case .addUVSphere:   return "Add UV Sphere"
        case .addIcoSphere:  return "Add Ico Sphere"
        case .extrudeRegion: return "Extrude Region"
        case .insetFaces:    return "Inset Faces"
        case .bevel:         return "Bevel"
        case .loopCut:       return "Loop Cut"
        case .knife:         return "Knife"
        case .polyBuild:     return "Poly Build"
        case .spin:          return "Spin"
        case .smoothTool:    return "Smooth"
        case .randomize:     return "Randomize"
        case .edgeSlide:     return "Edge Slide"
        case .shrinkFatten:  return "Shrink/Fatten"
        case .shear:         return "Shear"
        case .ripRegion:     return "Rip Region"
        case .sculptDraw:    return "Draw"
        case .sculptInflate: return "Inflate"
        case .sculptSmooth:  return "Smooth"
        case .sculptFlatten: return "Flatten"
        case .sculptGrab:    return "Grab"
        case .sculptPinch:   return "Pinch"
        case .boxMask:       return "Box Mask"
        case .boxHide:       return "Box Hide"
        case .boxFaceSet:    return "Box Face Set"
        case .meshFilter:    return "Mesh Filter"
        case .lineProject:   return "Line Project"
        case .paintDraw:     return "Draw"
        case .paintBlur:     return "Blur"
        case .paintAverage:  return "Average"
        case .paintSmear:    return "Smear"
        case .gradient:      return "Gradient"
        case .sampleWeight:  return "Sample Weight"
        case .paintFill:     return "Fill"
        case .paintClone:    return "Clone"
        }
    }

    public var icon: String {
        switch self {
        case .select:        return "cursorarrow"
        case .boxSelect:     return "rectangle.dashed"
        case .circleSelect:  return "circle.dashed"
        case .lassoSelect:   return "lasso"
        case .cursor:        return "scope"
        case .move:          return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate:        return "arrow.triangle.2.circlepath"
        case .scale:         return "arrow.up.left.and.arrow.down.right"
        case .transform:     return "move.3d"
        case .annotate:      return "pencil.tip"
        case .measure:       return "ruler"
        case .addCube:       return "cube.transparent"
        case .addCone:       return "cone"
        case .addCylinder:   return "cylinder"
        case .addUVSphere:   return "globe"
        case .addIcoSphere:  return "circle.hexagongrid"
        case .extrudeRegion: return "arrow.up.square"
        case .insetFaces:    return "square.on.square"
        case .bevel:         return "square.righthalf.filled"
        case .loopCut:       return "square.split.2x1"
        case .knife:         return "scissors"
        case .polyBuild:     return "hammer"
        case .spin:          return "tornado"
        case .smoothTool:    return "drop"
        case .randomize:     return "dice"
        case .edgeSlide:     return "arrow.left.and.right"
        case .shrinkFatten:  return "arrow.up.and.down.circle"
        case .shear:         return "skew"
        case .ripRegion:     return "scissors.badge.ellipsis"
        case .sculptDraw:    return "paintbrush.pointed"
        case .sculptInflate: return "arrow.up.left.and.arrow.down.right.circle"
        case .sculptSmooth:  return "drop"
        case .sculptFlatten: return "square.bottomhalf.filled"
        case .sculptGrab:    return "hand.point.up.left"
        case .sculptPinch:   return "arrow.down.right.and.arrow.up.left"
        case .boxMask:       return "rectangle.dashed.badge.record"
        case .boxHide:       return "eye.slash"
        case .boxFaceSet:    return "square.grid.3x3"
        case .meshFilter:    return "camera.filters"
        case .lineProject:   return "line.diagonal"
        case .paintDraw:     return "paintbrush.pointed"
        case .paintBlur:     return "drop"
        case .paintAverage:  return "equal.circle"
        case .paintSmear:    return "hand.draw"
        case .gradient:      return "circle.lefthalf.filled"
        case .sampleWeight:  return "eyedropper"
        case .paintFill:     return "drop.fill"
        case .paintClone:    return "doc.on.doc"
        }
    }

    // MARK: what a tool does

    /// Whether a drag with this tool sweeps a selection region — Box, Circle
    /// or Lasso — rather than orbiting or transforming.
    public var isRegionSelect: Bool {
        self == .boxSelect || self == .circleSelect || self == .lassoSelect
    }

    /// The transform a drag performs, or nil if the tool is not a transform.
    /// Keeping this here means the viewport does not need a switch that has to
    /// be extended every time the toolbar grows.
    public var transformRole: TransformRole? {
        switch self {
        case .move, .transform: return .translate
        case .rotate:           return .rotate
        case .scale:            return .scale
        default:                return nil
        }
    }

    public enum TransformRole { case translate, rotate, scale }

    /// The primitive an Add tool creates.
    public var addsPrimitive: PrimitiveKind? {
        switch self {
        case .addCube:      return .cube
        case .addCone:      return .cone
        case .addCylinder:  return .cylinder
        case .addUVSphere:  return .uvSphere
        case .addIcoSphere: return .icoSphere
        default:            return nil
        }
    }

    /// The sculpt brush a sculpt-mode tool selects.
    public var sculptBrush: SculptBrush? {
        switch self {
        case .sculptDraw:    return .draw
        case .sculptInflate: return .inflate
        case .sculptSmooth:  return .smooth
        case .sculptFlatten: return .flatten
        case .sculptGrab:    return .grab
        case .sculptPinch:   return .pinch
        default:             return nil
        }
    }

    /// The next tool in the bar, for the Apple Pencil barrel double-tap.
    /// Cycles only the transform tools, which is what a double-tap is useful
    /// for mid-edit.
    public var next: ActiveTool {
        switch self {
        case .select: return .move
        case .move:   return .rotate
        case .rotate: return .scale
        case .scale:  return .select
        default:      return .select
        }
    }

    // MARK: per-mode layout

    /// The toolbar for a mode, grouped as Blender groups it. Separators in
    /// Blender's table become the gaps between these arrays.
    /// The mode this tool needs Blender to be in, or nil when it works in
    /// whichever one you are already in.
    ///
    /// This is what lets the interface stop asking. Blender makes the mode the
    /// user's problem — you pick Sculpt Mode, then a brush — because its modes
    /// change what the whole application is. Here there is one viewport and one
    /// object at a time, and picking a sculpt brush can only mean one thing.
    /// So the tool says what it needs and the mode follows it.
    ///
    /// Select, transform, add and annotate return nil deliberately: Blender's
    /// Move works on objects in object mode and on vertices in edit mode, and
    /// forcing either would take away the one the user wanted.
    public var requiredMode: InteractionMode? {
        switch self {
        case .sculptDraw, .sculptInflate, .sculptSmooth, .sculptFlatten,
             .sculptGrab, .sculptPinch, .boxMask, .boxHide, .boxFaceSet,
             .meshFilter, .lineProject:
            return .sculpt
        case .paintDraw, .paintBlur, .paintSmear, .paintClone, .paintFill:
            return .texturePaint
        // Average is a vertex- and weight-paint brush. Blender's Texture Paint
        // has none — `image_brush_type` has no AVERAGE — so it is not one here.
        case .paintAverage:
            return .vertexPaint
        case .gradient, .sampleWeight:
            return .weightPaint
        case .extrudeRegion, .insetFaces, .bevel, .loopCut, .knife, .polyBuild,
             .spin, .smoothTool, .randomize, .edgeSlide, .shrinkFatten,
             .shear, .ripRegion:
            return .edit
        default:
            return nil
        }
    }

    /// Every tool, in one list, grouped by what it does rather than by which
    /// mode Blender keeps it in.
    ///
    /// Blender has six toolbars and makes you choose between them first. That
    /// is a reasonable answer for an application whose modes each own a
    /// different editor; it is a poor one for a tablet, where the toolbar is
    /// already the width of a thumb and the first thing between you and a
    /// brush should not be a menu. One list, and the mode follows what you
    /// pick.
    public static var combined: [(title: String, tools: [ActiveTool])] {
        [("Select",    [.select, .boxSelect, .circleSelect, .lassoSelect]),
         ("Transform", [.move, .rotate, .scale, .transform, .cursor]),
         ("Add",       [.addCube, .addCone, .addCylinder, .addUVSphere, .addIcoSphere]),
         ("Mesh",      [.extrudeRegion, .insetFaces, .bevel, .spin,
                        .smoothTool, .randomize, .loopCut, .knife,
                        .polyBuild, .edgeSlide, .shrinkFatten, .shear, .ripRegion]),
         ("Sculpt",    [.sculptDraw, .sculptInflate, .sculptSmooth,
                        .sculptFlatten, .sculptGrab, .sculptPinch,
                        .boxMask, .boxHide, .boxFaceSet, .meshFilter, .lineProject]),
         ("Paint",     [.paintDraw, .paintBlur, .paintAverage, .paintSmear,
                        .paintClone, .paintFill, .gradient, .sampleWeight]),
         ("Measure",   [.annotate, .measure])]
    }

    public static func groups(for mode: InteractionMode) -> [[ActiveTool]] {
        let selection: [ActiveTool] = [.select, .boxSelect, .circleSelect, .lassoSelect]
        let transforms: [ActiveTool] = [.move, .rotate, .scale, .transform]
        let annotate: [ActiveTool] = [.annotate, .measure]
        let primitives: [ActiveTool] = [.addCube, .addCone, .addCylinder,
                                        .addUVSphere, .addIcoSphere]

        switch mode {
        case .object:
            return [selection, [.cursor], transforms, annotate, primitives]

        case .edit:
            return [selection, [.cursor], transforms, annotate, primitives,
                    [.extrudeRegion, .insetFaces, .bevel],
                    [.loopCut, .knife, .polyBuild, .spin],
                    [.smoothTool, .randomize],
                    [.edgeSlide, .shrinkFatten, .shear, .ripRegion]]

        case .sculpt:
            // Blender's sculpt toolbar is the brush list first, then the
            // mask/hide gestures, then the transforms.
            return [[.sculptDraw, .sculptInflate, .sculptSmooth,
                     .sculptFlatten, .sculptGrab, .sculptPinch],
                    [.boxMask, .boxHide, .boxFaceSet],
                    [.meshFilter, .lineProject],
                    transforms,
                    primitives,
                    annotate]

        case .vertexPaint:
            return [[.paintDraw, .paintBlur, .paintAverage, .paintSmear],
                    selection, annotate]

        case .weightPaint:
            return [[.paintDraw, .paintBlur, .paintAverage, .paintSmear],
                    [.gradient, .sampleWeight],
                    selection, annotate]

        case .texturePaint:
            return [[.paintDraw, .paintBlur, .paintSmear, .paintClone, .paintFill],
                    selection, annotate]
        }
    }

    /// The tool a mode lands on when it is entered, matching what Blender
    /// restores: the brush in a paint mode, Tweak everywhere else.
    public static func defaultTool(for mode: InteractionMode) -> ActiveTool {
        switch mode {
        case .sculpt:                              return .sculptDraw
        case .vertexPaint, .weightPaint, .texturePaint: return .paintDraw
        case .object, .edit:                       return .select
        }
    }
}

public extension InteractionMode {
    /// Sculpt and the paint modes: the modes a brush puts the view in.
    ///
    /// Painting here is the interface's own, drawn onto the display cache
    /// while Blender stays in object mode underneath, which is why those are
    /// left on their own by the mirror of Blender's mode. Sculpt Mode is
    /// Blender's own with the real Blender (`_blenderkit_sculpt`); only the
    /// simulator's stand-in sculpts the display cache.
    var isBrushMode: Bool {
        switch self {
        case .sculpt, .texturePaint, .vertexPaint, .weightPaint: return true
        case .object, .edit: return false
        }
    }
}

public extension ActiveTool {
    /// The brush modes this tool is a brush in.
    ///
    /// Blender's paint modes share their first brushes: Draw, Blur and Smear
    /// are in Texture, Vertex and Weight Paint, and Average in Vertex and
    /// Weight Paint. Picking one keeps whichever of those the view is in, and
    /// goes to `requiredMode` only from anywhere else. Before, Draw picked in
    /// Weight Paint went to Texture Paint.
    var brushModes: Set<InteractionMode> {
        switch self {
        case .paintDraw, .paintBlur, .paintSmear: return [.texturePaint, .vertexPaint, .weightPaint]
        case .paintAverage:                       return [.vertexPaint, .weightPaint]
        default:
            guard let needed = requiredMode, needed.isBrushMode else { return [] }
            return [needed]
        }
    }

    /// Whether this is a sculpt or paint brush.
    var isBrush: Bool { requiredMode?.isBrushMode == true }

    /// The mode choosing this tool takes the view to from `current`, or nil to
    /// stay where it is.
    ///
    /// A brush takes the view into its mode. Anything that is not a brush —
    /// select, box, the transforms, an add — takes it back out of a brush mode,
    /// as choosing Object Mode does in Blender. Before this, picking Move after
    /// a brush left the view sculpting: the Move button lit up and every drag
    /// still pushed the mesh around, with no way out short of changing tab.
    ///
    /// The edit-mode tools answer nil. Editing is entered with Edit Mesh or
    /// Tab, which Blender itself decides.
    func mode(whenChosenFrom current: InteractionMode) -> InteractionMode? {
        if let needed = requiredMode, needed.isBrushMode {
            return brushModes.contains(current) ? nil : needed
        }
        if requiredMode == nil, current.isBrushMode { return .object }
        return nil
    }
}

public extension MeshSelectMode {
    /// What `bpy.ops.mesh.select_mode(type=…)` and `mesh.delete(type=…)` call it.
    var bpyType: String {
        switch self {
        case .vertex: return "VERT"
        case .edge:   return "EDGE"
        case .face:   return "FACE"
        }
    }

    /// `tool_settings.mesh_select_mode`, as the tuple Blender stores.
    var blenderFlags: String {
        switch self {
        case .vertex: return "(True, False, False)"
        case .edge:   return "(False, True, False)"
        case .face:   return "(False, False, True)"
        }
    }

    /// From the bits the mirror reports: 1 vertex, 2 edge, 4 face. Blender
    /// allows several at once; the interface has one, and the finest wins.
    init?(blenderBits bits: Int32) {
        if bits & 1 != 0 { self = .vertex }
        else if bits & 2 != 0 { self = .edge }
        else if bits & 4 != 0 { self = .face }
        else { return nil }
    }
}
