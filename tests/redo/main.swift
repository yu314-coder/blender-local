import Foundation
import simd

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func equal(_ label: String, _ got: String, _ want: String) {
    check(label, got == want, "\n        got  \(got)\n        want \(want)")
}

print("Adjust Last Operation")

// MARK: the arguments Blender's own operators take
//
// Read out of bpy.ops.mesh.*.get_rna_type() in Blender 5.2.1. If any of these
// drift, the panel offers an argument the operator will reject.

print("\n  catalogue matches Blender 5.2.1")

func keys(_ kind: PrimitiveKind) -> [String] {
    LastOperator.add(kind, at: .zero).parameters.map(\.key)
}
func value(_ kind: PrimitiveKind, _ key: String) -> Double? {
    LastOperator.add(kind, at: .zero)[key]
}

equal("cube call", LastOperator.add(.cube, at: .zero).call,
      "bpy.ops.mesh.primitive_cube_add")
equal("uv sphere call", LastOperator.add(.uvSphere, at: .zero).call,
      "bpy.ops.mesh.primitive_uv_sphere_add")

check("plane takes size", keys(.plane) == ["size"], "\(keys(.plane))")
check("cube takes size", keys(.cube) == ["size"], "\(keys(.cube))")
check("monkey takes size", keys(.monkey) == ["size"], "\(keys(.monkey))")
check("circle", keys(.circle) == ["vertices", "radius", "fill_type"], "\(keys(.circle))")
check("uv sphere", keys(.uvSphere) == ["segments", "ring_count", "radius"], "\(keys(.uvSphere))")
check("ico sphere", keys(.icoSphere) == ["subdivisions", "radius"], "\(keys(.icoSphere))")
check("cylinder", keys(.cylinder) == ["vertices", "radius", "depth", "end_fill_type"],
      "\(keys(.cylinder))")
check("cone", keys(.cone) == ["vertices", "radius1", "radius2", "depth", "end_fill_type"],
      "\(keys(.cone))")
check("torus", keys(.torus) == ["major_segments", "minor_segments",
                                "major_radius", "minor_radius"], "\(keys(.torus))")
check("grid", keys(.grid) == ["x_subdivisions", "y_subdivisions", "size"], "\(keys(.grid))")

check("cube size default 2", value(.cube, "size") == 2)
check("circle vertices default 32", value(.circle, "vertices") == 32)
check("uv sphere rings default 16", value(.uvSphere, "ring_count") == 16)
check("ico subdivisions default 2", value(.icoSphere, "subdivisions") == 2)
check("cylinder depth default 2", value(.cylinder, "depth") == 2)
check("cone radius2 default 0", value(.cone, "radius2") == 0)
check("torus minor radius default 0.25", value(.torus, "minor_radius") == 0.25)
check("grid x subdivisions default 10", value(.grid, "x_subdivisions") == 10)

// MARK: the Python

print("\n  the call it writes")

equal("add cube at the origin",
      LastOperator.add(.cube, at: .zero).python,
      "bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))")

equal("add plane away from the origin",
      LastOperator.add(.plane, at: SIMD3(1.5, -2, 0.25)).python,
      "bpy.ops.mesh.primitive_plane_add(size=2, location=(1.5, -2, 0.25))")

// Enums are quoted; counts are not floats. Emitting `vertices=32.0` is a
// TypeError, and `fill_type=NGON` is a NameError.
equal("counts and enums",
      LastOperator.add(.cylinder, at: .zero).python,
      "bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=1, depth=2, "
      + "end_fill_type='NGON', location=(0, 0, 0))")

equal("circle defaults to no fill",
      LastOperator.add(.circle, at: .zero).python,
      "bpy.ops.mesh.primitive_circle_add(vertices=32, radius=1, "
      + "fill_type='NOTHING', location=(0, 0, 0))")

// The Info log and the tool button must be the same string, or copying the log
// out does not reproduce what the button did.
equal("the button writes what the panel writes",
      Bpy.addPrimitive(.torus, at: SIMD3(0, 0, 1)),
      LastOperator.add(.torus, at: SIMD3(0, 0, 1)).python)

// MARK: adjusting

print("\n  adjusting the arguments")

var op = LastOperator.add(.cube, at: .zero)
op["size"] = 3.5
equal("a changed size", op.python,
      "bpy.ops.mesh.primitive_cube_add(size=3.5, location=(0, 0, 0))")

var cyl = LastOperator.add(.cylinder, at: .zero)
cyl["vertices"] = 6
equal("a changed count stays whole", cyl.python,
      "bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=1, depth=2, "
      + "end_fill_type='NGON', location=(0, 0, 0))")

// A scrub lands between two integers. The operator only takes one of them.
cyl["vertices"] = 6.7
check("a scrub between counts rounds", cyl.python.contains("vertices=7"), cyl.python)

