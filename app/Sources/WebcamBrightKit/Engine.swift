// WebcamBright keeps the webcam exposed for your face, on its own.
//
// It does nothing until another app (Zoom, Meet, Slack, Chrome...) turns the camera on. Then,
// about twice a second, it finds your face with Apple's on-device face detection and nudges the
// camera until your face sits at the target brightness. It never turns the camera on by itself.
// It also reapplies its settings when the camera is plugged in, when the Mac wakes, and whenever
// it notices the camera has reset itself. Paused, or after Quit, the camera gets its own auto
// exposure back.
//
// Log: ~/Library/Logs/webcam-bright.log

import AppKit
import AVFoundation
import CoreMediaIO
import CUVC
import Vision

public final class Engine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main thread whenever `status` changes.
    public var onStatus: ((EngineStatus) -> Void)?
    public private(set) var status = EngineStatus()

    // Main thread: which camera, whether a call app is using it, and our capture session.
    private enum Phase { case idle, watching(since: Date), checking(stoppedAt: Date?) }
    private var phase = Phase.idle
    private var settings: Settings
    private var loggedSettings: Settings
    private var device: AVCaptureDevice?
    private var cmioID: CMIOObjectID?
    private var session: AVCaptureSession?
    private var paused = false
    private var pausedUntil: Date?      // nil while paused: until resumed
    private var picture = CallPicture()     // the control queue's latest
    private var lastCall: CallSummary?
    private var conflict: String?
    private var conflictCheckedAt = Date.distantPast
    private var warnedNoAccess = false
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let sessionQueue = DispatchQueue(label: "webcam-bright.session")  // start/stop block

    // Control queue: everything that touches camera controls or frames.
    private let queue = DispatchQueue(label: "webcam-bright.control")
    private var uvc: OpaquePointer?
    private var levers = Levers()
    private var tuning: Settings         // the control queue's copy of `settings`
    private var tone: Tone?              // contrast and saturation last set
    private var framesFrom = Date.distantFuture
    private var lastSample = Date.distantPast
    private var lastVerify = Date.distantPast
    private var lastFace: (value: Double, at: Date)?
    private var faceSum = 0.0, faceCount = 0, adjustments = 0
    private let faceRequest = VNDetectFaceRectanglesRequest()
    // One handler for the whole run: a new VNImageRequestHandler per frame made Vision reload and
    // recompile the face model every time (most of the CPU in the profile).
    private let faceHandler = VNSequenceRequestHandler()

    public init(settings: Settings) {
        self.settings = settings
        loggedSettings = settings
        tuning = settings
        super.init()
        status.cameraHint = settings.cameraName
        picture.target = settings.targetLuma
        picture.contrast = settings.dayContrast
    }

    /// Starts watching. `pausedUntil`: start paused until then (`.distantFuture`: until resumed).
    public func start(pausedUntil: Date? = nil) {
        Log.trim()
        log("started")
        if let until = pausedUntil, until > Date() {
            paused = true
            self.pausedUntil = until == .distantFuture ? nil : until
            log(self.pausedUntil.map { "paused until \(Self.timeFormat.string(from: $0))" } ?? "paused until resumed")
        }
        // A background app with no windows gets App Napped, which stalls the timer below.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watch the webcam during calls")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            log(granted ? "camera access: granted"
                        : "camera access: denied (turn on WebcamBright in System Settings > Privacy & Security > Camera)")
            DispatchQueue.main.async { self.publish() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, !self.paused, self.conflict == nil else { return }
                self.queue.async { self.reopenUVC(); self.applySettings("Mac woke up") }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutDown() })
        // Common modes: the timer keeps running while a slider in the menu is being dragged.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// New settings from the menu. `final` is false while a slider is still being dragged.
    public func update(_ new: Settings, final: Bool = true) {
        settings = new
        if final && new != loggedSettings {
            loggedSettings = new
            log(String(format: "settings: target %.0f, daylight contrast %d, anti-flicker %d Hz",
                       new.targetLuma, new.dayContrast, new.powerLineHz))
        }
        let touchCamera = device != nil && !paused && conflict == nil
        queue.async {
            let before = self.tuning
            self.tuning = new
            defer { self.report() }
            guard touchCamera else { return }
            if new.powerLine != before.powerLine { self.set("power-line", new.powerLine) }
            if new.dayContrast != before.dayContrast { self.applyTone(force: true) }
        }
    }

    /// Hands the camera back to its own auto exposure until `until` (nil: until resumed).
    public func pause(until: Date?) {
        pausedUntil = until
        log(until.map { "paused until \(Self.timeFormat.string(from: $0))" } ?? "paused until resumed")
        guard !paused else { publish(); return }
        paused = true
        let inCall = isInCall
        if session != nil { stopSession {} }
        phase = .idle
        if device != nil && conflict == nil {
            queue.async {
                if inCall { self.endCall() }
                self.handBackToCamera("paused")
            }
        }
        publish()
    }

    public func resume() {
        guard paused else { return }
        paused = false
        pausedUntil = nil
        log("resumed")
        if device != nil && conflict == nil { queue.async { self.applySettings("resumed") } }
        tick()
    }

    // MARK: Watching the camera (main thread)

    private var isInCall: Bool {
        if case .idle = phase { false } else { true }
    }

    private func tick() {
        if paused, let until = pausedUntil, Date() >= until { resume(); return }
        checkForAnotherCopy()
        refreshDevice()
        defer { publish() }
        guard !paused, conflict == nil, device != nil, let cmioID else { return }
        queue.async { self.verifySettings() }

        switch phase {
        case .idle:
            if cmioIsRunningSomewhere(cmioID) {
                log("camera turned on by an app")
                queue.async { self.beginCall() }
                startSession(firstTime: true)
            }
        case .watching(let since):
            // Our own session keeps the camera "running", so step aside now and then to see
            // whether the call app still has it.
            if Date().timeIntervalSince(since) >= releaseCheckEvery {
                phase = .checking(stoppedAt: nil)
                stopSession { [weak self] in
                    // Unless the call ended or the camera went away meanwhile.
                    if case .checking = self?.phase { self?.phase = .checking(stoppedAt: Date()) }
                }
            }
        case .checking(let stoppedAt):
            guard let stoppedAt, Date().timeIntervalSince(stoppedAt) >= 0.8 else { return }
            if cmioIsRunningSomewhere(cmioID) {
                startSession(firstTime: false)
            } else {
                phase = .idle
                queue.async { self.endCall() }
            }
        }
    }

    private func refreshDevice() {
        let hint = settings.cameraName
        let current = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first { $0.localizedName.contains(hint) }
        guard current?.uniqueID != device?.uniqueID else { return }

        if session != nil { stopSession {} }
        if isInCall { queue.async { self.endCall() } }
        phase = .idle
        device = current
        cmioID = current.flatMap { cmioDevice(uniqueID: $0.uniqueID) }
        if let current {
            log("camera connected: \(current.localizedName)")
            let paused = paused, ours = conflict == nil
            queue.async {
                self.reopenUVC()
                guard ours else { return }
                if paused { self.handBackToCamera("camera connected while paused") } else { self.applySettings("camera connected") }
            }
        } else {
            log("camera disconnected")
            queue.async { self.closeUVC() }
        }
    }

    /// Another WebcamBright (an older helper, or a second copy of the app) would fight this one over
    /// the camera: while one runs, leave the camera to it.
    private func checkForAnotherCopy() {
        guard Date().timeIntervalSince(conflictCheckedAt) >= 5 else { return }
        conflictCheckedAt = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        let other = NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != me else { return false }
            let id = app.bundleIdentifier ?? "", exe = app.executableURL?.lastPathComponent ?? ""
            return id.contains("webcam-bright") || exe == "webcam-bright" || exe == "WebcamBright"
        }
        let found = other.map { $0.bundleIdentifier ?? $0.executableURL?.path ?? "another copy" }
        guard found != conflict else { return }
        conflict = found
        if let found {
            log("another WebcamBright is running (\(found)): leaving the camera to it")
            if session != nil { stopSession {} }
            if isInCall { queue.async { self.endCall() } }
            phase = .idle
        } else {
            log("the other WebcamBright stopped: taking over the camera")
            if device != nil && !paused { queue.async { self.applySettings("taking over") } }
        }
    }

    private func startSession(firstTime: Bool) {
        guard let device else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            if !warnedNoAccess { log("camera is on but WebcamBright has no camera access") }
            warnedNoAccess = true
            phase = .watching(since: Date())
            return
        }
        // Keep the format (resolution, frame rate) the call app picked: hold the configuration
        // lock with the current format set, so our session can't switch it to its own preset.
        let locked = (try? device.lockForConfiguration()) != nil
        if locked { device.activeFormat = device.activeFormat }
        let s = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        // Small frames are plenty to measure a face and cost far less CPU and memory than full
        // HD. Keep the call app's exact aspect ratio, or AVFoundation refuses the size.
        // 420v is what the camera delivers at 30 fps, so no per-frame conversion is needed.
        var videoSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let source = device.activeFormat.formatDescription.dimensions
        if source.width > analysisWidth, (analysisWidth * Int(source.height)) % Int(source.width) == 0 {
            videoSettings[kCVPixelBufferWidthKey as String] = analysisWidth
            videoSettings[kCVPixelBufferHeightKey as String] = analysisWidth * Int(source.height) / Int(source.width)
        }
        output.videoSettings = videoSettings
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input), s.canAddOutput(output) else {
            if locked { device.unlockForConfiguration() }
            log("could not attach to the camera")
            phase = .watching(since: Date())
            return
        }
        s.addInput(input)
        s.addOutput(output)
        // Only a few frames a second reach us; the call app still gets every frame.
        if let connection = output.connection(with: .video), connection.isVideoMinFrameDurationSupported {
            connection.videoMinFrameDuration = CMTime(value: 1, timescale: analysisFPS)
        }
        session = s
        phase = .watching(since: Date())
        let settle = firstTime ? 1.5 : 0.3
        queue.async { self.framesFrom = Date().addingTimeInterval(settle) }
        sessionQueue.async {
            s.startRunning()
            if locked { device.unlockForConfiguration() }
            if firstTime {
                let d = device.activeFormat.formatDescription.dimensions
                log("watching the picture (call app format \(d.width)x\(d.height))")
            }
        }
    }

    private func stopSession(then done: @escaping () -> Void) {
        guard let s = session else { done(); return }
        session = nil
        sessionQueue.async {
            s.stopRunning()
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Quit: let go of the camera and give it its own auto exposure back, so it isn't left on
    /// fixed settings for the next call.
    private func shutDown() {
        timer?.invalidate()
        if let s = session {
            session = nil
            sessionQueue.sync { s.stopRunning() }
        }
        let inCall = isInCall, handBack = device != nil && !paused && conflict == nil
        phase = .idle
        queue.sync {
            if inCall { self.endCall() }
            if handBack { self.handBackToCamera("quit") }
            self.closeUVC()
        }
        log("stopped")
        Log.flush()
    }

    private func publish() {
        var s = status
        if paused {
            s.state = .paused(until: pausedUntil)
        } else if device == nil {
            s.state = .noCamera
        } else {
            s.state = isInCall ? .inCall : .idle
        }
        s.access = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
        s.camera = device?.localizedName
        s.cameraHint = settings.cameraName
        s.picture = picture
        s.lastCall = lastCall
        s.conflict = conflict
        guard s != status else { return }
        status = s
        onStatus?(s)
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Frames (control queue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now >= framesFrom, now.timeIntervalSince(lastSample) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSample = now

        try? faceHandler.perform([faceRequest], on: buffer, orientation: .up)
        if let face = largestFace(faceRequest.results), let skin = meanLuma(buffer, skinRegion(face)) {
            faceSum += skin; faceCount += 1
            lastFace = (skin, now)
            adjust(toward: skin)
        } else if let frame = meanLuma(buffer, CGRect(x: 0, y: 0, width: 1, height: 1)), frame < 40 || frame > 245 {
            // No face because the whole picture is far too dark or blown out: fix that first.
            // Otherwise (you stepped away) hold, so the window behind you doesn't steer anything.
            adjust(toward: frame)
        }
        report()
    }

    private func adjust(toward measured: Double) {
        let target = tuning.targetLuma
        guard let move = levers.adjust(toward: measured, target: target, reading: {
            Levers.Reading(exposure: get("exposure"), gain: get("gain"), brightness: get("brightness"))
        }) else { return }
        for (name, value) in levers.controls(for: move) { set(name, value) }
        applyTone()
        adjustments += 1
        if move == .lowLightOff {
            log(String(format: "face %.0f (target %.0f): low-light mode off -> exposure %d, gain %d, brightness %d, contrast %d",
                       measured, target, levers.exposure, levers.gain, levers.brightness, tone?.contrast ?? 0))
        } else if adjustments <= 6 || adjustments % 20 == 0 {
            log(String(format: "face %.0f (target %.0f): %@ -> exposure %d, gain %d, brightness %d, contrast %d (%.1f per gain unit)",
                       measured, target, move.rawValue, levers.exposure, levers.gain, levers.brightness,
                       tone?.contrast ?? 0, levers.gainPerUnit))
        }
    }

    /// The face and controls, for the menu.
    private func report() {
        var p = CallPicture()
        if let f = lastFace, Date().timeIntervalSince(f.at) < 2 { p.face = f.value }
        p.target = tuning.targetLuma
        p.exposure = levers.exposure
        p.gain = levers.gain
        p.brightness = levers.brightness
        p.contrast = tone?.contrast ?? levers.tone(dayContrast: tuning.dayContrast).contrast
        p.lowLight = levers.lowLight
        p.adjustments = adjustments
        DispatchQueue.main.async {
            self.picture = p
            self.publish()
        }
    }

    private func beginCall() {
        faceSum = 0; faceCount = 0; adjustments = 0
        lastFace = nil
        levers.beginCall()
        applySettings("call started")
    }

    private func endCall() {
        framesFrom = .distantFuture
        lastFace = nil
        let average = faceCount > 0 ? faceSum / Double(faceCount) : nil
        log("camera turned off: average face \(average.map { String(format: "%.0f", $0) } ?? "not seen"), \(adjustments) adjustments, " +
            "ended at exposure \(levers.exposure), gain \(levers.gain), brightness \(levers.brightness)")
        let summary = CallSummary(ended: Date(), averageFace: average, adjustments: adjustments)
        DispatchQueue.main.async { self.lastCall = summary }
        report()
    }

    // MARK: Camera controls (control queue)

    private func applyTone(force: Bool = false) {
        let t = levers.tone(dayContrast: tuning.dayContrast)
        guard force || t != tone else { return }
        if set("contrast", t.contrast) && set("saturation", t.saturation) { tone = t }
    }

    private var baseSettings: [(String, Int)] {
        [
            ("power-line", tuning.powerLine),  // anti-flicker: 1 = 50 Hz, 2 = 60 Hz
            ("backlight", 1),
            ("ae-mode", 1),                    // manual: this program is the auto exposure now
        ]
    }

    private func applySettings(_ reason: String) {
        var ok = true
        for (name, value) in baseSettings { ok = set(name, value) && ok }
        ok = set("exposure", levers.exposure) && ok
        ok = set("gain", levers.gain) && ok
        ok = set("brightness", levers.brightness) && ok
        applyTone(force: true)
        log("\(reason): settings \(ok ? "applied" : "could not be applied") " +
            "(exposure \(levers.exposure), gain \(levers.gain), brightness \(levers.brightness))")
        report()
    }

    /// The camera's own defaults for what WebcamBright moves, then its own auto exposure.
    private func handBackToCamera(_ reason: String) {
        var ok = true
        for name in handBackControls {
            if let value = get(name, UInt8(UVC_GET_DEF)) { ok = set(name, value) && ok }
        }
        ok = set("ae-mode", get("ae-mode", UInt8(UVC_GET_DEF)) ?? 8) && ok
        tone = nil
        log("\(reason): camera back on its own auto exposure\(ok ? "" : " (some controls could not be set)")")
    }

    private func verifySettings() {
        guard Date().timeIntervalSince(lastVerify) >= 30 else { return }
        lastVerify = Date()
        guard let aeMode = get("ae-mode") else { return }  // camera not reachable right now
        if aeMode != 1 || get("power-line") != tuning.powerLine || get("backlight") != 1 {
            applySettings("camera had reset its settings")
        }
    }

    private func reopenUVC() {
        closeUVC()
        uvc = uvc_open(tuning.cameraName)
    }

    private func closeUVC() {
        if let uvc { uvc_close(uvc) }
        uvc = nil
    }

    private func get(_ name: String, _ code: UInt8 = UInt8(UVC_GET_CUR)) -> Int? {
        var value = 0
        for attempt in 0..<2 {
            if uvc == nil || attempt == 1 { reopenUVC() }
            if let uvc, uvc_get(uvc, name, code, &value) == 0 { return value }
        }
        return nil
    }

    @discardableResult
    private func set(_ name: String, _ value: Int) -> Bool {
        for attempt in 0..<2 {
            if uvc == nil || attempt == 1 { reopenUVC() }
            if let uvc, uvc_set(uvc, name, value) == 0 { return true }
        }
        return false
    }
}
