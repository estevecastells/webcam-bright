import AppKit
import AVFoundation
import Foundation
import Observation
import ServiceManagement
import WebcamBrightKit

@MainActor
@Observable
public final class AppModel {
    /// What the panel shows. While the panel is closed it only follows state changes (idle, in a
    /// call, paused...), not every face measurement.
    public private(set) var status = EngineStatus()
    public private(set) var settings: Settings
    /// The menu bar icon, kept apart from `status` so the status item only redraws when the icon
    /// itself changes.
    public private(set) var menuBarSymbol = MenuBarLabel.symbol(for: EngineStatus())
    private(set) var actionError: String?
    private(set) var openAtLogin = false
    private(set) var loginItemNeedsApproval = false

    private let engine: Engine?
    private var panelOpen = false
    private var windowObservers: [NSObjectProtocol] = []

    private static let pausedUntilKey = "pausedUntil"
    private static let loginItemConfiguredKey = "loginItemConfigured"

    public init() {
        let settings = Settings.load()
        self.settings = settings
        let engine = Engine(settings: settings)
        self.engine = engine
        engine.onStatus = { [weak self] s in MainActor.assumeIsolated { self?.received(s) } }
        configureLoginItemOnFirstLaunch()
        observePanelWindow()
        let defaults = UserDefaults.standard
        var pausedUntil = defaults.object(forKey: Self.pausedUntilKey) as? Date
        if let until = pausedUntil, until <= Date() {
            defaults.removeObject(forKey: Self.pausedUntilKey)
            pausedUntil = nil
        }
        engine.start(pausedUntil: pausedUntil)
    }

    /// A static model for README screenshots: no engine, no camera.
    public init(preview: EngineStatus, settings: Settings) {
        engine = nil
        status = preview
        self.settings = settings
        menuBarSymbol = MenuBarLabel.symbol(for: preview)
        openAtLogin = true
    }

    private func received(_ s: EngineStatus) {
        assign(\.menuBarSymbol, MenuBarLabel.symbol(for: s))
        let sameState = s.state == status.state && s.access == status.access && s.camera == status.camera
            && s.lastCall == status.lastCall && s.conflict == status.conflict
        if panelOpen || !sameState { status = s }
        // The pause ran out on its own.
        if !s.isPaused, UserDefaults.standard.object(forKey: Self.pausedUntilKey) != nil {
            UserDefaults.standard.removeObject(forKey: Self.pausedUntilKey)
        }
    }

    /// Observation notifies on every assignment, even of an equal value, and each notification
    /// re-renders the menu bar item. Assign only real changes.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Panel

    /// The panel is the app's only window, so key status tracks whether it's open. This backs up
    /// the panel's onAppear/onDisappear, which SwiftUI doesn't call on every open and close of a
    /// menu bar window on every macOS version.
    private func observePanelWindow() {
        let center = NotificationCenter.default
        for (name, open) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelVisibilityChanged(open) }
            })
        }
    }

    public func panelVisibilityChanged(_ open: Bool) {
        guard open != panelOpen, let engine else { return }
        panelOpen = open
        if open, engine.status != status { status = engine.status }
    }

    // MARK: Running, paused, off

    enum Mode: Hashable { case on, pauseHour, off }

    var mode: Mode {
        guard case let .paused(until) = status.state else { return .on }
        return until == nil ? .off : .pauseHour
    }

    func setMode(_ mode: Mode) {
        guard let engine, mode != self.mode else { return }
        let defaults = UserDefaults.standard
        switch mode {
        case .on:
            defaults.removeObject(forKey: Self.pausedUntilKey)
            engine.resume()
        case .pauseHour:
            let until = Date().addingTimeInterval(3600)
            defaults.set(until, forKey: Self.pausedUntilKey)
            engine.pause(until: until)
        case .off:
            defaults.set(Date.distantFuture, forKey: Self.pausedUntilKey)
            engine.pause(until: nil)
        }
        status = engine.status
    }

    // MARK: Settings

    /// Change settings. `final` is false while a slider is still being dragged: the camera follows
    /// at once, and the change is saved and logged when the slider is let go.
    func update(final: Bool = true, _ change: (inout Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings || final else { return }
        settings = s
        if final { s.save() }
        engine?.update(s, final: final)
    }

    func restoreDefaults() {
        update { $0 = $0.reset }
    }

    // MARK: Camera access

    func requestCameraAccess() {
        if status.access == .undetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }
    }

    // MARK: Open at login

    /// Open at login by default the first time the app runs; after that the user's choice (from
    /// the menu or System Settings) wins.
    private func configureLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.loginItemConfiguredKey) {
            defaults.set(true, forKey: Self.loginItemConfiguredKey)
            setOpenAtLogin(true)
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        let state = SMAppService.mainApp.status
        openAtLogin = state == .enabled || state == .requiresApproval
        loginItemNeedsApproval = state == .requiresApproval
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            actionError = nil
        } catch {
            actionError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openLog() {
        NSWorkspace.shared.open(Log.url)
    }
}
