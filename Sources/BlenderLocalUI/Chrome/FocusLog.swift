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

/// The words on screen, as the app's own accessibility tree carries them:
/// every element's label (and value, when it has one), in the windows'
/// order. It is how the `-object-ops` hook's `ax` token (the only way in;
/// there is no flag of its own) reads what the bar, the tabs, the redo panel
/// and an open sheet say in the
/// running app — the names the round-4 renames are about (docs/blender-names.md)
/// — on a Mac whose screen is locked, where nothing can be clicked or seen.
@MainActor
enum AccessibilityDump {
    static func labels() -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if let view = element as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty {
                let value = element.accessibilityValue ?? ""
                let line = value.isEmpty ? label : label + " = " + value
                if out.last != line { out.append(line) }
            }
            if let elements = element.accessibilityElements as? [NSObject] {
                for child in elements { walk(child, depth: depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<count {
                        if let child = element.accessibilityElement(at: i) as? NSObject {
                            walk(child, depth: depth + 1)
                        }
                    }
                }
            }
            if let view = element as? UIView {
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows { walk(window, depth: 0) }
        return out
    }

    /// Prints them on one line, separated by " | ".
    static func print(_ tag: String) {
        Swift.print("[bk] ax \(tag): " + labels().joined(separator: " | "))
        fflush(stdout)
    }

    /// `-ui-audit <tag>`: every element with a label, one line each, with its
    /// frame in the window's points, and two marks a finger cares about — OFF
    /// when any of it lies outside the window (a row scrolled past its edge
    /// counts: nothing on screen says it is there), SMALL when either side is
    /// under Apple's 44 points. Read by eye from the simulator's console, for
    /// the interface's walkthrough at an iPad's own sizes.
    static func audit(_ tag: String) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let bounds = window.bounds
        Swift.print("[bk] ui-audit \(tag): window \(Int(bounds.width)) x \(Int(bounds.height))")
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if let view = element as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty {
                let f = window.convert(element.accessibilityFrame, from: nil)
                var marks: [String] = []
                if f.minX < bounds.minX - 1 || f.maxX > bounds.maxX + 1
                    || f.minY < bounds.minY - 1 || f.maxY > bounds.maxY + 1 { marks.append("OFF") }
                if f.width < 44 || f.height < 44 { marks.append("SMALL") }
                Swift.print(String(format: "[bk] ui-audit %@ %5.0f %5.0f %4.0f x %3.0f %@ %@", tag,
                                   f.minX, f.minY, f.width, f.height,
                                   marks.joined(separator: ",").padding(toLength: 9, withPad: " ", startingAt: 0),
                                   label))
            }
            if let elements = element.accessibilityElements as? [NSObject] {
                for child in elements { walk(child, depth: depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<count {
                        if let child = element.accessibilityElement(at: i) as? NSObject { walk(child, depth: depth + 1) }
                    }
                }
            }
            if let view = element as? UIView { for sub in view.subviews { walk(sub, depth: depth + 1) } }
        }
        for w in windows { walk(w, depth: 0) }
        fflush(stdout)
    }
}
#endif