// Blender's soft range is where a field scrubs; past it the value is clamped
// rather than passed to an operator that would reject it or hang.
var ico = LastOperator.add(.icoSphere, at: .zero)
ico["subdivisions"] = 400
check("subdivisions clamp to Blender's soft maximum of 8",
      ico["subdivisions"] == 8, "\(ico["subdivisions"] ?? -1)")
ico["subdivisions"] = -5
check("and to its minimum of 1", ico["subdivisions"] == 1, "\(ico["subdivisions"] ?? -1)")

var circle = LastOperator.add(.circle, at: .zero)
circle["vertices"] = 1
check("a circle cannot have fewer than three vertices",
      circle["vertices"] == 3, "\(circle["vertices"] ?? -1)")

var cube = LastOperator.add(.cube, at: .zero)
cube["size"] = -4
check("size cannot go negative", (cube["size"] ?? -1) > 0, "\(cube["size"] ?? -1)")

var enumOp = LastOperator.add(.cylinder, at: .zero)
enumOp["end_fill_type"] = 2
check("the third fill type is TRIFAN",
      enumOp.python.contains("end_fill_type='TRIFAN'"), enumOp.python)
enumOp["end_fill_type"] = 99
check("an out-of-range enum stays inside the options",
      enumOp.python.contains("end_fill_type='TRIFAN'"), enumOp.python)

// Blender writes NGON as "N-Gon" in the interface, and the panel is meant to
// read like Blender's, not like its identifiers.
let fillLabels = LastOperator.add(.cylinder, at: .zero)
    .parameters.first { $0.key == "end_fill_type" }
    .map { p -> [String] in
        if case .choice(let o) = p.kind { return o.map(\.label) }
        return []
    } ?? []
check("the fill types read as Blender writes them",
      fillLabels == ["Nothing", "N-Gon", "Triangle Fan"], "\(fillLabels)")

op = LastOperator.add(.cube, at: .zero)
op.location = SIMD3(0, 0, 2)
equal("a moved location", op.python,
      "bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 2))")

// MARK: re-running

print("\n  re-running replaces rather than repeats")

var fresh = LastOperator.add(.cube, at: .zero)
check("with nothing made yet, re-running is just the call",
      fresh.rerunPython == fresh.python, fresh.rerunPython)

fresh.subject = "Cube"
fresh["size"] = 4
let rerun = fresh.rerunPython
check("it removes the object it made",
      rerun.contains("bpy.data.objects.get(\"Cube\")")
      && rerun.contains("bpy.data.objects.remove(_o, do_unlink=True)"), rerun)
// Leaving the mesh behind frees the object name but not the mesh name, so the
// next cube arrives holding "Cube.001" — and a slider drag leaves a trail of
// orphans.
check("and the mesh it left behind",
      rerun.contains("bpy.data.meshes.remove(_d)"), rerun)
check("only when nothing else is using that mesh",
      rerun.contains("_d.users == 0"), rerun)
check("it guards against the object already being gone",
      rerun.contains("if _o is not None:"), rerun)
check("the new call comes last",
      rerun.hasSuffix("bpy.ops.mesh.primitive_cube_add(size=4, location=(0, 0, 0))"), rerun)

// A renamed object is still the one to remove, and its name is user text.
fresh.subject = "my \"cube\""
check("a name with quotes in it is escaped",
      fresh.rerunPython.contains("bpy.data.objects.get(\"my \\\"cube\\\"\")"),
      fresh.rerunPython)

// MARK: the mesh operators

print("\n  the mesh operators")

func meshKeys(_ m: LastOperator.Mesh) -> [String] {
    LastOperator.mesh(m).parameters.map(\.key)
}

// Blender 5.2.1's own argument names. `offset` on a bevel is the width; on a
// randomize it is the amount. Guessing either would be a TypeError.
// Affect first, where Blender's bevel panel draws it; Individual after Depth,
// where its inset panel does.
check("bevel", meshKeys(.bevel) == ["affect", "offset", "segments", "profile"], "\(meshKeys(.bevel))")
check("inset", meshKeys(.inset) == ["thickness", "depth", "use_individual"], "\(meshKeys(.inset))")
check("subdivide", meshKeys(.subdivide) == ["number_cuts", "smoothness"],
      "\(meshKeys(.subdivide))")
check("smooth", meshKeys(.smooth) == ["factor", "repeat"], "\(meshKeys(.smooth))")
check("merge by distance", meshKeys(.mergeByDistance) == ["threshold"],
      "\(meshKeys(.mergeByDistance))")
check("randomize", meshKeys(.randomize) == ["offset", "uniform", "normal", "seed"],
      "\(meshKeys(.randomize))")
check("loop cut", meshKeys(.loopCut) == ["number_cuts", "smoothness", "interpolation"],
      "\(meshKeys(.loopCut))")
