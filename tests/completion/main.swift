import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

let ops = ["mesh.primitive_cube_add", "mesh.primitive_cone_add", "mesh.bevel",
           "mesh.extrude_region_move", "object.delete", "object.duplicate",
           "object.shade_smooth", "transform.translate", "transform.resize"]

func labels(_ text: String, caret: Int? = nil) -> [String] {
    PythonCompletion.candidates(text: text,
                                caret: caret ?? (text as NSString).length,
                                operators: ops).map(\.label)
}

print("== reading the caret's context ==")
for (text, wantPath, wantPartial) in [
    ("bpy.ops.me",      "bpy.ops", "me"),
    ("bpy.",            "bpy",     ""),
    ("x = obj.loc",     "obj",     "loc"),
    ("prin",            "",        "prin"),
    ("bpy.ops.mesh.be", "bpy.ops.mesh", "be"),
] {
    let c = PythonCompletion.context(in: text, caret: (text as NSString).length)
    check("\(text) -> path '\(wantPath)', partial '\(wantPartial)'",
          c.path == wantPath && c.partial == wantPartial,
          "got '\(c.path)' / '\(c.partial)'")
}

print("\n== operators come from the backend, not a table ==")
let meshOps = labels("bpy.ops.mesh.")
check("bpy.ops.mesh. offers that module's operators",
      meshOps.contains("bevel") && meshOps.contains("primitive_cube_add"),
      "\(meshOps.prefix(4))")
check("and not operators from another module", !meshOps.contains("delete"))
let narrowed = labels("bpy.ops.mesh.prim")
check("typing narrows it", narrowed.allSatisfy { $0.hasPrefix("prim") }, "\(narrowed)")
check("a leaf is callable",
      PythonCompletion.candidates(text: "bpy.ops.mesh.bev", caret: 16, operators: ops)
        .first?.callable == true)

print("\n== bpy.ops. offers modules, once each ==")
let modules = labels("bpy.ops.")
check("modules, not operator paths", modules.contains("mesh") && modules.contains("object"),
      "\(modules.prefix(5))")
check("each module appears once", Set(modules).count == modules.count, "\(modules)")
check("no dotted paths at this level", modules.allSatisfy { !$0.contains(".") })

print("\n== the roots a bpy script names constantly ==")
check("bpy. offers data/ops/context",
      Set(labels("bpy.")).isSuperset(of: ["ops", "data", "context"]), "\(labels("bpy."))")
check("bpy.data. offers collections",
      Set(labels("bpy.data.")).isSuperset(of: ["objects", "materials"]), "\(labels("bpy.data."))")
check("bpy.context. offers the active object",
      labels("bpy.context.").contains("active_object"))
check("an unknown receiver falls back to object attributes",
      Set(labels("cube.")).isSuperset(of: ["location", "name"]), "\(labels("cube."))")

print("\n== names the buffer already contains ==")
let script = """
import bpy

def build_wheel(radius):
    spokes = 12
    return radius * spokes

build_w
"""
let learned = labels(script)
check("it learns the reader's own names", learned.contains("build_wheel"), "\(learned)")
let sp = labels("spoke_count = 4\nspoke_radius = 2\nspok")
check("and offers several", sp.count >= 2, "\(sp)")

print("\n== ranking and limits ==")
let short = labels("bpy.data.")
check("shortest first: 'images' before 'materials'",
      (short.firstIndex(of: "images") ?? 99) < (short.firstIndex(of: "materials") ?? 0),
      "\(short)")
check("the list is bounded",
      PythonCompletion.candidates(text: "b", caret: 1, operators: ops, limit: 5).count <= 5)

print("\n== when to offer nothing ==")
check("an empty buffer offers nothing", labels("").isEmpty)
check("a bare word with no prefix typed offers nothing", labels("x = ").isEmpty)
check("a caret past the end is not a crash",
      PythonCompletion.candidates(text: "bpy", caret: 999, operators: ops).isEmpty)
check("a negative caret is not a crash",
      PythonCompletion.candidates(text: "bpy", caret: -1, operators: ops).isEmpty)
check("a completion never offers what is already fully typed",
      !labels("print").contains("print"), "\(labels("print"))")

