import AppKit

/// A small Navi pane you drag into a permissions list in System Settings. macOS
/// won't add Navi to the Screen Recording list by itself (asked from the
/// background it refuses silently, and its prompt only points at Settings), but
/// it takes an app dropped onto the list. The tile carries Navi.app itself, as
/// dragging it from Finder would. It sits beside the System Settings window.
final class DragTile: NSPanel {
    private static var shown: DragTile?
    /// Called once the tile has been dropped somewhere that took it.
    fileprivate static var onDrop: (() -> Void)?
    static var frame: NSRect? { shown?.frame }

    /// Shows the tile just above `pane` (the setup pane), or beside System Settings.
    static func show(above pane: NSRect? = nil, onDrop: (() -> Void)? = nil) {
        let tile = shown ?? DragTile()
        shown = tile
        Self.onDrop = onDrop
        tile.orderFrontRegardless()
        if let pane { follow(above: pane); return }
        tile.place()
        // Settings takes a moment to open at the right page: follow it as it lands.
        for delay in [0.4, 1.0, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tile.place() } }
    }

    /// Keeps the tile sitting on top of the setup pane as it moves.
    static func follow(above pane: NSRect) {
        guard let tile = shown else { return }
        let o = NSPoint(x: pane.minX + (pane.width - tile.frame.width) / 2, y: pane.maxY + 10)
        if tile.frame.origin != o { tile.setFrameOrigin(o) }
    }

    static func hide() {
        shown?.orderOut(nil)
        shown = nil
        onDrop = nil
    }

    private init() {
        let size = NSSize(width: 288, height: 58)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        let (outer, content) = Glass.make(size: size, radius: 16)
        content.layer?.backgroundColor = Look.Pane.fill.withAlphaComponent(0.985).cgColor
        let grip = Grip(frame: NSRect(origin: .zero, size: size))
        content.addSubview(grip)
        contentView = outer
    }

    /// To the right of the System Settings window, level with its top; to its left
    /// if there's no room; near the top right of the screen if it isn't open.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        var origin = NSPoint(x: screen.visibleFrame.maxX - frame.width - 24, y: screen.visibleFrame.maxY - frame.height - 24)
        if let s = Self.settingsFrame() {
            let right = s.maxX + 14, left = s.minX - 14 - frame.width
            let x = right + frame.width <= screen.visibleFrame.maxX ? right : max(screen.visibleFrame.minX + 8, left)
            origin = NSPoint(x: x, y: s.maxY - frame.height - 56)
        }
        setFrameOrigin(origin)
    }

    /// System Settings' window in AppKit coordinates. Window bounds and owners are
    /// readable without Screen Recording (only titles need it).
    static func settingsFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let info = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else { return nil }
        let r = NSRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

/// The tile's face, and the drag: Navi's icon, its name and what to do.
private final class Grip: NSView, NSDraggingSource {
    private let icon = NSApp.applicationIconImage ?? NSImage()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView(image: icon)
        image.frame = NSRect(x: 12, y: 11, width: 36, height: 36)
        addSubview(image)
        let name = NSTextField(labelWithString: "Navi")
        name.font = Look.ui(13.5, .semibold)
        name.textColor = Look.warmWhite
        name.frame = NSRect(x: 58, y: 29, width: 160, height: 18)
        addSubview(name)
        let hint = NSTextField(labelWithString: "Drag me into the list")
        hint.font = Look.ui(11.5)
        hint.textColor = Look.softText
        hint.frame = NSRect(x: 58, y: 12, width: 170, height: 16)
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
        trace("Setup: dragging Navi.app from the tile.")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        trace("Setup: tile dropped (\(operation.isEmpty ? "not taken" : "taken")).")
        if !operation.isEmpty { DragTile.onDrop?() }
    }
}
