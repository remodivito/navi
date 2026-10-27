import Foundation
import WinSDK
import NaviWinGfx

// Win32 values Swift doesn't import as the right type (or at all, for the
// pointer-valued macros).
let wsPopup: DWORD = 0x8000_0000
let wsExTopmost: DWORD = 0x0000_0008
let wsExTransparent: DWORD = 0x0000_0020
let wsExToolWindow: DWORD = 0x0000_0080
let wsExLayered: DWORD = 0x0008_0000
let wsExNoActivate: DWORD = 0x0800_0000
let wsExNoRedirectionBitmap: DWORD = 0x0020_0000
let wdaExcludeFromCapture: DWORD = 0x0000_0011
let perMonitorAwareV2 = DPI_AWARENESS_CONTEXT(bitPattern: -4)

/// One transparent, click-through, topmost window over a monitor, with its own
/// composition swap chain. With per-monitor DPI awareness v2, `frame` is in
/// physical pixels in the virtual-screen space, and `scale` is pixels per DIP.
final class Screen {
    let monitor: HMONITOR
    let frame: RECT
    let hwnd: HWND
    let scale: Double
    let surface: OpaquePointer
    /// Whether this screen showed anything last frame, so it's cleared once after.
    var drew = false
    /// Whether the window is kept out of screenshots (WDA_EXCLUDEFROMCAPTURE).
    let excluded: Bool

    init?(monitor: HMONITOR, frame: RECT, windowClass: [WCHAR], capturable: Bool = false) {
        self.monitor = monitor
        self.frame = frame
        let w = frame.right - frame.left, h = frame.bottom - frame.top
        let ex = wsExTopmost | wsExTransparent | wsExToolWindow | wsExLayered | wsExNoActivate | wsExNoRedirectionBitmap
        guard let hwnd = CreateWindowExW(ex, windowClass, windowClass, wsPopup, frame.left, frame.top, w, h,
                                         nil, nil, GetModuleHandleW(nil), nil) else { return nil }
        self.hwnd = hwnd
        // Layered windows need an alpha set before they show; 255 leaves the
        // swap chain's own alpha in charge. WS_EX_TRANSPARENT makes clicks pass through.
        SetLayeredWindowAttributes(hwnd, 0, 255, DWORD(LWA_ALPHA))
        excluded = capturable ? false : SetWindowDisplayAffinity(hwnd, wdaExcludeFromCapture)
        scale = Double(GetDpiForWindow(hwnd)) / 96
        guard let surface = nw_surface_create(UnsafeMutableRawPointer(hwnd), w, h) else {
            DestroyWindow(hwnd)
            return nil
        }
        self.surface = surface
        ShowWindow(hwnd, SW_SHOWNOACTIVATE)
    }

    deinit {
        nw_surface_destroy(surface)
        DestroyWindow(hwnd)
    }

    func contains(_ x: Double, _ y: Double) -> Bool {
        x >= Double(frame.left) && x < Double(frame.right) && y >= Double(frame.top) && y < Double(frame.bottom)
    }

    /// Whether a circle in global pixels touches this screen.
    func touches(_ x: Double, _ y: Double, radius r: Double) -> Bool {
        x + r >= Double(frame.left) && x - r < Double(frame.right) && y + r >= Double(frame.top) && y - r < Double(frame.bottom)
    }

    /// Global pixels to this window's pixels.
    func local(_ x: Double, _ y: Double) -> (Float, Float) {
        (Float(x - Double(frame.left)), Float(y - Double(frame.top)))
    }

    static func monitors() -> [(HMONITOR, RECT)] {
        var found: [(HMONITOR, RECT)] = []
        withUnsafeMutablePointer(to: &found) { list in
            _ = EnumDisplayMonitors(nil, nil, { monitor, _, _, data -> WindowsBool in
                let list = UnsafeMutablePointer<[(HMONITOR, RECT)]>(bitPattern: UInt(data))!
                var info = MONITORINFO()
                info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
                if let monitor, GetMonitorInfoW(monitor, &info) { list.pointee.append((monitor, info.rcMonitor)) }
                return true
            }, LPARAM(Int(bitPattern: list)))
        }
        return found
    }
}
