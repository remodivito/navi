import AppKit

extension Prompt {
    static func label(_ shot: ScreenShot, of count: Int) -> String {
        label(index: shot.index, hasCursor: shot.hasCursor, of: count)
    }

    /// One turn's content from the Mac's screenshots, encoded as JPEGs here (see `turn(screens:…)`).
    static func turn(shots: [ScreenShot], context: String?, gesture: String?, message: String,
                     extras: [String] = []) -> [[String: Any]] {
        let screens = shots.compactMap { shot in
            Capture.jpeg(shot.image).map { Screen(index: shot.index, hasCursor: shot.hasCursor, width: Int(shot.pixelSize.width),
                                                  height: Int(shot.pixelSize.height), jpeg: $0) }
        }
        return turn(screens: screens, displays: shots.count, context: context, gesture: gesture, message: message, extras: extras)
    }
}
