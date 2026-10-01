import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
/// `|` marks the caret; the expected pair is given as offsets into the text
/// with the marker removed.
func matching(_ marked: String) -> (Int, Int)? {
    let caret = marked.distance(from: marked.startIndex,
                                to: marked.firstIndex(of: "|") ?? marked.startIndex)
    return BracketMatch.match(in: marked.replacingOccurrences(of: "|", with: ""), caret: caret)
}

print("Bracket matching")

print("\n  the pair either side of the caret")
check("after an opener", matching("|(a)").map { $0 == (0, 2) } ?? false, "\(matching("|(a)") as Any)")
check("before a closer", matching("(a)|").map { $0 == (0, 2) } ?? false, "\(matching("(a)|") as Any)")
// Monaco looks behind the caret first, so typing the closer highlights the
// pair you just finished.
check("typing the closer highlights what it closed",
      matching("f(x)|").map { $0 == (1, 3) } ?? false, "\(matching("f(x)|") as Any)")
check("nesting counts", matching("|(a(b)c)").map { $0 == (0, 6) } ?? false,
      "\(matching("|(a(b)c)") as Any)")
check("the inner pair when the caret is on it",
      matching("(a|(b)c)").map { $0 == (2, 4) } ?? false, "\(matching("(a|(b)c)") as Any)")
check("square brackets", matching("|[1, 2]").map { $0 == (0, 5) } ?? false)
check("braces", matching("|{k: v}").map { $0 == (0, 5) } ?? false)
check("no bracket, no pair", matching("a| = 1") == nil)
check("an unclosed bracket has no pair", matching("|(a") == nil)
check("a stray closer has no pair", matching("a)|") == nil)
check("brackets do not pair across kinds", matching("|(a]") == nil)

print("\n  strings and comments are not code")
// Without this a bracket in a string pairs with one in the code, and the
// editor boxes two characters that have nothing to do with each other.
check("a bracket inside a string is ignored",
      matching("|(print(\"(\"))").map { $0 == (0, 11) } ?? false,
      "\(matching("|(print(\"(\"))") as Any)")
check("and one inside a comment",
      matching("|(a)  # )").map { $0 == (0, 2) } ?? false, "\(matching("|(a)  # )") as Any)")
check("single quotes too",
      matching("|(f('('))").map { $0 == (0, 7) } ?? false, "\(matching("|(f('('))") as Any)")
check("an escaped quote does not end the string",
      matching("|(\"a\\\"(\")").map { $0 == (0, 7) } ?? false,
      "\(matching("|(\"a\\\"(\")") as Any)")
check("a triple-quoted docstring hides its brackets",
      matching("|(x)\n\"\"\"a ) b\"\"\"").map { $0 == (0, 2) } ?? false,
      "\(matching("|(x)\n\"\"\"a ) b\"\"\"") as Any)")
check("a caret on a bracket inside a string finds nothing",
      matching("print(\"|(\")") == nil, "\(matching("print(\"|(\")") as Any)")

print("\n  a real line")
let call = "bpy.ops.mesh.primitive_cube_add(location=(i * 2.5, 0, 0), rotation=(0, 0, 0))"
// The opening bracket sits at 31 — "bpy.ops.mesh.primitive_cube_add" is
// exactly that many characters — and the call ends on the last one.
let open = call.distance(from: call.startIndex, to: call.firstIndex(of: "(")!)
let outer = BracketMatch.match(in: call, caret: open)
check("the call's own brackets, across two nested pairs",
      outer.map { $0 == (open, call.count - 1) } ?? false, "\(outer as Any)")
// The inner pairs pair with each other, not with the outer one.
let inner = BracketMatch.match(in: call, caret: 41)
check("and the nested location tuple",
      inner.map { call[call.index(call.startIndex, offsetBy: $0.0)] == "("
                  && call[call.index(call.startIndex, offsetBy: $0.1)] == ")"
                  && $0.1 < call.count - 1 } ?? false, "\(inner as Any)")

print("\n  indentation, in columns")
check("none", BracketMatch.indentColumns(of: "x = 1") == 0)
check("four spaces", BracketMatch.indentColumns(of: "    x = 1") == 4)
check("eight", BracketMatch.indentColumns(of: "        x = 1") == 8)
check("a tab counts as a stop, not a character",
      BracketMatch.indentColumns(of: "\tx = 1") == 4)
check("a tab after two spaces fills to the next stop",
      BracketMatch.indentColumns(of: "  \tx") == 4, "\(BracketMatch.indentColumns(of: "  \tx"))")
check("a blank line has no indent", BracketMatch.indentColumns(of: "") == 0)
check("whitespace-only counts what is there",
      BracketMatch.indentColumns(of: "    ") == 4)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
