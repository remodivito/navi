import AppKit

/// Records the pointer path while the hotkey is held. Polls the mouse
/// position, so it needs no permissions.
final class GestureTracker {
    private(set) var points: [NSPoint] = []   // AppKit global coordinates
    private var timer: Timer?
    var onUpdate: (([NSPoint]) -> Void)?

    func start() {
        points = [NSEvent.mouseLocation]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if let last = self.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            self.points.append(p)
            self.onUpdate?(self.points)
        }
    }

    @discardableResult
    func stop() -> [NSPoint] {
        timer?.invalidate()
        timer = nil
        return points
    }

    static func length(_ pts: [NSPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Small jiggles while holding the key aren't a gesture.
    static func isMeaningful(_ pts: [NSPoint]) -> Bool {
        pts.count > 3 && length(pts) > 40
    }

    /// The screenshot most of the gesture landed on.
    static func shot(for pts: [NSPoint], in shots: [ScreenShot]) -> ScreenShot? {
        shots.max { a, b in
            pts.filter { NSMouseInRect($0, a.screen.frame, false) }.count
                < pts.filter { NSMouseInRect($0, b.screen.frame, false) }.count
        }
    }

    /// Plain-language summary of the gesture, in screenshot pixels.
    static func describe(_ pts: [NSPoint], on shot: ScreenShot) -> String {
        let px = pts.map { shot.pixel($0) }
        let xs = px.map(\.x), ys = px.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let span = max(box.width, box.height, 1)
        let first = px.first!, last = px.last!
        let gap = hypot(last.x - first.x, last.y - first.y)
        let len = length(pts) / shot.scale

        let what: String
        if gap < span * 0.35 && len > span * 1.8 {
            what = "circled the area centred at (\(Int(box.midX)), \(Int(box.midY))), about \(Int(box.width))×\(Int(box.height)) px"
        } else if len > span * 3 {
            what = "scribbled over the area around (\(Int(box.midX)), \(Int(box.midY)))"
        } else {
            what = "drew a line from (\(Int(first.x)), \(Int(first.y))) to (\(Int(last.x)), \(Int(last.y)))"
        }
        return "While asking, the user \(what) on screen \(shot.index) (\(region(box, shot.pixelSize))). "
            + "It is drawn in magenta on that screenshot; it is their pointer gesture, not part of the UI. "
            + "Treat it as exactly what they are pointing at."
    }

    private static func region(_ box: CGRect, _ size: CGSize) -> String {
        let col = ["left", "centre", "right"][min(2, Int(box.midX / size.width * 3))]
        let row = ["top", "middle", "bottom"][min(2, Int(box.midY / size.height * 3))]
        return row == "middle" && col == "centre" ? "centre of the screen" : "\(row)-\(col) of the screen"
    }
}
