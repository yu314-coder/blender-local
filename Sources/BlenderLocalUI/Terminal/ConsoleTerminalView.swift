import GameController
import SwiftTerm
import SwiftUI
import UIKit

/// The console's screen: SwiftTerm, set up the way BenchCode sets up its
/// terminal — the same font, colours, gestures and keyboard bar — with the
/// console's line editor deciding what every key does.
struct ConsoleTerminalView: UIViewRepresentable {
    var scene: BKScene
    var session: BpySession
    /// Handed in so that a new console line, or a run starting or ending, is a
    /// change SwiftUI can see, and reports to `updateUIView`.
    var lineCount: Int
    var lastLine: UUID?
    var isRunning: Bool
    /// Bumped to put the keyboard in the console: the menu bar's Switch Editor
    /// and Console.
    var focusRequest: Int
    var fontSize: Int
    /// Columns and rows, for the strip above.
    var onSize: (Int, Int) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ConsoleTerminal {
        let terminal = ConsoleTerminal(frame: .zero)
        context.coordinator.attach(terminal)
        return terminal
    }

    func updateUIView(_ terminal: ConsoleTerminal, context: Context) {
        #if DEBUG
        FocusLog.count("console update")
        #endif
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(fontSize: fontSize)
        coordinator.sync()
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            coordinator.focus()
        }
    }

    static func dismantleUIView(_ terminal: ConsoleTerminal, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        if ConsoleTerminal.focused === terminal { ConsoleTerminal.focused = nil }
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate,
                             UIPointerInteractionDelegate {
        var parent: ConsoleTerminalView
        var lastFocusRequest: Int
        let editor: ConsoleLineEditor
        private var transcript = ConsoleTranscript()
        private weak var terminal: ConsoleTerminal?
        private weak var focusTap: UITapGestureRecognizer?
        /// Nothing is drawn until SwiftTerm knows its real size: drawn at its
        /// zero-width fallback, every character would wrap onto its own row.
        private var ready = false
        private var appliedFontSize = 0
        private var pendingRepaint: DispatchWorkItem?
        /// The keyboard's way into a running console command.
        private let stdin = ConsoleStdin()
        /// A running command's output, on its way to the screen.
        private var rawStream = ConsoleRawStream()
        /// A console command is running and drawing straight to the screen.
        private var liveRun = false

        static let historyKey = "bl_console_history"
        /// Clears the screen and the scrollback, and puts the cursor home.
        static let clearAll = "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3J"

        init(_ parent: ConsoleTerminalView) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            editor = ConsoleLineEditor(history: UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? [])
            super.init()
            editor.write = { [weak self] text in self?.terminal?.feed(text: text) }
            editor.onSubmit = { [weak self] source in self?.run(source) }
            editor.onInterrupt = { [weak self] in self?.parent.session.stopScript() }
            editor.onForward = { [weak self] bytes in self?.stdin.write(bytes) }
            editor.onEndOfInput = { [weak self] in self?.stdin.closeInput() }
            editor.onKey = { [weak self] in self?.terminal?.scroll(toPosition: 1) }
            editor.candidates = { [weak self] text, caret in
                guard let session = self?.parent.session else { return [] }
                return PythonCompletion.candidates(text: text, caret: caret, operators: [], limit: 120,
                                                   introspect: { session.introspect($0) })
            }
            editor.shellCompletions = { [weak self] line, caret in self?.shellCompletions(line, caret) }
            editor.onHistoryChange = { UserDefaults.standard.set($0, forKey: Self.historyKey) }
            editor.cursorScreenRow = { [weak self] in
                self?.terminal?.getTerminal().getCursorLocation().y ?? 0
            }
            editor.onOverflow = { [weak self] in
                guard let self, let terminal = self.terminal else { return }
                terminal.feed(text: Self.clearAll)
                terminal.feed(text: self.transcript.renderShown())
            }
        }

        func attach(_ terminal: ConsoleTerminal) {
            self.terminal = terminal
            terminal.terminalDelegate = self
            terminal.onLayout = { [weak self] in self?.layoutChanged() }
            terminal.onKeys = { [weak self] bytes in self?.receive(bytes) }
            terminal.copyAll = { [weak self] in
                guard let self else { return }
                UIPasteboard.general.string = ConsoleTranscript.plainText(self.parent.session.console)
            }
            parent.session.onConsoleOutput = { [weak self] chunk in self?.consoleOutput(chunk) }
            parent.session.onStop = { [weak self] in self?.stopConsoleInput() }
            // BenchCode's terminal colours, tuned for its near-black ground.
            let background = UIColor(red: 0.020, green: 0.024, blue: 0.032, alpha: 1)   // #05060a
            terminal.backgroundColor = background
            terminal.nativeBackgroundColor = background
            terminal.nativeForegroundColor = UIColor(red: 0.878, green: 0.894, blue: 0.925, alpha: 1)
            terminal.installColors(Self.palette)
            terminal.keyboardAppearance = .dark
            apply(fontSize: parent.fontSize)

            // SwiftTerm's own bar of Esc and F-keys goes. BenchCode's short one
            // takes its place, and only when there is no hardware keyboard.
            terminal.inputAccessoryView = nil
            updateKeyBar()
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyBar),
                                                   name: .GCKeyboardDidConnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyBar),
                                                   name: .GCKeyboardDidDisconnect, object: nil)

            let tap = UITapGestureRecognizer(target: self, action: #selector(focusFromTap))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            terminal.addGestureRecognizer(tap)
            focusTap = tap
            // Scrolling takes two fingers so that one finger can select, as in
            // BenchCode. A trackpad's two-finger scroll is not touches, and
            // scrolls either way.
            terminal.panGestureRecognizer.minimumNumberOfTouches = 2
            terminal.panGestureRecognizer.maximumNumberOfTouches = 2
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragSelect(_:)))
            drag.minimumNumberOfTouches = 1
            drag.maximumNumberOfTouches = 1
            drag.delegate = self
            terminal.addGestureRecognizer(drag)
            for recognizer in terminal.gestureRecognizers ?? [] {
                if let press = recognizer as? UILongPressGestureRecognizer, press.minimumPressDuration >= 0.6 {
                    press.minimumPressDuration = 0.5
                }
            }
            terminal.addInteraction(UIPointerInteraction(delegate: self))
        }

        func apply(fontSize: Int) {
            guard fontSize != appliedFontSize, let terminal else { return }
            appliedFontSize = fontSize
            let size = CGFloat(fontSize)
            terminal.font = UIFont(name: "SFMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        func focus() {
            guard let terminal else { return }
            // Resign first: the software keyboard can be gone while the view
            // still thinks it has it, and only a fresh become brings it back.
            if terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
            _ = terminal.becomeFirstResponder()
            terminal.reloadInputViews()
        }

        private func receive(_ bytes: [UInt8]) {
            flushPendingRepaint()
            editor.receive(bytes)
        }

        // MARK: Running what was typed

        /// Runs a line from the prompt — a shell command or Python — on the
        /// interpreter's thread, with the keyboard connected to it.
        ///
        /// Standard input is opened first: a command that reads at once, `cat`
        /// with no file, must find the pipe there and not the fd 0 of an app.
        private func run(_ source: String) {
            stdin.open()
            rawStream = ConsoleRawStream()
            liveRun = true
            editor.beginConsoleRun()
            parent.session.runConsole(source, scene: parent.scene,
                                      columns: editor.columns, rows: editor.rows)
            // The echo is in the console now; it has to be on the screen before
            // any of the output that follows it.
            sync()
        }

        /// Output from the running command: straight to the screen, with the
        /// full-screen markers taken out and acted on.
        private func consoleOutput(_ chunk: String) {
            guard liveRun, let terminal else { return }
            for event in rawStream.take(chunk) {
                switch event {
                case .text(let text): terminal.feed(text: text)
                case .raw: editor.setRawInput(true)
                case .cooked: editor.setRawInput(false)
                }
            }
        }

        /// Stop: a command blocked reading keys cannot be reached by the
        /// interpreter's interrupt, which fires between bytecodes. End of file
        /// wakes it, and ^C tells a command that reads keys to quit.
        private func stopConsoleInput() {
            guard liveRun else { return }
            stdin.write([0x03])
            stdin.closeInput()
        }

        /// The command finished: whatever output was held back, standard input
        /// closed, and the cursor at the start of a line for the prompt.
        private func finishLiveRun() {
            liveRun = false
            for case .text(let text) in rawStream.finish() { terminal?.feed(text: text) }
            stdin.finish()
            if let terminal, terminal.getTerminal().getCursorLocation().x > 0 {
                terminal.feed(text: "\r\n")
            }
        }

        private func shellCompletions(_ line: String, _ caret: Int) -> (start: Int, options: [String])? {
            let files = FileManager.default
            guard let shell = ConsoleShell.completions(
                line: line, caret: caret, cwd: files.currentDirectoryPath, home: NSHomeDirectory(),
                list: { path in
                    ((try? files.contentsOfDirectory(atPath: path)) ?? []).map { name in
                        var isDirectory: ObjCBool = false
                        files.fileExists(atPath: (path as NSString).appendingPathComponent(name),
                                         isDirectory: &isDirectory)
                        return (name, isDirectory.boolValue)
                    }
                })
            else { return nil }
            // The first word may as well be Python: `b` is `bpy` as much as
            // `base64`, so both are offered.
            let chars = Array(line)
            guard shell.start == chars.prefix(while: { $0 == " " }).count else { return shell }
            let python = editor.candidates(line, String(chars[..<caret]).utf16.count)
                .filter { $0.insert == $0.label }
                .map(\.insert)
            return (shell.start, Array(Set(shell.options + python)).sorted())
        }

        // MARK: Keeping the screen in step with the session

        func sync() {
            guard ready, let terminal else { return }
            let session = parent.session
            if session.isRunning { editor.setRunning(true) }
            var drawnLive: Range<Int>?
            if liveRun, !session.isRunning {
                drawnLive = session.lastConsoleOutput
                finishLiveRun()
            }
            if transcript.differs(from: session.console) {
                // The prompt comes off while the screen still matches the
                // transcript: if coming off means repainting, the repaint is
                // of what was on the screen, not of lines not printed yet.
                editor.erase()
                switch transcript.update(to: session.console, alreadyShown: drawnLive) {
                case .none:
                    break
                case .append(let text):
                    terminal.feed(text: text)
                case .repaint(let text):
                    terminal.feed(text: Self.clearAll)
                    editor.screenCleared()
                    terminal.feed(text: text)
                }
            }
            if !session.isRunning {
                editor.endRun()
                editor.show()
            }
        }

        private func layoutChanged() {
            guard let terminal else { return }
            let size = terminal.getTerminal()
            sizeChanged(source: terminal, newCols: size.cols, newRows: size.rows)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 10, newRows > 1, let terminal, terminal.bounds.width > 80 else { return }
            let widthChanged = !ready || newCols != editor.columns
            guard widthChanged || newRows != editor.rows else { return }
            editor.resize(columns: newCols, rows: newRows)
            let report = parent.onSize
            DispatchQueue.main.async { report(newCols, newRows) }
            if !ready {
                ready = true
                terminal.feed(text: "\u{1b}[?2004h")   // bracketed paste
                terminal.getTerminal().changeHistorySize(ConsoleTranscript.repaintLimit)
                transcript.invalidate()
                sync()
                #if DEBUG
                typeLaunchKeysIfRequested()
                #endif
                return
            }
            // A command drawing its own screen owns the layout until it ends.
            guard widthChanged, !liveRun else { return }
            // Every wrap has moved, so the screen is repainted from the record
            // — once the size settles, since dragging the split resizes many
            // times a second.
            pendingRepaint?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingRepaint = nil
                self?.transcript.invalidate()
                self?.sync()
            }
            pendingRepaint = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// A key while a repaint is waiting would edit a prompt drawn for the
        /// old width, so the repaint happens first.
        private func flushPendingRepaint() {
            guard let work = pendingRepaint else { return }
            work.cancel()
            pendingRepaint = nil
            transcript.invalidate()
            sync()
        }

        #if DEBUG
        /// Debug builds accept `-console64 <base64>`: keys typed into the console
        /// once it is on screen, which is how the terminal gets exercised from the
        /// command line. The text splits on U+001F into separate writes, one per
        /// key as SwiftTerm sends them. A piece that is U+001D and a number waits
        /// that many milliseconds, and U+001D "dump" prints the screen — as does
        /// running out of keys — so a check can read the terminal's own text
        /// rather than squint at a photograph of it.
        private func typeLaunchKeysIfRequested() {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-console64"), i + 1 < args.count,
                  let data = Data(base64Encoded: args[i + 1]),
                  let script = String(data: data, encoding: .utf8) else { return }
            var steps = script.components(separatedBy: "\u{1F}")
            func next() {
                guard !steps.isEmpty else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.printScreen() }
                    return
                }
                let step = steps.removeFirst()
                var delay = 0.25
                if step == "\u{1D}dump" {
                    self.printScreen()
                } else if step.hasPrefix("\u{1D}"), let ms = Double(step.dropFirst()) {
                    delay = ms / 1000
                } else if !step.isEmpty {
                    self.receive(Array(step.utf8))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
        }

        /// Every row SwiftTerm holds, scrollback included, one printed line each.
        private func printScreen() {
            guard let terminal else { return }
            var lines = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                .components(separatedBy: "\n")
            while lines.last?.isEmpty == true { lines.removeLast() }
            print("[bk] screen-begin")
            for line in lines { print("[bk] screen| \(line)") }
            print("[bk] screen-end")
            fflush(stdout)
        }
        #endif

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) { receive(Array(data)) }
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        // The app makes no connections, and output is not a place to start one.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // MARK: Keyboard bar

        @objc private func updateKeyBar() {
            guard let terminal else { return }
            if GCKeyboard.coalesced != nil {
                terminal.inputAccessoryView = nil
            } else if !(terminal.inputAccessoryView is ConsoleKeyBar) {
                terminal.inputAccessoryView = ConsoleKeyBar { [weak self] bytes in
                    self?.receive(bytes)
                    _ = self?.terminal?.becomeFirstResponder()
                }
            }
            if terminal.isFirstResponder { terminal.reloadInputViews() }
        }

        // MARK: Gestures and pointer

        @objc private func focusFromTap() { focus() }

        /// One finger drags out a selection at once, instead of after a long
        /// press. SwiftTerm has no public way to start one, so this drives its
        /// own handlers the way BenchCode does: a double tap seeds a selection
        /// where the finger went down, and the pan handler extends it.
        @objc private func dragSelect(_ g: UIPanGestureRecognizer) {
            guard let terminal else { return }
            let location = g.location(in: terminal)
            let panSelector = NSSelectorFromString("panSelectionHandler:")
            func pan(_ state: UIGestureRecognizer.State) {
                guard terminal.responds(to: panSelector) else { return }
                let fake = ForcedStatePanRecognizer()
                fake.attached = terminal
                fake.fakeLocation = location
                fake.fakeTranslation = state == .began ? .zero : g.translation(in: terminal)
                fake.fakeState = state
                _ = terminal.perform(panSelector, with: fake)
            }
            switch g.state {
            case .began:
                let doubleTap = NSSelectorFromString("doubleTap:")
                if terminal.responds(to: doubleTap) {
                    let fake = ForcedEndedTapRecognizer()
                    fake.attached = terminal
                    fake.fakeLocation = location
                    _ = terminal.perform(doubleTap, with: fake)
                }
                pan(.began)
            case .changed:
                pan(.changed)
            case .ended, .cancelled, .failed:
                pan(.ended)
            default:
                break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            // A touch that turns into a press or a drag is a selection, not a
            // request for the keyboard.
            g === focusTap && (other is UILongPressGestureRecognizer || other is UIPanGestureRecognizer)
        }

        func pointerInteraction(_ interaction: UIPointerInteraction,
                                styleFor region: UIPointerRegion) -> UIPointerStyle? {
            UIPointerStyle(shape: .verticalBeam(length: CGFloat(max(appliedFontSize, 10)) * 1.3))
        }

        /// BenchCode's sixteen colours.
        static let palette: [SwiftTerm.Color] = [
            .init(red: 0x0000, green: 0x0000, blue: 0x0000),
            .init(red: 0xd954, green: 0x4747, blue: 0x4747),
            .init(red: 0x5ecf, green: 0xb852, blue: 0x6d5a),
            .init(red: 0xe0a5, green: 0xad26, blue: 0x5e5e),
            .init(red: 0x5a99, green: 0x88cd, blue: 0xe663),
            .init(red: 0xa26b, green: 0x7e6b, blue: 0xd0a3),
            .init(red: 0x4ed5, green: 0xab42, blue: 0xc0cc),
            .init(red: 0xcccc, green: 0xcccc, blue: 0xcccc),
            .init(red: 0x5555, green: 0x5555, blue: 0x5555),
            .init(red: 0xf99a, green: 0x6b85, blue: 0x6b85),
            .init(red: 0x70bd, green: 0xd51f, blue: 0x80e0),
            .init(red: 0xf99a, green: 0xcb1e, blue: 0x6b85),
            .init(red: 0x711d, green: 0xa622, blue: 0xff6c),
            .init(red: 0xc96d, green: 0x88cd, blue: 0xfd4e),
            .init(red: 0x77e6, green: 0xd1e7, blue: 0xeeee),
            .init(red: 0xf2f2, green: 0xf2f2, blue: 0xf2f2),
        ]
    }
}

