import Foundation

// The interface language, without the app: the generated tables are well
// formed in every language, and the lookup finds plain text, text with
// values in it, and leaves names and numbers alone.
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func table(_ code: String) -> [String: String] {
    let url = root.appendingPathComponent("Resources/Localization/\(code).lproj/Localizable.strings")
    return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
}
func placeholders(_ s: String) -> Int {
    let r = try! NSRegularExpression(pattern: "%(\\d+\\$)?@")
    return r.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
}

print("== every language's table ==")
for lang in Translation.languages.map(\.code) where !lang.isEmpty && lang != "en" {
    let t = table(lang)
    check("\(lang): the table reads, and is not small", t.count > 2000, "\(t.count) entries")
    let bad = t.filter { placeholders($0.key) != placeholders($0.value) }
    check("\(lang): every translation keeps its values", bad.isEmpty, "\(bad.prefix(3))")
    let lines = t.filter { $0.key.filter { $0 == "\n" }.count != $0.value.filter { $0 == "\n" }.count }
    check("\(lang): line breaks kept", lines.isEmpty, "\(lines.keys.prefix(3))")
    check("\(lang): the Preferences heading is the language sense",
          t["Translation"].map { $0 != table(lang)["Move"] } ?? false, t["Translation"] ?? "-")
}

print("== the lookup ==")
Translation.install(table("zh-Hans"), code: "zh-Hans")
check("a Blender name reads as Blender's own", Translation.iface("Edit Mode") == "编辑模式", Translation.iface("Edit Mode"))
check("a menu Add is the verb, not arithmetic", Translation.iface("Add") == "添加", Translation.iface("Add"))
check("a value is put into its place", Translation.iface("Ran 12 lines") == "已运行 12 行", Translation.iface("Ran 12 lines"))
check("a name nothing knows stays as it is", Translation.iface("Cube.001") == "Cube.001")
check("a number stays as it is", Translation.iface("0.000 m") == "0.000 m")
check("the Scene Collection is translated as a name", Translation.dataName("Scene Collection") == "场景集合")
check("a datablock's name is not", Translation.dataName("Camera") == "Camera")
check("numbered values go where the translation puts them",
      Translation.substitute("%2$@ / %1$@", ["a", "b"]) == "b / a")
check("values in order", Translation.substitute("%@ → %@", ["a", "b"]) == "a → b")
Translation.install([:], code: "en")
check("English shows the source text", Translation.iface("Edit Mode") == "Edit Mode")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
