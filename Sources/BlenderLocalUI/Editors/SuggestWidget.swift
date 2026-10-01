import UIKit
import SwiftUI

/// Monaco's suggest widget: the list that appears under the caret as you type.
///
/// There was already a completion strip above the keyboard, and it is still
/// there — it is the better place for punctuation, and on a phone it is the
/// only place there is room. But a strip can only show a handful of labels in
/// one row, and it shows them a long way from the word being typed. Monaco puts
/// the list *at the caret*, tall rather than wide, so the eye does not leave
/// the code and the list can be as long as it needs.
///
/// UIKit rather than SwiftUI because it has to be positioned from
/// `caretRect(for:)` and live inside the text view's own coordinate space,
/// which is where the caret is.
final class SuggestWidget: UIView {

    /// What a candidate is, in Monaco's vocabulary: the icon says what kind of
    /// thing it is before the name is read.
    enum Kind {
        case keyword, builtin, module, operatorPath, word

        var symbol: String {
            switch self {
            case .keyword:      return "k"
            case .builtin:      return "f"
            case .module:       return "m"
            case .operatorPath: return "op"
            case .word:         return "w"
            }
        }

        var colour: Color {
            switch self {
            case .keyword:      return Color(hex: 0xC792EA)
            case .builtin:      return Color(hex: 0x82AAFF)
            case .module:       return Color(hex: 0x89DDFF)
            case .operatorPath: return BTheme.active
            case .word:         return BTheme.textDim
            }
        }
    }

    static let rowHeight: CGFloat = 26
    static let maximumRows = 8

    private(set) var candidates: [PythonCompletion.Candidate] = []
    private(set) var selection = 0
    private weak var target: UITextView?
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    var isShowing: Bool { !isHidden && !candidates.isEmpty }

    init(target: UITextView) {
        self.target = target
        super.init(frame: .zero)
        backgroundColor = UIColor(BTheme.menuBack)
        layer.borderColor = UIColor(BTheme.outline).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = BTheme.Metric.corner
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        isHidden = true

        stack.axis = .vertical
        stack.spacing = 0
        scroll.showsVerticalScrollIndicator = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: what to show

    func show(_ found: [PythonCompletion.Candidate]) {
        // One candidate that is already exactly what has been typed is not a
        // suggestion, it is an echo. Monaco hides the widget in that case too.
        guard let target, !found.isEmpty else { return dismiss() }
        let (_, partial) = PythonCompletion.context(in: target.text,
                                                    caret: target.selectedRange.location)
        if found.count == 1, found[0].insert == partial { return dismiss() }
        // Nothing typed yet and nothing to narrow by: the strip covers that
        // case, and a list of everything under the caret is in the way.
        guard !partial.isEmpty || found.count <= Self.maximumRows else { return dismiss() }

        candidates = found
        selection = 0
        rebuild()
        isHidden = false
        position()
        // Again after the run loop turns. The first call happens while the
        // editor is still being configured, when the text view's own layout
        // may not have settled and the caret has nowhere to be.
        DispatchQueue.main.async { [weak self] in self?.position() }
    }

    func dismiss() {
        isHidden = true
        candidates = []
    }

    /// Arrow keys and Tab/Return, as Monaco has them.
    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        selection = (selection + delta + candidates.count) % candidates.count
        rebuild()
        scrollToSelection()
    }

    @discardableResult
    func acceptSelected() -> Bool {
        guard isShowing, selection < candidates.count else { return false }
        insert(candidates[selection])
        return true
    }

    // MARK: doing it

    private func insert(_ candidate: PythonCompletion.Candidate) {
        guard let target else { return }
        let caret = target.selectedRange.location
        let (_, partial) = PythonCompletion.context(in: target.text, caret: caret)
        // Replace what has been typed of the word rather than appending to it,
        // which is what the strip does and what Monaco does.
        if !partial.isEmpty {
            let start = caret - (partial as NSString).length
            target.selectedRange = NSRange(location: start, length: (partial as NSString).length)
        }
        target.insertText(candidate.insert + (candidate.callable ? "()" : ""))
        if candidate.callable {
            let back = target.selectedRange.location - 1
            if back >= 0 { target.selectedRange = NSRange(location: back, length: 0) }
        }
        UIDevice.current.playInputClick()
        dismiss()
    }

    @objc private func rowTapped(_ sender: UIButton) {
        guard sender.tag < candidates.count else { return }
        insert(candidates[sender.tag])
    }

    // MARK: drawing itself

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, candidate) in candidates.enumerated() {
            stack.addArrangedSubview(row(candidate, index: i))
        }
        let rows = min(candidates.count, Self.maximumRows)
        frame.size = CGSize(width: 240, height: CGFloat(rows) * Self.rowHeight + 6)
    }

    private func row(_ candidate: PythonCompletion.Candidate, index: Int) -> UIView {
        let button = UIButton(type: .system)
        button.tag = index
        button.addTarget(self, action: #selector(rowTapped), for: .touchUpInside)
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = index == selection
            ? UIColor(BTheme.select).withAlphaComponent(0.28) : .clear
        button.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true

        let kind = Self.kind(of: candidate)
        let text = NSMutableAttributedString(
            string: kind.symbol.padding(toLength: 3, withPad: " ", startingAt: 0),
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor(kind.colour),
            ])
        text.append(NSAttributedString(string: candidate.label, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor(BTheme.text),
        ]))
        button.setAttributedTitle(text, for: .normal)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return button
    }

    static func kind(of candidate: PythonCompletion.Candidate) -> Kind {
        if candidate.insert.contains(".") { return .operatorPath }
        if PythonWords.keywords.contains(candidate.insert) { return .keyword }
        if PythonWords.builtins.contains(candidate.insert) { return .builtin }
        if candidate.callable { return .builtin }
        return .word
    }

    /// Under the caret, or above it when there is no room below — which on an
    /// iPad with the keyboard up is most of the time near the bottom.
    private func position() {
        guard let target else { return }
        // From the layout, not from `caretRect(for:)` — see the note on
        // `caretRect(atCharacter:)`. The list has to land under the caret even
        // when the editor has not been tapped into yet.
        let fromLayout = (target as? LineNumberTextView)?
            .caretRect(atCharacter: target.selectedRange.location)
        let caret = fromLayout
            ?? target.selectedTextRange.map { target.caretRect(for: $0.end) }
            ?? .zero
        guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret != .zero else { return }

        var origin = CGPoint(x: caret.maxX, y: caret.maxY + 4)
        let visibleBottom = target.contentOffset.y + target.bounds.height
            - target.adjustedContentInset.bottom
        if origin.y + frame.height > visibleBottom {
            origin.y = caret.minY - frame.height - 4
        }
        origin.x = min(origin.x, target.contentOffset.x + target.bounds.width - frame.width - 8)
        origin.x = max(origin.x, target.contentOffset.x + 4)
        frame.origin = origin
    }

    private func scrollToSelection() {
        let y = CGFloat(selection) * Self.rowHeight
        scroll.scrollRectToVisible(CGRect(x: 0, y: y, width: 1, height: Self.rowHeight),
                                   animated: false)
    }
}
