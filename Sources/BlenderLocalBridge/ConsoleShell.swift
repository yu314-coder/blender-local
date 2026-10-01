import Foundation

/// The console's shell commands: which lines are commands rather than Python,
/// and how one is handed to the Python module that runs it.
///
/// BenchCode's terminal is a shell that falls through to Python. Blender Local's
/// console is Python with the same shell commands in it. The commands live in
/// `_blenderkit_shell.py`, where they can be the code BenchCode runs; this side
/// only decides where a line goes. That has to happen before it is sent: `echo
/// a:` read as Python would wait for a block that is never coming.
///
/// Pure over its inputs, so the rules run on the Mac.
public enum ConsoleShell {

    /// Every command `_blenderkit_shell` runs, aliases included.
    public static let commands: Set<String> = [
        "help", "man",
        "pwd", "cd",
        "ls", "ll", "la", "cat", "head", "tail", "wc", "grep", "find", "tree", "stat", "file",
        "xxd", "hexdump", "diff", "less", "more",
        "mkdir", "rm", "rmdir", "touch", "cp", "mv", "mktemp", "tee",
        "echo", "env", "export", "which", "date", "uptime", "uname", "whoami", "hostname", "id",
        "nproc", "basename", "dirname", "realpath",
        "sort", "uniq", "tr", "seq", "yes", "sleep", "time", "bc", "cal", "nl", "tac", "rev", "cut",
        "base64", "sha256sum", "sha1sum", "md5sum",
        "du", "df", "zip", "unzip", "tar", "gzip", "gunzip", "extract",
        "clear", "cls", "history",
        "ps", "kill", "watch", "top", "htop", "ncdu",
        "python", "python3", "py",
        "exit", "quit",
    ]

    /// BenchCode commands that are not here, routed to the module anyway so it
    /// can say why rather than leave Python to report a syntax error.
    ///
    /// Only names nobody uses as a variable. `md`, `js` or `ai` typed at a
    /// Python prompt are far more likely to be the reader's own names.
    public static let unavailable: Set<String> = [
        "pip", "pip3", "git", "curl", "wget", "ping", "node",
        "gcc", "clang", "c++", "g++", "clang++", "gfortran",
        "pdflatex", "xelatex", "latex", "manim",
        "7z", "unar", "binwalk", "simg2img", "cpu-z", "gpu-z", "cpuz", "gpuz",
    ]

    /// Written by the module around a full-screen command, as BenchCode's
    /// terminal does: raw keys while `top` or `ncdu` runs, lines again after.
    public static let rawMarker = "\u{1b}]blenderlocal;raw\u{1b}\\"
    public static let cookedMarker = "\u{1b}]blenderlocal;cooked\u{1b}\\"

    public enum Route: Equatable, Sendable {
        case shell(String)
        case python(String)
    }

    /// Where a line typed at the prompt goes.
    ///
    /// A command word first, as in BenchCode, unless what follows it makes the
    /// line Python: `id = 3`, `time + 1`. `!` forces a command and `%` forces
    /// Python, for the lines the rule gets wrong.
    public static func route(_ input: String) -> Route {
        if input.contains("\n") { return .python(input) }
        let text = input.drop { $0 == " " || $0 == "\t" }
        if text.hasPrefix("!") {
            let command = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? .python(input) : .shell(command)
        }
        if text.hasPrefix("%") {
            return .python(String(text.dropFirst()))
        }
        let word = String(text.prefix { $0 != " " && $0 != "\t" })
        guard commands.contains(word) || unavailable.contains(word) else { return .python(input) }
        let rest = text.dropFirst(word.count).drop { $0 == " " || $0 == "\t" }
        if rest.isEmpty || !readsAsPython(rest) {
            return .shell(text.trimmingCharacters(in: .whitespaces))
        }
        return .python(input)
    }

