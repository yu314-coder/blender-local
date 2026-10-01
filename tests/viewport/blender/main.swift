import Foundation
import simd
// The exact strings the interface sends for a tap-select and a gizmo drag.
print("### SELECT")
print(Bpy.select("Target"))
print("### SELECTVERTS")
// The two top corners of a default 2m cube, in the object's own space.
print(Bpy.selectVertices(of: "Target", at: [SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]))
print("### TRANSLATE")
print(String(format: "bpy.ops.transform.translate(value=(%.4f, %.4f, %.4f), constraint_axis=%@)",
             1.5, 0.0, 0.0, "(True, False, False)"))

print("### QUOTED")
print(Bpy.quote("import bpy\n# \"quotes\", slash /, backslash \\, 中文\n"))
