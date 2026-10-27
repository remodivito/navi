import AppKit
import QuartzCore

extension Formula {
    /// Splits a line of working into terms: numbers and letters with their
    /// powers stay together ("a²", "16", "√25"); operators stand alone.
    static func tokens(_ text: String, font: NSFont) -> [Token] {
        let pattern = try! NSRegularExpression(pattern: #"[√]?[\p{L}\p{N}.²³⁴⁵⁶⁷⁸⁹⁰¹]+|\S"#)
        let ns = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let prefix = ns.substring(to: m.range.location)
            let piece = ns.substring(with: m.range)
            return Token(text: piece, x: (prefix as NSString).size(withAttributes: attrs).width,
                         width: (piece as NSString).size(withAttributes: attrs).width)
        }
    }

    /// Smootherstep, Manim's default "smooth" (design-tokens.json, motion.formula).
    static let smooth = Look.curve(Tokens.shared.motion.formula.curve)
}
