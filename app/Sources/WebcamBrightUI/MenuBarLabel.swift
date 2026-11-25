import SwiftUI
import WebcamBrightKit

public struct MenuBarLabel: View {
    let symbol: String

    public init(symbol: String) {
        self.symbol = symbol
    }

    public var body: some View {
        Image(systemName: symbol)
    }

    /// The icon for an engine state. `AppModel` stores the result and only publishes it when it
    /// changes, so face measurements don't redraw the status item.
    public static func symbol(for status: EngineStatus) -> String {
        if status.conflict != nil { return "exclamationmark.triangle" }
        switch status.state {
        case .paused: return "pause.circle"
        case .noCamera, .starting: return "video.slash"
        case .idle, .inCall:
            if status.access == .denied { return "exclamationmark.triangle" }
            return status.state == .inCall ? "web.camera.fill" : "web.camera"
        }
    }
}
