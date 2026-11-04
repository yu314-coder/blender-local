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

    /// Which prompt the console is at. It opens at BenchCode's shell, where a
    /// command word runs the command and anything else runs as Python;
    /// `python` there opens the Python prompt, where every line is Python, as
    /// BenchCode's `python` does, and `exit()` comes back (the user, November
    /// 4: "shell first", like BenchCode's terminal).
    public enum Mode: Equatable, Sendable {
        case shell, python
    }

    /// `python`, `python3` or `py` with nothing after it: BenchCode's way to
    /// the `>>>` prompt. With arguments (`python file.py`, `python -c …`)
    /// they are the shell's command.
    public static func entersPython(_ input: String) -> Bool {
        ["python", "python3", "py"].contains(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `exit()`, `quit()`, `exit` or `quit` at the Python prompt: back to the
    /// shell. Python's own would end the interpreter the whole app runs in.
    public static func leavesPython(_ input: String) -> Bool {
        ["exit()", "quit()", "exit", "quit"].contains(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the Python prompt says as it opens: what is there to use, and the
    /// way back.
    public static func pythonGreeting(realBlender: Bool) -> String {
        (realBlender ? "Python with Blender's bpy" : "Python with Blender Local's bpy shim")
            + ": C is bpy.context, D is bpy.data.\n"
            + "!ls runs a command; exit() or ⌃D goes back to the shell."
    }

    /// The shell's folder — ~/Documents/Scripts, beside the Scripting tab's
    /// scripts, or ~/Documents — which `_blenderkit_shell.init` moves to on
    /// its first command. Moved to when the terminal opens instead, so its
    /// first prompt names the folder commands will run in, and Python lines
    /// typed first run there too. Only from where an app starts, `/`: a
    /// folder something already moved to is left alone.
    public static func enterWorkFolder() {
        let files = FileManager.default
        guard files.currentDirectoryPath == "/" else { return }
        let home = NSHomeDirectory()
        for folder in [home + "/Documents/Scripts", home + "/Documents"] {
            guard (try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil,
                  files.changeCurrentDirectoryPath(folder) else { continue }
            setenv("PWD", files.currentDirectoryPath, 1)
            return
        }
    }

    /// Where a line goes at `mode`'s prompt: at the Python prompt, Python,
    /// unless `!` asks for a command.
    public static func route(_ input: String, mode: Mode) -> Route {
        guard mode == .python else { return route(input) }
        let text = input.drop { $0 == " " || $0 == "\t" }
        if !input.contains("\n"), text.hasPrefix("!") {
            let command = text.dropFirst().trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { return .shell(command) }
        }
        return .python(input)
    }

    /// The prompt for `mode`: BenchCode's, modelled on zsh's — `user@host`
    /// in bold, the folder with the home as `~`, a bold `%` — or Python's
    /// `>>>`. With its escape sequences; the record keeps it so, and Copy
    /// takes them out.
    public static func prompt(mode: Mode, user: String, host: String, cwd: String, home: String) -> String {
        switch mode {
        case .python:
            return "\u{1b}[1m>>>\u{1b}[0m "
        case .shell:
            return "\u{1b}[1m\(user)@\(host)\u{1b}[0m \(displayPath(cwd, home: home)) \u{1b}[1m%\u{1b}[0m "
        }
    }

    /// The prompt for `mode` on this device, in the folder the shell is in.
    public static func prompt(mode: Mode) -> String {
        prompt(mode: mode, user: user, host: host,
               cwd: FileManager.default.currentDirectoryPath, home: NSHomeDirectory())
    }

    /// `cwd` with the home folder written `~`, as BenchCode's prompt writes it.
    public static func displayPath(_ cwd: String, home: String) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        // The home reached through a symlink, as /private/var is /var.
        let realCwd = (cwd as NSString).resolvingSymlinksInPath
        let realHome = (home as NSString).resolvingSymlinksInPath
        if realCwd == realHome { return "~" }
        if realCwd.hasPrefix(realHome + "/") { return "~" + realCwd.dropFirst(realHome.count) }
        return cwd
    }

    /// The user in the prompt, as BenchCode finds it: `USER`, `LOGNAME`, else
    /// the app's own name, since iOS gives an app no login.
    public static let user: String = {
        let env = ProcessInfo.processInfo.environment
        return [env["USER"], env["LOGNAME"]].compactMap { $0 }.first { !$0.isEmpty } ?? "blender"
    }()

    /// The host, as BenchCode names it: the kind of device, since iOS calls
    /// every device "localhost".
    public static let host: String = {
        if ProcessInfo.processInfo.isiOSAppOnMac { return "Mac" }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        if model.hasPrefix("iPad") { return "iPad" }
        if model.hasPrefix("iPhone") { return "iPhone" }
        return "Mac"
    }()

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
    /// a mirror of the scene into the viewport. Only running Python can: the
    /// command itself, or the one `time` or `watch` runs (`_time_cmd` and
    /// `_watch` in _blenderkit_shell call the next word's builtin). Reading the
    /// first word alone took `time python -c "…"` for a command that touches
    /// nothing: whatever it changed in Blender was not mirrored into the
    /// viewport and had no undo step (round 4's review of group 7).
    public static func touchesScene(_ command: String) -> Bool {
        var words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let word = words.first {
            switch word {
            case "python", "python3", "py":
                return true
            case "time":
                words.removeFirst()
            case "watch":
                // `watch [-n SEC] [-c COUNT] CMD`: the flags and their values.
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") {
                    words.removeFirst()
                    if ["-n", "-c", "--count"].contains(flag), !words.isEmpty { words.removeFirst() }
                }
            default:
                return false
            }
        }
        return false
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