check("shrink/fatten, push/pull and to sphere all take value",
      [LastOperator.Mesh.shrinkFatten, .pushPull, .toSphere].allSatisfy { meshKeys($0) == ["value"] })

// Loop Cut is the ring through the selected edges, so the ring is selected
// first, an empty selection is an error the reader can act on, and the cut is
// the last line — in the first run, the re-run and the log alike.
let loopCut = LastOperator.mesh(.loopCut)
let cutLines = loopCut.python.split(separator: "\n").map(String.init)
check("loop cut selects the ring before cutting",
      cutLines.first == "bpy.ops.mesh.select_edge_ring_multi()", loopCut.python)
check("loop cut refuses an empty selection in words",
      loopCut.python.contains("raise RuntimeError('Loop Cut cuts across the selected edges"), loopCut.python)
check("loop cut ends with the cut, linear by default",
      cutLines.last == "bpy.ops.mesh.subdivide_edgering(number_cuts=1, smoothness=0, interpolation='LINEAR')",
      cutLines.last ?? "")
var adjustedCut = loopCut
adjustedCut.subject = "Cube"
adjustedCut["number_cuts"] = 3
check("an adjusted loop cut re-selects the ring before cutting again",
      adjustedCut.rerunPython.contains("bpy.ops.mesh.select_edge_ring_multi()\n    if bpy.context.object.data.total_edge_sel == 0:")
      && adjustedCut.rerunPython.contains("subdivide_edgering(number_cuts=3,"),
      adjustedCut.rerunPython)
check("the operators without a lead are unchanged",
      !LastOperator.mesh(.bevel).python.contains("\n"), LastOperator.mesh(.bevel).python)

equal("a bevel writes what the tool wrote before, with Blender's Affect spelled out",
      LastOperator.mesh(.bevel).python,
      "bpy.ops.mesh.bevel(affect='EDGES', offset=0.1, segments=2, profile=0.5)")
check("a mesh operator places nothing, so it has no location",
      !LastOperator.mesh(.inset).python.contains("location"),
      LastOperator.mesh(.inset).python)

// MARK: Spin's centre

print("\n  spin turns about a centre the panel can move")

// Three fields in the panel, one argument in the call. Emitted one by one they
// would be `center.x=` — not Python — or three `center=`, which Python refuses.
let spinAtOrigin = LastOperator.mesh(.spin)
equal("the default spin is the line it always was",
      spinAtOrigin.python,
      "bpy.ops.mesh.spin(steps=12, angle=6.2832, dupli=False, axis=(0.0, 0.0, 1.0), center=(0, 0, 0))")
check("the centre is three fields keyed per axis, so the panel's rows stay distinct",
      meshKeys(.spin) == ["steps", "angle", "dupli", "axis", "center.x", "center.y", "center.z"],
      "\(meshKeys(.spin))")
check("and they read as Blender's Center column",
      spinAtOrigin.parameters.suffix(3).map(\.label) == ["X", "Y", "Z"]
      && spinAtOrigin.parameters.suffix(3).allSatisfy {
          if case .component("center", "Center", _) = $0.kind { return true }
          return false
      }, "\(spinAtOrigin.parameters.suffix(3).map(\.kind))")

// Seeded from the object's origin, so a spin nobody adjusts does what it did.
let wheel = LastOperator.mesh(.spin, spinningAround: SIMD3(0, 7, 0.5))
check("it starts at the edited object's origin",
      wheel.python.hasSuffix("center=(0, 7, 0.5))"), wheel.python)

// A bolt circle: geometry at the hub, orbiting a point it does not sit on.
var bolts = LastOperator.mesh(.spin, spinningAround: .zero)
bolts["center.x"] = 2
bolts["dupli"] = 1
bolts["steps"] = 36
equal("moving one axis of the centre moves only that one",
      bolts.python,
      "bpy.ops.mesh.spin(steps=36, angle=6.2832, dupli=True, axis=(0.0, 0.0, 1.0), center=(2, 0, 0))")
check("and the centre is one argument, however many fields it has",
      bolts.python.components(separatedBy: "center=").count == 2, bolts.python)
bolts["center.y"] = -1e9
check("a centre clamps to Blender's soft range of ±10000",
      bolts.python.contains("center=(2, -10000, 0)"), bolts.python)
bolts.subject = "Hub"
check("an adjusted spin re-runs with its centre",
      bolts.rerunPython.contains("center=(2, -10000, 0))"), bolts.rerunPython)
check("bisect still cuts through the origin it was given",
      LastOperator.mesh(.bisect, spinningAround: SIMD3(1, 2, 3)).python.hasSuffix("plane_co=(1, 2, 3))"),
      LastOperator.mesh(.bisect, spinningAround: SIMD3(1, 2, 3)).python)

// MARK: Knife Project

print("\n  knife project cuts with another object's outline")

