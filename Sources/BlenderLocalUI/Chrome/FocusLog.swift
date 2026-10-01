#if DEBUG
import UIKit
import WebKit

/// Debug builds accept `-focus-log`: whenever the keyboard's owner changes, it
/// is printed, so a click can be matched to what took the keyboard. The
/// Scripting tab puts a web view (Monaco), a terminal and a Metal view side by
/// side, and which of them receives a key is invisible from the outside.
///
/// The owner is found by searching the windows for the view that is first
/// responder, not by sending an action to the first responder: views that
/// refuse unknown actions — WebKit's content view, SwiftTerm — pass such an
/// action up to their superview, which then looks like the owner. Monaco's own
/// idea of focus is printed beside it, since a page can believe it has the
/// caret while the keys go elsewhere.
///
/// It also prints main-thread stalls, and once a second how often the
/// counted places ran (`FocusLog.count`), since a late key-up is what turns
/// one key into a row of them and a late focus change is what sends a key to
/// the pane the reader just left.
@MainActor
enum FocusLog {
    static weak var monaco: WKWebView?
    static let isOn = ProcessInfo.processInfo.arguments.contains("-focus-log")
    private static var counts: [String: Int] = [:]

    /// Counts a pass through a place worth watching, such as a view update.
    static func count(_ place: String) {
        guard isOn else { return }
        counts[place, default: 0] += 1
    }

    static func startIfRequested() {
        guard isOn else { return }
        var last = ""
        var tick = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                let late = (now - tick - 0.02) * 1000
                tick = now
                if late > 60 { print(String(format: "[bk] stall: %.0f ms", late)); fflush(stdout) }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !counts.isEmpty else { return }
                print("[bk] counts: " + counts.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                fflush(stdout)
                counts.removeAll()
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let owner = firstResponderName()
                let page = "if (window.editor) { (editor.hasTextFocus() ? 'text' : 'no-text') + (document.hasFocus() ? '+doc' : '-doc') } else { 'loading' }"
                guard let web = monaco else { report("\(owner) | monaco: none", &last); return }
                web.evaluateJavaScript(page) { value, _ in
                    MainActor.assumeIsolated {
                        report("\(owner) | monaco: \(value as? String ?? "?")", &last)
                    }
                }
            }
        }
    }

    private static func report(_ line: String, _ last: inout String) {
        guard line != last else { return }
        last = line
        print("[bk] focus: \(line)")
        fflush(stdout)
    }

    private static func firstResponderName() -> String {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if window.isFirstResponder { return "UIWindow" }
            if let view = find(in: window) {
                return String(describing: type(of: view)) + " < "
                    + String(describing: type(of: view.superview ?? view)).prefix(60)
            }
        }
        return "none"
    }

    private static func find(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }
}
#endif
