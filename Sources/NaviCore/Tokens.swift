import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// A colour in the design tokens: `hex` ("#F5F3EE") or, for colours first
/// chosen as fractions, `rgb` (0…1 each), plus an optional `alpha`.
public struct Colour: Codable, Equatable {
    public var hex: String?
    public var rgb: [Double]?
    public var alpha: Double?

    public init(hex: String, alpha: Double? = nil) { (self.hex, self.rgb, self.alpha) = (hex, nil, alpha) }
    public init(rgb: [Double], alpha: Double? = nil) { (self.hex, self.rgb, self.alpha) = (nil, rgb, alpha) }

    /// Red, green, blue and alpha, 0…1.
    public var components: (r: Double, g: Double, b: Double, a: Double) {
        let a = alpha ?? 1
        if let rgb, rgb.count == 3 { return (rgb[0], rgb[1], rgb[2], a) }
        let v = Int((hex ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return (Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255, a)
    }
}

/// Navi's design values, one set for every platform: colours, line weights, motion, the ink pane, the
/// caption's sizes and the explanation palette. Read from
/// Resources/Shared/design-tokens.json, with `fallback` compiled in.
/// The owl's palette lives with its grid, in owl.json (see `Owl`).
public struct Tokens: Codable, Equatable {
    public struct Colours: Codable, Equatable {
        /// The pen: marks, targets, the primary button.
        public var ink: Colour
        /// The hold-and-move gesture trail: a light, passing stroke.
        public var gestureInk: Colour
        /// The user's own marks as burnt into screenshots, where Claude reads them as magenta.
        public var userMark: Colour
        /// The user's own marks on screen, in Mark mode.
        public var userInk: Colour
        /// The highlighter that sweeps along a highlighted line of text.
        public var marker: Colour
        /// Navi's light: its core, and the glow just around it.
        public var lamp: Colour
        public var lampGlow: Colour
        /// Text on the ink pane, then secondary, then quieter still.
        public var warmWhite: Colour
        public var softText: Colour
        public var faintText: Colour
    }

    public struct Line: Codable, Equatable {
        /// Traced marks: rings, arrows, lines, outlines.
        public var mark: Double
        /// The pen's faint second pass, for the hand-drawn look.
        public var echo: Double
        public var echoAlpha: Double
        /// Fine lines: target, hover and pulse rings, highlight edges.
        public var fine: Double
        /// Dashes on a click target, marching slowly; hovers are true dots.
        public var targetDash: [Double]
        public var hoverDash: [Double]
        public var marchPeriod: Double
        /// The tint inside rings, targets and highlights.
        public var fillAlpha: Double
        /// A click target breathes: it grows to `breathScale` and back every
        /// `breathPeriod` seconds each way, at `breathOpacity`, with a `glow` this wide.
        public var breathScale: Double
        public var breathPeriod: Double
        public var breathOpacity: Double
        public var glow: Double
    }

    public struct Shadow: Codable, Equatable {
        public var opacity: Double
        public var radius: Double
        /// Points; negative is downwards on the Mac (layers are y-up).
        public var offsetY: Double
    }

    public struct Motion: Codable, Equatable {
        public struct Transform: Codable, Equatable {
            public var duration: Double
            /// Cubic Bézier control points (x1, y1, x2, y2), as in CSS.
            public var curve: [Double]
        }
        /// A tap or press, a word lifting.
        public var quick: Double
        /// Things appearing and fading.
        public var base: Double
        /// Colour changes, the spotlight, words cooling.
        public var gentle: Double
        /// Arriving: fast out, soft landing (control points).
        public var settle: [Double]
        /// Formulas transforming in place: Manim's smootherstep.
        public var formula: Transform
    }

    /// Navi's own surface: a warm near-black, a hairline inside the edge, a faint sheen at the top.
    public struct Pane: Codable, Equatable {
        public var fill: Colour
        public var hairline: Colour
        public var sheen: Colour
        public var sheenDepth: Double
        public var catchRadius: Double
        public var catchAlpha: Double
        public var shadow: Shadow
    }

    public struct Caption: Codable, Equatable {
        public var maxWidth: Double
        public var padX: Double
        public var padY: Double
        public var radius: Double
        /// Between Navi's light and the pane.
        public var gap: Double
        public var fontSize: Double
        public var lineHeight: Double
        public var dockWidth: Double
        public var priorFontSize: Double
        /// How faint an earlier sentence is.
        public var ghost: Double
        /// How long the words wait at a tour stop: the light's glide plus a beat to look.
        public var tourPause: Double
    }

    /// One explanation colour: on dark (the caption, the panel, dark pages) and
    /// the deeper version for light pages.
    public struct Pair: Codable, Equatable {
        public var dark: Colour
        public var light: Colour
    }

    public var colours: Colours
    public var line: Line
    /// One lift for marks and labels: soft, slightly below.
    public var lift: Shadow
    public var motion: Motion
    public var pane: Pane
    public var caption: Caption
    /// Explanation colours, in order of introduction (3Blue1Brown-style).
    public var explanation: [Pair]

    /// The tokens in use: the shared file, or the built-in values if it can't be read.
    public static let shared: Tokens = SharedFiles.decode("design-tokens.json", fallback: fallback)

    /// The values the app was designed with; design-tokens.json starts as a copy.
    public static let fallback = Tokens(
        colours: Colours(
            ink: Colour(rgb: [0.24, 0.52, 1.0]),
            gestureInk: Colour(rgb: [0.66, 0.6, 1.0], alpha: 0.95),
            userMark: Colour(rgb: [0.91, 0.29, 0.65]),
            userInk: Colour(rgb: [0.66, 0.6, 1.0]),
            marker: Colour(rgb: [1.0, 0.81, 0.43], alpha: 0.38),
            lamp: Colour(hex: "#FFF7EA"),
            lampGlow: Colour(hex: "#FFF1DA"),
            warmWhite: Colour(hex: "#F5F3EE"),
            softText: Colour(hex: "#F5F3EE", alpha: 0.62),
            faintText: Colour(hex: "#F5F3EE", alpha: 0.38)),
        line: Line(mark: 3.5, echo: 1.2, echoAlpha: 0.45, fine: 2, targetDash: [10, 7], hoverDash: [0, 7], marchPeriod: 1.4,
                   fillAlpha: 0.10, breathScale: 1.15, breathPeriod: 1.0, breathOpacity: 0.7, glow: 8),
        lift: Shadow(opacity: 0.16, radius: 4, offsetY: -1),
        motion: Motion(quick: 0.18, base: 0.3, gentle: 0.6, settle: [0.2, 0.8, 0.2, 1],
                       formula: Motion.Transform(duration: 0.85, curve: [0.6, 0, 0.4, 1])),
        pane: Pane(fill: Colour(hex: "#121216", alpha: 0.95), hairline: Colour(hex: "#FFFFFF", alpha: 0.10),
                   sheen: Colour(hex: "#FFFFFF", alpha: 0.055), sheenDepth: 40, catchRadius: 110, catchAlpha: 0.20,
                   shadow: Shadow(opacity: 0.26, radius: 11, offsetY: -8)),
        caption: Caption(maxWidth: 292, padX: 15, padY: 12, radius: 16, gap: 16, fontSize: 15, lineHeight: 21, dockWidth: 420,
                         priorFontSize: 13, ghost: 0.16, tourPause: 1.7),
        explanation: [
            Pair(dark: Colour(hex: "#58C4DD"), light: Colour(hex: "#1F8FB8")),   // blue
            Pair(dark: Colour(hex: "#F0AC5F"), light: Colour(hex: "#C27A1C")),   // gold
            Pair(dark: Colour(hex: "#FC6255"), light: Colour(hex: "#D9473B")),   // red
            Pair(dark: Colour(hex: "#83C167"), light: Colour(hex: "#4F8F35")),   // green: only past three things, never in lessons
        ])
}