print("\n== keywords and builtins ==")
check("'imp' offers import", labels("imp").contains("import"), "\(labels("imp"))")
check("'ret' offers return", labels("ret").contains("return"))
check("'mathu' offers mathutils", labels("mathu").contains("mathutils"))

print("\n== what a newline should indent to ==")
func indent(_ line: String) -> String { PythonIndent.afterNewline(in: line) }
for (line, want, why) in [
    ("def build():",            "    ", "a colon opens a block"),
    ("    for i in range(3):",  "        ", "and nests from where it already was"),
    ("    bpy.ops.object.delete()", "    ", "an ordinary line keeps its level"),
    ("x = 1",                   "",     "column zero stays there"),
    ("        return radius",   "    ", "return comes back out one level"),
    ("    pass",                "",     "so does pass"),
    ("",                        "",     "an empty line indents to nothing"),
    ("    ",                    "    ", "whitespace only keeps its whitespace"),
] {
    check("\(why): '\(line)'", indent(line) == want,
          "got '\(indent(line))' wanted '\(want)'")
}

print("\n== colons that do not open a block ==")
for (line, want, why) in [
    ("s = \"a:\"",              "", "a colon inside a string"),
    ("    d = {'k': 1}",       "    ", "a dict literal"),
    ("    x = 1  # note:",     "    ", "a colon in a trailing comment"),
    ("for i in range(3):  # go", "    ", "a real colon with a comment after it"),
] {
    check("\(why): \(line)", indent(line) == want,
          "got '\(indent(line))' wanted '\(want)'")
}

print("\n  prose is not code")

// The bike script's own header, which is what produced the complaint: typing
// `i` offered `its`, `into`, `item`, `instead`, `including` — words out of a
// docstring, presented as if they were identifiers.
let prosey = """
\"\"\"A procedural bicycle, built entirely from code.

Everything is parametric: change WHEEL_R and the whole bike rebuilds around
it. No mesh is hand-modelled instead, including the spokes, which are a
radial loop; each item is placed into its own collection.
\"\"\"
import bpy
inner_radius = 0.2
"""
let names = PythonCompletion.identifiers(in: prosey)
for word in ["instead", "including", "into", "item", "its", "radial", "bicycle"] {
    check("\(word) is prose, not a name", !names.contains(word),
          "\(names.sorted().prefix(12))")
}
check("a real name in the code is still found", names.contains("inner_radius"),
      "\(names.sorted())")
check("and so is the import", names.contains("bpy"))
check("a word in a comment is not a name",
      !PythonCompletion.identifiers(in: "x = 1  # todo: rename everything")
          .contains("rename"))
check("a word in a single-quoted string is not a name",
      !PythonCompletion.identifiers(in: "name = 'placeholder'").contains("placeholder"))
check("but the variable it is assigned to is",
      PythonCompletion.identifiers(in: "name = 'placeholder'").contains("name"))
check("a number is not a name",
      !PythonCompletion.identifiers(in: "x = 1024").contains("1024"))

// The end-to-end version of the complaint.
let offered = PythonCompletion.candidates(text: prosey + "\nfor i",
                                          caret: (prosey + "\nfor i").count,
                                          operators: [])
check("typing `i` no longer offers prose",
      !offered.contains { ["its", "into", "item", "instead", "including"].contains($0.label) },
      "\(offered.map(\.label))")
check("it still offers the keywords",
      offered.contains { $0.label == "in" }, "\(offered.map(\.label))")

check("signature context resolves an unfinished operator call",
      PythonCompletion.callContext(in: "bpy.ops.mesh.bevel(off", caret: 22) == "bpy.ops.mesh.bevel")
check("no parameter suggestions inside strings",
      PythonCompletion.callContext(in: "bpy.ops.mesh.bevel('off", caret: 23) == nil)
let parameterText = "bpy.ops.mesh.bevel(off"
let parameters = PythonCompletion.candidates(text: parameterText, caret: parameterText.utf16.count,
    operators: [], introspect: { path in path.hasSuffix(".#parameters") ? [("offset=", false)] : nil })
check("real RNA parameter names are inserted with equals", parameters.first?.insert == "offset=")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