var knife = LastOperator.knifeProject(cutter: "Circle")
equal("the operator runs inside a view aimed along the cutter",
      knife.python,
      "import _blenderkit_knife\n"
      + "with _blenderkit_knife.projecting(\"Circle\"):\n"
      + "    bpy.ops.mesh.knife_project(cut_through=False)")
check("it works on the mesh being edited", knife.needsEditMode && knife.restoration == .restoreMesh)
check("Cut Through is its one adjustable argument, as in Blender's panel",
      knife.parameters.map(\.key) == ["cut_through"], "\(knife.parameters.map(\.key))")
knife["cut_through"] = 1
knife.subject = "Plane"
let knifeRerun = knife.rerunPython
check("an adjusted knife project re-runs the whole block, indented under the restore",
      knifeRerun.contains("    import _blenderkit_knife\n"
                          + "    with _blenderkit_knife.projecting(\"Circle\"):\n"
                          + "        bpy.ops.mesh.knife_project(cut_through=True)"), knifeRerun)
check("a cutter's name is user text, and is quoted as such",
      LastOperator.knifeProject(cutter: "the \"lid\"").python
        .contains("projecting(\"the \\\"lid\\\"\")"),
      LastOperator.knifeProject(cutter: "the \"lid\"").python)

// MARK: the edge tools

print("\n  the edge tools: loops, slides, seams, sharp, crease, bevel weight")

// Blender 5.2.1's argument names, read from get_rna_type(); the Blender half
// of this is tests/redo/blender, which runs every call below.
check("edge slide takes Factor, Even and Flipped",
      meshKeys(.edgeSlide) == ["value", "use_even", "flipped"], "\(meshKeys(.edgeSlide))")
check("slide vertices takes Factor and a direction",
      meshKeys(.slideVertices) == ["value", "direction"], "\(meshKeys(.slideVertices))")
check("offset edge slide's factor is the edge slide sub-operator's",
      meshKeys(.offsetEdgeSlide) == ["TRANSFORM_OT_edge_slide"], "\(meshKeys(.offsetEdgeSlide))")
check("crease and bevel weight take a value",
      meshKeys(.edgeCrease) == ["value"] && meshKeys(.bevelWeight) == ["value"])
// Mark Sharp's `use_verts` is shown in Blender's panel and not offered
// here; `clear` is hidden there (5.2.1's RNA).
check("connect path and the marks have nothing the panel offers",
      [LastOperator.Mesh.connectVertexPath, .markSeam, .clearSeam, .markSharp, .clearSharp]
        .allSatisfy { meshKeys($0).isEmpty })
// They were listed with the marks as having nothing to adjust, which 5.2.1's
// RNA contradicts: `delimit_edge_loop` and `delimit_edge_ring` are enum flags.
check("the selections take Blender's Delimit",
      meshKeys(.selectEdgeLoops) == ["delimit_edge_loop"]
      && meshKeys(.selectEdgeRings) == ["delimit_edge_ring"],
      "\(meshKeys(.selectEdgeLoops)) \(meshKeys(.selectEdgeRings))")
var delimited = LastOperator.mesh(.selectEdgeLoops)
delimited["delimit_edge_loop"] = 3
check("each Delimit keeps Blender's default flags and adds Seam, Sharp or both",
      delimited.python.hasSuffix(
          "select_edge_loop_multi(delimit_edge_loop={'NGONS', 'OUTER_CORNERS', 'SEAM', 'SHARP'})"),
      delimited.python)

func lastLine(_ m: LastOperator.Mesh) -> String {
    LastOperator.mesh(m).python.split(separator: "\n").map(String.init).first {
        $0.contains(m.call)
    } ?? ""
}
equal("select edge loops calls Blender's Select Loops operator, at its default Delimit",
      lastLine(.selectEdgeLoops),
      "bpy.ops.mesh.select_edge_loop_multi(delimit_edge_loop={'NGONS', 'OUTER_CORNERS'})")
equal("and edge rings", lastLine(.selectEdgeRings),
      "bpy.ops.mesh.select_edge_ring_multi(delimit_edge_ring={'NGONS'})")
equal("mark seam says clear=False, as Blender's Info log does",
      lastLine(.markSeam), "bpy.ops.mesh.mark_seam(clear=False)")
equal("clear seam is the same operator with clear=True",
      lastLine(.clearSeam), "bpy.ops.mesh.mark_seam(clear=True)")
equal("mark sharp", lastLine(.markSharp), "bpy.ops.mesh.mark_sharp(clear=False)")
equal("clear sharp", lastLine(.clearSharp), "bpy.ops.mesh.mark_sharp(clear=True)")
equal("connect vertex path", lastLine(.connectVertexPath), "bpy.ops.mesh.vert_connect_path()")

