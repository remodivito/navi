// swift-tools-version:5.10
import PackageDescription
import Foundation

// A `.dev-build` file next to this one (never committed; see .gitignore) turns
// on dev-only code: the History window then also keeps screenshots. Without
// it, as in any open-source build, that code isn't compiled in.
let devBuild = FileManager.default.fileExists(atPath: Context.packageDirectory + "/.dev-build")
// A `.with-kokoro` file builds in the on-device Kokoro voice (about 380 MB in the
// app), from the folder NAVI_KOKORO_DIR names (with kokoro-coreml/swift-tts, bundle
// and metal-wheel in it). Navi is text first for now, so it's off.
let kokoroDir = Context.environment["NAVI_KOKORO_DIR"] ?? ""
let withKokoro = FileManager.default.fileExists(atPath: Context.packageDirectory + "/.with-kokoro") && !kokoroDir.isEmpty

let devDefines: [SwiftSetting] = devBuild ? [.define("SP_DEV_SCREENSHOTS")] : []

// Each platform resolves only the shell it can build.
#if os(macOS)
// Sparkle (MIT): the standard Mac updater, so beta users get fixes without re-downloading.
let shellDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sparkle-project/Sparkle", "2.9.6"..<"3.0.0"),
]
let shellProducts: [Product] = [
    .executable(name: "Navi", targets: ["NaviMac"]),
]
let shellTargets: [Target] = [
    // The Mac shell: windows, drawing, capture, hotkeys, voice.
    .executableTarget(
        name: "NaviMac",
        dependencies: ["NaviCore", .product(name: "Sparkle", package: "Sparkle")]
            + (withKokoro ? [.product(name: "KokoroTTS", package: "KokoroTTS")] : []),
        swiftSettings: devDefines + (withKokoro ? [.define("SP_KOKORO")] : []),
        linkerSettings: [
            .linkedFramework("Carbon"),
            .linkedFramework("ScreenCaptureKit"),
        ]
    ),
]
#elseif os(Windows)
let shellDependencies: [Package.Dependency] = []
let shellProducts: [Product] = [
    .executable(name: "NaviWin", targets: ["NaviWin"]),
]
let shellTargets: [Target] = [
    // DirectComposition, Direct3D 11 and Direct2D behind a small C API: their
    // headers are C++ only, so Swift can't call them directly.
    .target(
        name: "NaviWinGfx",
        linkerSettings: [
            .linkedLibrary("d3d11"),
            .linkedLibrary("dxgi"),
            .linkedLibrary("d2d1"),
            .linkedLibrary("dcomp"),
            .linkedLibrary("dwmapi"),
        ]
    ),
    // The Windows shell: for now, a bare overlay on every screen.
    .executableTarget(
        name: "NaviWin",
        dependencies: ["NaviCore", "NaviWinGfx"],
        linkerSettings: [.linkedLibrary("user32")]
    ),
]
#else
let shellDependencies: [Package.Dependency] = []
let shellProducts: [Product] = []
let shellTargets: [Target] = []
#endif

let package = Package(
    name: "Navi",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "NaviCore", targets: ["NaviCore"]),
        .executable(name: "navi-core-check", targets: ["navi-core-check"]),
    ] + shellProducts,
    dependencies: shellDependencies + (withKokoro ? [
        // On-device neural voice (Apache 2.0), with word timings added.
        .package(name: "KokoroTTS", path: kokoroDir + "/kokoro-coreml/swift-tts"),
    ] : []),
    targets: [
        // The teaching logic, shared with a future Windows shell: Foundation only
        // (CGPoint and CGRect come with Foundation on every platform). No AppKit,
        // ScreenCaptureKit, Carbon or AVFoundation.
        .target(
            name: "NaviCore",
            swiftSettings: devDefines
        ),
        // The core's self-tests on their own, for any platform.
        .executableTarget(
            name: "navi-core-check",
            dependencies: ["NaviCore"]
        ),
    ] + shellTargets
)
