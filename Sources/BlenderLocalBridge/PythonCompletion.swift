import Foundation

/// What could be typed next, given a buffer and a caret.
///
/// Deliberately not a language server. A bpy script is mostly three things —
/// operator paths, attribute names on a handful of well-known objects, and
/// names the script has already used — so those are what it offers. Guessing
/// beyond that would need to evaluate the code to know a variable's type,
/// which is not something an editor should do to a half-typed line.
///
/// Pure over its inputs so the ranking, which is the part that decides whether
/// this feels useful or noisy, can be tested without a text view.
public enum PythonCompletion {

    public struct Candidate: Equatable {
        /// Shown on the strip.
        public let label: String
        /// What replaces the partial word.
        public let insert: String
        /// True when the completion is a callable worth adding `()` to.
        public let callable: Bool

        public init(label: String, insert: String, callable: Bool = false) {
            self.label = label
            self.insert = insert
            self.callable = callable
        }
    }

    /// The word being typed at `caret`, and the dotted path it hangs off.
    ///
    /// Split apart because they rank differently: after a dot the reader has
    /// named the thing they want members of, so only members belong; with no
    /// dot, anything in scope is fair.
    public static func context(in text: String, caret: Int) -> (path: String, partial: String) {
        let chars = Array(text.utf16)
        guard caret >= 0, caret <= chars.count else { return ("", "") }
        func isWord(_ u: UInt16) -> Bool {
            (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95
        }
        var start = caret
        while start > 0, isWord(chars[start - 1]) { start -= 1 }
        let partial = String(decoding: chars[start..<caret], as: UTF16.self)

        // Walk back over `a.b.c` before the partial word.
        var pathEnd = start
        var pathStart = start
        if pathEnd > 0, chars[pathEnd - 1] == 46 {   // '.'
            pathEnd -= 1
            pathStart = pathEnd
            while pathStart > 0, isWord(chars[pathStart - 1]) || chars[pathStart - 1] == 46 {
                pathStart -= 1
            }
        } else {
            pathStart = pathEnd
        }
        let path = String(decoding: chars[pathStart..<pathEnd], as: UTF16.self)
        return (path, partial)
    }

    /// Members of the paths a bpy script names constantly.
    ///
    /// A short, hand-kept list only for the roots. Nothing under `bpy.ops` is
    /// here: those come from the operator paths the caller passes in, which
    /// the backend was asked for. A table of operators in Swift would drift
    /// from what the module can actually do — the mistake the operator search
    /// already avoids, and there is no reason to reintroduce it here.
    static let members: [String: [String]] = [
        "bpy": ["ops", "data", "context", "types", "utils", "app", "props"],
        "bpy.data": ["objects", "meshes", "materials", "scenes", "curves",
                     "collections", "images", "cameras", "lights"],
        "bpy.context": ["object", "active_object", "selected_objects", "scene",
                        "view_layer", "collection", "mode"],
        "mathutils": ["Vector", "Matrix", "Euler", "Quaternion", "Color"],
    ]

    /// Names on an object, for the common case of a variable holding one.
    static let objectAttributes = [
        "location", "rotation_euler", "scale", "name", "data", "modifiers",
        "select_set", "select_get", "hide_viewport", "matrix_world",
        "dimensions", "active_material", "parent", "type", "users_collection",
    ]

    /// Innermost unfinished call, ignoring comments and quoted strings.
    public static func callContext(in text: String, caret: Int) -> String? {
        let units = Array(text.utf16.prefix(max(0, caret)))
        var stack: [(UInt16, String?)] = []
        var quote: UInt16?; var escaped = false; var comment = false
        for (i, c) in units.enumerated() {
            if comment { if c == 10 { comment = false }; continue }
            if let q = quote {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == q { quote = nil }
                continue
            }
            if c == 35 { comment = true; continue }
            if c == 34 || c == 39 { quote = c; continue }
            if c == 40 || c == 91 || c == 123 {
                var start = i
                while start > 0 {
                    let v = units[start - 1]
                    if (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v) || v == 95 || v == 46 { start -= 1 }
                    else { break }
                }
                let path = String(decoding: units[start..<i], as: UTF16.self)
                stack.append((c, c == 40 && path.hasPrefix("bpy.ops.") ? path : nil))
            } else if c == 41 || c == 93 || c == 125 {
                if !stack.isEmpty { stack.removeLast() }
            }
        }
        guard quote == nil, !comment else { return nil }
        return stack.last?.1
    }

    /// What to offer, best first.
    ///
    /// - `operators`: `mesh.bevel` style paths from the backend.
    /// - `identifiers`: words already in the buffer, which is how a completion
    ///   list learns the reader's own variable names without parsing anything.
    /// - `introspect`: what the live interpreter says a dotted path has on it.
    ///   Given one, it is preferred over the static table — the interpreter
    ///   cannot be out of date about its own objects, and a table always is.
    public static func candidates(text: String,
                                  caret: Int,
                                  operators: [String],
                                  limit: Int = 12,
                                  introspect: ((String) -> [(name: String, callable: Bool)]?)? = nil)
    -> [Candidate] {
        let (path, partial) = context(in: text, caret: caret)
        if path.isEmpty, let call = callContext(in: text, caret: caret),
           let parameters = introspect?(call + ".#parameters") {
            let values = parameters.filter { $0.name.hasPrefix(partial) }.map {
                Candidate(label: $0.name, insert: $0.name)
            }
            if !values.isEmpty { return Array(values.prefix(limit)) }
        }

        // After `bpy.ops.` the useful thing is the operator list, not a module
        // list — `bpy.ops.mesh.` should offer bevel, not another module.
        if path == "bpy.ops" || path.hasPrefix("bpy.ops.") {
            let sub = path == "bpy.ops" ? "" : String(path.dropFirst("bpy.ops.".count))
            var found: [Candidate] = []
            for op in operators {
                if sub.isEmpty {
                    // Offer the module names once each.
                    let module = String(op.split(separator: ".").first ?? "")
                    guard module.hasPrefix(partial), !found.contains(where: { $0.label == module })
                    else { continue }
                    found.append(Candidate(label: module, insert: module))
                } else if op.hasPrefix(sub + ".") {
                    let leaf = String(op.dropFirst(sub.count + 1))
                    guard leaf.hasPrefix(partial) else { continue }
                    found.append(Candidate(label: leaf, insert: leaf, callable: true))
                }
            }
            // Only if the catalogue had anything. It is loaded from the
            // backend and is empty until it arrives — and was empty in the
            // simulator altogether, which is why typing `bpy.ops.mesh.prim`
            // offered nothing at all. `bpy.ops.mesh` is a real object with real
            // attributes; if the catalogue cannot answer, ask it.
            if !found.isEmpty { return rank(found, partial: partial, limit: limit) }
        }

        if !path.isEmpty {
            // Ask the interpreter first. It knows what is actually on the
            // object, including everything the table never had and everything
            // the reader defined thirty seconds ago.
            if let live = introspect?(path), !live.isEmpty {
                let found = live.filter { $0.name.hasPrefix(partial) }
                    .map { Candidate(label: $0.name, insert: $0.name, callable: $0.callable) }
                return rank(found, partial: partial, limit: limit)
            }
            var names = members[path] ?? []
            if names.isEmpty { names = objectAttributes }
            let found = names.filter { $0.hasPrefix(partial) }
                .map { Candidate(label: $0, insert: $0,
                                 callable: $0.hasPrefix("select_")) }
            return rank(found, partial: partial, limit: limit)
        }

        // No dot: keywords, known names, and whatever the buffer already says.
        guard !partial.isEmpty else { return [] }
        var pool = Set<String>()
        pool.formUnion(PythonWords.keywords)
        pool.formUnion(PythonWords.builtins)
        pool.formUnion(identifiers(in: text))
        // What is actually defined right now — imported modules, names bound
        // by a previous run, the reader's own functions. A completion list
        // that knows `bpy` exists because it was imported is worth more than
        // one that knows it because the word appears in the file.
        var callables = Set<String>()
        if let live = introspect?("") {
            pool.formUnion(live.map(\.name))
            callables.formUnion(live.filter(\.callable).map(\.name))
        }
        let found = pool.filter { $0.hasPrefix(partial) && $0 != partial }
            .map { Candidate(label: $0, insert: $0,
                             callable: callables.contains($0)
                                || PythonWords.builtins.contains($0)) }
        return rank(found, partial: partial, limit: limit)
    }

    /// The reader's own names, taken from the code and *only* the code.
    ///
    /// This used to read the whole buffer, which meant a docstring was a word
    /// list. Typing `i` in a file whose header says "the spokes are a radial
    /// loop … instead … including" offered `its`, `into`, `item`, `instead`,
    /// `including` — English prose presented as if it were code, and the real
    /// candidates buried under it. A comment is not an identifier no matter
    /// how much it looks like one.
    static func identifiers(in text: String) -> Set<String> {
        let chars = Array(text)
        let code = BracketMatch.codePositions(chars)
        var out = Set<String>()
        var current = ""
        var start = 0
        for (i, ch) in chars.enumerated() {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if isWord, code.contains(i) {
                if current.isEmpty { start = i }
                current.append(ch)
            } else {
                // A word only counts when all of it was code — a run that
                // began inside a string cannot end up in the list because its
                // last character happened to fall outside one.
                if current.count >= 3, code.contains(start) { out.insert(current) }
                current = ""
            }
        }
        if current.count >= 3, code.contains(start) { out.insert(current) }
        // A number is not a name.
        return out.filter { !($0.first?.isNumber ?? true) }
    }

    /// Shortest first, then alphabetical.
    ///
    /// Shortest-first because the shortest match of a prefix is usually the
    /// thing named by that prefix — `data` before `data_path` — and a reader
    /// who wanted the longer one has more to type either way.
    private static func rank(_ found: [Candidate], partial: String, limit: Int) -> [Candidate] {
        Array(found.sorted {
            $0.label.count == $1.label.count ? $0.label < $1.label
                                             : $0.label.count < $1.label.count
        }.prefix(limit))
    }
}

/// What a newline should insert, given the line it is splitting.
///
/// Python is the language where getting this wrong is not cosmetic: the
/// indentation *is* the block structure, so an editor that drops the reader
/// back to column zero after `def f():` has made them retype the thing the
/// keyboard has no key for.
public enum PythonIndent {

