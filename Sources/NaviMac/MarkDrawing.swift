import AppKit

/// Drawing a Mark on the Mac: its clean path, the numbered marks burnt into a
/// screenshot, and a close-up. The mark itself is NaviCore's.
extension Mark {
    /// The clean shape, in whatever coordinates `map` converts to.
    func path(_ map: (NSPoint) -> CGPoint) -> CGPath {
        let p = CGMutablePath()
        switch kind {
        case .ring, .scribble:
            let a = map(NSPoint(x: rect.minX, y: rect.minY)), b = map(NSPoint(x: rect.maxX, y: rect.maxY))
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            if kind == .ring { p.addEllipse(in: r) } else { p.addRoundedRect(in: r, cornerWidth: 8, cornerHeight: 8) }
        case .underline, .arrow:
            let a = map(from), b = map(to)
            p.move(to: a)
            p.addLine(to: b)
            if kind == .arrow {
                let ang = atan2(b.y - a.y, b.x - a.x), len: CGFloat = 14
                p.move(to: CGPoint(x: b.x - len * cos(ang - 0.5), y: b.y - len * sin(ang - 0.5)))
                p.addLine(to: b)
                p.addLine(to: CGPoint(x: b.x - len * cos(ang + 0.5), y: b.y - len * sin(ang + 0.5)))
            }
        case .point:
            let c = map(from)
            p.addEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
        }
        return p
    }

    /// One line for Claude, in this screenshot's pixels.
    func describe(_ n: Int, on shot: ScreenShot, elements: [String]) -> String {
        describe(n, pixel: shot.pixel, elements: elements)
    }

    /// The marks drawn into a screenshot, numbered, in the user's magenta.
    static func burn(_ marks: [Mark], into shot: ScreenShot) -> CGImage {
        let w = shot.image.width, h = shot.image.height
        guard !marks.isEmpty, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return shot.image }
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let map: (NSPoint) -> CGPoint = { p in let q = shot.pixel(p); return CGPoint(x: q.x, y: CGFloat(h) - q.y) }
        let magenta = Look.userMark.withAlphaComponent(0.95).cgColor
        for (i, m) in marks.enumerated() {
            ctx.addPath(m.path(map))
            if m.kind == .point { ctx.setFillColor(magenta); ctx.fillPath() } else {
                ctx.setStrokeColor(magenta)
                ctx.setLineWidth(max(3, 3.5 / shot.scale))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
            // The number, so "1" and "2" can be talked about.
            let c = map(m.badge), r = max(9, 9 / shot.scale)
            ctx.setFillColor(magenta)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let label = NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: r * 1.2), .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(label)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: c.x - bounds.width / 2, y: c.y - bounds.height / 2)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage() ?? shot.image
    }

    /// A close-up of the mark, so small text and icons are readable (about 2.5× the mark, at most 600 px).
    func closeUp(from shot: ScreenShot) -> CGImage? {
        let lo = shot.pixel(NSPoint(x: rect.minX, y: rect.maxY)), hi = shot.pixel(NSPoint(x: rect.maxX, y: rect.minY))
        let w = max(hi.x - lo.x, 80) * 1.6, h = max(hi.y - lo.y, 60) * 1.6
        let c = CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2)
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: min(w, 600), height: min(h, 600))
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard !r.isEmpty else { return nil }
        return shot.image.cropping(to: r.integral)
    }
}
