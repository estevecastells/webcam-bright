// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WebcamBright",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WebcamBright", targets: ["WebcamBright"]),
        .executable(name: "uvcctl", targets: ["uvcctl"]),
    ],
    targets: [
        // UVC camera controls over IOKit, in plain C.
        .target(
            name: "CUVC",
            cSettings: [.unsafeFlags(["-Wall"])],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // Command line tool for those controls: `build/uvcctl list`.
        .executableTarget(name: "uvcctl", dependencies: ["CUVC"], cSettings: [.unsafeFlags(["-Wall"])]),
        // The engine: call detection, face measurement and the camera levers. No UI.
        .target(name: "WebcamBrightKit", dependencies: ["CUVC"]),
        // SwiftUI views and the app model.
        .target(name: "WebcamBrightUI", dependencies: ["WebcamBrightKit"]),
        // The menu bar app.
        .executableTarget(name: "WebcamBright", dependencies: ["WebcamBrightUI", "WebcamBrightKit"]),
        // Renders the README screenshot from the real views: `swift run RenderScreenshots ../docs/images`.
        .executableTarget(name: "RenderScreenshots", dependencies: ["WebcamBrightUI", "WebcamBrightKit"]),
        // Self-checking test runner for the lever logic. XCTest isn't available with the Command
        // Line Tools alone, so `swift run KitChecks` works on any setup.
        .executableTarget(name: "KitChecks", dependencies: ["WebcamBrightKit"]),
    ]
)
