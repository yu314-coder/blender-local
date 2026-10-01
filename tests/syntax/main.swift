import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

/// What the scanner makes of the character at a UTF-16 offset.
func token(_ src: String, at offset: Int) -> PythonSyntax.Token {
    for (r, t) in PythonSyntax.spans(src) where NSLocationInRange(offset, r) { return t }
    return .plain
}
func offset(_ src: String, of needle: String) -> Int {
    (src as NSString).range(of: needle).location
}
func expect(_ label: String, _ src: String, _ needle: String, _ want: PythonSyntax.Token) {
    let got = token(src, at: offset(src, of: needle))
    check("\(label): \(needle.prefix(24))", got == want, "got \(got), wanted \(want)")
}

print("== the basics ==")
let basic = "import bpy\nx = 42\nprint('hi')  # note\n"
expect("import is a keyword", basic, "import", PythonSyntax.Token.keyword)
expect("bpy is picked out", basic, "bpy", PythonSyntax.Token.builtin)
expect("42 is a number", basic, "42", PythonSyntax.Token.number)
expect("print is a builtin", basic, "print", PythonSyntax.Token.builtin)
expect("the string body", basic, "'hi'", PythonSyntax.Token.string)
expect("the comment", basic, "# note", PythonSyntax.Token.comment)

print("\n== the cases that break naive highlighters ==")
// A # inside a string is not a comment.
let hashInString = "url = 'http://x#frag'\ny = 1\n"
expect("# inside a string stays string", hashInString, "#frag", PythonSyntax.Token.string)
expect("code after it still colours", hashInString, "1", PythonSyntax.Token.number)

// A quote inside a comment does not open a string.
let quoteInComment = "# it's fine\nz = 7\n"
expect("apostrophe in a comment", quoteInComment, "'s fine", PythonSyntax.Token.comment)
expect("the next line is unaffected", quoteInComment, "7", PythonSyntax.Token.number)

// A keyword inside a string is not a keyword.
let kwInString = "s = 'import for while'\n"
expect("keywords inside strings", kwInString, "import", PythonSyntax.Token.string)

// Escaped quote must not end the string early.
let escaped = "s = 'don\\'t'\nn = 5\n"
expect("escaped quote keeps the string open", escaped, "t'", PythonSyntax.Token.string)
expect("and the line after is normal", escaped, "5", PythonSyntax.Token.number)

// Triple quotes span lines, and a # inside is not a comment.
let triple = "\"\"\"a docstring\n# not a comment\nstill string\"\"\"\nq = 9\n"
expect("triple-quoted spans lines", triple, "# not a comment", PythonSyntax.Token.string)
expect("and ends where it should", triple, "9", PythonSyntax.Token.number)

// An unterminated string should not swallow the rest of the file.
let unterminated = "s = 'oops\nk = 3\n"
expect("unterminated string stops at the newline", unterminated, "3", PythonSyntax.Token.number)

// A dotted attribute is not a number just because it starts with a dot.
let attr = "bpy.ops.mesh.primitive_cube_add(size=2)\n"
expect("size= is plain", attr, "size", PythonSyntax.Token.plain)
expect("2 is a number", attr, "2", PythonSyntax.Token.number)
check("the dot in bpy.ops is not a number",
      token(attr, at: offset(attr, of: ".ops")) == .plain,
      "\(token(attr, at: offset(attr, of: ".ops")))")

// Floats, exponents and hex.
let numbers = "a = 1.5e-3\nb = 0x1f\nc = 1_000\n"
for n in ["1.5e-3", "0x1f", "1_000"] {
    expect("number form", numbers, n, PythonSyntax.Token.number)
}

// A decorator.
expect("decorator", "@property\ndef f(): pass\n", "@property", PythonSyntax.Token.decorator)

print("\n== offsets survive characters outside the BMP ==")
// NSRange counts UTF-16 units; an emoji is two. If the scanner counted
// scalars, every colour after one would be shifted by one unit per emoji.
let emoji = "# 🎬 clapper\nvalue = 123\n"
expect("a number after an emoji comment", emoji, "123", PythonSyntax.Token.number)
let emojiString = "s = '🎬'\nn = 77\n"
expect("a number after an emoji string", emojiString, "77", PythonSyntax.Token.number)

print("\n== the real bike script ==")
if let bike = try? String(contentsOfFile: "examples/bike.py", encoding: .utf8) {
    let spans = PythonSyntax.spans(bike)
    let ns = bike as NSString
    check("it produces spans", spans.count > 200, "\(spans.count)")
    check("no span runs past the end",
          spans.allSatisfy { $0.0.location + $0.0.length <= ns.length })
    check("no span is empty", spans.allSatisfy { $0.0.length > 0 })
    var last = -1
    check("spans are ordered and do not overlap",
          spans.allSatisfy { s in
              let ok = s.0.location > last
              last = s.0.location + s.0.length - 1
              return ok
          })
} else {
    check("bike.py readable", false, "not found")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