    /// Whether what follows a command word continues a Python expression.
    static func readsAsPython(_ rest: Substring) -> Bool {
        // An assignment, a call or a subscript — `id = 3`, `id (x)`. Not a
        // dot: `cd ..` and `ls ./scripts` start their argument with one.
        if let first = rest.first, "=([,:".contains(first) { return true }
        // An operator standing on its own. Flags start with `-` too, but a
        // flag has no space after its dash.
        let operators = ["+", "-", "*", "/", "//", "%", "**", "==", "!=", "<", ">", "<=", ">=",
                         "+=", "-=", "*=", "/=", "&", "|", "^", "@"]
        let token = rest.prefix { $0 != " " && $0 != "\t" }
        if operators.contains(String(token)), rest.count > token.count { return true }
        let keywords = ["if", "else", "for", "in", "is", "and", "or", "not"]
        return keywords.contains(String(token)) && rest.count > token.count
    }

    /// The Python that runs one command: the line travels as base64, so no
    /// quote or backslash in it can end the string it is carried in.
    ///
    /// Two lines, so the interpreter runs it as a script and does not echo the
    /// command's exit status the way it would echo a console expression.
    public static func source(for command: String, columns: Int, rows: Int) -> String {
        let encoded = Data(command.utf8).base64EncodedString()
        return "import _blenderkit_shell as _bk_shell\n"
            + "_bk_shell.run_b64('\(encoded)', \(max(columns, 20)), \(max(rows, 5)))\n"
    }

    /// Whether a command may change the scene, and so is worth an undo step and
    /// a mirror of the scene into the viewport. Only running a Python file can.
    public static func touchesScene(_ command: String) -> Bool {
        let word = command.prefix { $0 != " " && $0 != "\t" }
        return word == "python" || word == "python3" || word == "py"
    }

    /// What a console run leaves in the record.
    ///
    /// A full-screen command redraws itself many times a second; its frames are
    /// a display, not a transcript, and a hundred of them would bury the lines
    /// around them. So the stretch between the raw and cooked markers is left
    /// out, and one that never switched back runs to the end.
    public static func recordable(_ output: String) -> String {
        var rest = Substring(output)
        var kept = ""
        while let start = rest.range(of: rawMarker) {
            kept += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: cookedMarker) else { return kept }
            rest = after[end.upperBound...]
        }
        kept += rest
        return kept.replacingOccurrences(of: cookedMarker, with: "")
    }

    /// Completions for a shell line: command names for the first word, paths
    /// for the words after it.
    ///
    /// - Parameters:
    ///   - line: the line being edited.
    ///   - caret: characters before the caret.
    ///   - list: the entries of a directory, given an absolute path.
    ///   - home: where `~` points.
    ///   - cwd: where a relative path starts.
    /// - Returns: where the word being completed starts, and whole replacements
    ///   for it; nil when the line is not a shell line.
    public static func completions(line: String, caret: Int,
                                   cwd: String, home: String,
                                   list: (String) -> [(name: String, isDirectory: Bool)])
    -> (start: Int, options: [String])? {
        let chars = Array(line)
        guard caret >= 0, caret <= chars.count else { return nil }
        let before = chars[..<caret]
        let leading = before.prefix { $0 == " " }.count
        let start = (before.lastIndex(of: " ").map { $0 + 1 }) ?? leading
        let word = String(chars[start..<caret])
        if start == leading {
            // The first word: a command, if it could be one and is not
            // already Python-shaped.
            guard !word.isEmpty, !word.contains(where: { ".([=".contains($0) }) else { return nil }
            let names = commands.filter { $0.hasPrefix(word) }.sorted()
            return names.isEmpty ? nil : (start, names)
        }
        let first = String(chars[leading...].prefix { $0 != " " })
        guard commands.contains(first) else { return nil }

        // A path: the directory part stays as typed, the name part completes.
        let slash = word.lastIndex(of: "/")
        let typedDirectory = slash.map { String(word[...$0]) } ?? ""
        let prefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
        var directory = typedDirectory
        if directory.hasPrefix("~") { directory = home + directory.dropFirst() }
        if !directory.hasPrefix("/") { directory = cwd + (cwd.hasSuffix("/") ? "" : "/") + directory }
        let options = list(directory)
            .filter { $0.name.hasPrefix(prefix) && (prefix.hasPrefix(".") || !$0.name.hasPrefix(".")) }
            .sorted { $0.name < $1.name }
            .map { typedDirectory + $0.name + ($0.isDirectory ? "/" : "") }
        return (start, options)
    }
}