// The ones that return CANCELLED without a word raise instead, wherever the
// call runs: first run and re-run alike. The Info log keeps the bare call,
// as Blender's does — the check is the interface's scaffolding.
let slide = LastOperator.mesh(.edgeSlide)
equal("edge slide starts halfway and raises what Blender would only have shown",
      slide.executedPython,
      "if 'CANCELLED' in bpy.ops.transform.edge_slide(value=0.5, use_even=False, flipped=False):\n"
      + "    raise RuntimeError(\(Bpy.quote(LastOperator.Mesh.edgeSlide.refusal!)))")
equal("and logs the call Blender logs", slide.python,
      "bpy.ops.transform.edge_slide(value=0.5, use_even=False, flipped=False)")
equal("slide vertices, halfway along +X",
      LastOperator.mesh(.slideVertices).python,
      "bpy.ops.transform.vert_slide(value=0.5, direction=(1.0, 0.0, 0.0))")
equal("offset edge slide nests its factor under the sub-operator",
      LastOperator.mesh(.offsetEdgeSlide).python,
      "bpy.ops.mesh.offset_edge_loops_slide(TRANSFORM_OT_edge_slide={\"value\": 0.5})")
equal("edge crease starts at a full crease",
      LastOperator.mesh(.edgeCrease).python, "bpy.ops.transform.edge_crease(value=1)")
equal("bevel weight too",
      LastOperator.mesh(.bevelWeight).python, "bpy.ops.transform.edge_bevelweight(value=1)")
check("each of those runs with its refusal around it",
      [LastOperator.Mesh.slideVertices, .offsetEdgeSlide, .edgeCrease, .bevelWeight].allSatisfy {
          let op = LastOperator.mesh($0)
          return op.executedPython == "if 'CANCELLED' in \(op.python):\n"
              + "    raise RuntimeError(\(Bpy.quote($0.refusal!)))"
      })
check("and the bridge's first run is the one with the refusal",
      BpyBridge.performBody(for: slide).contains("    if 'CANCELLED' in bpy.ops.transform.edge_slide("),
      BpyBridge.performBody(for: slide))
// Not Bevel any more: with nothing selected it returns CANCELLED and raises
// nothing (measured in 5.2.1, Affect on Edges and on Vertices), so it has a
// refusal now.
check("the operators that raise on their own keep a plain call",
      LastOperator.mesh(.markSeam).refusal == nil
      && !LastOperator.mesh(.markSeam).executedPython.contains("CANCELLED"))

// The ones that return FINISHED having done nothing refuse an empty selection
// before the call, in words.
for m in [LastOperator.Mesh.selectEdgeLoops, .selectEdgeRings, .markSeam, .clearSeam,
          .markSharp, .clearSharp] {
    let lines = LastOperator.mesh(m).python.split(separator: "\n").map(String.init)
    check("\(m.displayName) refuses an empty edge selection before the call",
          lines.count == 3 && lines[0] == "if bpy.context.object.data.total_edge_sel == 0:"
          && lines[1].contains("raise RuntimeError('\(m.displayName) ") && lines[2].hasPrefix(m.call),
          lines.joined(separator: " / "))
}
check("connect vertex path wants two vertices",
      LastOperator.mesh(.connectVertexPath).python.hasPrefix(
          "if bpy.context.object.data.total_vert_sel < 2:\n"
          + "    raise RuntimeError('Connect Vertex Path joins selected vertices: select two')"),
      LastOperator.mesh(.connectVertexPath).python)

// Factors are bare numbers; lengths keep their metres.
check("a factor reads as a factor",
      LastOperator.mesh(.edgeSlide).parameters[0].display == "0.500"
      && LastOperator.mesh(.offsetEdgeSlide).parameters[0].display == "0.500"
      && LastOperator.mesh(.edgeCrease).parameters[0].display == "1.000",
      LastOperator.mesh(.edgeSlide).parameters[0].display)
func field(_ m: LastOperator.Mesh, _ key: String) -> LastOperator.Parameter? {
    LastOperator.mesh(m).parameters.first { $0.key == key }
}
check("a length still reads in metres",
      field(.bevel, "offset")?.display == "0.100 m"
      && field(.extrude, "TRANSFORM_OT_shrink_fatten")?.display == "0.200 m",
      field(.bevel, "offset")?.display ?? "none")
check("and a count as a count", field(.bevel, "segments")?.unit == .count)

var slid = LastOperator.mesh(.edgeSlide)
slid["value"] = -0.25
slid["flipped"] = 1
slid.subject = "Grid"
check("an adjusted slide re-runs with the refusal around it, indented under the restore",
      slid.rerunPython.contains(
          "    if 'CANCELLED' in bpy.ops.transform.edge_slide(value=-0.25, use_even=False, flipped=True):\n"
          + "        raise RuntimeError("), slid.rerunPython)
