import AppKit
import Vision
import ScreenCaptureKit

/// One display's screenshot. `index` is what Claude calls `screenN`;
/// screen 1 is always the one the cursor was on.
extension ScreenShot {
    /// How light the page is around a screenshot pixel (0 dark … 1 white), so
    /// marks can pick the version of their colour that reads on it.
    func lightness(around p: CGPoint, radius: CGFloat = 40) -> CGFloat {
        let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            .intersection(CGRect(origin: .zero, size: pixelSize))
        guard !r.isNull, let crop = image.cropping(to: r.integral),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let px = data.bindMemory(to: UInt8.self, capacity: 4)
        return (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
    }
}

struct ScreenShot {
    let index: Int
    let screen: NSScreen
    var image: CGImage
    let hasCursor: Bool

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    /// Screen points per screenshot pixel.
    var scale: CGFloat { screen.frame.width / CGFloat(image.width) }

    /// Screenshot pixel (top-left origin) → AppKit global point (bottom-left origin).
    func globalPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: screen.frame.minX + p.x * scale, y: screen.frame.maxY - p.y * scale)
    }

    /// AppKit global point → screenshot pixel.
    func pixel(_ p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - screen.frame.minX) / scale, y: (screen.frame.maxY - p.y) / scale)
    }
}

enum Capture {
    /// Claude downsamples very large images, so cap the long edge ourselves.
    static let maxLongEdge: CGFloat = 1568

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Every display in the Mac's own order, so a screen keeps its number
    /// when the cursor moves between them.
    static func orderedScreens() -> [NSScreen] { NSScreen.screens }

    /// Whether `words` can be read on `screen` right now, by on-device text recognition
    /// (Vision; nothing leaves the Mac). nil if the screen couldn't be read.
    static func shows(_ words: String, on screen: NSScreen) async -> Bool? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID(screen) }),
              let image = try? await capture(display: display, screen: screen,
                                             ownApps: content.applications.filter { $0.processID == getpid() }, longEdge: 2200)
        else { return nil }
        let wanted = normalised(words)
        guard !wanted.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            // Vision may call back and also throw: answer exactly once.
            let once = NSLock()
            var answered = false
            func answer(_ v: Bool?) {
                once.lock(); defer { once.unlock() }
                guard !answered else { return }
                answered = true
                cont.resume(returning: v)
            }
            let request = VNRecognizeTextRequest { req, error in
                guard error == nil else { return answer(nil) }
                let lines = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                answer(lines.contains { normalised($0).contains(wanted) })
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { answer(nil) }
            answer(nil)   // in case Vision neither called back nor threw
        }
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func takeAll() async throws -> [ScreenShot] {
        let screens = orderedScreens()
        let cursor = screenUnderMouse()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == getpid() }

        let results = await withTaskGroup(of: Result<ScreenShot, Error>.self) { group -> [Result<ScreenShot, Error>] in
            for (i, screen) in screens.enumerated() {
                guard let display = content.displays.first(where: { $0.displayID == displayID(screen) }) else { continue }
                group.addTask {
                    // One display asleep or going away doesn't cost the others.
                    do {
                        let image = try await capture(display: display, screen: screen, ownApps: ownApps, longEdge: maxLongEdge)
                        return .success(ScreenShot(index: i + 1, screen: screen, image: image, hasCursor: screen == cursor))
                    } catch {
                        trace("Capture: screen \(i + 1) skipped (\(error.localizedDescription)).")
                        return .failure(error)
                    }
                }
            }
            var all: [Result<ScreenShot, Error>] = []
            for await r in group { all.append(r) }
            return all
        }
        var shots: [ScreenShot] = []
        var firstError: Error?
        for r in results {
            switch r {
            case .success(let s): shots.append(s)
            case .failure(let e): firstError = firstError ?? e
            }
        }
        guard !shots.isEmpty else {
            // Every display failed: the reason (a missing permission, say) is the first one's.
            throw firstError ?? NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't capture any screen."])
        }
        return shots.sorted { $0.index < $1.index }
    }

    private static func capture(display: SCDisplay, screen: NSScreen, ownApps: [SCRunningApplication],
                                longEdge: CGFloat) async throws -> CGImage {
        // Leave our own overlay and prompt out of the picture.
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let points = screen.frame.size
        let scale = min(1, longEdge / max(points.width, points.height))
        let config = SCStreamConfiguration()
        config.width = Int((points.width * scale).rounded())
        config.height = Int((points.height * scale).rounded())
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Draws the user's pointer gesture onto a copy of the screenshot in magenta,
    /// so Claude sees exactly what they marked.
    static func burn(gesture points: [NSPoint], into shot: ScreenShot) -> CGImage {
        let w = shot.image.width, h = shot.image.height
        guard points.count > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return shot.image }
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext is bottom-left origin; pixel() is top-left.
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let px = shot.pixel(p)
            let q = CGPoint(x: px.x, y: CGFloat(h) - px.y)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.85, alpha: 0.9))
        ctx.setLineWidth(max(3, 4 / shot.scale))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return ctx.makeImage() ?? shot.image
    }

    /// Waits until the screen stops changing (an animation, a menu opening,
    /// a page loading), sampling a small greyscale copy every 90 ms: settled once
    /// it has held still for five samples in a row (about half a second). Apps often
    /// pause before drawing the next page, so a quarter second of stillness looked too
    /// soon (a blank pane mid-load). Returns false if it was still changing when time ran out.
    @discardableResult
    static func waitForSettle(screen: NSScreen, timeout: TimeInterval = 3) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID(screen) }) else { return true }
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [UInt8]?
        var stableCount = 0
        try? await Task.sleep(nanoseconds: 150_000_000)
        while Date() < deadline, !Task.isCancelled {
            guard let img = try? await capture(display: display, screen: screen, ownApps: ownApps, longEdge: 200),
                  let sample = grey(img) else { return true }
            if let previous, previous.count == sample.count {
                let diff = zip(previous, sample).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                stableCount = Double(diff) / Double(sample.count) < 0.8 ? stableCount + 1 : 0
                if stableCount >= 5 { return true }
            }
            previous = sample
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
        return Task.isCancelled
    }

    private static func grey(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
