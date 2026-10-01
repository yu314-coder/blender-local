import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

typealias Outcome = BpySession.RunOutcome

print("== which line a traceback blames ==")

// The shape the bike script produced when it failed earlier in development.
let real = """
Traceback (most recent call last):
  File "<string>", line 279, in <module>
  File "<string>", line 189, in build
  File "<string>", line 30, in clear_scene
AttributeError: '_Data' object has no attribute 'curves'
"""
check("the innermost script frame wins, not the outermost",
      Outcome.scriptLine(inTraceback: real) == 30,
      "\(Outcome.scriptLine(inTraceback: real) ?? -1)")

// Frames from real files belong to somebody else's code and cannot be shown
// in this editor, so they must not be picked.
let mixed = """
Traceback (most recent call last):
  File "<string>", line 12, in <module>
  File "/app/python/site/bpy/__init__.py", line 4021, in primitive_cube_add
  File "/app/python/site/bpy/__init__.py", line 900, in _add
ValueError: unknown primitive
"""
check("a library frame is not offered as a script line",
      Outcome.scriptLine(inTraceback: mixed) == 12,
      "\(Outcome.scriptLine(inTraceback: mixed) ?? -1)")

// A syntax error names the line without a frame list.
let syntax = """
  File "<string>", line 7
    for i in range(3)
                     ^
SyntaxError: expected ':'
"""
check("a syntax error still gives its line",
      Outcome.scriptLine(inTraceback: syntax) == 7,
      "\(Outcome.scriptLine(inTraceback: syntax) ?? -1)")

check("a clean run offers nothing",
      Outcome.scriptLine(inTraceback: "Bike built: 24 objects\n") == nil)
check("empty output offers nothing",
      Outcome.scriptLine(inTraceback: "") == nil)
check("a line number of zero is not a line",
      Outcome.scriptLine(inTraceback: "File \"<string>\", line 0, in <module>") == nil)
check("text that merely mentions a line is ignored",
      Outcome.scriptLine(inTraceback: "print('File \"<string>\" has 40 lines')") == nil)

print("\n== it reaches the outcome ==")
var o = Outcome(lines: 10, duration: 0.1, error: "boom",
                objectsBefore: 0, objectsAfter: 0)
check("nil until set", o.errorLine == nil)
o.errorLine = Outcome.scriptLine(inTraceback: real)
check("set from a traceback", o.errorLine == 30, "\(o.errorLine ?? -1)")
check("a failing run is not succeeded", !o.succeeded)

print("\n== the console's closing line ==")
// The traceback above it already ends with the error, so a failed run that
// closed with its summary printed that line twice.
var failed = Outcome(lines: 279, duration: 0.012,
                     error: "RuntimeError: Operator bpy.ops.object.select_all.poll() failed, context is incorrect",
                     objectsBefore: 24, objectsAfter: 24)
failed.errorLine = 28
check("a failed run does not repeat the error its traceback ends with",
      failed.consoleLine != failed.error, failed.consoleLine)
check("it says where the run stopped and what it left",
      failed.consoleLine == "Stopped at line 28 after 12 ms · 24 objects", failed.consoleLine)
check("the editor's banner still gets the error itself", failed.summary == failed.error)
let clean = Outcome(lines: 12, duration: 0.2, error: nil, objectsBefore: 1, objectsAfter: 3)
check("a clean run closes with its summary", clean.consoleLine == clean.summary, clean.consoleLine)

print("\n== counting lines the way Python does ==")
let unix = "x = 1\ny = 2\nz = 3\n1/0\n"
let windows = "x = 1\r\ny = 2\nz = 3\r\n1/0\n"
check("Windows line endings are lines too",
      BpySession.lineCount(of: windows) == BpySession.lineCount(of: unix),
      "\(BpySession.lineCount(of: windows)) vs \(BpySession.lineCount(of: unix))")
check("and so are old Mac ones", BpySession.lineCount(of: "x = 1\ry = 2") == 2,
      "\(BpySession.lineCount(of: "x = 1\ry = 2"))")
check("plain text counts as it always did",
      BpySession.lineCount(of: unix) == unix.split(separator: "\n", omittingEmptySubsequences: false).count)

print("\n== the frames a failed run offers ==")
let frames = Outcome.scriptFrames(inTraceback: real)
check("every script frame, innermost first",
      frames.map(\.line) == [30, 189, 279], "\(frames.map(\.line))")
check("each named after its function",
      frames.map(\.function) == ["clear_scene", "build", "<module>"], "\(frames.map(\.function))")
check("the innermost agrees with the line the editor marks",
      frames.first?.line == Outcome.scriptLine(inTraceback: real))
check("library frames are not places to jump to",
      Outcome.scriptFrames(inTraceback: mixed).map(\.line) == [12],
      "\(Outcome.scriptFrames(inTraceback: mixed).map(\.line))")
check("a syntax error has a line but no function",
      Outcome.scriptFrames(inTraceback: syntax) == [.init(line: 7, function: "")],
      "\(Outcome.scriptFrames(inTraceback: syntax))")
check("a clean run has none",
      Outcome.scriptFrames(inTraceback: "Bike built: 24 objects\n").isEmpty)

print("\n== the error, split for the card ==")
check("the exception's name", failed.errorName == "RuntimeError", failed.errorName ?? "nil")
check("and what it says, without the name",
      failed.errorMessage == "Operator bpy.ops.object.select_all.poll() failed, context is incorrect",
      failed.errorMessage ?? "nil")
let sentence = Outcome(lines: 0, duration: 0, error: "Nothing to run — the editor is empty.",
                       objectsBefore: 0, objectsAfter: 0)
check("a sentence is not split into a name", sentence.errorName == nil, sentence.errorName ?? "nil")
check("and is its own message", sentence.errorMessage == sentence.error, sentence.errorMessage ?? "nil")
let bare = Outcome(lines: 3, duration: 0.1, error: "KeyboardInterrupt",
                   objectsBefore: 0, objectsAfter: 0)
check("an exception with nothing to say still has a name",
      bare.errorName == "KeyboardInterrupt", bare.errorName ?? "nil")
check("and no message", bare.errorMessage == nil, bare.errorMessage ?? "nil")
check("a clean run has neither", clean.errorName == nil && clean.errorMessage == nil)

print("\n== a warning Blender prints for an operator becomes a report ==")
// What Python gets for `bpy.ops.uv.unwrap()` on a UV sphere with a seam
// missing (measured in 5.2.1): FINISHED, and this on stdout.
let unwrapped = [BpyLine(.output, "Warning: Unwrap failed to solve 1 of 7 island(s), edge seams may need to be added"),
                 BpyLine(.info, "[Blender Local] viewport mirrored 1 of 1 mesh objects from bpy.data.")]
check("the operator's warning is found, without Blender's prefix",
      BpyBridge.blenderWarning(in: unwrapped) == "Unwrap failed to solve 1 of 7 island(s), edge seams may need to be added",
      BpyBridge.blenderWarning(in: unwrapped) ?? "nil")
check("a script's own output is not a warning",
      BpyBridge.blenderWarning(in: [BpyLine(.output, "Warnings: 3"), BpyLine(.output, "done")]) == nil)
check("nor is the mirroring pass's",
      BpyBridge.blenderWarning(in: [BpyLine(.info, "Warning: from the pass")]) == nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
