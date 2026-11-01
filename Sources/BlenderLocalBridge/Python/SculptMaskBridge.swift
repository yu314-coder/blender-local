import Foundation

// `_blenderkit.sync_mask`: Blender's sculpt mask, handed to the viewport with
// the sculpted mesh (`_blenderkit_sculpt.push_mask`) so Sculpt Mode shows what
// is masked. The values are Blender's `.sculpt_mask`, read from the evaluated
// mesh the viewport draws; nothing here paints a mask.

@_cdecl("bk_sculpt_set_mask")
func bk_sculpt_set_mask(_ name: UnsafePointer<CChar>?, _ values: UnsafePointer<Float>?,
                        _ count: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let name = name.map({ String(cString: $0) }),
              let object = scene.objects.first(where: { $0.name == name })
        else { return -1 }
        let mask: [Float] = count > 0 && values != nil
            ? Array(UnsafeBufferPointer(start: values, count: Int(count))) : []
        if mask != object.sculptMask {
            object.sculptMask = mask
            object.sculptMaskVersion &+= 1
        }
        return 0
    }
}

// `_blenderkit.sync_paint`: what Weight Paint or Vertex Paint draws of one
// object, read from Blender (`_blenderkit_vwpaint.push`) after every chunk of
// a stroke and every mirroring pass in those modes — the weights of the
// active vertex group, or the active colour attribute in sRGB, one value per
// vertex of the evaluated mesh the viewport draws. The app paints none of it
// itself any more: what the 3D View shows is what Blender holds.
@_cdecl("bk_paint_set_values")
func bk_paint_set_values(_ name: UnsafePointer<CChar>?, _ kind: Int32, _ values: UnsafePointer<Float>?,
                         _ count: Int32) -> Int32 {
    onMain {
        guard let scene = PythonSceneBridge.scene,
              let name = name.map({ String(cString: $0) }),
              let object = scene.objects.first(where: { $0.name == name })
        else { return -1 }
        let floats: [Float] = count > 0 && values != nil
            ? Array(UnsafeBufferPointer(start: values, count: Int(count))) : []
        if kind == 1 {
            let colours = stride(from: 0, to: floats.count - 3, by: 4).map {
                SIMD4(floats[$0], floats[$0 + 1], floats[$0 + 2], floats[$0 + 3])
            }
            if colours != object.vertexColours {
                object.vertexColours = colours
                object.textureVersion &+= 1
            }
        } else if floats != object.vertexWeights {
            object.vertexWeights = floats
            object.textureVersion &+= 1
        }
        return 0
    }
}