/// SwiftTerm's view with what a console adds to it: knowing when it has the
/// keyboard, and the Mac's editing keys that a terminal does not send.
final class ConsoleTerminal: TerminalView {
    /// The console that has the keyboard, if one does — so Switch Editor and
    /// Console knows which way to switch, and ⌘+ which text to size.
    static weak var focused: ConsoleTerminal?
    /// Posted when a console takes the keyboard, so the code editor can let go
    /// of its caret: a page keeps its focused element when a native view takes
    /// the keys, and showed a caret that typing never reached.
    static let didTakeKeyboard = Notification.Name("ConsoleTerminal.didTakeKeyboard")

    var onLayout: (() -> Void)?
    var onKeys: (([UInt8]) -> Void)?
    var copyAll: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            Self.focused = self
            NotificationCenter.default.post(name: Self.didTakeKeyboard, object: self)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, Self.focused === self { Self.focused = nil }
        return resigned
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: .command, action: #selector(lineStart)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command, action: #selector(lineEnd)),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: .command, action: #selector(deleteToStart)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .command, action: #selector(scrollToTop)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .command, action: #selector(scrollToBottom)),
            UIKeyCommand(title: "Copy", action: #selector(copySelectionOrAll),
                         input: "c", modifierFlags: .command),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func lineStart() { onKeys?([0x1b, 0x5b, 0x48]) }
    @objc private func lineEnd() { onKeys?([0x1b, 0x5b, 0x46]) }
    @objc private func deleteToStart() { onKeys?([0x15]) }
    @objc private func scrollToTop() { scroll(toPosition: 0) }
    @objc private func scrollToBottom() { scroll(toPosition: 1) }

