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
