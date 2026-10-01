import Foundation
import simd

// Every call the redo panel can emit, printed for a real Blender to run.
//
// Generated from the catalogue rather than copied out of it: a hand-written
// list of expected calls tests the list, not the code that builds them.

var out: [String] = []
func emit(_ head: String, _ body: String) { out.append("### \(head)\n\(body)") }

for kind in PrimitiveKind.allCases {
    var op = LastOperator.add(kind, at: SIMD3(0.5, -1, 2))
    // Adds bracket their mode too, now that one of them was found to crash
    // Blender outright when it ran in sculpt mode.
    emit("add.\(kind.rawValue) ENTRY", op.entryPython)
    emit("add.\(kind.rawValue) FIRST", op.executedPython)
    emit("add.\(kind.rawValue) EXIT", op.exitPython)
    op.subject = "@SUBJECT@"   // the bridge re-reads this after every run; so does the verifier
    for i in op.parameters.indices {
        let p = op.parameters[i]
        for v in [-1e9, 1e9, (p.softMin + p.softMax) / 2] {
            var t = op; t.parameters[i].value = v
            emit("add.\(kind.rawValue) RERUN", t.rerunPython)
        }
    }
    // The same arguments again: the result must not drift.
    emit("add.\(kind.rawValue) SAME", op.rerunPython)
}

for m in LastOperator.Mesh.allCases {
    var op = LastOperator.mesh(m)
    // The three blocks `perform` runs, in the order it runs them: take the
    // backup, get into the mode the operator needs, then the operator.
    emit("mesh.\(m.rawValue) PREAMBLE", op.preamble)
    emit("mesh.\(m.rawValue) ENTRY", op.entryPython)
    emit("mesh.\(m.rawValue) FIRST", op.executedPython)
    emit("mesh.\(m.rawValue) EXIT", op.exitPython)
    op.subject = "@SUBJECT@"
    for i in op.parameters.indices {
        let p = op.parameters[i]
        for v in [-1e9, 1e9, (p.softMin + p.softMax) / 2] {
            var t = op; t.parameters[i].value = v
            emit("mesh.\(m.rawValue) RERUN", t.rerunPython)
        }
    }
    emit("mesh.\(m.rawValue) SAME", op.rerunPython)
}

// Knife Project needs a second object to cut with, so it is not in the loop
// above: the verifier builds a mesh and a cutter named "Cutter" for these and
// runs them itself. PERFORM is exactly what the bridge sends for the first
// press, backup and mode bracketing included.
var knife = LastOperator.knifeProject(cutter: "Cutter")
emit("knife.project PERFORM", BpyBridge.performBody(for: knife))
emit("knife.project UNDOPERFORM", BpyBridge.performBody(for: knife, backup: false))
knife.subject = "@SUBJECT@"
var through = knife
through["cut_through"] = 1
emit("knife.project THROUGH", through.rerunPython)
emit("knife.project SAME", knife.rerunPython)
emit("knife.missing PERFORM", BpyBridge.performBody(for: LastOperator.knifeProject(cutter: "Nothing")))

// The edge tools, for what they do rather than only whether Blender takes them:
// verify.py builds a grid for each and measures the result. PERFORM is what
// the bridge sends for the first press from the Mesh menu.
func edgeCase(_ name: String, _ op: LastOperator) {
    emit("edge.\(name) PERFORM", BpyBridge.performBody(for: op))
}
edgeCase("loops", .mesh(.selectEdgeLoops))
edgeCase("rings", .mesh(.selectEdgeRings))
var loopsAtSeams = LastOperator.mesh(.selectEdgeLoops)
loopsAtSeams["delimit_edge_loop"] = 1
edgeCase("loopsSeam", loopsAtSeams)
var ringsAtSharp = LastOperator.mesh(.selectEdgeRings)
ringsAtSharp["delimit_edge_ring"] = 2
edgeCase("ringsSharp", ringsAtSharp)
edgeCase("slide", .mesh(.edgeSlide))
var slideBack = LastOperator.mesh(.edgeSlide)
slideBack["value"] = -0.5
edgeCase("slideBack", slideBack)
edgeCase("vertex", .mesh(.slideVertices))
var vertexY = LastOperator.mesh(.slideVertices)
vertexY["direction"] = 2
edgeCase("vertexY", vertexY)
edgeCase("connect", .mesh(.connectVertexPath))
edgeCase("offset", .mesh(.offsetEdgeSlide))
edgeCase("markSeam", .mesh(.markSeam))
edgeCase("clearSeam", .mesh(.clearSeam))
edgeCase("markSharp", .mesh(.markSharp))
edgeCase("clearSharp", .mesh(.clearSharp))
edgeCase("crease", .mesh(.edgeCrease))
var creaseHalf = LastOperator.mesh(.edgeCrease)
creaseHalf["value"] = 0.5
edgeCase("creaseHalf", creaseHalf)
edgeCase("bevelWeight", .mesh(.bevelWeight))

// The order a session starts Blender's GPU module in, for gpu_order.py: what
// the app runs on the main thread before a script-thread render, and the
// Render panel's own Eevee render, which the session has to recognise as one.
let render = RenderRequest(engine: .eevee, quality: .draft, width: 32, height: 32,
                           source: .sceneCamera, output: "@OUTPUT@").python
guard ScriptThread.mayStartGPU(render) else {
    FileHandle.standardError.write(Data("the Render panel's render is not recognised as starting the GPU\n".utf8))
    exit(1)
}
emit("knife.gpu START", ScriptThread.gpuStart)
emit("knife.gpu RENDER", render)

emit("DISCARD", LastOperator.discardBackup)
print(out.joined(separator: "\n#--\n"))
