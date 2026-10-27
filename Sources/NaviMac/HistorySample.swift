#if DEBUG
import Foundation

/// Made-up History for looking at the window's design (`--history-sample`): a few
/// conversations and a kept GIS lesson, in throwaway folders.
enum HistorySample {
    static func show() {
        Bookmarks.useScratch()
        Bookmarks.shared.keep(Bookmark(
            title: "QGIS practical 3", goal: "Buffer the roads layer by 500 m and find the schools inside it",
            outline: ["Add the roads layer", "Open Vector › Geoprocessing", "Choose Buffer", "Set the distance to 500 m",
                      "Run it", "Select schools by location"],
            done: ["Added roads.shp from the practical folder", "Opened the Vector menu", "Chose Geoprocessing Tools › Buffer",
                   "Typed 500 in Distance"],
            next: "Click Run to make the buffer layer.", stuckOn: ["Choosing the distance units"],
            app: "QGIS", bundleID: "org.qgis.qgis",
            files: ["~/Documents/GIS/Practical 3.pdf", "~/Documents/GIS/Lecture 5 - Buffers.pdf"],
            lastUsed: Date().addingTimeInterval(-26 * 3600)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("navi-history-sample-\(UUID().uuidString)")
        let h = History(folder: folder)
        let talks: [(String, [(String, String)], TimeInterval)] = [
            ("What's a map projection?", [
                ("What's a map projection?", "[TOPIC:Map projections] A projection flattens the round Earth onto a flat map. [WRITE:200,200:sphere → plane] Every one stretches something: area, shape or distance. Mercator keeps shapes but swells the poles."),
                ("why does greenland look huge", "Mercator stretches everything more the further it is from the equator. [HIGHLIGHT:100,100,300,200:Greenland] Greenland is near the pole, so it's drawn about fourteen times too big."),
            ], -2 * 3600),
            ("Where's the export button?", [
                ("Where's the export button?", "[POINT:820,40:Export] Top right, under File."),
            ], -5 * 3600),
            ("Set up a new QGIS project", [
                ("Set up a new QGIS project", "[TOPIC:QGIS: first project] [TARGET:40,60,30:New] Click New Project, the blank page at the top left."),
                ("continue", "[TARGET:300,400,40:CRS] Now set the coordinate system: click the CRS button at the bottom right."),
            ], -27 * 3600),
        ]
        for (title, turns, ago) in talks {
            let id = h.begin(title: title, now: Date().addingTimeInterval(ago))
            for (q, r) in turns {
                h.record(thread: id, kind: "question", action: "fresh", content: [["type": "text", "text": q]],
                         reply: r, error: nil, stats: nil)
            }
        }
        HistoryWindow.show(h)
    }
}
#endif
