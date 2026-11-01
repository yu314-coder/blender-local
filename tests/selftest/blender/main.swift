import Foundation

// The Swift side of scripts/run-selftest-blender-check.sh.
//
//   dump                 prints the Python the app sends (`SelfTest.python`),
//                        with @REPORT@, @HISTORY@ and @RENDER@ where the app
//                        puts its paths; verify.py puts the check's own there
//   dump parse <log>     reads every `[self-test]` line a run printed with
//                        `SelfTest.event`, as the app's sheet reads them, and
//                        fails on one it cannot read or a count that does not
//                        add up

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "parse" {
    let text = (try? String(contentsOfFile: arguments[2], encoding: .utf8)) ?? ""
    var started = 0, passed = 0, failed = 0, ended: SelfTest.Event?, history = 0, unread: [String] = []
    var total = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    where line.hasPrefix("[self-test] ") {
        switch SelfTest.event(line) {
        case .started(_, let n, _)?: started += 1; total = n
        case .finished(let result, _)?: if result.passed { passed += 1 } else { failed += 1 }
        case .ended?: ended = SelfTest.event(line)
        case .history?: history += 1
        case nil: unread.append(line)
        }
    }
    var problems: [String] = []
    if !unread.isEmpty { problems.append("\(unread.count) line(s) the sheet cannot read: \(unread.prefix(2))") }
    if started == 0 || started != passed + failed || started != total {
        problems.append("\(started) started, \(passed + failed) ended, of \(total)")
    }
    if case .ended(let p, let f, _, _)? = ended {
        if p != passed || f != failed { problems.append("the end says \(p) passed and \(f) failed") }
    } else {
        problems.append("no end line")
    }
    if history != 1 { problems.append("\(history) history lines") }
    print(problems.isEmpty
          ? "  PASS  the sheet reads every progress line the run printed: \(started) checks, \(passed) passed, "
            + "\(failed) failed, the end and the history"
          : "  FAIL  the sheet's reading of the run's lines: " + problems.joined(separator: "; "))
    exit(problems.isEmpty ? 0 : 1)
}

print(SelfTest.python(report: "@REPORT@", historyRoot: "@HISTORY@", renderOutput: "@RENDER@",
                      about: [("App", "Blender Local's modules in desktop Blender (the Self-Test's check)")]))
