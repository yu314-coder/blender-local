#if DEBUG
import SwiftUI
import UIKit

/// `-timeline-ops "<token>;<token>;…"`: the Timeline driven through the same
/// calls its touches, keys and menu rows make — `TimelineController`'s press,
/// hover, key and row handlers at the points a frame is drawn at — so a run
/// on this Mac needs no hand on the screen. Each step prints what the
/// timeline shows (`dump`) or what Blender holds (`py:`); `shot:<name>`
/// pauses for a window screenshot. Ends with "[bk] timeline-ops: done".
///
///   until:<text>            wait for the console to show it (a -eval64 script's print)
///   wait:<seconds>
///   tap:<frame>             a tap on the key row; shift-tap:, ctrl-tap:, alt-tap: with the key held
///   box:<f0>:<f1>[:shift|:ctrl]   a drag across the key row from beside the keys
///   drag:<f0>:<f1>[:hold]   a drag from the column at f0; with hold it is not let go (`release`)
///   release                 lets go of a held drag
///   marker-tap:<index>[:shift], marker-double:<index>, marker-drag:<index>:<frame>[:hold]
///   hover:<frame>[:markers] the pointer over the key row (or the markers)
///   key:<token>             a key, by TimelineInputView's token (move, scale, delete.menu, …)
///   type:<text>             digits typed into G or S
///   confirm, cancel         G, S and Shift+D's Return and Escape
///   menu:<id>               opens one of the menus at the middle (TimelineMenus.ids); close shuts it
///   focus                   the Timeline takes the keyboard, as a touch on it does
///   keys:<k k …>            prints them for the run's watcher to press (keypost), and waits
///   row:<id>/<title>        runs that menu row
///   rename:<name>           F2's field committed
///   zoom:<scale>, pan:<dx>, frameall, seconds:on|off, markers:on|off, frame:<n>
///   undo, redo              the top bar's Undo and Redo
///   dump                    the columns and markers the timeline draws
///   py:<code>               prints what Blender answers
///   shot:<name>             prints a marker line and waits 8 s for a screenshot
enum TimelineOps {
    @MainActor
    static func launchIfRequested(scene: BKScene, session: BpySession, driver: TimelineDriver,
                                  controller: TimelineController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-timeline-ops"), i + 1 < args.count else { return }
        let tokens = args[i + 1].split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        scene.animation.showsTimeline = true
        Task { @MainActor in
            // The bridge, Blender and a laid-out body first.
            for _ in 0..<240 {
                if driver.isAvailable, session.usesRealBlender, controller.bodySize.width > 10 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for token in tokens where !token.isEmpty {
                while session.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                await run(token, scene: scene, session: session, driver: driver, controller: controller)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            say("timeline-ops: done")
        }
    }

    private static func say(_ text: String) {
        print("[bk] " + text)
        fflush(stdout)
    }

    @MainActor private static var held: (start: CGPoint, last: CGPoint)?

    @MainActor
    private static func run(_ token: String, scene: BKScene, session: BpySession, driver: TimelineDriver,
                            controller c: TimelineController) async {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        let fields = arg.split(separator: ":").map(String.init)
        let keyY = TimelineController.scrubHeight + TimelineController.keysHeight / 2
        let markerY = TimelineController.scrubHeight + TimelineController.keysHeight + TimelineController.markersHeight / 2
        func x(_ frame: String) -> CGFloat { c.window.x(Double(frame) ?? 0) }
        func point(_ frame: String, _ y: CGFloat) -> CGPoint { CGPoint(x: x(frame), y: y) }
        func modifiers(_ word: String?) -> UIKeyModifierFlags {
            switch word {
            case "shift": return .shift
            case "ctrl": return .control
            case "alt": return .alternate
            default: return []
            }
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        /// A finger from `a` to `b` in steps a display refresh apart.
        func drag(from a: CGPoint, to b: CGPoint, mods: UIKeyModifierFlags, lift: Bool) async {
            c.pressBegan(at: a, modifiers: mods)
            let steps = 20
            for k in 1...steps {
                let t = CGFloat(k) / CGFloat(steps)
                c.pressMoved(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), modifiers: mods)
                await pause(0.016)
            }
            if lift { c.pressEnded(at: b, modifiers: mods) } else { held = (a, b) }
        }
        say("timeline-ops: " + token)
        switch name {
        case "until":
            for _ in 0..<240 {
                if session.console.contains(where: { $0.text.contains(arg) }) { break }
                await pause(0.25)
            }
        case "wait":
            await pause(Double(arg) ?? 1)
        case "tap", "shift-tap", "ctrl-tap", "alt-tap":
            let mods = modifiers(name.split(separator: "-").count > 1 ? String(name.split(separator: "-")[0]) : nil)
            let p = point(arg, keyY)
            c.pressBegan(at: p, modifiers: mods)
            c.pressEnded(at: p, modifiers: mods)
        case "box":
            guard fields.count >= 2 else { break }
            await drag(from: point(fields[0], keyY), to: point(fields[1], keyY),
                       mods: modifiers(fields.count > 2 ? fields[2] : nil), lift: true)
        case "drag":
            guard fields.count >= 2 else { break }
            await drag(from: point(fields[0], keyY), to: point(fields[1], keyY), mods: [],
                       lift: !(fields.count > 2 && fields[2] == "hold"))
        case "release":
            if let h = held { c.pressEnded(at: h.last, modifiers: []) }
            held = nil
        case "marker-tap", "marker-double":
            guard let index = Int(fields.first ?? ""), scene.animation.markers.indices.contains(index) else {
                say("timeline-ops: no marker \(arg)")
                break
            }
            let p = CGPoint(x: c.window.x(Double(scene.animation.markers[index].frame)), y: markerY)
            let mods = modifiers(fields.count > 1 ? fields[1] : nil)
            for _ in 0..<(name == "marker-double" ? 2 : 1) {
                c.pressBegan(at: p, modifiers: mods)
                c.pressEnded(at: p, modifiers: mods)
                await pause(0.1)
            }
        case "marker-drag":
            guard fields.count >= 2, let index = Int(fields[0]), scene.animation.markers.indices.contains(index) else {
                break
            }
            let from = CGPoint(x: c.window.x(Double(scene.animation.markers[index].frame)), y: markerY)
            await drag(from: from, to: point(fields[1], markerY), mods: [],
                       lift: !(fields.count > 2 && fields[2] == "hold"))
        case "hover":
            c.hover(at: point(fields.first ?? "0", fields.count > 1 && fields[1] == "markers" ? markerY : keyY))
        case "key":
            let handled = c.key(arg)
            if !handled { say("timeline-ops: key \(arg) not the Timeline's") }
        case "type":
            for ch in arg {
                c.key(ch == "-" ? "minus" : ch == "." ? "period" : "digit:\(ch)")
            }
        case "confirm": c.confirmModal()
        case "cancel": c.cancelModal()
        case "menu":
            c.popup(arg, at: nil, pie: arg == "DOPESHEET_MT_snap_pie")
        case "close":
            c.openMenu?(nil)
        case "focus":
            // The Timeline takes the keyboard, as a touch on it does.
            c.inputView?.takeKeyboard()
            say("timeline-ops: first responder \(c.inputView?.isFirstResponder == true ? "the Timeline" : "elsewhere")")
        case "keys":
            // Real keys, sent by the run's watcher (keypost) while this waits.
            say("timeline-ops keys " + arg)
            await pause(4)
        case "row":
            let ids = arg.split(separator: "/", maxSplits: 1).map(String.init)
            guard ids.count == 2,
                  let row = TimelineMenus.rows(ids[0], usePreviewRange: scene.animation.usePreviewRange)
                    .first(where: { $0.title == ids[1] }) else {
                say("timeline-ops: no row \(arg)")
                break
            }
            switch row.kind {
            case .action(let action): c.perform(action)
            case .interface(let what): c.interface(what)
            default: say("timeline-ops: \(arg) is not a row that runs")
            }
        case "rename":
            c.beginRename()
            c.state.renameText = arg
            c.commitRename()
        case "zoom":
            c.pinch(by: CGFloat(Double(arg) ?? 1), at: c.bodySize.width / 2)
        case "pan":
            c.pan(by: CGFloat(Double(arg) ?? 0))
        case "frameall":
            c.interface("view.frame_all")
        case "seconds":
            c.state.showSeconds = arg == "on"
        case "markers":
            c.state.showMarkers = arg != "off"
        case "frame":
            driver.setFrame(Int(arg) ?? 1)
        case "undo":
            session.performUndo()
        case "redo":
            session.performRedo()
        case "dump":
            let keys = scene.timelineKeys.map { k in
                String(format: "%g%@%@%@", Double(k.frame), k.selected ? "*" : "",
                       k.type == .keyframe ? "" : "/" + k.type.identifier, k.partial ? "~" : "")
            }
            say("timeline keys: " + keys.joined(separator: " "))
            let markers = scene.animation.markers.map { "\($0.name)@\($0.frame)\($0.selected ? "*" : "")" }
            say("timeline markers: " + markers.joined(separator: " ") + (scene.animation.lockMarkers ? " (locked)" : ""))
            let w = c.window
            say(String(format: "timeline view: %.2f to %.2f over %.0f pt, frame %d%@", w.first, w.last,
                       Double(w.width), scene.frameCurrent, c.state.showSeconds ? ", Use Timecode" : ""))
        case "py":
            let code = arg.replacingOccurrences(of: "\\n", with: "\n")
            say("timeline py: " + (session.capture(code) ?? "(error)").replacingOccurrences(of: "\n", with: " | "))
        case "shot":
            say("timeline-ops shot " + arg)
            // Long enough for a loaded Mac's watcher to take it.
            await pause(8)
        default:
            say("timeline-ops: unknown token \(token)")
        }
    }
}
#endif
