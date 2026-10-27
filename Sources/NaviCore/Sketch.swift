import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// Turns shapes into point lists, optionally with a hand-drawn wobble.
public enum Sketch {
    /// Points along the shape, roughly every `step` points.
    public static func polyline(_ kind: ShapeKind, _ p: [CGPoint], sketchy: Bool, step: CGFloat = 6) -> [CGPoint] {
        switch kind {
        case .circle:
            let r = max(hypot(p[1].x - p[0].x, p[1].y - p[0].y), 12)
            // A sketched ring overshoots its start a little, like a pen loop.
            let sweep = sketchy ? 2 * CGFloat.pi + 0.45 : 2 * CGFloat.pi
            let start = sketchy ? CGFloat(seed(p) % 628) / 100 : 0
            let n = max(24, Int(sweep * r / step))
            return (0...n).map { i in
                let a = start + sweep * CGFloat(i) / CGFloat(n)
                let wobble: CGFloat = sketchy ? 1 + 0.035 * sin(3 * a + start) : 1
                return CGPoint(x: p[0].x + r * wobble * cos(a), y: p[0].y + r * 0.97 * wobble * sin(a))
            }
        case .line, .arrow:
            return resample(p, step: step)
        case .polygon:
            return resample(p + [p[0]], step: step)
        case .curve:
            return resample(curvePoints(p), step: step)
        }
    }

    /// Smooth wobble across the line, so it looks drawn by hand rather than random.
    public static func jitter(_ pts: [CGPoint], seed s: Int, amount: CGFloat = 1.6) -> [CGPoint] {
        let phase = CGFloat(s % 1000) / 100
        return pts.enumerated().map { i, p in
            let t = CGFloat(i)
            return CGPoint(x: p.x + amount * (sin(t * 0.37 + phase) + 0.5 * sin(t * 0.91 + 2 * phase)),
                           y: p.y + amount * (cos(t * 0.41 + 2 * phase) + 0.5 * sin(t * 0.83 + phase)))
        }
    }

    public static func seed(_ pts: [CGPoint]) -> Int {
        abs(pts.reduce(17) { $0 &* 31 &+ Int($1.x) &* 7 &+ Int($1.y) })
    }

    /// Smooth curve through the points (quadratics using midpoints as anchors);
    /// two points get a gentle sideways bow so they still read as a curve.
    private static func curvePoints(_ p: [CGPoint]) -> [CGPoint] {
        func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> [CGPoint] {
            (1...16).map { i -> CGPoint in
                let t = CGFloat(i) / 16, u = 1 - t
                // Spelled out in steps: one expression is too slow for the Linux compiler.
                let uu = u * u, ut = 2 * u * t, tt = t * t
                let x = uu * a.x + ut * c.x + tt * b.x
                let y = uu * a.y + ut * c.y + tt * b.y
                return CGPoint(x: x, y: y)
            }
        }
        if p.count == 2 {
            let mid = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
            let dx = p[1].x - p[0].x, dy = p[1].y - p[0].y
            return [p[0]] + quad(p[0], CGPoint(x: mid.x - dy * 0.25, y: mid.y + dx * 0.25), p[1])
        }
        var out = [p[0]]
        var from = p[0]
        for i in 1..<(p.count - 1) {
            let to = i == p.count - 2 ? p[i + 1] : CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
            out += quad(from, p[i], to)
            from = to
        }
        return out
    }

    private static func resample(_ p: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard p.count > 1 else { return p }
        var out = [p[0]]
        for (a, b) in zip(p, p.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }
}
