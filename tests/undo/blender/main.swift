import Foundation
import simd

// What undo on the device sends, printed for a headless Blender to run in the
// order a session sends it: the history's own calls, and the commands whose
// steps it keeps — adds, deletes, transforms, modifiers, edit-mode operators,
// mode changes and selection, a Texture Paint stroke, animation keys, a light
// and a camera setting, adjusting the last operation both ways, and a script.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }

// MARK: the history

emit("PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false, forceCheckpoints: false))
emit("PUSH_REPLACE", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: true, forceCheckpoints: false))
emit("PUSH_FORCED", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false, forceCheckpoints: true))
emit("UNDO", BackendHistoryPython.step(-1))
emit("REDO", BackendHistoryPython.step(1))
emit("REWIND", BackendHistoryPython.rewind)
emit("CANCEL_REWIND", BackendHistoryPython.cancelRewind)
emit("AUTOSAVE", BackendHistoryPython.autosave(path: "@PATH@"))

// MARK: commands, as BpyBridge.run sends them

emit("DELETE", BpyModeGuard.wrap(Bpy.deleteSelected))
emit("TRANSLATE", BpyModeGuard.wrap(Bpy.translate(SIMD3(1, 2, 0.5))))
emit("ROTATE", BpyModeGuard.wrap(Bpy.rotate(0.5, axis: "Z")))
emit("MODIFIER", BpyModeGuard.wrap(Bpy.addModifier("SUBSURF")))
emit("SELECT_ALL", BpyModeGuard.wrap(Bpy.selectAll(editing: false)))
emit("DESELECT_ALL", BpyModeGuard.wrap(Bpy.deselectAll(editing: false)))
emit("TOGGLE_EDIT", BpyModeGuard.wrap(Bpy.toggleEditMode))
emit("EDIT_SELECT_ALL", BpyModeGuard.wrap(Bpy.selectAll(editing: true)))
emit("EDIT_DESELECT_ALL", BpyModeGuard.wrap(Bpy.deselectAll(editing: true)))
emit("EDIT_SUBDIVIDE", BpyModeGuard.wrap(Bpy.subdivide(1)))
emit("EDIT_DELETE_VERTS", BpyModeGuard.wrap(Bpy.deleteSelection(editing: true, mode: .vertex)))
// A tap, which records no step of its own and mirrors only the selection.
emit("TAP", BpyBridge.selectionScript(Bpy.select("Cylinder")))

// Object Details > a property, as OperatorSearch.apply writes it.
func setProperty(_ path: String, _ key: String, _ json: String) -> String {
    BpyModeGuard.wrap("import _blenderkit_sync as _bkui; import json; _bkui.set_property(\(Bpy.quote(path)), \(Bpy.quote(key)), json.loads(\(Bpy.quote(json))))")
}
emit("LIGHT_ENERGY", setProperty("bpy.data.lights[\"Light\"]", "energy", "250.0"))
emit("CAMERA_LENS", setProperty("bpy.data.cameras[\"Camera\"]", "lens", "35.0"))
emit("CAMERA_LIMITS", setProperty("bpy.data.cameras[\"Camera\"]", "show_limits", "true"))

emit("ANIM_INSERT", BpyAnimation.insertKeyframe)
emit("ANIM_DELETE", BpyAnimation.deleteKeyframe)

emit("PAINT_ENTER", TexturePaintBpy.enter(object: "Cube", width: 64, height: 64))
emit("PAINT_WRITE", TexturePaintBpy.write(images: ["Material Base Color"]))

// MARK: adjusting the last operation

let cylinder = LastOperator.add(.cylinder, at: SIMD3(0, 3, 0))
emit("CYLINDER", BpyBridge.performBody(for: cylinder, backup: false))
var eight = cylinder; eight["vertices"] = 8
var twelve = cylinder; twelve["vertices"] = 12
// What readjust sends between the rewind and the push.
emit("CYLINDER_8", BpyBridge.script(push: nil, discardBackup: false, body: BpyBridge.performBody(for: eight, backup: false)))
emit("CYLINDER_12", BpyBridge.script(push: nil, discardBackup: false, body: BpyBridge.performBody(for: twelve, backup: false)))

let bevel = LastOperator.mesh(.bevel)
var wide = bevel; wide["offset"] = 0.3
emit("BEVEL", BpyBridge.performBody(for: bevel, backup: false))
emit("BEVEL_WIDE", BpyBridge.script(push: nil, discardBackup: false, body: BpyBridge.performBody(for: wide, backup: false)))
// An edit selection pushed in the operator's own evaluation, which the rerun
// has to hand over again: vertex 0 and its neighbours on the cube.
let push = Bpy.pushEditSelection(object: "Cube", mode: .vertex, vertices: [0, 1, 2, 3],
                                 vertexCount: 8, polygonCount: 6)
emit("BEVEL_PICKED", BpyBridge.script(push: push, discardBackup: false, body: BpyBridge.performBody(for: bevel, backup: false)))
emit("BEVEL_PICKED_WIDE", BpyBridge.script(push: push, discardBackup: false, body: BpyBridge.performBody(for: wide, backup: false)))

// The checkpoint fallback keeps adjusting through LastOperator's restoration.
emit("BEVEL_BACKUP", BpyBridge.performBody(for: bevel, backup: true))
var wideRerun = wide; wideRerun.subject = "@SUBJECT@"
emit("BEVEL_RERUN", wideRerun.rerunPython)
emit("DISCARD", LastOperator.discardBackup)

print(out.joined(separator: "\n#--\n"))