var along = LastOperator.mesh(.slideVertices)
along["direction"] = 3
along["value"] = -1
check("slide vertices clamps at 0, where Blender's Clamp stops it, and slides along -Y",
      along.python.contains("vert_slide(value=0, direction=(0.0, -1.0, 0.0))"), along.python)

// The Mesh menu reads these.
check("the new groups are Blender's headings, in its header's order",
      LastOperator.Mesh.Group.allCases.map(\.rawValue)
      == ["Select Loops", "Add Geometry", "Split", "Cut and Divide", "Vertex", "Edge",
          "Clean Up", "Fill", "Normals", "Deform"],
      "\(LastOperator.Mesh.Group.allCases.map(\.rawValue))")
check("and the Edge group lists Blender's Edge menu in its order",
      LastOperator.Mesh.allCases.filter { $0.group == .edge }.map(\.displayName)
      == ["Edge Slide", "Offset Edge Slide", "Edge Bevel Weight", "Edge Crease",
          "Mark Seam", "Clear Seam", "Mark Sharp", "Clear Sharp", "Un-Subdivide"],
      "\(LastOperator.Mesh.allCases.filter { $0.group == .edge }.map(\.displayName))")
// The menu draws every group and fills it from `group`, so an operator is
// always in a drawn group; what can go wrong is a group drawn empty.
check("every group the menu draws has an operator in it",
      LastOperator.Mesh.Group.allCases.allSatisfy { g in
          LastOperator.Mesh.allCases.contains { $0.group == g }
      })

// From Object Mode the menu runs an operator on the selection the mesh last
// stored, which the app does not draw there. These change nothing else.
check("the selections and the edge flags are offered in Edit Mode only",
      LastOperator.Mesh.allCases.filter(\.editModeOnly)
      == [.selectEdgeLoops, .selectEdgeRings, .bevelWeight, .edgeCrease,
          .markSeam, .clearSeam, .markSharp, .clearSharp],
      "\(LastOperator.Mesh.allCases.filter(\.editModeOnly))")

// Flipped picks which neighbour Even follows, and does nothing without Even
// (measured in 5.2.1): its row is greyed until Even is on.
var evenSlide = LastOperator.mesh(.edgeSlide)
let flippedRow = evenSlide.parameters.first { $0.key == "flipped" }!
check("Flipped is greyed while Even is off", !evenSlide.isActive(flippedRow))
evenSlide["use_even"] = 1
check("and live once it is on", evenSlide.isActive(flippedRow))
check("the other rows are always live",
      evenSlide.parameters.filter { $0.key != "flipped" }.allSatisfy { evenSlide.isActive($0) }
      && LastOperator.mesh(.bevel).parameters.allSatisfy { LastOperator.mesh(.bevel).isActive($0) })

// Knife Project's `within` indents every line of the call now; one line is
// exactly what it was.
equal("a single-line call inside `within` is unchanged",
      LastOperator.knifeProject(cutter: "Circle").python.split(separator: "\n").last.map(String.init) ?? "",
      "    bpy.ops.mesh.knife_project(cut_through=False)")

// MARK: putting a mesh back

print("\n  putting a mesh back")

var bevel = LastOperator.mesh(.bevel)
check("the backup is taken from the live mesh, not the pre-edit-mode one",
      bevel.preamble.contains("_s.update_from_editmode()"), bevel.preamble)
check("it takes a backup before running",
      bevel.preamble.contains("_b = _s.data.copy()")
      && bevel.preamble.contains("_b.use_fake_user = True"), bevel.preamble)
check("clearing any previous one first, so the name is free",
      bevel.preamble.contains("bpy.data.meshes.remove(_b)"), bevel.preamble)
check("an add takes no backup — it has nothing yet to back up",
      LastOperator.add(.cube, at: .zero).preamble.isEmpty)

bevel.subject = "Cube"
bevel["segments"] = 5
let reb = bevel.rerunPython
check("re-running puts the mesh back from the copy",
      reb.contains("_o.data = _b.copy()"), reb)
check("out of edit mode first, since a datablock cannot be swapped in it",
      reb.contains("if _m != 'OBJECT':"), reb)
check("and back into edit mode to run the operator",
      reb.contains("bpy.ops.object.mode_set(mode='EDIT')"), reb)
check("ending in the mode it started in",
      reb.contains("if _o.mode != _m:") && reb.contains("bpy.ops.object.mode_set(mode=_m)"), reb)
check("the discarded mesh is not left orphaned",
      reb.contains("if _old.users == 0:"), reb)
check("the new arguments are the ones that run",
      reb.contains("bpy.ops.mesh.bevel(affect='EDGES', offset=0.1, segments=5, profile=0.5)"), reb)
check("and it does nothing at all if either half is missing",
      reb.contains("if _o is not None and _b is not None:"), reb)