    /// Keywords that open a block, so the next line goes one level deeper.
    static let openers = ["def", "class", "if", "elif", "else", "for", "while",
                          "try", "except", "finally", "with", "match", "case"]

    /// Keywords that close one, so the next line comes back out.
    static let closers = ["return", "break", "continue", "pass", "raise"]

    public static let unit = "    "

    /// The whitespace to insert after a newline typed at the end of `line`.
    public static func afterNewline(in line: String) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return leading }

        // A line ending in a colon opens a block — but only a real one. A
        // colon inside a string or a comment does not, and a dict literal's
        // colons are not at the end of the line.
        if endsBlockOpener(body) { return leading + unit }

        // After a statement that leaves the block, come back out one level.
        let firstWord = String(body.prefix { $0.isLetter })
        if closers.contains(firstWord), leading.count >= unit.count {
            return String(leading.dropLast(unit.count))
        }
        return leading
    }

    /// Whether a line's *code* ends with a colon.
    ///
    /// Checked by scanning rather than by looking at the last character, so a
    /// trailing comment (`for i in range(3):  # go`) still opens a block and a
    /// colon inside a string (`s = "a:"`) does not.
    static func endsBlockOpener(_ body: String) -> Bool {
        var inString: Character?
        var lastCode: Character?
        var escaped = false
        for ch in body {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let quote = inString {
                if ch == quote { inString = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inString = ch; lastCode = ch; continue }
            if ch == "#" { break }
            if ch != " " && ch != "\t" { lastCode = ch }
        }
        return lastCode == ":"
    }
}
