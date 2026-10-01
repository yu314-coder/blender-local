import Foundation
let raw: [(String, String)] = [
  ("object.select_all",   Bpy.selectAll),
  ("object.deselect_all", Bpy.deselectAll),
  ("object.delete",       Bpy.deleteSelected),
  ("object.tap_select",   Bpy.select("Cube")),
  ("mesh.extrude_region", Bpy.extrudeRegion),
  ("mesh.extrude_indiv",  Bpy.extrudeIndividual),
  ("mesh.flip_normals",   Bpy.flipNormals),
  ("mesh.recalc_normals", Bpy.recalcNormals),
  ("mesh.delete_verts",   Bpy.deleteMesh("VERT")),
  ("mesh.select_all",     Bpy.selectAllMesh),
  ("mesh.deselect_all",   Bpy.deselectAllMesh),
  ("mesh.invert",         Bpy.invertMesh),
  ("mesh.select_linked",  Bpy.selectLinked),
  ("mesh.select_more",    Bpy.selectMore),
  ("mesh.select_less",    Bpy.selectLess),
  ("mesh.shade_smooth",   "bpy.ops.mesh.faces_shade_smooth()"),
  ("mesh.select_random",  "bpy.ops.mesh.select_random(ratio=0.5)"),
] + UVOperator.allCases.map { ("uv.\($0.rawValue)", Bpy.uv($0)) }
for (k, v) in raw { print("### \(k)\n\(BpyModeGuard.wrap(v))\n#--") }
