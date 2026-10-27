// The Windows spike (milestone 1): a bare overlay on every
// monitor with Navi's light following the pointer and one sketched ring
// drawing itself, measured frame by frame.
//
//   swift run NaviWin [--seconds N] [--capturable]    Esc quits early.
//
// --capturable leaves the overlay in screenshots, as the control for checking
// that it's otherwise excluded.
import Foundation
import WinSDK
import NaviWinGfx
import NaviCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let seconds = args.firstIndex(of: "--seconds").flatMap { Double(args[$0 + 1]) } ?? 30
let capturable = args.contains("--capturable")

// Per-monitor DPI awareness v2 before any window exists, so every window
// works in physical pixels and hears about its own monitor's scale.
guard SetProcessDpiAwarenessContext(perMonitorAwareV2) else {
    print("FAIL couldn't set per-monitor DPI awareness v2 (error \(GetLastError()))")
    exit(1)
}
let initResult = nw_init()
guard initResult == 0 else {
    print("FAIL graphics devices: HRESULT 0x\(String(UInt32(bitPattern: initResult), radix: 16))")
    exit(1)
}

// MARK: Windows

var needsRebuild = false
let className: [WCHAR] = Array("NaviOverlay".utf16) + [0]
var windowClass = WNDCLASSEXW()
windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
windowClass.hInstance = GetModuleHandleW(nil)
windowClass.lpfnWndProc = { hwnd, msg, wParam, lParam in
    switch msg {
    case UINT(WM_DISPLAYCHANGE), UINT(WM_DPICHANGED):
        needsRebuild = true
        return 0
    case UINT(WM_NCHITTEST):
        return LRESULT(HTTRANSPARENT)
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}
className.withUnsafeBufferPointer { name in
    windowClass.lpszClassName = name.baseAddress
    _ = RegisterClassExW(&windowClass)
}

func buildScreens() -> [Screen] {
    let screens = Screen.monitors().compactMap { Screen(monitor: $0.0, frame: $0.1, windowClass: className, capturable: capturable) }
    for s in screens {
        let f = s.frame
        print("screen \(f.right - f.left)x\(f.bottom - f.top) at (\(f.left), \(f.top)), scale \(s.scale)"
              + (s.excluded ? ", excluded from capture" : ", NOT excluded from capture (error \(GetLastError()))"))
    }
    return screens
}
var screens = buildScreens()
guard !screens.isEmpty else { print("FAIL no overlay windows"); exit(1) }

// MARK: Design values

let tokens = Tokens.shared
func nw(_ c: Colour, alpha: Double = 1) -> NWColor {
    let k = c.components
    return NWColor(r: Float(k.r), g: Float(k.g), b: Float(k.b), a: Float(k.a * alpha))
}
let ink = tokens.colours.ink, lamp = tokens.colours.lamp, lampGlow = tokens.colours.lampGlow

// MARK: The light

/// Follows the pointer on the Mac's spring (response 0.25 s, damping 0.7),
/// beside and below it, in global pixels.
struct Light {
    var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
    static let response = 0.25, damping = 0.7
    static let offset = (dx: 22.0, dy: 26.0)   // DIPs; y grows downwards on Windows

    mutating func step(towards tx: Double, _ ty: Double, dt: Double) {
        let k = pow(2 * .pi / Self.response, 2), c = 4 * .pi * Self.damping / Self.response
        let n = max(1, Int(dt / 0.002))
        let h = dt / Double(n)
        for _ in 0..<n {
            vx += (k * (tx - x) - c * vx) * h
            vy += (k * (ty - y) - c * vy) * h
            x += vx * h
            y += vy * h
        }
    }
}

func drawLight(_ light: Light, on s: Screen) {
    let (x, y) = s.local(light.x, light.y)
    let k = Float(s.scale)
    // The halo: a soft ink glow, as Buddy's (62% of a 120 pt box, at 35%).
    let haloStops: [Float] = [0, 0.35, 1]
    let halo = [nw(ink, alpha: 0.46 * 0.35), nw(ink, alpha: 0.15 * 0.35), nw(ink, alpha: 0)]
    nw_glow(s.surface, x, y, 37.2 * k, haloStops, halo, 3)
    // The lamp-white core with its warm glow (shadow radius 4 at 90%).
    let glowStops: [Float] = [0, 0.4, 1]
    let glow = [nw(lampGlow, alpha: 0.9), nw(lampGlow, alpha: 0.45), nw(lampGlow, alpha: 0)]
    nw_glow(s.surface, x, y, (3.8 + 6) * k, glowStops, glow, 3)
    nw_disc(s.surface, x, y, 3.8 * k, nw(lamp))
}

// MARK: The ring

/// One sketched ring, drawn at the pen's even hand speed, held, then faded;
/// then another, on whichever monitor the pointer is on.
struct Ring {
    var start: Double
    var centre: (x: Double, y: Double)   // global pixels
    var scale: Double
    var main: [CGPoint] = [], echo: [CGPoint] = []
    var strokeTime = 0.6
    static let radius: CGFloat = 64
    static let hold = 1.4, gap = 0.6

    init(start: Double, centre: (Double, Double), scale: Double, cycle: Int) {
        self.start = start
        self.centre = centre
        self.scale = scale
        let a = CGFloat(cycle) * 1.7
        let pts = [CGPoint.zero, CGPoint(x: Self.radius * cos(a), y: Self.radius * sin(a))]
        let line = Sketch.polyline(.circle, pts, sketchy: true)
        let seed = Sketch.seed(pts)
        main = Sketch.jitter(line, seed: seed)
        echo = Sketch.jitter(line, seed: seed + 7, amount: 2.2)
        // Pen strokes at 650 pt/s, clamped to 0.3–1.4 s.
        let length = zip(main, main.dropFirst()).reduce(0.0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) }
        strokeTime = min(1.4, max(0.3, length / 650))
    }

    var end: Double { start + strokeTime + Self.hold + tokens.motion.base + Self.gap }

    /// The first `fraction` of the line, in a screen's pixels, as x, y pairs.
    func pixels(_ line: [CGPoint], fraction: Double, on s: Screen, dy: Double = 0) -> [Float] {
        guard fraction > 0, line.count > 1 else { return [] }
        let f = min(1, fraction) * Double(line.count - 1)
        let whole = Int(f)
        var pts = Array(line[0...whole])
        if whole < line.count - 1 {
            let a = line[whole], b = line[whole + 1], t = CGFloat(f - Double(whole))
            pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        var out: [Float] = []
        out.reserveCapacity(pts.count * 2)
        for p in pts {
            let (x, y) = s.local(centre.x + Double(p.x) * scale, centre.y + (Double(p.y) + dy) * scale)
            out.append(x)
            out.append(y)
        }
        return out
    }

    func draw(at now: Double, on s: Screen) {
        let t = now - start
        let fadeStart = strokeTime + Self.hold
        let opacity = t < fadeStart ? 1 : max(0, 1 - (t - fadeStart) / tokens.motion.base)
        guard opacity > 0 else { return }
        let k = Float(scale), line = tokens.line
        let drawn = t / strokeTime, echoDrawn = (t - 0.05) / strokeTime
        // The fill fades in once the pen is most of the way round.
        let fill = min(1, max(0, (t - strokeTime * 0.6) / tokens.motion.base))
        if fill > 0 {
            let xy = pixels(main, fraction: 1, on: s)
            nw_fill_polygon(s.surface, xy, Int32(xy.count / 2), nw(ink, alpha: line.fillAlpha * fill * opacity))
        }
        // The lift (black 16%, radius 4, 1 pt down), approximated by two soft strokes beneath.
        let lift = pixels(main, fraction: drawn, on: s, dy: 1)
        let liftAlpha = tokens.lift.opacity * opacity
        nw_polyline(s.surface, lift, Int32(lift.count / 2), Float(line.mark + 4) * k, NWColor(r: 0, g: 0, b: 0, a: Float(liftAlpha * 0.3)))
        nw_polyline(s.surface, lift, Int32(lift.count / 2), Float(line.mark + 1.5) * k, NWColor(r: 0, g: 0, b: 0, a: Float(liftAlpha * 0.5)))
        let xy = pixels(main, fraction: drawn, on: s)
        nw_polyline(s.surface, xy, Int32(xy.count / 2), Float(line.mark) * k, nw(ink, alpha: opacity))
        let e = pixels(echo, fraction: echoDrawn, on: s)
        nw_polyline(s.surface, e, Int32(e.count / 2), Float(line.echo) * k, nw(ink, alpha: line.echoAlpha * opacity))
    }
}

func screen(at x: Double, _ y: Double) -> Screen {
    screens.first { $0.contains(x, y) } ?? screens[0]
}

func newRing(at now: Double, cycle: Int) -> Ring {
    var p = POINT()
    GetCursorPos(&p)
    let s = screen(at: Double(p.x), Double(p.y))
    let c = (Double(s.frame.left + s.frame.right) / 2, Double(s.frame.top + s.frame.bottom) / 2)
    return Ring(start: now, centre: c, scale: s.scale, cycle: cycle)
}

// MARK: The loop

let refresh = nw_refresh_period()
print(String(format: "compositor refresh %.2f Hz", refresh > 0 ? 1 / refresh : 0))
var stats = FrameStats(refresh: refresh), whole = FrameStats(refresh: refresh)
var light = Light()
var cursor = POINT()
GetCursorPos(&cursor)
(light.x, light.y) = (Double(cursor.x), Double(cursor.y))
let began = nw_now()
var last = began, lastReport = began
var cycle = 0
var ring = newRing(at: began + 0.5, cycle: cycle)
var usedClock = false
var msg = MSG()

while true {
    while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
    if needsRebuild {
        needsRebuild = false
        print("displays changed: rebuilding the overlay windows")
        screens = []
        screens = buildScreens()
        if screens.isEmpty { print("FAIL no overlay windows"); exit(1) }
    }
    let now = nw_now()
    if now - began > seconds || GetAsyncKeyState(VK_ESCAPE) < 0 { break }
    let dt = min(0.1, now - last)
    if now - began > 1 { stats.intervals.append(now - last); whole.intervals.append(now - last) }
    last = now

    GetCursorPos(&cursor)
    let here = screen(at: Double(cursor.x), Double(cursor.y))
    light.step(towards: Double(cursor.x) + Light.offset.dx * here.scale, Double(cursor.y) + Light.offset.dy * here.scale, dt: dt)
    if now > ring.end {
        cycle += 1
        ring = newRing(at: now, cycle: cycle)
    }

    let ringReach = Double(Ring.radius + 12) * ring.scale
    for s in screens {
        let showsLight = s.touches(light.x, light.y, radius: 40 * s.scale)
        let showsRing = now >= ring.start && s.touches(ring.centre.x, ring.centre.y, radius: ringReach)
        guard showsLight || showsRing || s.drew else { continue }
        nw_begin(s.surface)
        if showsRing { ring.draw(at: now, on: s) }
        if showsLight { drawLight(light, on: s) }
        let hr = nw_end(s.surface)
        if hr != 0 { print("present failed: HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16))") }
        s.drew = showsLight || showsRing
    }
    if now - began > 1 { let w = nw_now() - now; stats.work.append(w); whole.work.append(w) }

    if now - lastReport >= 5 {
        print(stats.summary(String(format: "%5.1fs", now - began)))
        stats.reset()
        lastReport = now
    }
    usedClock = nw_wait_frame() == 1
}

print((usedClock ? "paced by DCompositionWaitForCompositorClock" : "paced by DwmFlush"))
print(whole.summary("whole run (after 1 s warm-up)"))
screens = []
