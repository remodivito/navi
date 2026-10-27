import Foundation

/// Frame intervals and per-frame work, summarised as percentiles.
struct FrameStats {
    var intervals: [Double] = []   // seconds between frame starts
    var work: [Double] = []        // seconds spent updating, drawing and presenting
    let refresh: Double            // the compositor's period, in seconds

    mutating func reset() { intervals.removeAll(keepingCapacity: true); work.removeAll(keepingCapacity: true) }

    private static func pct(_ sorted: [Double], _ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    func summary(_ label: String) -> String {
        let i = intervals.sorted(), w = work.sorted()
        let total = intervals.reduce(0, +)
        let fps = total > 0 ? Double(intervals.count) / total : 0
        // A frame "late" by more than half a refresh period means the compositor showed the old one again.
        let late = refresh > 0 ? intervals.filter { $0 > refresh * 1.5 }.count : 0
        let over60 = intervals.filter { $0 > 1.5 / 60 }.count
        func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }
        return "\(label): \(intervals.count) frames, \(String(format: "%.1f", fps)) fps | interval ms p50 \(ms(Self.pct(i, 0.5))) "
            + "p95 \(ms(Self.pct(i, 0.95))) p99 \(ms(Self.pct(i, 0.99))) max \(ms(i.last ?? 0)) | "
            + "late vs refresh \(late), over 25 ms \(over60) | work ms p50 \(ms(Self.pct(w, 0.5))) p95 \(ms(Self.pct(w, 0.95))) max \(ms(w.last ?? 0))"
    }
}
