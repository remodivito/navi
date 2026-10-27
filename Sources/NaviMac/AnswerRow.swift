import AppKit

/// The caption's panel: it only takes the keys while a practice answer is being typed,
/// and never brings Navi's app forward (it's non-activating), so the app being learned
/// stays in front.
final class AnswerPanel: NSPanel {
    override var canBecomeKey: Bool { !ignoresMouseEvents }
}

/// A practice question's answer line, inside the caption under the question:
/// a field to type into and two ways out for when you're stuck.
///
///     YOUR TURN
///     Legs of 5 and 12. What's c?
///     ─────────────────────────────
///     Your answer                ↩
///     ( Hint )  ( Show me )
final class AnswerRow: NSView, NSTextFieldDelegate {
    typealias Help = Shell.AnswerHelp

    static let height: CGFloat = 64
    static let minWidth: CGFloat = 220

    let field = NSTextField()
    private let rule = NSView()
    private let enter = NSTextField(labelWithString: "↩")
    private let hint = AnswerRow.chip("Hint")
    private let showMe = AnswerRow.chip("Show me")

    var onSubmit: ((String) -> Void)?
    var onHelp: ((Help) -> Void)?
    var onCancel: (() -> Void)?

    /// The lamp colour of the "Your turn" kicker.
    private static let lamp = NSColor(calibratedRed: 0.94, green: 0.67, blue: 0.37, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Look.warmWhite.withAlphaComponent(0.16).cgColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Look.ui(14, .medium)
        field.textColor = Look.warmWhite
        field.placeholderAttributedString = NSAttributedString(string: "Your answer", attributes: [
            .font: Look.ui(14, .medium), .foregroundColor: Look.warmWhite.withAlphaComponent(0.38)])
        field.delegate = self
        field.cell?.isScrollable = true
        enter.font = Look.ui(12, .medium)
        enter.textColor = Look.warmWhite.withAlphaComponent(0.4)
        hint.target = self
        hint.action = #selector(askHint)
        showMe.target = self
        showMe.action = #selector(askShowMe)
        [rule, field, enter, hint, showMe].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() { field.stringValue = "" }

    override func layout() {
        super.layout()
        let w = bounds.width
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: w, height: 0.5)
        field.frame = NSRect(x: 0, y: bounds.height - 30, width: w - 22, height: 20)
        enter.frame = NSRect(x: w - 14, y: bounds.height - 29, width: 14, height: 16)
        let hw = hint.intrinsicContentSize.width + 18, sw = showMe.intrinsicContentSize.width + 18
        hint.frame = NSRect(x: 0, y: 2, width: hw, height: 22)
        showMe.frame = NSRect(x: hw + 6, y: 2, width: sw, height: 22)
    }

    /// The lamp-coloured underline shows where the answer goes.
    override func draw(_ dirtyRect: NSRect) {
        Self.lamp.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: field.frame.minY - 3, width: min(140, bounds.width - 22), height: 1.5).fill()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onSubmit?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    @objc private func askHint() { onHelp?(.hint) }
    @objc private func askShowMe() { onHelp?(.showMe) }

    private static func chip(_ title: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 11
        b.layer?.borderWidth = 0.5
        b.layer?.borderColor = Look.warmWhite.withAlphaComponent(0.3).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Look.ui(11.5, .medium), .foregroundColor: Look.warmWhite.withAlphaComponent(0.78)])
        return b
    }
}
