import Foundation

/// Which computer Navi runs on, for words that differ: what Claude is told
/// and what the user reads. Behaviour differences belong in the shells.
public enum Platform: Sendable, Equatable {
    case mac, windows

    public static var current: Platform {
        #if os(Windows)
        .windows
        #else
        .mac
        #endif
    }

    /// What the user's computer is called: "Mac" or "PC".
    public var computer: String { self == .mac ? "Mac" : "PC" }
}
