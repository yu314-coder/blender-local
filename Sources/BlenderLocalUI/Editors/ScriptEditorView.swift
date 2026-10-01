import SwiftUI
import UIKit

/// Blender's Text Editor: a script buffer with a line-number gutter and a Run
/// Script button in the header.
struct ScriptEditorView: View {
    /// Word wrap, on as BenchCode's Monaco has it.
    ///
    /// On is only bearable because a wrapped continuation now keeps its line's
    /// indentation — Monaco's `wrappingIndent: 'same'`. Without that the
    /// continuation lands in column zero under the line it belongs to and
    /// reads as a new statement, which is what it was doing here.
    @AppStorage("bl_editor_word_wrap") private var wrapsLines = true

    @Binding var text: String
    /// The outcome of the last run, shown as a banner. Without it, pressing Run
    /// changes nothing you are looking at — the only evidence is a few lines in
    /// a console pane on the other side of the screen.
    var lastRun: BpySession.RunOutcome?
    /// Operator paths for completion, from the backend's own catalogue.
    var operators: [String] = []
    /// Asks the live interpreter what a path really has on it.
    var introspect: ((String) -> [(name: String, callable: Bool)]?)?
    var documentName: String = "untitled.py"
    var isRunning = false
    var onSymbol: ((String) -> Void)?
    var onRun: (String) -> Void

    /// Bumped to ask the text view to reveal the failing line. A token rather
    /// than a flag, so asking twice for the same line works — after scrolling
    /// away, "show me again" is a reasonable thing to want.
    @State private var scrollToErrorToken = 0

