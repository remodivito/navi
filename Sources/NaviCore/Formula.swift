import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// Formulas that transform in place:
/// when Navi writes the next step of working where the last one is, the
/// terms that carry over slide to their new places, a term whose value
/// changes crossfades where it stands (a² → 3² → 9), and terms that combine
/// fold into what they become (9 + 16 → 25). Manim's TransformMatchingTex,
/// done with the pen's colours and timing. Measuring terms in a font and
/// animating them is the shell's job (FormulaMac.swift on the Mac).
public enum Formula {
    public struct Token: Equatable {
        public let text: String
        /// Left edge and width within the line, in points.
        public let x: CGFloat
        public let width: CGFloat

        public init(text: String, x: CGFloat, width: CGFloat) { (self.text, self.x, self.width) = (text, x, width) }
    }

    /// What happens to each term between two lines.
    public enum Step: Equatable {
        case move(from: Int, to: Int)            // the same term, sliding to its new place
        case change(from: Int, to: Int)          // same slot, new value: crossfade in place
        case fold(from: [Int], into: [Int])      // terms combining (or splitting)
    }

    /// Matches the longest common run of identical terms, then pairs what's
    /// left between matches: equal numbers pair up, otherwise they fold.
    public static func plan(_ old: [String], _ new: [String]) -> [Step] {
        let n = old.count, m = new.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0, gapOld: [Int] = [], gapNew: [Int] = []
        func flush() {
            if gapOld.count == gapNew.count {
                for (a, b) in zip(gapOld, gapNew) { steps.append(.change(from: a, to: b)) }
            } else if !(gapOld.isEmpty && gapNew.isEmpty) {
                steps.append(.fold(from: gapOld, into: gapNew))
            }
            gapOld = []; gapNew = []
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                flush()
                steps.append(.move(from: i, to: j)); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapNew.append(j); j += 1
            } else {
                gapOld.append(i); i += 1
            }
        }
        flush()
        return steps
    }

    /// How long a line takes to transform (design-tokens.json, motion.formula).
    public static var duration: TimeInterval { Tokens.shared.motion.formula.duration }
}
