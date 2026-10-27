import Foundation

/// Navi's face: a small pixel owl. The light that follows the pointer is Navi's
/// hand on the screen; the owl is its face in the interface (the type bar, the
/// topic pill, the pause card, the caption and the menu bar).
///
/// Moods come mostly from what Navi is doing (listening, thinking, a step
/// taken), with an occasional pinch of tone from Claude ([MOOD:wow]). There's
/// one owl: every view shows `Owl.shared.mood`. Used on the main thread only.
///
/// The base sprite and its palette come from owl.json (Resources/Shared); the
/// moods are drawn from it here, so every platform animates the same owl.
public final class Owl {
    public static let shared = Owl()

    public enum Mood: String, CaseIterable {
        // States: what Navi is doing.
        case idle, thinking, listening, writing, pointing, nodding, resting
        // Reactions: one-shots that return to the state.
        case happy, confused, sorry, celebrate, hello, peek, wow, love, proud, grumpy
    }

    /// Claude may set these with [MOOD:…]; anything else is ignored.
    public static let tones: Set<Mood> = [.wow, .love, .proud, .confused]
    /// While Navi is listening, nothing interrupts it. A reaction can show over
    /// thinking: a step taken is celebrated while the next one is worked out.
    public static let busy: Set<Mood> = [.listening]

    public private(set) var state: Mood = .resting
    private var reaction: (mood: Mood, until: Date)?
    private var lastTone = Date.distantPast
    /// The animation clock every owl shares, so they blink together.
    public let clock = Date()

    public var mood: Mood { Self.resolve(state: state, reaction: reaction, now: Date()) }

    /// The rule, separate so it can be tested: a reaction shows until it ends,
    /// unless Navi is listening.
    public nonisolated static func resolve(state: Mood, reaction: (mood: Mood, until: Date)?, now: Date) -> Mood {
        if let r = reaction, now < r.until, !busy.contains(state) { return r.mood }
        return state
    }

    public func set(_ s: Mood) {
        settling.forEach { $0.cancel() }
        settling = []
        state = s
    }

