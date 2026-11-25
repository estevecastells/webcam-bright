import SwiftUI
import WebcamBrightKit

public struct MenuContent: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(status: model.status)
            if let other = model.status.conflict {
                Label("Another WebcamBright is running (\(other)). Quit or uninstall it: two would fight over the camera. Until then this one leaves the camera alone.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            AccessWarning(model: model)
            ModePicker(model: model)
            Divider()
            SettingsView(model: model)

            if let error = model.actionError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
                if model.loginItemNeedsApproval {
                    Button("Approve…") { model.openLoginItemSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("macOS needs you to allow WebcamBright in Login Items")
                }
            }
            .font(.callout)
            HStack {
                Button("Log") { model.openLog() }
                    .help("Every adjustment, with the face brightness before it")
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/estevecastells/webcam-bright")!)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .help("The camera goes back to its own auto exposure")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.panelVisibilityChanged(true) }
        .onDisappear { model.panelVisibilityChanged(false) }
    }
}

// MARK: - Header

@MainActor
private struct Header: View {
    let status: EngineStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: MenuBarLabel.symbol(for: status))
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let caption {
                        Text(caption).font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var p: CallPicture { status.picture }

    private var face: Double? {
        status.state == .inCall ? p.face : nil
    }

    /// Another copy is running, so this one isn't watching for calls.
    private var standingBy: Bool { status.conflict != nil && !status.isPaused }

    private var title: String {
        switch status.state {
        case .starting: "Starting…"
        case .noCamera: "No camera"
        case .idle: standingBy ? "Standing by" : "Ready"
        case .inCall: face.map { String(format: "%.0f", $0) } ?? "In a call"
        case .paused: "Paused"
        }
    }

    private var caption: String? {
        guard face != nil else { return nil }
        return String(format: "face · target %.0f", p.target)
    }

    private var lines: [String] {
        let camera = status.camera ?? "camera"
        switch status.state {
        case .starting:
            return []
        case .noCamera:
            return ["Looking for a camera named “\(status.cameraHint)”"]
        case .idle:
            var lines = [standingBy ? "Not watching for calls while the other copy runs" : "Waiting for an app to turn on the \(camera)"]
            if let last = status.lastCall {
                let face = last.averageFace.map { String(format: "face %.0f on average", $0) } ?? "no face seen"
                lines.append("Last call, \(last.ended.formatted(date: .omitted, time: .shortened)): \(face), "
                    + "\(last.adjustments) \(last.adjustments == 1 ? "adjustment" : "adjustments")")
            }
            return lines
        case .inCall:
            guard status.access == .granted else { return ["Can't see the picture without camera access"] }
            var lines: [String] = []
            if face == nil { lines.append("No face in view: holding the camera as it is") }
            lines.append(String(format: "Exposure %.1f ms · gain %d · contrast %d", Double(p.exposure) / 10, p.gain, p.contrast))
            if p.lowLight { lines.append("Low-light mode: about 25 fps until there is more light") }
            if p.adjustments > 0 {
                lines.append("\(p.adjustments) \(p.adjustments == 1 ? "adjustment" : "adjustments") this call")
            }
            return lines
        case let .paused(until):
            return [until.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until you turn it back on",
                    "The camera uses its own auto exposure"]
        }
    }

    private var tint: Color {
        switch status.state {
        case .inCall:
            guard let face else { return .primary }
            return abs(face - p.target) <= deadband ? .green : .orange
        case .idle: return .primary
        default: return .secondary
        }
    }
}

// MARK: - Camera access

@MainActor
private struct AccessWarning: View {
    let model: AppModel

    var body: some View {
        switch model.status.access {
        case .granted:
            EmptyView()
        case .undetermined:
            HStack {
                Label("WebcamBright needs camera access to see your face.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow…") { model.requestCameraAccess() }.controlSize(.small)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("WebcamBright can't see the camera. Turn it on in Privacy & Security → Camera.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Open Camera Settings") { model.requestCameraAccess() }.controlSize(.small)
            }
        }
    }
}

// MARK: - On, paused, off

@MainActor
private struct ModePicker: View {
    let model: AppModel

    var body: some View {
        Picker("", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            Text("On").tag(AppModel.Mode.on)
            Text("Pause 1 h").tag(AppModel.Mode.pauseHour)
            Text("Off").tag(AppModel.Mode.off)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Paused or off, the camera uses its own auto exposure")
    }
}

// MARK: - Settings

@MainActor
private struct SettingsView: View {
    let model: AppModel

    @State private var target = 115.0
    @State private var contrast = 100.0
    /// Only a slider being dragged sends unsaved changes.
    @State private var dragging = false

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 10) {
            slider("Face brightness", value: $target, range: Settings.targetRange, step: 5,
                   text: String(format: "%.0f", target),
                   help: "How bright your skin should look, from 0 to 255") { final in
                model.update(final: final) { $0.targetLuma = target }
            }
            slider("Daylight contrast", value: $contrast,
                   range: Double(Settings.dayContrastRange.lowerBound)...Double(Settings.dayContrastRange.upperBound), step: 4,
                   text: contrast == 128 ? "128 (camera's own)" : String(format: "%.0f", contrast),
                   help: "Lower softens the shadows on your face. In a dark room it rises on its own") { final in
                model.update(final: final) { $0.dayContrast = Int(contrast) }
            }
            HStack {
                Text("Anti-flicker").font(.callout)
                    .help("Match your mains: 50 Hz in Europe and most of the world, 60 Hz in most of the Americas")
                Spacer()
                Picker("", selection: Binding(get: { settings.powerLineHz }, set: { hz in model.update { $0.powerLineHz = hz } })) {
                    Text("50 Hz").tag(50)
                    Text("60 Hz").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if settings != settings.reset {
                Button("Restore defaults") { model.restoreDefaults() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.settings) { _, _ in if !dragging { load() } }
    }

    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String, help: String,
        apply: @escaping (_ final: Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(text).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { editing in
                dragging = editing
                if !editing { apply(true) }
            }
            .onChange(of: value.wrappedValue) { _, _ in if dragging { apply(false) } }
        }
        .help(help)
    }

    private func load() {
        target = model.settings.targetLuma
        contrast = Double(model.settings.dayContrast)
    }
}