    var body: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(BTheme.textDim)
                Text("Text Editor").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Text(documentName).font(BTheme.Font.ui(11)).foregroundStyle(BTheme.textDim)
                Spacer()
                Menu {
                    ForEach(ScriptExample.allCases) { example in
                        Button {
                            text = example.source
                        } label: {
                            if example.needsRealBpy {
                                Label(example.rawValue + " (device only)", systemImage: "iphone")
                            } else {
                                Text(example.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Examples", systemImage: "book")
                        .font(BTheme.Font.ui(11))
                        .foregroundStyle(BTheme.text)
                }
                // Blender keeps Word Wrap in the Text Editor's View menu and
                // ships it off. Off is what makes the gutter trustworthy, so it
                // is the default here too — but a long line on a narrow iPad
                // split is a real reason to want it, so it is one tap away.
                Button { wrapsLines.toggle() } label: {
                    Image(systemName: "text.append")
                        .font(.system(size: 11))
                        .foregroundStyle(wrapsLines ? BTheme.active : BTheme.textDim)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .help(wrapsLines ? "Word Wrap: on" : "Word Wrap: off")
                BButton("Run Script", icon: "play.fill") { onRun(text) }.disabled(isRunning)
            }

            if let lastRun {
                let banner = HStack(spacing: 6) {
                    Image(systemName: lastRun.succeeded ? "checkmark.circle.fill"
                                                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(lastRun.summary)
                        .font(BTheme.Font.mono(11))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    // Where the failure was, and a way to get there. The line
                    // number is in the traceback either way, but reading it
                    // out of a console and then scrolling to find it is work
                    // the reader should not be doing.
                    if let line = lastRun.errorLine {
                        Label("line \(line)", systemImage: "arrow.right.to.line")
                            .font(BTheme.Font.mono(11))
                            .labelStyle(.titleAndIcon)
                    }
                }
                .foregroundStyle(lastRun.succeeded ? BTheme.text : Color(hex: 0xFF6B5E))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((lastRun.succeeded ? BTheme.select : Color(hex: 0xFF6B5E))
                    .opacity(0.16))

                if lastRun.errorLine != nil {
                    Button { scrollToErrorToken &+= 1 } label: { banner }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                } else {
                    banner.textSelection(.enabled)
                }
            }

            CodeTextView(text: $text,
                         operators: operators,
                         errorLine: lastRun?.errorLine,
                         scrollToErrorToken: $scrollToErrorToken,
                         wrapsLines: wrapsLines,
                         introspect: introspect, onSymbol: onSymbol)
        }
        .background(BTheme.textEditor)
    }
}

/// A `UITextView` with a line-number gutter.
///
/// SwiftUI's `TextEditor` cannot draw a gutter that stays aligned while
/// scrolling, so this drops to UIKit and renders the numbers from the same
/// layout manager that positions the text.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    /// Operator paths the backend reported, for completion. Empty until the
    /// catalogue has loaded, which only costs the reader the operator half of
    /// the list until then.
    var operators: [String] = []
    /// The line the last run failed on, if it failed.
    var errorLine: Int?
    /// Set when the reader asks to be taken to that line.
    @Binding var scrollToErrorToken: Int
    /// Blender's Word Wrap, off by default as Blender ships it.
    var wrapsLines: Bool = false
    /// What the live interpreter says a path has on it, if there is one.
    var introspect: ((String) -> [(name: String, callable: Bool)]?)?
    var onSymbol: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LineNumberTextView {
        // TextKit 1: the gutter is drawn from `layoutManager`, which TextKit 2
        // does not expose.
        let view = LineNumberTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.backgroundColor = UIColor(BTheme.textEditor)
        view.textColor = UIColor(BTheme.text)
        view.tintColor = UIColor(BTheme.select)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.isFindInteractionEnabled = true
        view.keyboardAppearance = .dark
        view.alwaysBounceVertical = true
        view.wrapsLines = wrapsLines
        view.text = text

        context.coordinator.recolour(view)
        // Python needs punctuation the iPad keyboard buries, and an indent key
        // it does not have at all.
        // No key row. It was a strip of punctuation buttons above the
        // keyboard — Tab, a colon, brackets — from before there was a
        // suggestion list. The list does the completion half properly now, at
        // the caret, and what was left was a row of keys the keyboard already
        // has, taking a hundred points off the top of a keyboard that is
        // already half the screen.
        //
        // Tab is the one that was not on the keyboard. Newlines still carry
        // their indent, which is what it was mostly used for.

        // Inside the text view rather than over it, so it scrolls with the
        // caret it belongs to instead of hanging in mid-air when the document
        // moves under it.
        let suggestions = SuggestWidget(target: view)
        view.addSubview(suggestions)
        context.coordinator.suggestions = suggestions
        return view
    }

    func updateUIView(_ view: LineNumberTextView, context: Context) {
        context.coordinator.parent = self
        view.errorLine = errorLine
        view.wrapsLines = wrapsLines
        #if DEBUG
        // `-caret <offset>` parks the caret somewhere specific. The simulator
        // cannot tap, so the current-line band and the bracket boxes would
        // otherwise only ever be photographed wherever the caret happens to
        // land, which is the end of the file, next to nothing.
        //
        // Asserted here rather than once at construction: setting it in
        // `makeUIView` took — the state printed correctly — and by the time
        // anything was drawn the caret was back at the end of the text, on a
        // view that had been built again.
        // `-fold <line>`, repeatable, folds regions at launch. The gutter
        // chevrons need a tap and the simulator has none.
        let launchArgs = ProcessInfo.processInfo.arguments
        for (j, arg) in launchArgs.enumerated()
        where arg == "-fold" && j + 1 < launchArgs.count {
            if let line = Int(launchArgs[j + 1]), !view.foldedLines.contains(line) {
                view.toggleFold(at: line)
            }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-caret"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let offset = Int(ProcessInfo.processInfo.arguments[i + 1]),
           offset <= (view.text as NSString).length,
           view.selectedRange.location != offset {
            view.selectedRange = NSRange(location: offset, length: 0)
            view.refreshCaretDecorations()
            // Setting the range in code does not reliably reach the delegate,
            // and the completions are built there.
            context.coordinator.refreshCompletions(view)
        }
        #endif
        if scrollToErrorToken != context.coordinator.lastScrollToken {
            context.coordinator.lastScrollToken = scrollToErrorToken
            if let line = errorLine { view.scrollToLine(line) }
        }
        // Only push a value in that did *not* come from the text view itself.
        //
        // Writing the binding back unconditionally fights the typist: the
        // binding lags a keystroke behind, so every character typed was undone
        // on the next render — and assigning `text` also drops the selection,
        // which put the caret back at the start. The editor was unusable.
        // Comparing against the last value handed to SwiftUI separates our own
        // echo from a genuine external change (loading a file, an example).
        guard text != context.coordinator.lastReported else { return }
        context.coordinator.lastReported = text
        guard view.text != text else { return }

        // Keep the caret where it was when the change came from elsewhere and
        // the text is still long enough to hold it.
        let selection = view.selectedRange
        view.text = text
        context.coordinator.recolour(view)
        if selection.location + selection.length <= (text as NSString).length {
            view.selectedRange = selection
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        /// The most recent value this coordinator pushed into the binding.
        var lastReported: String = ""
        /// The last "go to the error" request already acted on, so a redraw
        /// does not scroll the reader away from wherever they have moved to.
        var lastScrollToken = 0
        init(_ parent: CodeTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            lastReported = textView.text
            parent.text = textView.text
            recolour(textView)
            refreshCompletions(textView)
            // The gutter is drawn from the layout manager, so it has to be
            // redrawn when the line count changes.
            textView.setNeedsDisplay()
        }

        /// Re-run the syntax scanner over the whole buffer.
        ///
        /// Whole-buffer rather than incremental because a single keystroke can
        /// change the colour of everything after it — typing one `"` opens a
        /// string that runs to the end of the file until the closing one
        /// arrives. Scanning is a single linear pass, and the whole bike
        /// script is 279 lines, so the honest version is also the fast enough
        /// one. If a buffer ever gets large enough for this to show, the fix
        /// is to scan only the visible range, not to guess at what changed.
        ///
        /// Assigning `attributedText` resets the selection and the typing
        /// attributes, so both are restored — without that the caret jumps to
        /// the start on every character, which is the same bug that once made
        /// this editor unusable, arriving by a different route.
        func recolour(_ textView: UITextView) {
            guard !isRecolouring, textView.markedTextRange == nil else { return }
            isRecolouring = true
            defer { isRecolouring = false }

            let font = textView.font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let selection = textView.selectedRange
            let coloured = NSMutableAttributedString(
                attributedString: PythonSyntax.highlight(textView.text, font: font))
            Self.applyWrappingIndent(to: coloured, font: font)
            let offset = textView.contentOffset
            textView.textStorage.setAttributedString(coloured)
            textView.selectedRange = selection
            textView.setContentOffset(offset, animated: false)
            (textView as? LineNumberTextView)?.refreshFoldRegions()
            // `attributedText` also clears these, and without them the *next*
            // character typed comes out in the system font at system size.
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: PythonSyntax.Token.plain.colour,
            ]
        }

        /// Monaco's `wrappingIndent: 'same'`: a wrapped line's continuation is
        /// indented to where its own code starts, so it stays visibly part of
        /// the line above rather than appearing to begin a new statement in
        /// column zero.
        ///
        /// A paragraph style per line, because the indent differs per line —
        /// one style over the whole document would indent every continuation
        /// to the first line's depth.
        static func applyWrappingIndent(to text: NSMutableAttributedString, font: UIFont) {
            let column = ("0" as NSString).size(withAttributes: [.font: font]).width
            let ns = text.string as NSString
            var offset = 0
            while offset < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
                let columns = BracketMatch.indentColumns(of: ns.substring(with: lineRange))
                let style = NSMutableParagraphStyle()
                // A hanging indent: the first line sits where it sits, and
                // everything the wrap produces lines up under its code. The
                // extra four columns are Monaco's too — a continuation one
                // level deeper reads as continuation rather than as a sibling.
                style.headIndent = CGFloat(columns + 4) * column
                style.lineBreakMode = .byWordWrapping
                text.addAttribute(.paragraphStyle, value: style, range: lineRange)
                offset = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
            }
        }

        /// Guards against `attributedText` triggering `textViewDidChange`.
        private var isRecolouring = false

        /// Monaco's list at the caret. It sits alongside the strip rather than
        /// replacing it: the strip is where the punctuation lives, and it is
        /// the only place there is room on a phone.
        weak var suggestions: SuggestWidget?

        /// Python's indentation is its block structure, so a newline has to
        /// carry the indent with it. Handled here rather than after the fact
        /// because inserting the newline and then fixing the line would put a
        /// half-formed state through the undo stack.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            // Monaco's `autoClosingBrackets: 'always'` and `autoClosingQuotes`.
            // On a keyboard with no dedicated bracket keys this is worth more
            // than it is on a desktop: the closer is the character that costs a
            // trip to another keyboard plane to type.
            if range.length == 0, let closer = Self.autoClose[text] {
                let ns = textView.text as NSString
                let next = range.location < ns.length
                    ? ns.substring(with: NSRange(location: range.location, length: 1))
                    : ""
                // Not before a word: typing `(` in front of `name` should not
                // produce `()name`. Monaco makes the same exception.
                let beforeWord = !next.isEmpty
                    && (next.rangeOfCharacter(from: .alphanumerics) != nil || next == "_")
                // A quote already sitting under the caret is one this inserted;
                // typing it again should step over rather than double it.
                if text == next, Self.autoClose[text] == text {
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return false
                }
                if !beforeWord {
                    textView.insertText(text + closer)
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return false
                }
            }
            // Typing the closer that is already there steps over it, which is
            // what makes the pair feel like one thing rather than two.
            if range.length == 0, Self.closers.contains(text) {
                let ns = textView.text as NSString
                if range.location < ns.length,
                   ns.substring(with: NSRange(location: range.location, length: 1)) == text {
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return false
                }
            }
            // Backspace between an empty pair takes both halves.
            if text.isEmpty, range.length == 1 {
                let ns = textView.text as NSString
                if range.location + 1 < ns.length {
                    let before = ns.substring(with: NSRange(location: range.location, length: 1))
                    let after = ns.substring(with: NSRange(location: range.location + 1, length: 1))
                    if Self.autoClose[before] == after {
                        textView.replace(textView.textRange(from: textView.position(
                            from: textView.beginningOfDocument, offset: range.location)!,
                            to: textView.position(from: textView.beginningOfDocument,
                                                  offset: range.location + 2)!)!, withText: "")
                        return false
                    }
                }
            }

            if text == "\n", acceptSuggestionIfShowing() { return false }
            guard text == "\n" else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let upToCaret = ns.substring(with: NSRange(
                location: lineRange.location,
                length: max(0, range.location - lineRange.location)))
            let indent = PythonIndent.afterNewline(in: upToCaret)
            textView.insertText("\n" + indent)
            return false
        }

        /// What auto-closes, and with what. Quotes close with themselves,
        /// which is why stepping over one has to be told apart from opening a
        /// new one.
        static let autoClose: [String: String] = [
            "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'",
        ]
        static let closers: Set<String> = [")", "]", "}"]

        /// Return accepts the highlighted suggestion when the list is up,
        /// which is Monaco's `acceptSuggestionOnEnter: 'on'`. Otherwise it is
        /// an ordinary newline and the indent logic below handles it.
        func acceptSuggestionIfShowing() -> Bool {
            suggestions?.acceptSelected() ?? false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshCompletions(textView)
            let symbol = PythonCompletion.context(in: textView.text, caret: textView.selectedRange.location)
            let path = PythonCompletion.callContext(in: textView.text, caret: textView.selectedRange.location)
                ?? (symbol.path.isEmpty ? symbol.partial : symbol.path + "." + symbol.partial)
            let callback = parent.onSymbol
            DispatchQueue.main.async { callback?(path.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            (textView as? LineNumberTextView)?.refreshCaretDecorations()
        }

        /// What could be typed next, given where the caret is.
        private var completionWork: DispatchWorkItem?
        func refreshCompletions(_ textView: UITextView) {
            completionWork?.cancel()
            guard textView.selectedRange.length == 0, !textView.isDragging,
                  textView.markedTextRange == nil else {
                suggestions?.dismiss()
                return
            }
            let text = textView.text ?? ""
            let caret = textView.selectedRange.location
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, textView.text == text,
                      textView.selectedRange.location == caret else { return }
                let found = PythonCompletion.candidates(text: text, caret: caret,
                    operators: self.parent.operators, introspect: self.parent.introspect)
                self.suggestions?.show(found)
            }
            completionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
}

final class LineNumberTextView: UITextView {
    private let gutterWidth: CGFloat = 40

    /// The script line the last run's traceback blamed, 1-based.
    ///
    /// Drawn rather than merely reported, because the traceback lives in a
    /// console pane on the far side of the screen and names a number the
    /// reader then has to find. Marking the line closes that gap: the error
    /// and the code are in the same place.
    var errorLine: Int? {
        didSet { if errorLine != oldValue { setNeedsDisplay() } }
    }

    /// Which regions are folded, by their opening line. Monaco's
    /// `folding: true` — a `def` you are not reading should not take up
    /// twenty rows of an iPad's worth of screen.
    private(set) var foldedLines: Set<Int> = []
    /// The foldable regions, recomputed when the text changes rather than on
    /// every draw: the scan is over the whole document.
    private var regions: [PythonFolding.Region] = []
    /// The character ranges currently hidden, in the order the layout manager
    /// will ask about them.
    private var hiddenRanges: [NSRange] = []

    /// Recomputes what can fold. Call when the text changes.
    func refreshFoldRegions() {
        regions = PythonFolding.regions(in: text)
        // A fold whose line no longer opens a region is not a fold any more.
        let openable = Set(regions.map(\.startLine))
        foldedLines.formIntersection(openable)
        rebuildHiddenRanges()
    }

    private func rebuildHiddenRanges() {
        hiddenRanges = regions
            .filter { foldedLines.contains($0.startLine) }
            .compactMap { PythonFolding.hiddenRange(for: $0, in: text) }
        layoutManager.invalidateGlyphs(
            forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            actualCharacterRange: nil)
        setNeedsDisplay()
    }

    func toggleFold(at line: Int) {
        guard regions.contains(where: { $0.startLine == line }) else { return }
        if foldedLines.contains(line) { foldedLines.remove(line) } else { foldedLines.insert(line) }
        rebuildHiddenRanges()
    }

    /// Whether a character offset is inside something folded away.
    func isHidden(_ offset: Int) -> Bool {
        hiddenRanges.contains { NSLocationInRange(offset, $0) }
    }

    /// The bracket pair to box, recomputed when the caret moves. Monaco's
    /// `matchBrackets: 'always'`.
    private var bracketPair: (Int, Int)?

    override var selectedTextRange: UITextRange? {
        didSet { refreshCaretDecorations() }
    }

    /// The current line and its bracket pair both follow the caret, and both
    /// are drawn, so both have to be recomputed when it moves.
    func refreshCaretDecorations() {
        bracketPair = BracketMatch.match(in: text, caret: selectedRange.location)
        // Unconditionally: the current-line band moves with the caret whether
        // or not the bracket pair changed, so there is nothing to compare
        // against that would let us skip the redraw.
        setNeedsDisplay()
    }

    /// Blender's Text Editor has a Word Wrap toggle and ships with it off;
    /// Monaco does the same. Off is the right default for code: a wrapped line
    /// has no number of its own, so the gutter and the text stop lining up and
    /// a continuation reads as a new statement — `0, 0))` sitting in column
    /// zero under a call that ran long.
    /// A finite stand-in for "as wide as it needs to be". Not
    /// `.greatestFiniteMagnitude`: the layout manager does arithmetic on this,
    /// and an infinity in it comes back as a NaN. Ten million points is about a
    /// hundred thousand monospace characters.
    static let unbounded: CGFloat = 10_000_000

    var wrapsLines = true {
        didSet {
            guard wrapsLines != oldValue else { return }
            applyWrapping()
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainerInset = UIEdgeInsets(top: 8, left: gutterWidth, bottom: 8, right: 8)
        contentMode = .redraw
        applyWrapping()
        layoutManager.delegate = self

        // The chevrons live in the gutter, which is inset padding rather than
        // a view, so the tap is caught here and rejected unless it lands in
        // that strip. A recogniser that swallowed taps anywhere would take the
        // caret away from the editor.
        let tap = UITapGestureRecognizer(target: self, action: #selector(gutterTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func gutterTapped(_ recogniser: UITapGestureRecognizer) {
        let point = recogniser.location(in: self)
        guard point.x < gutterWidth else { return }
        guard let line = lineNumber(at: point) else { return }
        toggleFold(at: line)
    }

    /// The 1-based line whose fragment contains a point, or nil.
    private func lineNumber(at point: CGPoint) -> Int? {
        let y = point.y - textContainerInset.top
        var glyphIndex = 0
        let starts = lineStarts
        while glyphIndex < layoutManager.numberOfGlyphs {
            var range = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &range)
            if y >= fragment.minY, y < fragment.maxY {
                let chars = layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                return Self.line(containing: chars.location, in: starts)
            }
            glyphIndex = NSMaxRange(range)
        }
        return nil
    }

    /// With wrapping off the container is given unbounded width and told to
    /// stop tracking the view, so layout runs long and the scroll view gains
    /// something to scroll horizontally.
    private func applyWrapping() {
        textContainer.widthTracksTextView = wrapsLines
        textContainer.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
        // A finite width, not `.greatestFiniteMagnitude`. The layout manager
        // does its own arithmetic on the container size, and an infinity in it
        // comes back as a NaN that it resolves by wrapping to the view width —
        // which looks exactly like the setting having no effect. Ten million
        // points is about a hundred thousand characters of monospace: longer
        // than any line anyone will scroll to the end of.
        textContainer.size = CGSize(width: wrapsLines ? bounds.width : Self.unbounded,
                                    height: Self.unbounded)
        layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            actualCharacterRange: nil)
        // A code editor scrolls sideways; it does not bounce sideways over
        // nothing, which is what happens when the longest line fits.
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = !wrapsLines
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Setting this once is not enough. UITextView re-establishes its own
        // container tracking during layout: `widthTracksTextView` was back to
        // true and the width clamped to the view's by the first
        // `layoutSubviews`, which is why turning wrapping off appeared to do
        // nothing at all. So it is asserted on every pass, and only written
        // when it actually differs — writing unconditionally re-triggers
        // layout, forever.
        let wanted: CGFloat = wrapsLines ? bounds.width : Self.unbounded
        if textContainer.widthTracksTextView != wrapsLines {
            textContainer.widthTracksTextView = wrapsLines
        }
        if textContainer.size.width != wanted {
            textContainer.size = CGSize(width: wanted, height: Self.unbounded)
        }
    }

    convenience init(usingTextLayoutManager: Bool) {
        // UITextView's TextKit-1 initialiser is the no-container path.
        self.init(frame: .zero, textContainer: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Put a 1-based line in view and place the caret on it.
    ///
    /// Placing the caret as well as scrolling means the reader can start
    /// typing the fix where they landed, rather than scrolling somewhere and
    /// then having to tap to get a cursor.
    func scrollToLine(_ line: Int) {
        let ns = text as NSString
        var location = 0
        var current = 1
        while current < line, location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            current += 1
        }
        guard location <= ns.length else { return }
        let target = ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0))
        selectedRange = NSRange(location: target.location, length: 0)
        scrollRangeToVisible(target)
        becomeFirstResponder()
    }

    /// One monospace advance, which every column measurement here is in.
    private var columnWidth: CGFloat {
        let f = font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }

    /// Where the caret would be drawn for a character offset, computed from
    /// the layout rather than from `caretRect(for:)`.
    ///
    /// `caretRect(for:)` wants a `UITextPosition`, and `selectedTextRange` is
    /// nil while the view is not first responder — so anything positioned from
    /// it lands at the origin until the reader has tapped into the editor,
    /// which is exactly when a suggestion list is least useful.
    func caretRect(atCharacter offset: Int) -> CGRect? {
        // Ask for the layout rather than hoping it has happened. On the first
        // pass — which is exactly when a launch-placed caret asks — there are
        // no glyphs yet, so this returned nil and anything positioned from it
        // stayed at the origin.
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let ns = text as NSString
        let clamped = min(max(offset, 0), max(ns.length - 1, 0))
        let glyph = layoutManager.glyphIndexForCharacter(at: clamped)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        return CGRect(x: fragment.origin.x + location.x + textContainerInset.left,
                      y: fragment.origin.y + textContainerInset.top,
                      width: 1, height: fragment.height)
    }

    /// The line fragment a character offset falls on.
    private func fragment(forCharacter offset: Int) -> CGRect? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, max(ns.length - 1, 0)))
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Monaco's line highlight, indent guides and bracket boxes.
    private func drawUnderlays(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              layoutManager.numberOfGlyphs > 0 else { return }
        let ns = text as NSString
        let inset = textContainerInset

        // --- the current line ---------------------------------------------
        // `renderLineHighlight: 'all'` — the whole row, gutter included, so
        // the eye can find where it is without hunting for the caret.
        // The whole logical line, both rows of it when it has wrapped — a band
        // that stops at the first row says the continuation is somewhere else.
        let caretLine = ns.lineRange(for: NSRange(location: min(selectedRange.location,
                                                               max(ns.length - 1, 0)),
                                                  length: 0))
        if let first = fragment(forCharacter: caretLine.location) {
            let lastCharacter = max(caretLine.location, NSMaxRange(caretLine) - 1)
            let last = fragment(forCharacter: lastCharacter) ?? first
            let top = first.origin.y + inset.top
            let bottom = last.origin.y + last.height + inset.top
            context.setFillColor(UIColor(BTheme.text).withAlphaComponent(0.055).cgColor)
            context.fill(CGRect(x: 0, y: top,
                                width: max(rect.width, bounds.width),
                                height: max(bottom - top, first.height)))
        }

        // --- indent guides -------------------------------------------------
        // One hairline per four columns of a line's own indentation, so the
        // block a line belongs to is visible without counting spaces. Drawn
        // per logical line rather than per fragment: a wrapped continuation is
        // not a new level.
        let column = columnWidth
        context.setStrokeColor(UIColor(BTheme.text).withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1)
        var offset = 0
        while offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: lineRange)
            let depth = BracketMatch.indentColumns(of: line) / 4
            // A folded line has no fragment of its own, and asking for one
            // hands back the fragment of the line it collapsed into — so a
            // folded body drew all of its guides on top of the `def` that hid
            // it, which read as the `def` being three levels deep.
            if depth > 0, !isHidden(lineRange.location),
               let frag = fragment(forCharacter: lineRange.location) {
                let y = frag.origin.y + inset.top
                // From zero: a line indented one level shows the guide at the
                // left edge of its indentation, which is the level it sits
                // inside. Starting at one drew nothing for depth-1 lines and
                // put the depth-2 guide where the depth-1 guide belongs.
                for level in 0..<depth {
                    let x = (inset.left + CGFloat(level * 4) * column).rounded() + 0.5
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + frag.height))
                }
                context.strokePath()
            }
            offset = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }

        // --- the matching brackets ------------------------------------------
        if let (open, close) = bracketPair {
            context.setStrokeColor(UIColor(BTheme.active).withAlphaComponent(0.85).cgColor)
            context.setFillColor(UIColor(BTheme.active).withAlphaComponent(0.16).cgColor)
            for offset in [open, close] {
                guard offset < ns.length,
                      let frag = fragment(forCharacter: offset) else { continue }
                let glyph = layoutManager.glyphIndexForCharacter(at: offset)
                let location = layoutManager.location(forGlyphAt: glyph)
                let box = CGRect(x: frag.origin.x + location.x + inset.left - 0.5,
                                 y: frag.origin.y + inset.top,
                                 width: column + 1, height: frag.height)
                context.fill(box)
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    override func draw(_ rect: CGRect) {
        // Behind the text, not over it. Monaco's line highlight, indent guides
        // and bracket boxes all sit under the glyphs; drawing them afterwards
        // means every one of them is a veil over the code it is pointing at.
        drawUnderlays(rect)
        super.draw(rect)
        guard let layoutManager = self.layoutManager as NSLayoutManager?,
              let context = UIGraphicsGetCurrentContext() else { return }

        // The gutter background, drawn behind the numbers.
        context.setFillColor(UIColor(BTheme.header).cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: gutterWidth - 6, height: rect.height))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor(BTheme.textDim),
        ]

        // Walk the laid-out line fragments so wrapped lines do not each get a
        // number — only real newlines advance the count, as in Blender.
        var glyphIndex = 0
        let glyphCount = layoutManager.numberOfGlyphs
        let nsText = text as NSString
        // Counted, not accumulated. With a fold in the document the layout
        // simply has no fragments for the hidden lines, so a running counter
        // would number the line after a folded `def` as 2. The number has to
        // come from where the text actually is.
        let starts = lineStarts
        let foldable = Set(regions.map(\.startLine))

        while glyphIndex < glyphCount {
            var lineRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            let charRange = layoutManager.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            let lineNumber = Self.line(containing: charRange.location, in: starts)

            // A fragment starts a new logical line when the character before it
            // is a newline (or it is the very first fragment).
            let isLineStart = charRange.location == 0
                || nsText.substring(with: NSRange(location: charRange.location - 1, length: 1)) == "\n"

            if isLineStart {
                let y = fragment.origin.y + textContainerInset.top
                let failed = (lineNumber == errorLine)

                if failed {
                    // A band across the whole width, not just the gutter: the
                    // eye finds a filled row far faster than a coloured digit,
                    // and the point is to be found without being looked for.
                    context.setFillColor(UIColor(red: 1, green: 0.42, blue: 0.37, alpha: 0.16).cgColor)
                    context.fill(CGRect(x: 0, y: y, width: rect.width, height: fragment.height))
                    context.setFillColor(UIColor(red: 1, green: 0.42, blue: 0.37, alpha: 0.9).cgColor)
                    context.fill(CGRect(x: 0, y: y, width: 3, height: fragment.height))
                }

                let label = "\(lineNumber)" as NSString
                var lineAttrs = attrs
                if failed {
                    lineAttrs[.foregroundColor] = UIColor(red: 1, green: 0.42, blue: 0.37, alpha: 1)
                }
                let size = label.size(withAttributes: lineAttrs)
                label.draw(at: CGPoint(x: gutterWidth - 12 - size.width, y: y),
                           withAttributes: lineAttrs)

                // Monaco shows its chevrons on hover and keeps folded ones
                // visible. There is no hover on a touch screen, so they are
                // always there — small, dim, and only on lines that open
                // something.
                if foldable.contains(lineNumber) {
                    let folded = foldedLines.contains(lineNumber)
                    let chevron = (folded ? "\u{25B8}" : "\u{25BE}") as NSString
                    let colour = folded ? UIColor(BTheme.active) : UIColor(BTheme.textDim)
                    chevron.draw(at: CGPoint(x: 4, y: y),
                                 withAttributes: [
                                    .font: UIFont.systemFont(ofSize: 11),
                                    .foregroundColor: colour,
                                 ])
                    if folded {
                        // Blender and Monaco both say how much is hidden
                        // rather than hiding it silently.
                        let count = (regions.first { $0.startLine == lineNumber }
                                        .map { $0.endLine - $0.startLine + 1 }) ?? 0
                        let tag = " \u{22EF} \(count) lines" as NSString
                        let after = layoutManager.usedRect(for: textContainer).width
                        tag.draw(at: CGPoint(x: min(after + textContainerInset.left, bounds.width - 90),
                                             y: y),
                                 withAttributes: [
                                    .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                    .foregroundColor: UIColor(BTheme.textDim),
                                 ])
                    }
                }
            }
            glyphIndex = NSMaxRange(lineRange)
        }
    }

    /// The character offset each 1-based line starts at.
    private var lineStarts: [Int] {
        let ns = text as NSString
        var out = [0]
        var location = 0
        while location < ns.length {
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            if location < ns.length { out.append(location) }
        }
        return out
    }

    /// Which 1-based line an offset falls on, by binary search rather than by
    /// counting newlines from the top for every fragment.
    static func line(containing offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found + 1
    }
}

