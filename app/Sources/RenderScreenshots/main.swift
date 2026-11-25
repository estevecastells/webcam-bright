// Renders the menu bar panel to PNG (light and dark) with the app's real SwiftUI views, from a
// made-up call. Needs no camera and no screen-recording permission:
//
//   swift run RenderScreenshots ../docs/images

import AppKit
import SwiftUI
import WebcamBrightKit
import WebcamBrightUI

let args = CommandLine.arguments
guard args.count == 2 else {
    print("usage: RenderScreenshots <output-dir>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var status = EngineStatus()
status.state = .inCall
status.access = .granted
status.camera = "HD Pro Webcam C920"
status.cameraHint = "C920"
status.picture.face = 117
status.picture.target = 115
status.picture.exposure = 156
status.picture.gain = 34
status.picture.brightness = 128
status.picture.contrast = 100
status.picture.adjustments = 9

/// The panel as it appears under the menu bar: rounded, on the window background.
struct Panel: View {
    let model: AppModel

    var body: some View {
        MenuContent(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

@MainActor
func render(dark: Bool, to url: URL) throws {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    var settings = Settings()
    settings.powerLineHz = 50
    let host = NSHostingView(rootView: Panel(model: AppModel(preview: status, settings: settings)))
    host.appearance = appearance
    // Lay out once and let onAppear state settle (the sliders load there), then measure.
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.display()

    let scale = 2
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.featureUnsupported) }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
    print("wrote \(url.path) (\(Int(size.width))×\(Int(size.height)) pt)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    do {
        try render(dark: false, to: outDir.appendingPathComponent("panel-light.png"))
        try render(dark: true, to: outDir.appendingPathComponent("panel-dark.png"))
    } catch {
        print("render failed: \(error)")
        exit(1)
    }
}
