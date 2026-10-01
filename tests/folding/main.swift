import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}
func folds(_ text: String) -> [(Int, Int)] {
    PythonFolding.regions(in: text).map { ($0.startLine, $0.endLine) }
}
func same(_ got: [(Int, Int)], _ want: [(Int, Int)]) -> Bool {
    got.count == want.count && zip(got, want).allSatisfy { $0 == $1 }
}

print("Python folding")

print("\n  what opens a region")
check("a def folds its body",
      same(folds("def f():\n    a = 1\n    b = 2\n"), [(1, 3)]),
      "\(folds("def f():\n    a = 1\n    b = 2\n"))")
check("a flat file folds nothing",
      folds("a = 1\nb = 2\n").isEmpty, "\(folds("a = 1\nb = 2\n"))")
check("the region ends where the indentation returns",
      same(folds("def f():\n    a = 1\nb = 2\n"), [(1, 2)]),
      "\(folds("def f():\n    a = 1\nb = 2\n"))")

print("\n  nesting")
let nested = """
def outer():
    for i in range(3):
        print(i)
    return 1
after = 2
"""
check("both the def and the loop fold",
      same(folds(nested), [(1, 4), (2, 3)]), "\(folds(nested))")

print("\n  blank and comment lines belong to the block")
// Without this every paragraph break inside a function would close it, and a
// def with a blank line in the middle would fold only its first half.
let spaced = """
def f():
    a = 1

    b = 2
c = 3
"""
check("a blank line does not end the region",
      same(folds(spaced), [(1, 4)]), "\(folds(spaced))")
let commented = """
def f():
    a = 1
# a comment at column zero
    b = 2
c = 3
"""
// Python ignores where a comment sits, so folding does too: a `#` line at
// column zero inside a function is still inside it.
check("nor does an outdented comment",
      same(folds(commented), [(1, 4)]), "\(folds(commented))")
check("trailing blank lines are not swallowed",
      same(folds("def f():\n    a = 1\n\n\n"), [(1, 2)]),
      "\(folds("def f():\n    a = 1\n\n\n"))")

print("\n  things that are not blocks")
check("a line indented less does not open one",
      folds("    a = 1\nb = 2\n").isEmpty, "\(folds("    a = 1\nb = 2\n"))")
check("the last line cannot open a region",
      folds("a = 1\ndef f():").isEmpty, "\(folds("a = 1\ndef f():"))")
check("an empty file folds nothing", folds("").isEmpty)
check("a comment never opens a region of its own",
      folds("# note\n    a = 1\n").isEmpty, "\(folds("# note\n    a = 1\n"))")
check("a block whose only body is a comment still folds",
      same(folds("def f():\n    # todo\n"), [(1, 2)]), "\(folds("def f():\n    # todo\n"))")

print("\n  a class, as a file would have it")
let cls = """
import bpy

class Rig:
    def build(self):
        for i in range(3):
            print(i)

    def clear(self):
        pass

r = Rig()
"""
check("the class and both methods and the loop",
      same(folds(cls), [(3, 9), (4, 6), (5, 6), (8, 9)]), "\(folds(cls))")

print("\n  what gets hidden")
let text = "def f():\n    a = 1\n    b = 2\nc = 3\n"
let region = PythonFolding.regions(in: text)[0]
let hidden = PythonFolding.hiddenRange(for: region, in: text)
check("the opening line stays visible",
      hidden.map { $0.location == 9 } ?? false, "\(hidden as Any)")
check("the body is what goes",
      hidden.map { (text as NSString).substring(with: $0) == "    a = 1\n    b = 2\n" } ?? false,
      hidden.map { (text as NSString).substring(with: $0) } ?? "nothing")
check("and the line after it is untouched",
      hidden.map { NSMaxRange($0) < (text as NSString).length } ?? false)

print("\n  line ranges")
let ns = "one\ntwo\nthree" as NSString
check("the first line", PythonFolding.lineRange(ns, 1).map { ns.substring(with: $0) == "one\n" } ?? false)
check("the middle", PythonFolding.lineRange(ns, 2).map { ns.substring(with: $0) == "two\n" } ?? false)
check("the last, with no newline",
      PythonFolding.lineRange(ns, 3).map { ns.substring(with: $0) == "three" } ?? false)
check("past the end is nothing", PythonFolding.lineRange(ns, 9) == nil)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