check("the backup is droppable",
      LastOperator.discardBackup.contains("_b.use_fake_user = False")
      && LastOperator.discardBackup.contains("bpy.data.meshes.remove(_b)"),
      LastOperator.discardBackup)

// An add is still restored by removal, not by a mesh copy.
var addOp = LastOperator.add(.cube, at: .zero)
addOp.subject = "Cube"
check("an add still replaces the object it made",
      addOp.rerunPython.contains("bpy.data.objects.remove(_o, do_unlink=True)"),
      addOp.rerunPython)
check("and does not go looking for a backup mesh",
      !addOp.rerunPython.contains(LastOperator.backupMesh), addOp.rerunPython)

// MARK: number formatting

print("\n  numbers read as numbers")

equal("a whole number has no decimal point", LastOperator.number(2), "2")
equal("a fraction keeps only what it needs", LastOperator.number(0.25), "0.25")
equal("trailing zeros go", LastOperator.number(1.5000), "1.5")
equal("negative zero is zero", LastOperator.number(-0.00001), "0")
equal("a negative number keeps its sign", LastOperator.number(-2.5), "-2.5")

// MARK: the undo stack

print("\n  the undo stack keeps its height")

// Without the startup file, so the only object in it is the one the test adds.
let scene = BKScene(startupFile: false)
let undo = UndoStack()
undo.seed(scene)
scene.objects.append(BKObject(name: "Cube", kind: .cube))
undo.push("Add Cube", scene)
check("one add is one step", undo.canUndo && !undo.canRedo)
let nameAfterAdd = undo.undoName

// Sixty frames of a slider drag.
for _ in 0..<60 { undo.replaceTop("Add Cube", scene) }
check("sixty adjustments are still one step", undo.undoName == nameAfterAdd)
undo.undo(into: scene)
check("and one undo goes back past the add", scene.objects.isEmpty,
      "\(scene.objects.count) left")
check("with nothing further to undo", !undo.canUndo)

// MARK: the Info log

print("\n  the Info log reads as a script")

let session = BpySession()
session.logOperator("bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))", output: [])
let afterFirst = session.infoLog.count
for size in [3, 4, 5] {
    session.replaceLastOperator("bpy.ops.mesh.primitive_cube_add(size=\(size), location=(0, 0, 0))")
}
check("adjusting rewrites the line rather than adding one",
      session.infoLog.count == afterFirst, "\(session.infoLog.count) vs \(afterFirst)")
check("and the line left is the last value",
      session.infoLog.last == "bpy.ops.mesh.primitive_cube_add(size=5, location=(0, 0, 0))",
      session.infoLog.last ?? "nothing")

// MARK: end to end, through the bridge

print("\n  a full add-then-adjust, through the bridge")

let live = BKScene(startupFile: false)
let liveUndo = UndoStack()
liveUndo.seed(live)
let liveSession = BpySession(runtime: StubBpyRuntime())
liveSession.bind(scene: live, undo: liveUndo)
let bridge = BpyBridge(session: liveSession, scene: live, undo: liveUndo)

check("nothing to adjust before anything has run", bridge.adjustable == nil)

bridge.perform(LastOperator.add(.cylinder, at: .zero))
check("the add succeeded", live.objects.count == 1, "\(live.objects.count) objects")
check("and left something to adjust", bridge.adjustable != nil)
check("named after the operator", bridge.adjustable?.name == "Add Cylinder",
      bridge.adjustable?.name ?? "nothing")
check("holding the name of what it made",
      bridge.adjustable?.subject == "Cylinder",
      bridge.adjustable?.subject ?? "nothing")
let defaultVertices = live.objects[0].mesh.vertices.count

// Twenty frames of a slider drag.
var live_op = bridge.adjustable!
let generationAtAdd = bridge.adjustableGeneration
for v in stride(from: 31, through: 12, by: -1) {
    live_op["vertices"] = Double(v)
    guard let updated = bridge.readjust(live_op) else {
        check("adjustment \(v) succeeded", false, "readjust returned nothing")
        break
    }
    live_op = updated
}

check("twenty adjustments leave one object", live.objects.count == 1,
      "\(live.objects.count) objects")
check("the geometry actually changed",
      live.objects.first?.mesh.vertices.count != defaultVertices,
      "still \(defaultVertices) vertices")
check("and it is still named Cylinder", live.objects.first?.name == "Cylinder",
      live.objects.first?.name ?? "nothing")
check("adjusting is not a new operation", bridge.adjustableGeneration == generationAtAdd,
      "\(bridge.adjustableGeneration) vs \(generationAtAdd)")
check("one undo goes back past the whole thing",
      { liveUndo.undo(into: live); return live.objects.isEmpty }(),
      "\(live.objects.count) left")