    /// Nothing happening: idle, nodding off after a minute, resting after three.
    public func settle() {
        set(.idle)
        for (delay, m) in [(60.0, Mood.nodding), (180.0, .resting)] {
            let work = DispatchWorkItem { [weak self] in self?.state = m }
            settling.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    private var settling: [DispatchWorkItem] = []
    private var lastHello = Date.distantPast

    /// Navi appearing: a hello the first time each day, otherwise a quick peek.
    public func appear() {
        let first = !Calendar.current.isDate(lastHello, inSameDayAs: Date())
        if first { lastHello = Date() }
        set(.idle)
        react(first ? .hello : .peek, for: first ? 1.6 : 1.2)
    }

    public func react(_ m: Mood, for seconds: TimeInterval = 1.4) {
        reaction = (m, Date().addingTimeInterval(seconds))
        reactionStarted = Date()
    }
    private var reactionStarted = Date.distantPast

    /// Where the current animation starts: a reaction plays from its own beginning
    /// (a pop-up always rises from the bottom), everything else from the shared clock.
    public var animationStart: Date {
        if let r = reaction, Date() < r.until, !Self.busy.contains(state) { return reactionStarted }
        return clock
    }

    /// Claude's pinch of tone: only the allowed few, and wow or love at most every two minutes.
    public func tone(_ name: String) {
        guard let m = Mood(rawValue: name.lowercased()), Self.tones.contains(m) else { return }
        if m == .wow || m == .love, Date().timeIntervalSince(lastTone) < 120 { return }
        if m == .wow || m == .love { lastTone = Date() }
        react(m, for: 1.8)
    }

    // MARK: Frames

    /// One frame: the owl's 12×11 grid, its offset, and pixels outside it
    /// (sparks, Zs, a question mark) on the 16×15 canvas.
    public struct Frame {
        public var grid: [[Character]]
        public var dx = 0, dy = 0
        public var extras: [(x: Int, y: Int, c: Character)] = []

        public init(grid: [[Character]], dx: Int = 0, dy: Int = 0, extras: [(x: Int, y: Int, c: Character)] = []) {
            (self.grid, self.dx, self.dy, self.extras) = (grid, dx, dy, extras)
        }
    }

    /// The base sprite: a 12×11 grid of palette letters ('.' is clear), where it
    /// sits on the canvas, and the canvas size, which leaves room for extras.
    public struct Sprite: Codable, Equatable {
        public var grid: [String]
        /// Letter → "#RRGGBB".
        public var palette: [String: String]
        public var origin: [Int]
        public var canvas: [Int]

        /// The shape the frame code expects: 11 rows of 12, and two numbers each for origin and canvas.
        public var isValid: Bool {
            grid.count == 11 && grid.allSatisfy { $0.count == 12 } && origin.count == 2 && canvas.count == 2
                && palette.keys.allSatisfy { $0.count == 1 }
        }
    }

    public static let builtIn = Sprite(
        grid: ["B..........B", "BBBBBBBBBBBB", "BFFFFFFFFFFB", "BFFFFFFFFFFB", "BFFwkFFwkFFB", "BFFkkFFkkFFB",
               "BBBBBYYBBBBB", "BBBBBBBBBBbb", "BBBBBBBBBBbb", "BBBBBBBBBBbb", ".Y........Y."],
        palette: ["B": "#935C40", "b": "#7A4A33", "F": "#F0EBC2", "k": "#141418", "w": "#FFFFFF",
                  "Y": "#F2B33D", "c": "#C9746A", "z": "#B5D4F4", "s": "#85B7EB", "q": "#FFF1DA", "r": "#E24B4A"],
        origin: [2, 3], canvas: [16, 15])

    /// The sprite in use: owl.json if it reads and has the right shape, else the built-in one.
    public static let sprite: Sprite = {
        let s = SharedFiles.decode("owl.json", fallback: builtIn)
        if s.isValid { return s }
        trace("owl.json doesn't have a 12×11 grid; using the built-in owl.")
        return builtIn
    }()

    public static let body = sprite.grid
    /// Where the owl sits on the canvas, leaving room for extras.
    public static let origin = (x: sprite.origin[0], y: sprite.origin[1])
    public static let canvas = (w: sprite.canvas[0], h: sprite.canvas[1])
    /// Each palette letter's colour; the shell turns these into its own colours.
    public static let colours: [Character: Colour] = Dictionary(uniqueKeysWithValues: sprite.palette.compactMap { k, v in
        k.first.map { ($0, Colour(hex: v)) }
    })

    /// The frame for `mood` at `t` seconds. With `still` (Reduce Motion) the
    /// expression shows but nothing moves.
    public nonisolated static func frame(_ mood: Mood, at t: TimeInterval, still: Bool = false) -> Frame {
        // The clock is wall time: a clock set back makes `t` negative, and a negative
        // or non-finite count would build an empty range below and trap.
        let ms = still ? 1000 : Int(t.isFinite ? max(0, min(t, 1e9)) * 1000 : 0)
        var g = body.map { Array($0) }
        func set(_ r: Int, _ c: Int, _ v: Character) { if g.indices.contains(r), g[r].indices.contains(c) { g[r][c] = v } }
        func eyes(_ kind: String) {
            for c0 in [3, 7] {
                for (a, b) in [(0, 0), (0, 1), (1, 0), (1, 1)] { set(4 + a, c0 + b, "F") }
                switch kind {
                case "open": set(4, c0, "w"); set(4, c0 + 1, "k"); set(5, c0, "k"); set(5, c0 + 1, "k")
                case "closed": set(5, c0, "k"); set(5, c0 + 1, "k")
                case "happy": set(4, c0, "k"); set(4, c0 + 1, "k")
                case "up": set(4, c0 + 1, "k")
                case "down": set(5, c0, "k"); set(5, c0 + 1, "k")
                case "left": set(4, c0, "k"); set(5, c0, "k")
                case "right": set(4, c0 + 1, "k"); set(5, c0 + 1, "k")
                case "dot": set(5, c0 == 3 ? c0 + 1 : c0, "k")
                case "wide": set(4, c0, "k"); set(4, c0 + 1, "k"); set(5, c0, "k"); set(5, c0 + 1, "w")
                case "heart": for (a, b) in [(0, 0), (0, 1), (1, 0), (1, 1)] { set(4 + a, c0 + b, "r") }
                case "sad": set(5, c0, "k"); set(5, c0 + 1, "k"); set(4, c0 == 3 ? c0 + 1 : c0, "k")
                default: break
                }
            }
        }
        func brows(_ kind: String) {
            switch kind {
            case "grumpy": [2, 3, 4, 7, 8, 9].forEach { set(3, $0, "k") }
            case "raised": [2, 3, 4, 7, 8, 9].forEach { set(2, $0, "k") }
            case "one": [7, 8, 9].forEach { set(2, $0, "k") }
            case "sad": set(2, 4, "k"); set(3, 3, "k"); set(3, 2, "k"); set(2, 7, "k"); set(3, 8, "k"); set(3, 9, "k")
            default: break
            }
        }
        let blink = ms % 3200 < 150
        let o = origin
        func at(_ y: Int, _ x: Int, _ c: Character) -> (x: Int, y: Int, c: Character) { (o.x + x, o.y + y, c) }
        var f = Frame(grid: g)
        switch mood {
        case .idle, .pointing:
            let phase = (ms / 900) % 6
            eyes(blink ? "closed" : mood == .pointing ? "right" : phase == 3 ? "left" : phase == 4 ? "right" : "open")
        case .thinking:
            brows("one"); eyes("up")
            f.extras = (0..<((ms / 400) % 4)).map { at(-3, 9 + $0 * 2, "q") }
        case .listening:
            eyes(blink ? "closed" : "right"); f.dx = 1
            f.extras = (0...((ms / 500) % 3)).map { at(4 - $0, 13 + $0, "z") }
        case .writing:
            eyes("down")
            let n = (ms / 150) % 6
            f.extras = (0...n).map { at(12, 2 + $0, "q") } + [at(11, 2 + n, "Y")]
        case .nodding:
            let p = ms % 3000
            eyes(p < 2200 ? "closed" : "open"); f.dy = (p >= 1100 && p < 2200) ? 1 : 0
        case .resting:
            eyes("closed"); f.dy = ms % 2400 < 1200 ? 0 : 1
            let z = (ms / 350) % 5
            f.extras = [at(1 - z, 12, "z"), at(-1 - z, 13, "z")]
        case .happy:
            eyes("happy"); set(5, 2, "c"); set(5, 9, "c")
            let p = ms % 1600; f.dy = (p < 200 || (p > 300 && p < 500)) ? -1 : 0
        case .confused:
            brows("one"); eyes("open"); f.dx = 1
            if ms % 1200 < 900 { f.extras = [at(-3, 12, "q"), at(-3, 13, "q"), at(-2, 13, "q"), at(-1, 12, "q"), at(1, 12, "q")] }
        case .sorry:
            brows("sad"); eyes("down"); f.dy = ms % 3000 < 1500 ? 1 : 0
        case .celebrate:
            eyes("happy"); set(5, 2, "c"); set(5, 9, "c")
            let ph = (ms / 200) % 4
            f.dy = ph % 2 == 1 ? -1 : 0
            let spark: Character = ph < 2 ? "Y" : "q"
            f.extras = [at(5, -1, "B"), at(4, -2, "B"), at(5, 12, "B"), at(4, 13, "B")]
                + [(-2, -1), (-3, 6), (-2, 13)].map { at($0.0 - ph % 2, $0.1, spark) }
        case .hello:
            eyes("happy"); set(5, 2, "c"); set(5, 9, "c")
            f.extras = (ms / 250) % 2 == 0 ? [at(5, 12, "B"), at(4, 13, "B"), at(3, 13, "B")] : [at(6, 12, "B"), at(5, 13, "B"), at(6, 13, "B")]
        case .peek:
            // A quick, springy pop: up from below, a touch past, settle. Then a blink.
            let rise = [(60, 7), (120, 3), (180, 0), (260, -1)]
            f.dy = rise.first { ms < $0.0 }?.1 ?? 0
            eyes(ms > 520 && ms < 640 ? "closed" : "open")
        case .wow:
            brows("raised"); eyes("wide"); set(6, 5, "k"); set(6, 6, "k")
            if ms % 2000 < 1000 { f.extras = [at(-1, 0, "B"), at(-1, 11, "B")] }
        case .love:
            eyes(ms % 1600 < 1100 ? "heart" : "happy"); f.dy = ms % 800 < 400 ? 0 : -1
        case .proud:
            eyes("happy"); brows("raised")
        case .grumpy:
            brows("grumpy"); eyes(ms % 3600 < 160 ? "closed" : "open")
        }
        if still { f.dx = 0; f.dy = 0 }
        f.grid = g
        return f
    }
}
