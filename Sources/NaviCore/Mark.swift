import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// Something the user marked on screen in Mark mode, tidied into a clean
/// shape: a rough loop becomes a ring, a flat stroke an underline, a stroke
/// with direction an arrow, a tap a dot. Clean shapes say exactly what was
/// meant, to the user and to Claude. In the shell's global points (AppKit's on
/// the Mac); drawing it and burning it into a screenshot are the shell's job.
public struct Mark: Equatable {
    public enum Kind: String { case ring, underline, arrow, point, scribble }

    public let kind: Kind
    /// The area the mark covers (a ring's ellipse box; a line's bounds).
    public let rect: CGRect
    /// For lines and arrows: where it starts and ends. For a point: the spot.
    public let from: CGPoint
    public let to: CGPoint

    public init(kind: Kind, rect: CGRect, from: CGPoint, to: CGPoint) {
        (self.kind, self.rect, self.from, self.to) = (kind, rect, from, to)
    }

    /// How it's named in the question box ("1 circled").
    public var verb: String {
        switch kind {
        case .ring: return "circled"
        case .underline: return "underlined"
        case .arrow: return "arrow"
        case .point: return "tapped"
        case .scribble: return "scribbled"
        }
    }

    /// Reads a raw stroke. Nil for nothing at all.
    public static func tidy(_ stroke: [CGPoint]) -> Mark? {
        guard let first = stroke.first, let last = stroke.last else { return nil }
        let xs = stroke.map(\.x), ys = stroke.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let span = max(box.width, box.height)
        let length = zip(stroke, stroke.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let gap = hypot(last.x - first.x, last.y - first.y)
        if span < 10 {
            return Mark(kind: .point, rect: CGRect(x: first.x - 10, y: first.y - 10, width: 20, height: 20), from: first, to: first)
        }
        if gap < span * 0.35 && length > span * 1.8 && stroke.count > 6 {
            return Mark(kind: .ring, rect: box.insetBy(dx: -6, dy: -6), from: first, to: last)
        }
        if length > span * 3 {
            return Mark(kind: .scribble, rect: box.insetBy(dx: -4, dy: -4), from: first, to: last)
        }
        let straight = gap / max(length, 1)
        let flat = abs(last.y - first.y) < span * 0.25
        // A flat, straight stroke is an underline; anything else that goes somewhere is an arrow.
        if flat && straight > 0.9 {
            return Mark(kind: .underline, rect: box.insetBy(dx: 0, dy: -14), from: first, to: last)
        }
        return Mark(kind: .arrow, rect: box.insetBy(dx: -8, dy: -8), from: first, to: last)
    }

    /// One line for Claude, in screenshot pixels: `pixel` converts a global
    /// point into the screenshot's pixels.
    public func describe(_ n: Int, pixel: (CGPoint) -> CGPoint, elements: [String]) -> String {
        let a = pixel(from), b = pixel(to)
        let lo = pixel(CGPoint(x: rect.minX, y: rect.maxY)), hi = pixel(CGPoint(x: rect.maxX, y: rect.minY))
        let box = "(\(Int(lo.x)), \(Int(lo.y)))–(\(Int(hi.x)), \(Int(hi.y)))"
        var s: String
        switch kind {
        case .ring: s = "\(n): circled the area \(box)"
        case .scribble: s = "\(n): scribbled over the area \(box)"
        case .underline: s = "\(n): underlined from (\(Int(a.x)), \(Int(a.y))) to (\(Int(b.x)), \(Int(b.y)))"
        case .arrow: s = "\(n): drew an arrow from (\(Int(a.x)), \(Int(a.y))) to (\(Int(b.x)), \(Int(b.y)))"
        case .point: s = "\(n): tapped (\(Int(a.x)), \(Int(a.y)))"
        }
        if !elements.isEmpty { s += "; inside it: " + elements.joined(separator: "; ") }
        return s
    }

    /// Where its number badge sits (global points).
    public var badge: CGPoint {
        switch kind {
        case .ring, .scribble: return CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - rect.height * 0.08)
        case .underline, .arrow: return CGPoint(x: to.x + 10, y: to.y + 12)
        case .point: return CGPoint(x: from.x + 12, y: from.y + 12)
        }
    }
}
