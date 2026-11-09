import Foundation
import simd

// Properties ▸ Material, the Swift half: the state the tab reads
// (`MaterialPanelState`), what each control sends (`MaterialBpy`), the
// slots the 3D View draws (`MaterialLook`, `carryMaterials`, the merge, the
// runs by slot) and the preview of a drag. Pure strings; no Metal, no
// Python. What Blender does with it: scripts/run-material-blender-check.sh.

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail())")
    if !ok { failures += 1 }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)

// What `_blenderkit_material.state` prints for a cube of two slots whose
// first material has a Principled BSDF with Base Color from an Image Texture.
let stateLine = #"""
{"object":"Cube","type":"MESH","mode":"OBJECT","slots":[{"material":"Q \"uoted\" 名前;|=%","link":"DATA","swatch":[0.9,0.1,0.2]},{"material":null,"link":"OBJECT","swatch":null}],"active":0,"materials":[{"name":"Material","users":0,"fake_user":true,"swatch":[0.9,0.9,0.9]},{"name":"Q \"uoted\" 名前;|=%","users":2,"fake_user":false,"swatch":[0.9,0.1,0.2]}],"material":{"name":"Q \"uoted\" 名前;|=%","users":2,"fake_user":false,"library":false,"viewport":{"color":[0.8,0.8,0.8,1.0],"metallic":0.0,"roughness":0.4},"settings":{"pass_index":3,"use_backface_culling":true,"surface_render_method":"DITHERED","max_vertex_displacement":0.0},"surface":{"output":"Material Output","socket":"Surface","index":0,"link":"Principled BSDF","node":{"name":"Principled BSDF","type":"ShaderNodeBsdfPrincipled","label":"Principled BSDF","items":[{"kind":"input","id":"Base Color","index":0,"label":"Base Color","type":"RGBA","hide_value":false,"inactive":false,"link":"Image Texture"},{"kind":"input","id":"Metallic","index":1,"label":"Metallic","type":"VALUE","hide_value":false,"inactive":false,"link":null,"value":0.25,"subtype":"FACTOR","min":0.0,"max":1.0},{"kind":"input","id":"Thin Wall","index":5,"label":"Thin Wall","type":"BOOLEAN","hide_value":false,"inactive":false,"link":null,"value":false,"subtype":"NONE"},{"kind":"input","id":"Normal","index":6,"label":"Normal","type":"VECTOR","hide_value":true,"inactive":false,"link":null},{"kind":"panel","label":"Subsurface","open":false,"items":[{"kind":"prop","id":"subsurface_method","label":"Subsurface Method","value":"RANDOM_WALK","options":[["BURLEY","Christensen-Burley"],["RANDOM_WALK","Random Walk"]]},{"kind":"input","id":"Subsurface Radius","index":10,"label":"Radius","type":"VECTOR","hide_value":false,"inactive":false,"link":null,"value":[1.0,0.2,0.1],"subtype":"NONE","min":0.0,"max":100.0}]}]}},"volume":{"output":"Material Output","socket":"Volume","index":1,"link":null}},"has_materials":true}
"""#

print("== the state the tab reads ==")
let parsed = MaterialPanelState.parse("Info: something Blender printed first\n" + stateLine)
check("parses, past a line Blender printed before it", parsed != nil)
if let s = parsed {
    check("the object, its type and mode", s.object == "Cube" && s.type == "MESH" && !s.editing)
    check("two slots, a name with quotes, Unicode and separators kept whole, and an empty one",
          s.slots.map(\.material) == ["Q \"uoted\" 名前;|=%", nil], "\(s.slots.map(\.material))")
    check("each slot's link", s.slots.map(\.link) == ["DATA", "OBJECT"])
    check("the active slot", s.active == 0 && s.activeSlot?.material == "Q \"uoted\" 名前;|=%")
    check("two slots are sortable: Blender draws the arrows", s.isSortable)
    check("the browse menu's materials, with users and Fake User",
          s.materials.map(\.name) == ["Material", "Q \"uoted\" 名前;|=%"] && s.materials[0].fakeUser
          && s.materials[1].users == 2)
    if let m = s.material {
        check("the material, its users and Fake User", m.users == 2 && !m.fakeUser && !m.library)
        check("Viewport Display", m.viewport.color == [0.8, 0.8, 0.8, 1] && m.viewport.roughness == 0.4)
        check("Settings: a number, a switch and an enum",
              m.settings["pass_index"]?.number == 3 && m.settings["use_backface_culling"]?.bool == true
              && m.settings["surface_render_method"]?.text == "DITHERED")
        check("Surface: the Principled BSDF linked to it", m.surface.link == "Principled BSDF"
              && m.surface.node?.type == "ShaderNodeBsdfPrincipled")
        check("Volume: nothing linked", m.volume.link == nil && m.volume.node == nil && m.volume.output != nil)
        let inputs = m.surface.node?.inputs ?? []
        check("every input, panels opened up, in order",
              inputs.map(\.id) == ["Base Color", "Metallic", "Thin Wall", "Normal", "Subsurface Radius"],
              "\(inputs.map(\.id))")
        check("Base Color linked to an Image Texture shows the node, and no value",
              inputs[0].link == "Image Texture" && inputs[0].value == nil)
        check("Metallic's value and range", inputs[1].value?.number == 0.25 && inputs[1].min == 0 && inputs[1].max == 1)
        check("Thin Wall is a switch", inputs[2].value?.bool == false)
        check("Normal shows no value", inputs[3].hideValue && inputs[3].value == nil)
        check("Subsurface Radius in its panel, by its short label", inputs[4].label == "Radius"
              && inputs[4].value?.vector == [1.0, 0.2, 0.1])
        if case .panel(let label, let open, let items)? = m.surface.node?.items.last {
            check("the Subsurface panel, closed as Blender draws it, its method first",
                  label == "Subsurface" && !open && {
                      if case .prop(let p) = items.first { return p.id == "subsurface_method"
                          && p.name(of: "BURLEY") == "Christensen-Burley" }
                      return false
                  }())
        } else {
            check("the Subsurface panel", false)
        }
    } else {
        check("the material", false)
    }
}
let empty = MaterialPanelState.parse(#"{"object":"Empty","type":"EMPTY","mode":"OBJECT","slots":[],"active":-1,"materials":[],"material":null,"has_materials":false}"#)
check("an empty: no slots, no material, and it takes none", empty.map { $0.slots.isEmpty && $0.material == nil
                                                                    && !$0.hasMaterials && $0.activeSlot == nil } == true)
check("a line that is not a state is nothing", MaterialPanelState.parse("Traceback: oops") == nil)

print("== a value clamped as Blender's slider stops ==")
let metallic = parsed!.material!.surface.node!.inputs[1]
check("inside the range, itself", metallic.clamped(0.4) == 0.4)
check("past it, its end", metallic.clamped(5) == 1 && metallic.clamped(-1) == 0)
check("not a number, the value held", metallic.clamped(.nan) == 0.25)

print("== sRGB and linear ==")
check("0x4E as sRGB is 0.076 linear", abs(ColorSpace.linear(0x4E / 255) - 0.0762) < 1e-3)
check("0.8 linear is 0.906 sRGB", abs(ColorSpace.srgb(0.8) - 0.9063) < 1e-3)
let round = (0...20).map { Float($0) / 20 }.allSatisfy { abs(ColorSpace.srgb(ColorSpace.linear($0)) - $0) < 1e-5 }
check("sRGB to linear and back is the colour picked", round)
check("below zero is zero", ColorSpace.linear(-0.5) == 0 && ColorSpace.srgb(-0.5) == 0)

print("== what each control sends ==")
let odd = "Q \"uoted\" 名前;|=%"
let browse = MaterialBpy.browse(odd, object: "C\"ube", editing: false)
check("browse quotes both names as Python strings", browse.executed.contains(#"_bk_mat.browse("C\"ube", "Q \"uoted\" 名前;|=%")"#),
      browse.executed)
check("browse's step is the browse button's words", browse.undo == "Browse Material to be linked")
check("+ is Blender's Add Material Slot in Object Mode, no step in Edit Mode",
      MaterialBpy.addSlot(object: "C", editing: false).undo == "Add Material Slot"
      && MaterialBpy.addSlot(object: "C", editing: true).undo == nil)
check("- is Remove Material Slot", MaterialBpy.removeSlot(object: "C").call == "bpy.ops.object.material_slot_remove()"
      && MaterialBpy.removeSlot(object: "C").undo == "Remove Material Slot")
check("the arrows are Move Material, with Blender's direction",
      MaterialBpy.moveSlot(up: true, object: "C", editing: false).call
        == "bpy.ops.object.material_slot_move(direction='UP')"
      && MaterialBpy.moveSlot(up: false, object: "C", editing: false).undo == "Move Material")
check("a row's tap is Active Material Index", MaterialBpy.setActiveSlot(2, object: "C", editing: false).call
      == "bpy.context.object.active_material_index = 2")
check("Assign, Select, Deselect are Blender's operators and steps",
      MaterialBpy.assign(object: "C").undo == "Assign Material Slot"
      && MaterialBpy.select(true, object: "C").call == "bpy.ops.object.material_slot_select()"
      && MaterialBpy.select(false, object: "C").undo == "Deselect Material Slot")
check("Material Specials' rows in Blender's order",
      MaterialBpy.Special.allCases.map(\.rawValue) == ["Copy Material", "Copy Material to Selected",
                                                        "Paste Material", "Remove Unused Slots",
                                                        "Remove All Materials"])
check("Copy Material makes no step; Paste Material does, in Object Mode",
      MaterialBpy.special(.copyMaterial, object: "C", editing: false).undo == nil
      && MaterialBpy.special(.pasteMaterial, object: "C", editing: false).undo == "Paste Material"
      && MaterialBpy.special(.pasteMaterial, object: "C", editing: true).undo == nil)
check("the removals are not offered in Edit Mode, as Blender's polls fail there",
      !MaterialBpy.Special.removeAll.available(editing: true) && !MaterialBpy.Special.removeUnused.available(editing: true)
      && MaterialBpy.Special.copyToSelected.available(editing: true))
check("New is material.new; Unlink is Unlink Data-Block; the user count Make Single User",
      MaterialBpy.newMaterial(object: "C", editing: false).call == "bpy.ops.material.new()"
      && MaterialBpy.newMaterial(object: "C", editing: false).undo == "New Material"
      && MaterialBpy.unlink(object: "C", editing: false).undo == "Unlink Data-Block"
      && MaterialBpy.unlink(object: "C", editing: true).undo == nil
      && MaterialBpy.browse("M", object: "C", editing: true).undo == nil
      && MaterialBpy.setActiveSlot(0, object: "C", editing: true).undo == nil
      && MaterialBpy.makeSingleUser("M", object: "C", editing: false).undo == "Make Single User")
check("Fake User's line", MaterialBpy.fakeUser("M", true, editing: false).call
      == #"bpy.data.materials["M"].use_fake_user = True"#)
check("the slot's Link", MaterialBpy.link("OBJECT", slot: 1, object: "C", editing: false).call
      == "bpy.context.object.material_slots[1].link = 'OBJECT'")
check("a shader from the menu is Node input modify", MaterialBpy.setShader("ShaderNodeBsdfDiffuse", socket: "Surface",
                                                                           material: "M", editing: false).undo
      == "Node input modify")
let base = MaterialBpy.setInput(metallic, number: 3, node: "Principled BSDF", material: odd, editing: false)
check("an input's line is Blender's path to it, by index, clamped to the slider",
      base.call == #"bpy.data.materials["Q \"uoted\" 名前;|=%"].node_tree.nodes["Principled BSDF"].inputs[1].default_value = 1.0"#,
      base.call)
check("its step is the input's label", base.undo == "Metallic")
check("no step for it in Edit Mode", MaterialBpy.setInput(metallic, number: 0.5, node: "P", material: "M",
                                                          editing: true).undo == nil)
var colourInput = metallic
colourInput.type = "RGBA"
colourInput.label = "Base Color"
let colour = MaterialBpy.setInput(colourInput, srgb: SIMD3(0.5, 0.25, 0.75), node: "P", material: "M", editing: false)
check("a colour picked as sRGB is written linear", colour.call.hasSuffix("= (0.214041, 0.0508761, 0.522522)"),
      colour.call)
check("the viewport colour is written linear with its alpha",
      MaterialBpy.setViewportColor(srgb: SIMD4(1, 0, 0.5, 0.5), material: "M", editing: false).call
        .hasSuffix("diffuse_color = (1.0, 0.0, 0.214041, 0.5)"))
check("Viewport Display's Roughness is 0 to 1", MaterialBpy.setViewport(metallic: false, 2, material: "M",
                                                                        editing: false).call.hasSuffix("roughness = 1.0"))
check("Pass Index is whole and at most 32767",
      MaterialBpy.setSetting(.passIndex, number: 7.6, material: "M", editing: false).call.hasSuffix("pass_index = 8")
      && MaterialBpy.setSetting(.passIndex, number: 1e9, material: "M", editing: false).call.hasSuffix("= 32767"))
check("Settings' steps are the words Blender draws",
      MaterialBpy.setSetting(.backfaceCamera, bool: true, material: "M", editing: false).undo == "Camera"
      && MaterialBpy.Setting.renderMethod.label == "Render Method"
      && MaterialBpy.Setting.transparentShadow.label == "Transparent Shadows")

print("== the Surface menu is the module's ==")
let python = (try? String(contentsOf: root.appendingPathComponent("Resources/python/site/_blenderkit_material.py"),
                          encoding: .utf8)) ?? ""
let shadersPython: [String] = {
    guard let start = python.range(of: "SHADERS = ("), let end = python.range(of: "\n)", range: start.upperBound..<python.endIndex)
    else { return [] }
    let body = python[start.upperBound..<end.lowerBound]
    let pattern = try! NSRegularExpression(pattern: #"\('([A-Za-z]+)', '([^']+)'\)"#)
    let text = String(body)
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        let ns = text as NSString
        return ns.substring(with: $0.range(at: 1)) + "|" + ns.substring(with: $0.range(at: 2))
    }
}()
check("the Swift's \(MaterialBpy.shaders.count) shaders are the module's SHADERS, in order",
      MaterialBpy.shaders.map { "\($0.type)|\($0.name)" } == shadersPython, "\(shadersPython.count)")

print("== the slots the 3D View draws ==")
let record = "kind=slot;name=Red%3Bone;display=0.8,0.05,0.05,1.0;display_metallic=0.0;display_roughness=0.4;"
    + "connected=1;shader=ShaderNodeBsdfPrincipled;base=0.6,0.1,0.1;base_linked=0;metallic=0.5;roughness=0.25;"
    + "ior=1.45;alpha=1.0;emission=0.0,0.0,0.0;strength=0.0"
    + "|kind=slot;none=1"
    + "|kind=slot;name=Off;display=0.1,0.2,0.3,1.0;connected=0"
let looks = MaterialLook.parseRecord(record)
check("three slots", looks.count == 3)
check("the first: its name unescaped, Viewport Display and Principled values",
      looks[0].material == "Red;one" && looks[0].display == SIMD4(0.8, 0.05, 0.05, 1)
      && looks[0].base == SIMD3(0.6, 0.1, 0.1) && looks[0].metallic == 0.5 && looks[0].roughness == 0.25)
check("Solid draws its Viewport Display Color, Material Preview its base colour",
      looks[0].solidColour == SIMD4(0.8, 0.05, 0.05, 1) && looks[0].previewBase == SIMD4(0.6, 0.1, 0.1, 1))
check("an empty slot is Blender's default material", looks[1] == .default
      && MaterialLook.default.solidColour == SIMD4(0.8, 0.8, 0.8, 1))
check("nothing connected to Surface renders black", !looks[2].connected && looks[2].previewBase == SIMD4(0, 0, 0, 1)
      && looks[2].solidColour == SIMD4(0.1, 0.2, 0.3, 1))
check("no slot at all: an empty record", MaterialLook.parseRecord("").isEmpty)

let cube = BKObject(name: "Cube", kind: .cube)
let triangles = cube.mesh.indices.count / 3
check("a cube of \(triangles) triangles", triangles == 12)
let slots: [Int32] = [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2]
slots.withUnsafeBufferPointer { b in
    _ = SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube)
}
check("installed: three looks and a slot per triangle", cube.materialLooks.count == 3 && cube.triangleSlots.count == 12)
let runs = cube.slotRuns()
check("drawn as three runs: slot 0 eight triangles, slot 1 two, slot 2 two",
      runs?.map(\.slot) == [0, 1, 2] && runs?.map(\.triangles.count) == [8, 2, 2], "\(String(describing: runs))")
let version = cube.materialSlotsVersion
var unchanged = false
slots.withUnsafeBufferPointer { b in
    unchanged = !SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube)
}
check("the same slots again change nothing (the renderer's cache stays)", unchanged && cube.materialSlotsVersion == version)
let zeros = [Int32](repeating: 0, count: 12)
zeros.withUnsafeBufferPointer { b in _ = SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube) }
check("every triangle in slot 0: no slots kept, one look draws it", cube.triangleSlots.isEmpty && cube.slotRuns() == nil
      && cube.materialSlotsVersion != version)
let past: [Int32] = [7, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, -3]
past.withUnsafeBufferPointer { b in _ = SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube) }
check("a material index past the last slot draws with the last slot, below 0 with the first",
      cube.slotRuns()?.map(\.slot) == [0, 2] && cube.materialLook(slot: 7) == looks[2])
let short: [Int32] = [1, 1, 0]
short.withUnsafeBufferPointer { b in _ = SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube) }
check("slots that do not fit the mesh (a Multires level) draw with one look", cube.slotRuns() == nil)
check("the sole slot of a mesh with all its triangles in one slot", {
    let one = [Int32](repeating: 2, count: 12)
    one.withUnsafeBufferPointer { b in _ = SceneMirror.installMaterials(record: record, triangleSlots: b, on: cube) }
    return cube.soleSlot == 2 && cube.slotRuns() == nil
}())
check("no looks: Blender's default material", BKObject(name: "N", kind: .cube).materialLook(slot: 3) == .default)

print("== carried by a pass, and merged onto what is on screen ==")
let onScreen = BKObject(name: "Cube", kind: .cube)
let fresh = BKObject(name: "Cube", kind: .cube)
var carried = 0
slots.withUnsafeBufferPointer { b in
    carried = SceneMirror.carryMaterials(record: record, triangleSlots: b, named: "Cube", pass: [fresh],
                                         screen: [onScreen])
}
check("during a pass onto the object the pass pushed", carried == 1 && fresh.materialLooks.count == 3
      && onScreen.materialLooks.isEmpty)
slots.withUnsafeBufferPointer { b in
    carried = SceneMirror.carryMaterials(record: record, triangleSlots: b, named: "Nope", pass: [fresh], screen: [])
}
check("a pass naming an object it did not push is an error", carried == -1)
let scene = BKScene(startupFile: false)
scene.objects = [onScreen]
SceneMirror.merge([fresh], into: scene, unchanged: ["Cube"], selection: [], active: nil)
check("the merge carries the looks and the triangles' slots onto the object on screen, its mesh unchanged",
      onScreen.materialLooks.count == 3 && onScreen.triangleSlots.count == 12 && scene.objects.first === onScreen)

print("== a drag previewed on every object using the material ==")
let a = BKObject(name: "A", kind: .cube), b = BKObject(name: "B", kind: .cube), c = BKObject(name: "C", kind: .cube)
for (obj, rec) in [(a, record), (b, "kind=slot;none=1|" + record), (c, "kind=slot;name=Other;display=1,1,1,1")] {
    let none: [Int32] = []
    none.withUnsafeBufferPointer { buf in _ = SceneMirror.installMaterials(record: rec, triangleSlots: buf, on: obj) }
}
let shared = BKScene(startupFile: false)
shared.objects = [a, b, c]
shared.previewMaterial("Red;one") { $0.base = SIMD3(0, 0, 1) }
check("every slot of every object with the material changes, as it will in Blender",
      a.materialLooks[0].base == SIMD3(0, 0, 1) && b.materialLooks[1].base == SIMD3(0, 0, 1))
check("and nothing else", a.materialLooks[2].base == looks[2].base && c.materialLooks[0].material == "Other"
      && b.materialLooks[0] == .default)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
