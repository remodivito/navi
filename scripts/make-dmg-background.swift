// Draws the disk image window's background in Navi's ink: near-black with a warm lamp
// glow at the top, and an ink-blue hand-drawn arrow from Navi to Applications with
// "drag me across" beside it. That's the only text.
//   swift scripts/make-dmg-background.swift
// writes Resources/dmg-background.png (620×360) and Resources/dmg-background@2x.png.
// make-release.sh lays the window out to match: icons of 96 at (160, 175) and (460, 175).
import AppKit

// MARK: - The look, all in one place (change these, run the script again)

enum Style {
    // The arrow: from just right of Navi's icon to just left of Applications', bowed up
    // by `arrowLift` points, with a little hand wobble. `arrowRise` lifts both ends
    // above the icons' centres; `arrowGap` is the space left beside each icon.
    static let arrowLift: CGFloat = 22
    static let arrowRise: CGFloat = 4
    static let arrowGap: CGFloat = 18
    static let arrowWobble: CGFloat = 0.6      // 0 for a clean curve
    // Navi's hand goes over its line twice: a fainter second pass, a touch apart.
    static let secondPass: (offset: CGFloat, lift: CGFloat, alpha: CGFloat)? = (1.6, 3, 0.35)   // nil for one pass
    static let arrowWidth: CGFloat = 3.2
    static let arrowHead: CGFloat = 15         // length of each stroke of the head
    static let arrowHeadAngle: CGFloat = 0.5   // radians either side of the line
    static let arrowGlow: CGFloat = 8          // blur of the ink's glow; 0 for none

    // The words: written in Patrick Hand, centred over the arrow's middle.
    static let words = "drag me across"
    static let wordsSize: CGFloat = 24
    static let wordsAbove: CGFloat = 50        // above the arrow's ends (points)
    static let wordsOffsetX: CGFloat = 0

    // An optional light at the arrow's tip, like Navi's lamp: nil for none.
    static let tipLight: (radius: CGFloat, glow: CGFloat)? = (3.5, 12)   // nil for none

    // The lamp's glow over the top of the window; 0 to turn it off.
    static let lampAlpha: CGFloat = 0.16

    // Soft plates under the two icon names: Finder writes them in black or white
    // depending on the Mac's appearance, and both read on this mid tone. Nil for none.
    static let namePlates: (tone: UInt32, alpha: CGFloat, height: CGFloat)? = (0x6F6B65, 0.5, 20)
}

// MARK: - Layout

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let size = NSSize(width: 620, height: 360)
// Finder's icon positions are the icons' centres, from the window's top left.
let navi = NSPoint(x: 160, y: size.height - 175)
let applications = NSPoint(x: 460, y: size.height - 175)
let iconSize: CGFloat = 96

for f in (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Resources/Fonts"), includingPropertiesForKeys: nil)) ?? []
where f.pathExtension.lowercased() == "ttf" {
    CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
}

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let ink = colour(0x121216)
let blue = colour(0x3D85FF)
let lamp = colour(0xFFD696)
let lampWhite = colour(0xFFF7EA)

// MARK: - Pieces

/// The arrow's line, as points from tail to tip.
func arrowPoints(lift: CGFloat = Style.arrowLift, offset: CGFloat = 0) -> [NSPoint] {
    let from = NSPoint(x: navi.x + iconSize / 2 + Style.arrowGap, y: navi.y + Style.arrowRise)
    let to = NSPoint(x: applications.x - iconSize / 2 - Style.arrowGap, y: applications.y + Style.arrowRise)
    // Slow wobbles only, so the line reads as drawn rather than lumpy.
    return (0...48).map { i in
        let t = CGFloat(i) / 48
        let wobble = (sin(t * 5.3 + offset) * 0.8 + sin(t * 2.7 + 1) * 0.5) * Style.arrowWobble * sin(t * .pi)
        return NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t + sin(t * .pi) * lift + wobble + offset * sin(t * .pi))
    }
}

func drawArrow(_ points: [NSPoint], alpha: CGFloat = 1, width: CGFloat = Style.arrowWidth) {
    let stroke = NSBezierPath()
    stroke.move(to: points[0])
    for i in 1..<points.count {
        let mid = NSPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
        stroke.curve(to: mid, controlPoint1: points[i - 1], controlPoint2: points[i - 1])
    }
    let tip = points[points.count - 1], before = points[points.count - 4]
    stroke.line(to: tip)
    let angle = atan2(tip.y - before.y, tip.x - before.x)
    for side: CGFloat in [-1, 1] {
        let a = angle + .pi + side * Style.arrowHeadAngle
        stroke.move(to: tip)
        stroke.line(to: NSPoint(x: tip.x + cos(a) * Style.arrowHead, y: tip.y + sin(a) * Style.arrowHead + side * 0.8))
    }
    stroke.lineWidth = width
    stroke.lineCapStyle = .round
    stroke.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    if Style.arrowGlow > 0 {
        let shadow = NSShadow()
        shadow.shadowColor = blue.withAlphaComponent(0.55 * alpha)
        shadow.shadowBlurRadius = Style.arrowGlow
        shadow.set()
    }
    blue.withAlphaComponent(alpha).setStroke()
    stroke.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawTipLight(at tip: NSPoint) {
    guard let light = Style.tipLight else { return }
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = blue
    shadow.shadowBlurRadius = light.glow
    shadow.set()
    lampWhite.setFill()
    NSBezierPath(ovalIn: NSRect(x: tip.x - light.radius, y: tip.y - light.radius, width: light.radius * 2, height: light.radius * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func drawWords(over points: [NSPoint]) {
    let font = NSFont(name: "PatrickHand-Regular", size: Style.wordsSize) ?? .systemFont(ofSize: Style.wordsSize - 2)
    let s = NSAttributedString(string: Style.words, attributes: [.font: font, .foregroundColor: blue])
    let first = points[0], last = points[points.count - 1]
    let centre = NSPoint(x: (first.x + last.x) / 2 + Style.wordsOffsetX, y: (first.y + last.y) / 2 + Style.wordsAbove)
    let w = s.size()
    s.draw(at: NSPoint(x: centre.x - w.width / 2, y: centre.y - w.height / 2))
}

func draw() {
    ink.setFill()
    NSRect(origin: .zero, size: size).fill()
    if Style.lampAlpha > 0 {
        let glow = NSGradient(colors: [lamp.withAlphaComponent(Style.lampAlpha), lamp.withAlphaComponent(Style.lampAlpha * 0.3), lamp.withAlphaComponent(0)],
                              atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        let top = NSPoint(x: size.width / 2, y: size.height + 60)
        glow.draw(fromCenter: top, radius: 0, toCenter: top, radius: 330, options: [])
    }
    if let plate = Style.namePlates {
        for (centre, width) in [(navi, 70.0), (applications, 104.0)] {
            colour(plate.tone, plate.alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: centre.x - width / 2, y: centre.y - iconSize / 2 - 16 - plate.height / 2, width: width, height: plate.height),
                         xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        }
    }
    let points = arrowPoints()
    if let pass = Style.secondPass {
        drawArrow(arrowPoints(lift: Style.arrowLift + pass.lift, offset: pass.offset), alpha: pass.alpha, width: Style.arrowWidth * 0.7)
    }
    drawArrow(points)
    drawTipLight(at: points[points.count - 1])
    drawWords(over: points)
}

// MARK: - Output

for (scale, name) in [(1, "dmg-background.png"), (2, "dmg-background@2x.png")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size   // points, so the @2x image carries 144 dpi
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let out = root.appendingPathComponent("Resources/\(name)")
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    print("Wrote \(out.path)")
}
