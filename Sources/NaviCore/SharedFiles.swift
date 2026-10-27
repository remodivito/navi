import Foundation

/// Data files both platforms read: Resources/Shared (design-tokens.json,
/// owl.json, tags.md). The app bundle carries a copy (make-app.sh); a debug
/// build reads them from the source tree, as it does the fonts. Every value
/// also has a compiled-in fallback, so a missing or broken file never stops Navi.
public enum SharedFiles {
    /// Where the files are: `SP_SHARED_DIR` if set, then the bundle, then the source tree.
    public static var folder: URL? {
        let env = ProcessInfo.processInfo.environment["SP_SHARED_DIR"].map { URL(fileURLWithPath: $0) }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Shared")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Shared")
        return [env, bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func data(_ name: String) -> Data? {
        guard let url = folder?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Decodes a shared JSON file, or returns `fallback` (and says why in the log).
    static func decode<T: Decodable>(_ name: String, fallback: T) -> T {
        guard let data = data(name) else {
            trace("Shared file \(name) not found; using the built-in values.")
            return fallback
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            trace("Shared file \(name) couldn't be read (\(error)); using the built-in values.")
            return fallback
        }
    }
}
