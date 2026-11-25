import ServiceManagement
import SwiftUI
import WebcamBrightKit
import WebcamBrightUI

@main
@MainActor
struct WebcamBrightApp: App {
    @State private var model: AppModel

    init() {
        let args = CommandLine.arguments
        // Calibration: `WebcamBright.app/Contents/MacOS/WebcamBright --measure photo.jpg` prints the
        // skin crop as an ffmpeg filter, to measure a photo's skin brightness the same way.
        if let i = args.firstIndex(of: "--measure") {
            guard i + 1 < args.count else { print("usage: WebcamBright --measure photo.jpg"); exit(2) }
            switch skinCrop(ofImageAt: args[i + 1]) {
            case let .success(crop): print(crop); exit(0)
            case let .failure(error): print(error); exit(1)
            }
        }
        // Diagnostics: `WebcamBright.app/Contents/MacOS/WebcamBright --login-item-status`
        if args.contains("--login-item-status") {
            let names: [SMAppService.Status: String] = [
                .enabled: "enabled", .notRegistered: "not registered",
                .requiresApproval: "requires approval in System Settings › Login Items", .notFound: "not found",
            ]
            print("open at login: \(names[SMAppService.mainApp.status] ?? "unknown")")
            exit(0)
        }
        // Uninstall: `--remove-login-item` takes WebcamBright out of Login Items.
        if args.contains("--remove-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        // One copy at a time: a second one would fight the first over the camera.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            print("WebcamBright is already running")
            exit(0)
        }
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Only the symbol: reading `status` here would re-render the scene on every measurement.
            MenuBarLabel(symbol: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
