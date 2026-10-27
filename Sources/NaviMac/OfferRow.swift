import AppKit
import UniformTypeIdentifiers

/// A file Navi offers to download, inside the caption under the sentence that
/// offers it (or in the notch, when the answer lives there):
///
///     ┌──┐ open_duck_mini_v2.xml
///     │XML│ 38 KB · github.com
///     └──┘
///     ▂▂▂▂▂▂▂▂▂▂ (while it downloads)
///                    ( Not now )  ( Download )
final class OfferRow: NSView {
    static let height: CGFloat = 78
    static let minWidth: CGFloat = 250

    enum Phase { case asking, downloading(Double), saved, failed(String) }

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = CALayer()
    private let fill = CALayer()
    private let no = InkButton("Not now", target: nil, action: nil)
    private let yes = InkButton("Download", role: .primary, target: nil, action: nil)
    private var source = ""

    var onChoice: ((Bool) -> Void)?
    private(set) var phase = Phase.asking

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        name.font = Look.ui(12.5, .semibold)
        name.textColor = Look.warmWhite
        name.lineBreakMode = .byTruncatingMiddle
        detail.font = Look.ui(11)
        detail.textColor = Look.softText
        bar.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        bar.cornerRadius = 1.5
        fill.backgroundColor = Buddy.lamp.cgColor
        fill.shadowColor = NSColor(calibratedRed: 1, green: 0.84, blue: 0.59, alpha: 1).cgColor
        fill.shadowOpacity = 0.8
        fill.shadowRadius = 3
        fill.shadowOffset = .zero
        bar.addSublayer(fill)
        layer?.addSublayer(bar)
        no.target = self
        no.action = #selector(say(_:))
        yes.target = self
        yes.action = #selector(say(_:))
        [icon, name, detail, no, yes].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a fresh offer: the file's name, its size if known, and where it's from.
    func show(file: String, size: Int64?, from host: String) {
        source = host
        name.stringValue = file
        let ext = (file as NSString).pathExtension
        icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        set(.asking, size: size)
    }

    func set(_ p: Phase, size: Int64? = nil) {
        phase = p
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch p {
        case .asking:
            detail.stringValue = [sizeText, source].compactMap { $0 }.joined(separator: " · ")
            no.isHidden = false; yes.isHidden = false
            no.title = "Not now"; yes.title = "Download"
            bar.isHidden = true
        case .downloading(let f):
            detail.stringValue = "Downloading from \(source)…"
            no.isHidden = true; yes.isHidden = true
            bar.isHidden = false
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            fill.frame = CGRect(x: 0, y: 0, width: bar.bounds.width * max(0.04, min(1, f)), height: bar.bounds.height)
            CATransaction.commit()
        case .saved:
            detail.stringValue = "Saved to Downloads"
            bar.isHidden = true
            no.isHidden = true
            yes.isHidden = true
        case .failed(let why):
            detail.stringValue = why
            bar.isHidden = true
            no.isHidden = true; yes.isHidden = true
        }
        needsLayout = true
    }

    @objc private func say(_ sender: NSButton) {
        onChoice?(sender === yes)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, top = bounds.height
        icon.frame = NSRect(x: 0, y: top - 40, width: 32, height: 32)
        name.frame = NSRect(x: 40, y: top - 24, width: w - 40, height: 17)
        detail.frame = NSRect(x: 40, y: top - 41, width: w - 40, height: 15)
        bar.frame = CGRect(x: 0, y: 12, width: w, height: 3)
        if case .downloading(let f) = phase { fill.frame = CGRect(x: 0, y: 0, width: w * max(0.04, min(1, f)), height: 3) }
        let yw = yes.intrinsicContentSize.width + 22, nw = no.intrinsicContentSize.width + 22
        yes.frame = NSRect(x: w - yw, y: 0, width: yw, height: 26)
        no.frame = NSRect(x: w - yw - 8 - nw, y: 0, width: nw, height: 26)
    }
}
