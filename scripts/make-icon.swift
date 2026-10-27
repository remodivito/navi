// Draws Navi's app icon: the grumpy owl in a mortarboard on the ink tile.
//   swift scripts/make-icon.swift <out.iconset>
// then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let palette: [Character: String] = [
    "B": "#935C40", "b": "#7A4A33", "F": "#F0EBC2", "k": "#141418", "w": "#FFFFFF", "Y": "#F2B33D",
    "N": "#6B739A", "n": "#4A5170", "t": "#D9962B",
]
// The owl's grumpy face (Owl.frame .grumpy) under a mortarboard; 16 wide.
let art = [
    "....NNNNNNNN....",   // the top of the board, catching the light
    ".nnnnnnnnnnnnnn.",   // the board
    "..B..nnnnnn..BY.",   // ear tips, the cap's crown, the tassel
    "..BBBBBBBBBBBBY.",
    "..BFFFFFFFFFFBt.",
    "..BFkkkFFkkkFB..",   // the grumpy brows
    "..BFFwkFFwkFFB..",
    "..BFFkkFFkkFFB..",
    "..BBBBBYYBBBBB..",
    "..BBBBBBBBBBbb..",
    "..BBBBBBBBBBbb..",
    "..BBBBBBBBBBbb..",
    "...Y........Y...",
]

func colour(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = CGFloat(size) / 1024
    // The tile: macOS's icon grid (824 of 1024), plain in Navi's ink.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    colour("#16151A").setFill()
    shape.fill()
    // The owl, in whole pixels where the size allows, centred.
    ctx.imageInterpolation = .none
    ctx.shouldAntialias = false
    let cols = art[0].count, rows = art.count
    let px = max(1, (560 * s / CGFloat(cols)).rounded(.down))
    let x0 = (CGFloat(size) - px * CGFloat(cols)) / 2, y0 = ((CGFloat(size) - px * CGFloat(rows)) / 2 + 8 * s).rounded()
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() {
            guard let hex = palette[ch] else { continue }
            colour(hex).setFill()
            NSRect(x: (x0 + CGFloat(c) * px).rounded(), y: (CGFloat(size) - y0 - CGFloat(r + 1) * px).rounded(), width: px, height: px).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