    /// With a selection, copies it. Without one, copies the whole console —
    /// as BenchCode's terminal does — so ⌘C always does something.
    @objc private func copySelectionOrAll() {
        if selectionActive { copy(nil) } else { copyAll?() }
    }
}

/// BenchCode's keyboard bar, shown only when no hardware keyboard is attached:
/// the keys a prompt needs that the software keyboard hides.
final class ConsoleKeyBar: UIInputView {
    private let send: ([UInt8]) -> Void

    init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 40), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let esc = key("esc") { [weak self] in self?.send([0x1b]) }
        let keys = [
            key("tab") { [weak self] in self?.send([0x09]) },
            key("⌃C") { [weak self] in self?.send([0x03]) },
            key("⌃D") { [weak self] in self?.send([0x04]) },
            key("←", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x44]) },
            key("→", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x43]) },
            key("↑", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x41]) },
            key("↓", mono: true) { [weak self] in self?.send([0x1b, 0x5b, 0x42]) },
            key("⌫", mono: true) { [weak self] in self?.send([0x7f]) },
        ]
        let dismiss = key("⌄") {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // The spacer alone stretches, so the keys keep their width and dismiss
        // sits at the right edge.
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [esc] + keys + [spacer, dismiss])
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .fill
        for k in keys + [dismiss] { k.widthAnchor.constraint(equalTo: esc.widthAnchor).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func key(_ title: String, mono: Bool = false, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: mono ? UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
                        : UIFont.systemFont(ofSize: 13, weight: .semibold),
        ]))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

/// A tap recognizer that reports a fixed place and has always ended — what
/// SwiftTerm's `doubleTap:` needs to believe before it selects.
private final class ForcedEndedTapRecognizer: UITapGestureRecognizer {
    weak var attached: UIView?
    var fakeLocation: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set {}
    }
    override var view: UIView? { attached }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
}

/// A pan recognizer in whatever state it is told, for SwiftTerm's
/// `panSelectionHandler:` — began sets the pivot, changed extends, ended
/// shows the copy menu.
private final class ForcedStatePanRecognizer: UIPanGestureRecognizer {
    weak var attached: UIView?
    var fakeLocation: CGPoint = .zero
    var fakeTranslation: CGPoint = .zero
    var fakeState: UIGestureRecognizer.State = .changed
    override var state: UIGestureRecognizer.State {
        get { fakeState }
        set {}
    }
    override var view: UIView? { attached }
    override func location(in view: UIView?) -> CGPoint { fakeLocation }
    override func translation(in view: UIView?) -> CGPoint { fakeTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) {}
}