extension LineNumberTextView: UIGestureRecognizerDelegate {
    /// Only claim taps in the gutter. Everywhere else belongs to the editor's
    /// own selection handling, which must keep working.
    public override func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        guard recogniser is UITapGestureRecognizer, recogniser.delegate === self else {
            return super.gestureRecognizerShouldBegin(recogniser)
        }
        return recogniser.location(in: self).x < gutterWidth
    }
}

extension LineNumberTextView: NSLayoutManagerDelegate {
    /// Folding, at the only level where text can actually be made to disappear
    /// without being deleted: the glyphs for a hidden range are generated as
    /// null, so they take no space and are never drawn.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: UIFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length where isHidden(charIndexes[i]) {
            properties[i] = .null
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &properties,
                                characterIndexes: charIndexes, font: font,
                                forGlyphRange: glyphRange)
        return glyphRange.length
    }
}

// MARK: Offline Monaco editor
import WebKit

final class MonacoController {
    weak var webView: WKWebView?

    /// Put the failing line in front of the reader.
    ///
    /// The traceback already names it and `RunOutcome.scriptLine` already digs
    /// it out — that work was simply not reaching the editor any more, because
    /// the marker lived in the native view Monaco replaced.
    ///
    /// It arrives with the rest of what the traceback says — the exception,
    /// its message and the frames that called in — because a squiggle alone
    /// still sent the reader across the screen to the console to learn why.
    func markError(line: Int, name: String?, message: String?,
                   frames: [BpySession.RunOutcome.ScriptFrame], fileName: String) {
        var details: [String: Any] = [
            "line": line,
            "frames": frames.map { ["line": $0.line, "function": $0.function] },
            "traceback": Self.traceback(name: name, message: message,
                                        frames: frames, fileName: fileName)
        ]
        if let name { details["name"] = name }
        if let message { details["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: details),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.markError?.(\(json))")
    }

    /// What the card's Copy puts on the clipboard: a traceback in Python's own
    /// shape, naming the file rather than `<string>`, so it reads the way
    /// anyone who has seen one expects when it is pasted into a question.
    static func traceback(name: String?, message: String?,
                          frames: [BpySession.RunOutcome.ScriptFrame],
                          fileName: String) -> String {
        var lines = ["Traceback (most recent call last):"]
        for frame in frames.reversed() {
            let function = frame.function.isEmpty ? "" : ", in \(frame.function)"
            lines.append("  File \"\(fileName)\", line \(frame.line)\(function)")
        }
        switch (name, message) {
        case let (name?, message?): lines.append("\(name): \(message)")
        case let (name?, nil):      lines.append(name)
        case let (nil, message?):   lines.append(message)
        case (nil, nil):            break
        }
        return lines.joined(separator: "\n")
    }

    func clearError() {
        webView?.evaluateJavaScript("window.clearError?.()")
    }

    /// Runs one of Monaco's own actions — find, go to line, toggle comment —
    /// so a menu command does exactly what the editor's own key for it does.
    func trigger(_ action: String) {
        webView?.evaluateJavaScript("window.runEditorAction?.(\(Bpy.quote(action)))")
    }

    /// Puts the keyboard in the editor.
    func focus() {
        guard let web = webView else { return }
        web.becomeFirstResponder()
        web.evaluateJavaScript("window.editor?.focus()")
    }
    func source(_ completion: @escaping (String) -> Void) {
        guard let web = webView else { return }
        web.evaluateJavaScript("window.editor?.getValue()") { value, _ in
            withExtendedLifetime(web) {
                if let source = value as? String { completion(source) }
            }
        }
    }
}

struct MonacoScriptEditor: UIViewRepresentable {
    var documentID: UUID
    var source: String
    var metadata: String
    var controller: MonacoController
    var onChange: (String) -> Void
    var onRun: (String) -> Void
    /// The editor's text size in points; ⌘+ and ⌘− change it.
    var fontSize: Int = 14

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "blender-editor")
        config.userContentController.add(context.coordinator, name: "editor")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        view.scrollView.isScrollEnabled = false
        // Trackpad and mouse-wheel scrolling. Monaco scrolls itself and the
        // page's own scroll view is off, which left a Magic Keyboard trackpad's
        // two-finger scroll with nowhere to go. A scroll-only recogniser takes
        // it here and hands the distance to Monaco. It never sees a touch, so
        // typing, selection and touch scrolling stay Monaco's; and if WebKit
        // does deliver wheel events for the same gesture, the page drops the
        // forwarded distance, so the editor never scrolls twice.
        let trackpad = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleTrackpadScroll(_:)))
        trackpad.allowedScrollTypesMask = .all
        trackpad.allowedTouchTypes = []
        trackpad.maximumNumberOfTouches = 0
        trackpad.delegate = context.coordinator
        view.addGestureRecognizer(trackpad)
        // A click or tap in the editor takes the keyboard at once. WebKit moves
        // it to the page only after the page has answered, and until then keys
        // went on to the console the reader had just left. This recogniser
        // watches alongside WebKit's own and cancels nothing, so selection,
        // double-click and the caret stay Monaco's.
        let click = UITapGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.takeKeyboard(_:)))
        click.cancelsTouchesInView = false
        click.delaysTouchesBegan = false
        click.delaysTouchesEnded = false
        click.delegate = context.coordinator
        view.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.consoleTookKeyboard),
                                               name: ConsoleTerminal.didTakeKeyboard, object: nil)
        view.accessibilityLabel = "Monaco Python editor"
        #if DEBUG
        view.isInspectable = true
        FocusLog.monaco = view
        #endif
        context.coordinator.web = view
        controller.webView = view
        view.load(URLRequest(url: URL(string: "blender-editor://local/index.html")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        #if DEBUG
        FocusLog.count("monaco update")
        #endif
        context.coordinator.parent = self
        controller.webView = view
        context.coordinator.update()
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate,
                             UIGestureRecognizerDelegate {
        var parent: MonacoScriptEditor
        weak var web: WKWebView?
        var ready = false
        var loadedID: UUID?
        var loadedMetadata = ""
        var loadedFontSize = 14
        init(_ parent: MonacoScriptEditor) { self.parent = parent }

        /// A click in the editor: the console lets go of the keyboard and the
        /// page takes it now, rather than when WebKit gets round to it.
        @objc func takeKeyboard(_ recogniser: UITapGestureRecognizer) {
            guard let web else { return }
            if let console = ConsoleTerminal.focused { _ = console.resignFirstResponder() }
            web.becomeFirstResponder()
        }

        /// The console took the keyboard: drop Monaco's caret with it.
        @objc func consoleTookKeyboard() {
            web?.evaluateJavaScript("if (window.editor && editor.hasTextFocus()) { document.activeElement.blur(); }")
        }
        func update() {
            guard ready, let web else { return }
            if loadedID != parent.documentID {
                loadedID = parent.documentID
                web.evaluateJavaScript("window.setDocument(\(Bpy.quote(parent.source)))")
            }
            if loadedMetadata != parent.metadata {
                loadedMetadata = parent.metadata
                web.evaluateJavaScript("window.api = \(parent.metadata.isEmpty ? "{}" : parent.metadata)")
            }
            if loadedFontSize != parent.fontSize {
                loadedFontSize = parent.fontSize
                web.evaluateJavaScript("window.setFontSize?.(\(parent.fontSize))")
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "ready" {
                ready = true; update()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-editor-smoke") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.web?.evaluateJavaScript(Self.smoke) { result, error in
                            print("[monaco-smoke] \(result ?? error?.localizedDescription ?? "no result")")
                        }
                    }
                }
                #endif
                return
            }
            guard let source = body["source"] as? String else { return }
            if kind == "change" { parent.onChange(source) }
            if kind == "run" { parent.onChange(source); parent.onRun(source) }
            // The error card's Copy. The page cannot reach the clipboard
            // itself: `navigator.clipboard` needs a secure origin, and a custom
            // scheme is not one.
            if kind == "copy" { UIPasteboard.general.string = source }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "blender-editor" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else { return }
            let path = url.path
            let data: Data?
            let mime: String
            if path == "/index.html" {
                data = Self.html.data(using: .utf8); mime = "text/html"
            } else {
                let root = Bundle.main.bundleURL.appendingPathComponent("Monaco").standardizedFileURL
                let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
                guard file.path.hasPrefix(root.path + "/") else {
                    urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
                }
                data = try? Data(contentsOf: file)
                mime = ["js": "text/javascript", "css": "text/css", "ttf": "font/ttf", "json": "application/json"][file.pathExtension] ?? "application/octet-stream"
            }
            guard let data else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        /// A trackpad scroll over the editor, handed to Monaco as a distance.
        /// The content follows the fingers, as it does everywhere else on iPad.
        @objc func handleTrackpadScroll(_ g: UIPanGestureRecognizer) {
            guard let web else { return }
            switch g.state {
            case .began, .changed:
                let t = g.translation(in: g.view)
                g.setTranslation(.zero, in: g.view)
                guard t != .zero else { return }
                web.evaluateJavaScript("window.nativeScroll?.(\(-t.x), \(-t.y))")
            case .ended:
                // The fingers' speed as they lift, for the glide after.
                let v = g.velocity(in: g.view)
                web.evaluateJavaScript("window.nativeScrollEnd?.(\(-v.x), \(-v.y))")
            default:
                web.evaluateJavaScript("window.nativeScrollEnd?.(0, 0)")
            }
        }

        /// Alongside WebKit's own recognisers, never instead of them.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
        #if DEBUG
        static let smoke = #"""
        (()=>{
          const original=editor.getValue();suppress=true;clearTimeout(timer);
          try {
            editor.setValue('import bpy as B\nB.ops.mesh.primitive_cu');
            const model=editor.getModel();
            const names=completionProvider.provideCompletionItems(model,model.getPositionAt(model.getValueLength())).suggestions.map(x=>x.label);
            editor.setValue(Array.from({length:20000},(_,i)=>'# line '+i).join('\n'));
            const start=performance.now();
            for(let i=0;i<200;i++)editor.executeEdits('smoke',[{range:new monaco.Range(1,1,1,1),text:'x'}]);
            return JSON.stringify({engine:'Monaco',lines:editor.getModel().getLineCount(),edits:200,milliseconds:performance.now()-start,cubeCompletion:names.includes('primitive_cube_add'),operators:Object.keys(api.operators||{}).length});
          } finally {editor.setValue(original);suppress=false;}
        })()
        """#
        #endif
        static let html = #"""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body,#editor{margin:0;width:100%;height:100%;overflow:hidden;background:#1e1e1e}#loading{color:#aaa;font:14px system-ui;padding:20px}.bk-error-line{background:rgba(255,107,94,0.16)}
        .bk-card{position:absolute;box-sizing:border-box;display:flex;flex-direction:column;gap:8px;padding:10px 12px 12px;background:#252526;border:1px solid rgba(255,107,94,0.45);border-radius:6px;color:#E6E6E6;font:12px -apple-system,system-ui,sans-serif;z-index:10}
        .bk-card-head{display:flex;align-items:center;gap:8px;min-height:28px}
        .bk-card-name{font-weight:600;color:#FF6B5E}
        .bk-card-where{color:rgba(230,230,230,0.55)}
        .bk-card-grow{flex:1}
        .bk-card-icon{width:30px;height:28px;display:flex;align-items:center;justify-content:center;padding:0;border:0;border-radius:4px;background:transparent;color:rgba(230,230,230,0.55)}
        .bk-card-icon:active{background:#3D3D3D}
        .bk-card-msg{font:12px/17px Menlo,Monaco,monospace;color:#D4D4D4;white-space:pre-wrap;word-break:break-word}
        .bk-card-frames{display:flex;align-items:center;flex-wrap:wrap;gap:6px}
        .bk-card-label{font-size:11px;color:rgba(230,230,230,0.55)}
        .bk-card-chip{height:26px;padding:0 9px;border:0;border-radius:4px;background:#3D3D3D;color:#E6E6E6;font:11px Menlo,Monaco,monospace}
        .bk-card-chip:active{background:#545454}</style>
        </head><body><div id="editor"><div id="loading">Loading editor…</div></div>
        <script src="vs/loader.js"></script><script>
        const send = (kind, source) => window.webkit.messageHandlers.editor.postMessage({kind,source});
        window.api = {}; let suppress = false, timer;
        require.config({paths:{vs:'vs'}});
        require(['vs/editor/editor.main'], function(exports) {
          window.monaco = exports?.m || window.monaco;
          document.getElementById('loading').remove();
          window.editor = monaco.editor.create(document.getElementById('editor'), {
            value:'', language:'python', theme:'vs-dark', automaticLayout:true,
            fontSize:14, lineHeight:22, minimap:{enabled:false}, wordWrap:'on',
            scrollBeyondLastLine:false, smoothScrolling:false, tabSize:4,
            folding:true, glyphMargin:false, lineNumbersMinChars:3,
            quickSuggestions:{other:true,comments:false,strings:false},
            wordBasedSuggestions:'off', suggestOnTriggerCharacters:true, acceptSuggestionOnEnter:'off',
            parameterHints:{enabled:true}, accessibilitySupport:'on',
            padding:{top:12,bottom:12}, renderLineHighlight:'line'
          });
          // Where the traceback said it went wrong.
          //
          // The line number is the single most useful thing a failed run
          // produces, and the console that carries it is on the other side of
          // the screen. A marker puts the message on the line itself, the
          // decoration makes the row findable without reading, and the card
          // under the line says what went wrong and how the run got there —
          // so the console is where to read more, not where to find out.
          const CARD_ICONS = {
            alert: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#FF6B5E" stroke-width="1.6" stroke-linecap="round"><circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8.6M8 11.2V11.3"/></svg>',
            copy: '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><rect x="5.2" y="5.2" width="8.6" height="8.6" rx="1.5"/><path d="M2.2 10.2V3.6C2.2 2.8 2.8 2.2 3.6 2.2H10.2"/></svg>',
            close: '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 4L12 12M12 4L4 12"/></svg>'
          };
          let card = null;
          function cardElement(tag, className, text) {
            const node = document.createElement(tag);
            if (className) node.className = className;
            if (text != null) node.textContent = text;
            return node;
          }
          function removeCard() {
            if (!card) return;
            const going = card; card = null;
            editor.changeViewZones(a => a.removeZone(going.zoneId));
            editor.removeOverlayWidget(going.widget);
          }
          // A view zone holds the space under the line and an overlay widget
          // holds the card, moved onto the zone as it scrolls: the pairing
          // Monaco's own peek view uses, because a zone's own node sits under
          // the text layer and cannot be tapped.
          function placeCard() {
            if (!card) return;
            const info = editor.getLayoutInfo();
            card.node.style.left = info.contentLeft + 'px';
            card.node.style.width = Math.max(220, info.contentWidth - info.verticalScrollbarWidth - 16) + 'px';
            const height = Math.ceil(card.node.getBoundingClientRect().height) + 14;
            if (height !== card.zone.heightInPx) {
              card.zone.heightInPx = height;
              const id = card.zoneId;
              editor.changeViewZones(a => a.layoutZone(id));
            }
          }
          function showCard(line, d) {
            removeCard();
            const model = editor.getModel();
            const frames = d.frames || [];
            const node = cardElement('div', 'bk-card');
            const head = cardElement('div', 'bk-card-head');
            const alert = cardElement('span');
            alert.style.display = 'flex';
            alert.innerHTML = CARD_ICONS.alert;
            const inner = frames[0];
            head.append(alert,
                        cardElement('span', 'bk-card-name', d.name || 'Error'),
                        cardElement('span', 'bk-card-where',
                                    (inner && inner.function ? 'in ' + inner.function + ', ' : '') + 'line ' + line),
                        cardElement('span', 'bk-card-grow'));
            const copy = cardElement('button', 'bk-card-icon');
            copy.innerHTML = CARD_ICONS.copy;
            copy.setAttribute('aria-label', 'Copy the error');
            copy.onclick = () => send('copy', d.traceback || '');
            const close = cardElement('button', 'bk-card-icon');
            close.innerHTML = CARD_ICONS.close;
            close.setAttribute('aria-label', 'Dismiss');
            close.onclick = removeCard;
            head.append(copy, close);
            node.append(head);
            if (d.message) node.append(cardElement('div', 'bk-card-msg', d.message));
            if (frames.length > 1) {
              const row = cardElement('div', 'bk-card-frames');
              row.append(cardElement('span', 'bk-card-label', 'Called from'));
              for (const f of frames.slice(1)) {
                const chip = cardElement('button', 'bk-card-chip', (f.function || 'line') + ' · line ' + f.line);
                chip.onclick = () => {
                  const target = Math.max(1, Math.min(f.line, model.getLineCount()));
                  editor.revealLineInCenter(target);
                  editor.setPosition({ lineNumber: target,
                                       column: model.getLineFirstNonWhitespaceColumn(target) || 1 });
                  editor.focus();
                };
                row.append(chip);
              }
              node.append(row);
            }
            const widget = { getId: () => 'bk.error.card', getDomNode: () => node, getPosition: () => null };
            const zone = { afterLineNumber: line, heightInPx: 0, domNode: document.createElement('div'),
                           onDomNodeTop: top => { node.style.top = (top + 6) + 'px'; } };
            card = { node, widget, zone, zoneId: null };
            editor.addOverlayWidget(widget);
            editor.changeViewZones(a => { card.zoneId = a.addZone(zone); });
            placeCard();
          }
          editor.onDidLayoutChange(placeCard);
          window.markError = d => {
            const model = editor.getModel(); if (!model) return;
            const line = Math.max(1, Math.min(d.line, model.getLineCount()));
            // From the first character of code rather than column 1: a
            // squiggle under the indentation points at nothing.
            const first = model.getLineFirstNonWhitespaceColumn(line) || 1;
            monaco.editor.setModelMarkers(model, 'run', [{
              severity: monaco.MarkerSeverity.Error,
              startLineNumber: line, endLineNumber: line,
              startColumn: first, endColumn: model.getLineMaxColumn(line),
              message: [d.name, d.message].filter(Boolean).join(': ') || 'Run failed here'
            }]);
            window.errorDecorations = editor.deltaDecorations(
              window.errorDecorations || [],
              [{ range: new monaco.Range(line, 1, line, 1),
                 options: { isWholeLine: true, className: 'bk-error-line' } }]);
            showCard(line, d);
            editor.revealLineInCenterIfOutsideViewport(line);
          };
          window.clearError = () => {
            removeCard();
            const model = editor.getModel(); if (!model) return;
            monaco.editor.setModelMarkers(model, 'run', []);
            window.errorDecorations = editor.deltaDecorations(window.errorDecorations || [], []);
          };
          window.setDocument = source => {
            clearTimeout(timer); suppress=true;
            const old=editor.getModel(); editor.setModel(monaco.editor.createModel(source,'python')); old?.dispose();
            // Both halves. Dropping the decorations alone left the squiggle
            // and the message from the previous script sitting on a line of
            // the new one — markers belong to the model, and this is a new
            // model that has never been run.
            window.errorDecorations = [];
            window.clearError?.();
            suppress=false;
          };
          editor.onDidChangeModelContent(() => {
            if(suppress)return;
            clearTimeout(timer); timer=setTimeout(()=>send('change',editor.getValue()),180);
          });
          editor.addAction({id:'run-python',label:'Run Python',keybindings:[monaco.KeyMod.CtrlCmd|monaco.KeyCode.KeyR],run:()=>send('run',editor.getValue())});
          // The app's menu commands run Monaco's own actions through here, so
          // Find or Toggle Comment from the menu bar is the editor's own.
          window.runEditorAction = id => {
            editor.focus();
            const action = editor.getAction(id);
            if (action) { action.run(); } else { editor.trigger('keyboard', id, null); }
          };
          // Text size, with the line height kept in proportion to it.
          window.setFontSize = size => {
            editor.updateOptions({ fontSize: size, lineHeight: Math.round(size * 22 / 14) });
          };
          // Trackpad scrolling forwarded by the app. When WebKit also delivers
          // wheel events for the gesture, those win and the forwarded distance
          // is dropped, so the editor never moves twice for one swipe.
          let lastWheel = 0, glide = null;
          editor.getDomNode().addEventListener('wheel', () => { lastWheel = performance.now(); },
                                               { capture: true, passive: true });
          const wheelIsLive = () => performance.now() - lastWheel < 200;
          const scrollEditorBy = (dx, dy) => editor.setScrollPosition({
            scrollLeft: editor.getScrollLeft() + dx, scrollTop: editor.getScrollTop() + dy });
          window.nativeScroll = (dx, dy) => {
            if (glide) { cancelAnimationFrame(glide); glide = null; }
            if (wheelIsLive()) return;
            scrollEditorBy(dx, dy);
          };
          // A short glide after the fingers lift, the way a scroll view coasts.
          window.nativeScrollEnd = (vx, vy) => {
            if (wheelIsLive()) return;
            let last = performance.now();
            const step = now => {
              const dt = Math.min((now - last) / 1000, 0.05); last = now;
              vx *= Math.pow(0.04, dt); vy *= Math.pow(0.04, dt);
              if (Math.abs(vx) < 25 && Math.abs(vy) < 25) { glide = null; return; }
              scrollEditorBy(vx * dt, vy * dt);
              glide = requestAnimationFrame(step);
            };
            glide = requestAnimationFrame(step);
          };
          const builtins = ['print','range','len','enumerate','zip','list','dict','set','tuple','str','int','float','bool','sum','min','max','sorted','abs','round','open'];
          const keywords = ['import','from','as','for','in','if','else','elif','while','def','return','class','True','False','None','with','try','except','finally','pass','break','continue'];
          function canonical(path,model) {
            const aliases={};
            for(const line of model.getLinesContent()) {
              let m=line.match(/^\s*import\s+bpy\s+as\s+(\w+)/); if(m)aliases[m[1]]='bpy';
              m=line.match(/^\s*from\s+bpy\s+import\s+(\w+)(?:\s+as\s+(\w+))?/); if(m)aliases[m[2]||m[1]]='bpy.'+m[1];
              m=line.match(/^\s*(\w+)\s*=\s*([\w.]+)\s*$/); if(m) {
                const parts=m[2].split('.');parts[0]=aliases[parts[0]]||parts[0]; aliases[m[1]]=parts.join('.');
              }
            }
            const parts=path.split('.');parts[0]=aliases[parts[0]]||parts[0];return parts.join('.');
          }
          function callContext(model,pos) {
            const before=model.getValueInRange({startLineNumber:Math.max(1,pos.lineNumber-12),startColumn:1,endLineNumber:pos.lineNumber,endColumn:pos.column});
            const m=before.match(/([\w.]+)\(([^()]*)$/);return m?{path:canonical(m[1],model),args:m[2]}:null;
          }
          window.completionProvider = {
            triggerCharacters:['.'],
            provideCompletionItems(model,pos) {
              const word=model.getWordUntilPosition(pos), range={startLineNumber:pos.lineNumber,endLineNumber:pos.lineNumber,startColumn:word.startColumn,endColumn:word.endColumn};
              const line=model.getLineContent(pos.lineNumber).slice(0,pos.column-1);
              const match=line.match(/([\w.]+)\.[\w]*$/); const members=api.members||{}, ops=api.operators||{};
              const found=new Map();
              function add(label,kind,detail='',insertText=label){if(!found.has(label))found.set(label,{label,kind,detail,insertText,range});}
              const K=monaco.languages.CompletionItemKind;
              if(match) {
                const base=canonical(match[1],model);
                for(const n of members[base]||[])add(n,K.Property,base);
                for(const path of Object.keys(ops))if(path.startsWith(base+'.')){
                  const rest=path.slice(base.length+1), n=rest.split('.')[0];add(n,rest.includes('.')?K.Module:K.Function,ops[path].description);
                }
              } else {
                for(const n of keywords)add(n,K.Keyword);
                for(const n of builtins)add(n,K.Function,'Python built-in');
                add('bpy',K.Module,'Blender Python API');
                for(const line of model.getLinesContent()) {
                  const m=line.match(/^\s*(?:def\s+|class\s+)?([A-Za-z_]\w*)\s*(?:=|\()/);if(m)add(m[1],K.Variable,'In this script');
                }
                const ctx=callContext(model,pos), info=ctx&&ops[ctx.path];
                if(info)for(const n of info.parameters||[])if(!new RegExp('\\b'+n+'\\s*=').test(ctx.args))add(n+'=',K.Property,ctx.path);
              }
              return {suggestions:[...found.values()]};
            }
          };
          monaco.languages.registerCompletionItemProvider('python',window.completionProvider);
          monaco.languages.registerSignatureHelpProvider('python',{
            signatureHelpTriggerCharacters:['(',','],
            provideSignatureHelp(model,pos){const c=callContext(model,pos),i=c&&(api.operators||{})[c.path];if(!i)return null;
              return {value:{signatures:[{label:c.path+'('+i.parameters.join(', ')+')',documentation:i.description,parameters:i.parameters.map(label=>({label}))}],activeSignature:0,activeParameter:Math.min(c.args.split(',').length-1,Math.max(0,i.parameters.length-1))},dispose(){}};
            }
          });
          monaco.languages.registerHoverProvider('python',{
            provideHover(model,pos){const line=model.getLineContent(pos.lineNumber);const matches=line.matchAll(/[A-Za-z_][\w.]*/g);
              for(const m of matches)if(pos.column-1>=m.index&&pos.column-1<=m.index+m[0].length){const path=canonical(m[0],model),i=(api.operators||{})[path];if(i)return {contents:[{value:'**'+path+'**'},{value:i.description}]};}return null;
            }
          });
          send('ready','');
        }, function(error){document.getElementById('loading').textContent='Editor failed to load: '+error;});
        </script></body></html>
        """#
    }
}
