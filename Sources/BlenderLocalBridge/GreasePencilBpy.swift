import Foundation
import simd

/// The Python a Grease Pencil object's Draw Mode, layers, materials and onion
/// skinning send (`_blenderkit_gpencil`), with Blender's own names for their
/// undo steps — each measured in desktop 5.2.1 (run-gpencil-blender-check.sh).
public enum GreasePencilBpy {
    static let module = "import _blenderkit_gpencil\n"

    /// Into Draw Mode: Blender's mode menu row (`object.mode_set`). Refused in
    /// words for anything but a Grease Pencil object.
    public static let enter = """
        if bpy.context.view_layer.objects.active is None or bpy.context.view_layer.objects.active.type != 'GREASEPENCIL':
            raise RuntimeError('Draw Mode is for a Grease Pencil object')
        bpy.ops.object.mode_set(mode='\(InteractionMode.drawGreasePencil.bpyMode)')
        """
    public static let leave = "bpy.ops.object.mode_set(mode='OBJECT')"
    /// What Blender's history calls the step into or out of Draw Mode:
    /// `mode_set` runs `grease_pencil.paintmode_toggle`, and both ways
    /// pushed "Strokes Paint Mode Toggle" (measured).
    public static let modeUndo = "Strokes Paint Mode Toggle"
    /// A stroke drawn or erased: `grease_pencil.brush_stroke`'s name, the
    /// step Blender pushes for either.
    public static let strokeUndo = "Grease Pencil Draw"

    public static let stateQuery = module + "print(_blenderkit_gpencil.state())"
    public static let brushesQuery = module + "import json\nprint(json.dumps(_blenderkit_gpencil.brushes()))"

    /// Makes an Essentials Grease Pencil brush the brush (the asset shelf).
    public static func activate(_ brush: String) -> String {
        module + "_blenderkit_gpencil.activate(\(Bpy.quote(brush)))"
    }

    /// One of the brush's settings, as the header writes it.
    public static func setBrush(_ key: String, _ value: String) -> String {
        module + "_blenderkit_gpencil.set_brush('\(key)', \(value))"
    }

    // MARK: layers (Object Data ▸ Layers)

    /// `grease_pencil.layer_add`'s "+", named as Blender names a new layer.
    public static let layerAdd = "bpy.ops.grease_pencil.layer_add(new_layer_name='Layer')"
    public static let layerAddUndo = "Add New Layer"
    public static let layerRemove = "bpy.ops.grease_pencil.layer_remove()"
    public static let layerRemoveUndo = "Remove Layer"
    public static func layerMove(up: Bool) -> String {
        "bpy.ops.grease_pencil.layer_move(direction='\(up ? "UP" : "DOWN")')"
    }
    public static let layerMoveUndo = "Reorder Layer"

    /// A layer row tapped: Blender's Set Active Layer.
    public static func layerActive(_ object: String, layer: String) -> String {
        module + "_blenderkit_gpencil.layer_set_active(\(Bpy.quote(object)), \(Bpy.quote(layer)))"
    }
    public static let layerActiveUndo = "Set Active Layer"

    /// A layer's Hide, Locked, Opacity, Onion Skinning or Name, its undo step
    /// named after the property as Blender names a button's.
    public static func layerSet(_ object: String, layer: String, _ key: String, _ value: String) -> String {
        module + "_blenderkit_gpencil.layer_set(\(Bpy.quote(object)), \(Bpy.quote(layer)), '\(key)', \(value))"
    }

    public static func layerUndo(_ key: String) -> String {
        switch key {
        case "hide": return "Hide"
        case "lock": return "Locked"
        case "opacity": return "Opacity"
        case "use_onion_skinning": return "Onion Skinning"
        case "use_lights": return "Lights"
        case "name": return "Name"
        default: return key
        }
    }

    // MARK: onion skinning (Object Data ▸ Onion Skinning)

    /// One of the data's onion settings.
    public static func onionSet(_ object: String, _ key: String, _ value: String) -> String {
        "bpy.data.objects[\(Bpy.quote(object))].data.\(key) = \(value)"
    }

    /// Onion Skinning's rows, with Blender's names (the panel's text where it
    /// has its own: Opacity for Onion Opacity, Keyframes or Frames Before).
    public static let onionModes: [(String, String)] = [("ABSOLUTE", "Frames"), ("RELATIVE", "Keyframes"),
                                                        ("SELECTED", "Selected")]
    public static let onionFilters: [(String, String)] = [("ALL", "All"), ("KEYFRAME", "Keyframe"),
                                                          ("BREAKDOWN", "Breakdown"), ("MOVING_HOLD", "Moving Hold"),
                                                          ("EXTREME", "Extreme"), ("JITTER", "Jitter"),
                                                          ("GENERATED", "Generated")]

    // MARK: materials

    /// A new Grease Pencil material in a new slot, made active, with a colour
    /// picked on screen (sRGB) as its stroke and fill colour.
    public static func materialAdd(_ object: String, colour: SIMD3<Float>) -> String {
        let c = GreasePencilGeometry.linear(colour)
        return module + "_blenderkit_gpencil.material_add(\(Bpy.quote(object)), "
            + "(\(n(c.x)), \(n(c.y)), \(n(c.z)), 1.0))"
    }
    public static let materialAddUndo = "New Material"

    public static func materialActive(_ object: String, index: Int) -> String {
        "bpy.data.objects[\(Bpy.quote(object))].active_material_index = \(index)"
    }
    public static let materialActiveUndo = "Active Material Index"

    public static func materialColour(_ object: String, index: Int, colour: SIMD4<Float>) -> String {
        let c = GreasePencilGeometry.linear(SIMD3(colour.x, colour.y, colour.z))
        return module + "_blenderkit_gpencil.material_set_colour(\(Bpy.quote(object)), \(index), "
            + "(\(n(c.x)), \(n(c.y)), \(n(c.z)), \(n(colour.w))))"
    }
    /// The Stroke panel's colour row is Base Color.
    public static let materialColourUndo = "Base Color"

    // MARK: Draw Mode's tool settings

    /// Auto Keying and Additive Drawing, the timeline's and Draw Mode's
    /// header's toggles.
    public static func setTool(_ key: String, _ on: Bool) -> String {
        "bpy.context.scene.tool_settings.\(key) = \(on ? "True" : "False")"
    }

    static func n(_ v: Float) -> String { String(format: "%.6g", Double(v)) }
}

/// The eraser's three modes (`gpencil_settings.eraser_mode`), Blender's names.
public enum GPEraserMode: String, CaseIterable, Sendable {
    case dissolve = "SOFT", point = "HARD", stroke = "STROKE"

    public var label: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .point:    return "Point"
        case .stroke:   return "Stroke"
        }
    }
}

/// Draw Mode's Erase tool's settings: Blender's eraser brush's Mode, its Size
/// and Active Layer (`use_active_layer_only`).
public struct GPEraserSettings: Equatable, Sendable {
    public var mode: GPEraserMode = .dissolve
    /// A diameter, in the view's points, as Blender's brush Size is in pixels.
    public var size: Float = 40
    public var strength: Float = 1
    public var activeLayerOnly = false
    public init() {}
}