// A different operator takes the panel over; a selection change does not.
bridge.perform(LastOperator.add(.cube, at: .zero))
let afterCube = bridge.adjustableGeneration
check("a second add is a new operation", afterCube != generationAtAdd)
check("and the panel now shows it", bridge.adjustable?.name == "Add Cube",
      bridge.adjustable?.name ?? "nothing")
bridge.run(BpyCommands.deselect)
check("a selection change leaves the panel alone", bridge.adjustable?.name == "Add Cube",
      bridge.adjustable?.name ?? "nothing")
bridge.run(Bpy.deleteSelected, undo: "Delete")
check("but another real operator clears it", bridge.adjustable == nil,
      bridge.adjustable?.name ?? "nothing")

// MARK: what reaches the Info log

print("\n  the Info log gets the action, not the scaffolding")

let logScene = BKScene(startupFile: false)
let logUndo = UndoStack()
logUndo.seed(logScene)
let logSession = BpySession(runtime: StubBpyRuntime())
logSession.bind(scene: logScene, undo: logUndo)
let logBridge = BpyBridge(session: logSession, scene: logScene, undo: logUndo)

logBridge.perform(LastOperator.add(.cube, at: .zero))
check("an add logs exactly one line",
      logSession.infoLog.count == 1, "\(logSession.infoLog)")
check("and that line is the operator",
      logSession.infoLog.first == "bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))",
      logSession.infoLog.first ?? "nothing")

// A mesh operator takes a backup first. That is the interface talking to
// itself, and it has no business in a log meant to be re-runnable as a script.
let before = logSession.infoLog.count
logBridge.perform(LastOperator.mesh(.bevel))
let added = Array(logSession.infoLog.dropFirst(before))
check("a mesh operator never logs its backup-taking",
      !added.contains { $0.contains("_b") || $0.contains("use_fake_user") },
      "\(added)")
check("it logs the operator itself",
      added.contains("bpy.ops.mesh.bevel(affect='EDGES', offset=0.1, segments=2, profile=0.5)"),
      "\(added)")

print("\n  the Object menu's adjustable operators, and Add ▸ Curve and Text")
do {
    let auto = LastOperator.shadeAutoSmooth()
    check("Shade Auto Smooth calls Blender's operator with its Angle in radians",
          auto.python.contains("bpy.ops.object.shade_auto_smooth(angle=0.5236)"), auto.python)
    check("inside the helper that names a missing Essentials library",
          auto.python.contains("with _blenderkit_context.needs_essentials('Shade Auto Smooth'")
              && auto.python.contains("import _blenderkit_context"), auto.python)
    check("refusing anything but a mesh first", auto.python.hasPrefix("_bk_o = bpy.context.view_layer.objects.active"),
          auto.python)
    check("in object mode, with the mesh put back for a re-run",
          auto.requiredBlenderMode == "OBJECT" && auto.restoration == .restoreMesh)
    check("its Angle field reads in degrees",
          auto.parameters.first?.display == "30.0°", auto.parameters.first?.display ?? "-")

    let byAngle = LastOperator.shadeSmoothByAngle()
    check("Shade Smooth by Angle keeps sharp edges by default, as Blender does",
          byAngle.python.contains("bpy.ops.object.shade_smooth_by_angle(angle=0.5236, keep_sharp_edges=True)"),
          byAngle.python)

    var quad = LastOperator.quadriflowRemesh()
    check("QuadriFlow asks for Blender's 4000 faces, in FACES mode",
          quad.python.contains("bpy.ops.object.quadriflow_remesh(target_faces=4000, use_mesh_symmetry=True, "
                               + "use_preserve_sharp=False, use_preserve_boundary=False, smooth_normals=False, "
                               + "seed=0, mode='FACES')"), quad.python)
    quad["target_faces"] = 1633.4
    check("a number of faces is a whole number", quad.python.contains("target_faces=1633,"), quad.python)

    let text = LastOperator.add(.text, at: SIMD3(1, 2, 3))
    equal("Add Text", text.python, "bpy.ops.object.text_add(radius=1, location=(1, 2, 3))")
    var retext = text
    retext.subject = "Text"
    check("a re-run removes the old text's data from bpy.data.curves, where a TextCurve lives",
          retext.rerunPython.contains("bpy.data.curves.remove(_d)"), retext.rerunPython)
    equal("Add Bézier", LastOperator.add(.curve(.bezier), at: .zero).python,
          "bpy.ops.curve.primitive_bezier_curve_add(radius=1, location=(0, 0, 0))")
    equal("Add Bézier Circle", LastOperator.add(.curve(.circle), at: .zero).python,
          "bpy.ops.curve.primitive_bezier_circle_add(radius=1, location=(0, 0, 0))")
    check("named as Blender names them, which is the undo step",
          LastOperator.add(.curve(.bezier), at: .zero).name == "Add Bézier"
              && LastOperator.add(.curve(.circle), at: .zero).name == "Add Bézier Circle"
              && text.name == "Add Text")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
