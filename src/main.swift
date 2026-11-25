// WebcamBright keeps the webcam exposed for your face, on its own.
//
// It runs in the background (LaunchAgent io.github.estevecastells.webcam-bright) and does nothing until
// another app (Zoom, Meet, Slack, Chrome...) turns the camera on. Then, about twice a second,
// it finds your face with Apple's on-device face detection and nudges the camera until your
// face sits at the target brightness. It never turns the camera on by itself. It also
// reapplies its settings when the camera is plugged in, when the Mac wakes, and whenever it
// notices the camera has reset itself.
//
// What the Logitech C920 really does (measured 2026-11-25):
//  - exposure only takes the values in `exposureLadder`; anything else falls back to 15.6 ms,
//    and from 3.9 ms up the camera evens the picture out itself, so exposure is a coarse lever;
//  - gain is the reliable lever: face 104 / 150 / 184 / 208 at gain 0 / 10 / 20 / 30;
//  - brightness is a gentle offset, used here to darken in small steps;
//  - 31.2 ms exposure drops the camera to about 25 fps, so it is a last resort;
//  - in a dark room lit only by the screen it depends on the screen: with light content gain 100
//    at 15.6 ms reached the target at 30 fps, with dark content the face stayed near 50 even at
//    31.2 ms; past ~100 more gain makes the picture darker, and contrast/saturation 140 look less flat.
//
// Log: ~/Library/Logs/webcam-bright.log
// Calibration helper: webcam-bright --measure photo.jpg  (prints the skin crop for ffmpeg)

import AppKit
import AVFoundation
import CoreMediaIO
import ImageIO
import Vision

// MARK: - Settings

let cameraHint = "C920"           // part of the camera's name (run uvcctl list to see yours)
let targetLuma = 115.0            // skin brightness to aim for (0-255). Calibrated 2026-11-25:
                                  // factory 49, tuned shot 105 (looked right), gain 40 200 (washed out)
let deadband = 8.0                // leave the camera alone when this close to the target
let exposureLadder = [3, 9, 19, 39, 78, 156, 312]  // 0.1 ms units
let normalTopRung = 5             // 15.6 ms: the longest exposure that still gives 30 fps
let lowLightGain = 100            // only past this gain at 15.6 ms switch to 31.2 ms (about 25 fps)
let lowLightOffset = 10           // what 31.2 ms adds, in gain units: the camera evens most of it out
                                  // (gain 100: face 127 at 31.2 ms, 117 at 15.6 ms, ~13 units; measured)
let lowLightExitGain = 40         // at 31.2 ms, below this gain there is light enough for 15.6 ms and 30 fps
                                  // again (about gain 50 there, well below where low-light mode starts)
let maxGain = 100                 // above ~100 the C920 gets darker again (gain 160 < gain 100, measured)
let dayContrast = 100             // contrast in daylight: softer face shadows than the camera's 128
                                  // (95 still looked natural, 64 flat and grey; tested 2026-11-25)
let darkTone = 140                // contrast and saturation in a room lit only by the screen, which
                                  // alone looks grey and flat (saturation is 128 in daylight)
let toneFrom = 60, toneFull = 100 // how dark the room is, as the gain it needs at 15.6 ms: daylight,
                                  // even against a window, needed 20-50; screen light alone 100 or more
let analysisWidth = 640           // frames we analyse are scaled down to this width
let analysisFPS: Int32 = 4        // and delivered at this rate (we sample twice a second)
let gainPerUnitStart = 2.0        // face brightness per gain unit; it varies with the light
                                  // (4.6 and 0.75 measured on the same day), so it is learned live
let brightnessRange = 80...128    // 128 is neutral; lower values darken gently
let brightnessStep = 4
let releaseCheckEvery = 6.0       // seconds between checks that the call app still has the camera
let baseSettings: [(String, Int)] = [
    ("power-line", 1),            // anti-flicker: 1 = 50 Hz (Europe), 2 = 60 Hz (Americas)
    ("backlight", 1),
    ("ae-mode", 1),               // manual: this program is the auto exposure now
]

// MARK: - Log

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/webcam-bright.log")
let logQueue = DispatchQueue(label: "webcam-bright.log")
let logDateFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(logDateFormat.string(from: Date())) \(message)\n"
    logQueue.async {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

func trimLog() {
    if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 1_000_000 {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Face measurement

/// Forehead, eyes, nose and cheeks inside a Vision face box (origin bottom-left):
/// skips the hair at the edges and the mouth and beard below.
func skinRegion(_ face: CGRect) -> CGRect {
    CGRect(x: face.minX + face.width * 0.2, y: face.minY + face.height * 0.35,
           width: face.width * 0.6, height: face.height * 0.5)
}

func largestFace(_ results: [VNFaceObservation]?) -> CGRect? {
    results?.map(\.boundingBox).max { $0.width * $0.height < $1.width * $1.height }
}

/// Mean luma over a normalized region with Vision's bottom-left origin, on the full 0-255 scale
/// the target was calibrated on (video-range buffers store 16-235 and are rescaled).
func meanLuma(_ buffer: CVPixelBuffer, _ region: CGRect) -> Double? {
    guard let raw = rawMeanLuma(buffer, region) else { return nil }
    let videoRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    return videoRange ? min(255, max(0, (raw - 16) * 255 / 219)) : raw
}

private func rawMeanLuma(_ buffer: CVPixelBuffer, _ region: CGRect) -> Double? {
    guard CVPixelBufferIsPlanar(buffer) else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let x0 = max(0, Int(region.minX * CGFloat(w))), x1 = min(w, Int(region.maxX * CGFloat(w)))
    let y0 = max(0, Int((1 - region.maxY) * CGFloat(h))), y1 = min(h, Int((1 - region.minY) * CGFloat(h)))
    guard x1 > x0, y1 > y0 else { return nil }
    var sum = 0, count = 0
    for y in stride(from: y0, to: y1, by: 2) {
        let row = pixels + y * rowBytes
        for x in stride(from: x0, to: x1, by: 2) {
            sum += Int(row[x])
            count += 1
        }
    }
    return count > 0 ? Double(sum) / Double(count) : nil
}

// MARK: - Is the camera streaming to anyone? (CoreMediaIO)

func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func cmioDevice(uniqueID: String) -> CMIOObjectID? {
    var address = cmioAddress(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return nil }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return nil }
    for id in ids {
        var uidAddress = cmioAddress(kCMIODevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if CMIOObjectGetPropertyData(id, &uidAddress, 0, nil, uidSize, &uidSize, &uid) == 0,
           let value = uid?.takeRetainedValue() as String?, value == uniqueID { return id }
    }
    return nil
}

func cmioIsRunningSomewhere(_ id: CMIOObjectID) -> Bool {
    var address = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return CMIOObjectGetPropertyData(id, &address, 0, nil, size, &size, &running) == 0 && running != 0
}

// MARK: - Controller

final class Controller: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Main thread: which camera, whether a call app is using it, and our capture session.
    private enum Phase { case idle, watching(since: Date), checking(stoppedAt: Date?) }
    private var phase = Phase.idle
    private var device: AVCaptureDevice?
    private var cmioID: CMIOObjectID?
    private var session: AVCaptureSession?
    private var warnedNoAccess = false
    private var activity: NSObjectProtocol?
    private let sessionQueue = DispatchQueue(label: "webcam-bright.session")  // start/stop block

    // Control queue: everything that touches camera controls or frames.
    private let queue = DispatchQueue(label: "webcam-bright.control")
    private var uvc: OpaquePointer?
    private var rung = normalTopRung
    private var gain = 0
    private var brightness = 128
    private var tone = 0                // contrast last set; saturation follows the same darkness
    private var lowestRung = 0          // a rung that proved too dark this call is not tried again
    private var movedDownTo: Int?
    private var gainPerUnit = gainPerUnitStart
    private var lastGainMove: (delta: Int, faceBefore: Double)?
    private var framesFrom = Date.distantFuture
    private var lastSample = Date.distantPast
    private var lastVerify = Date.distantPast
    private var faceSum = 0.0, faceCount = 0, adjustments = 0
    private let faceRequest = VNDetectFaceRectanglesRequest()
    // One handler for the whole run: a new VNImageRequestHandler per frame made Vision reload and
    // recompile the face model every time (most of the CPU in the profile).
    private let faceHandler = VNSequenceRequestHandler()

    func start() {
        trimLog()
        log("started")
        // A background app with no windows gets App Napped, which stalls the timer below.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Watch the webcam during calls")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            log(granted ? "camera access: granted"
                        : "camera access: denied (turn on WebcamBright in System Settings > Privacy & Security > Camera)")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.queue.async { self?.reopenUVC(); self?.applySettings("Mac woke up") }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Watching the camera (main thread)

    private func tick() {
        refreshDevice()
        guard device != nil, let cmioID else { return }
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
                stopSession { [weak self] in self?.phase = .checking(stoppedAt: Date()) }
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
        let current = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        ).devices.first { $0.localizedName.contains(cameraHint) }
        guard current?.uniqueID != device?.uniqueID else { return }

        if session != nil { stopSession {} }
        if case .idle = phase {} else { queue.async { self.endCall() } }
        phase = .idle
        device = current
        cmioID = current.flatMap { cmioDevice(uniqueID: $0.uniqueID) }
        if let current {
            log("camera connected: \(current.localizedName)")
            queue.async { self.reopenUVC(); self.applySettings("camera connected") }
        } else {
            log("camera disconnected")
            queue.async { self.closeUVC() }
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
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let source = device.activeFormat.formatDescription.dimensions
        if source.width > analysisWidth, (analysisWidth * Int(source.height)) % Int(source.width) == 0 {
            settings[kCVPixelBufferWidthKey as String] = analysisWidth
            settings[kCVPixelBufferHeightKey as String] = analysisWidth * Int(source.height) / Int(source.width)
        }
        output.videoSettings = settings
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

    // MARK: Frames (control queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now >= framesFrom, now.timeIntervalSince(lastSample) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSample = now

        try? faceHandler.perform([faceRequest], on: buffer, orientation: .up)
        if let face = largestFace(faceRequest.results), let skin = meanLuma(buffer, skinRegion(face)) {
            faceSum += skin; faceCount += 1
            adjust(toward: skin)
        } else if let frame = meanLuma(buffer, CGRect(x: 0, y: 0, width: 1, height: 1)), frame < 40 || frame > 245 {
            // No face because the whole picture is far too dark or blown out: fix that first.
            // Otherwise (you stepped away) hold, so the window behind you doesn't steer anything.
            adjust(toward: frame)
        }
    }

    private func adjust(toward measured: Double) {
        // Learn how much the last gain change actually moved the face.
        if let move = lastGainMove {
            let perUnit = (measured - move.faceBefore) / Double(move.delta)
            if perUnit > 0.2 { gainPerUnit = min(6, max(0.5, 0.5 * gainPerUnit + 0.5 * perUnit)) }
            lastGainMove = nil
        }
        // Light enough again for 15.6 ms: back to 30 fps with the picture about as bright. Checked
        // even when the face is on target, or a call that started in the dark would stay at 25 fps.
        if rung > normalTopRung && gain < lowLightExitGain {
            rung = normalTopRung
            gain += lowLightOffset
            set("exposure", exposureLadder[rung]); set("gain", gain)
            applyTone()
            adjustments += 1
            log(String(format: "face %.0f (target %.0f): low-light mode off -> exposure %d, gain %d, brightness %d, contrast %d",
                       measured, targetLuma, exposureLadder[rung], gain, brightness, tone))
            return
        }
        let error = targetLuma - measured
        guard abs(error) > deadband else { return }
        readBack()
        let gainBefore = gain
        let gainStep = max(1, min(8, Int((abs(error) / gainPerUnit * 0.6).rounded())))
        var what: String

        let topRung = exposureLadder.count - 1
        if error > 0 {  // too dark: undo dimming, longer exposure up to 30 fps, gain, then low-light mode
            if let down = movedDownTo, rung == down { lowestRung = min(rung + 1, normalTopRung) }
            movedDownTo = nil
            if brightness < brightnessRange.upperBound {
                brightness = min(brightnessRange.upperBound, brightness + brightnessStep); what = "brightness"
            } else if rung < normalTopRung {
                rung += 1; what = "exposure"
            } else if rung == normalTopRung && gain < lowLightGain {
                gain = min(lowLightGain, gain + gainStep); what = "gain"
            } else if rung == normalTopRung {
                rung = topRung; gain = max(0, gain - lowLightOffset); what = "low-light mode on"
            } else if gain < maxGain {
                gain = min(maxGain, gain + gainStep); what = "gain"
            } else { return }
        } else {        // too bright: less gain first (low-light mode ends above), dim gently, then shorter exposure
            if gain > 0 {
                gain = max(0, gain - gainStep); what = "gain"
            } else if brightness > brightnessRange.lowerBound {
                brightness = max(brightnessRange.lowerBound, brightness - brightnessStep); what = "brightness"
            } else if rung > lowestRung {
                rung -= 1; brightness = brightnessRange.upperBound; movedDownTo = rung; what = "exposure"
            } else { return }
        }
        switch what {
        case "gain":
            set("gain", gain)
            lastGainMove = (gain - gainBefore, measured)
        case "brightness": set("brightness", brightness)
        default: set("exposure", exposureLadder[rung]); set("gain", gain); set("brightness", brightness)
        }
        applyTone()
        adjustments += 1
        if adjustments <= 6 || adjustments % 20 == 0 {
            log(String(format: "face %.0f (target %.0f): %@ -> exposure %d, gain %d, brightness %d, contrast %d (%.1f per gain unit)",
                       measured, targetLuma, what, exposureLadder[rung], gain, brightness, tone, gainPerUnit))
        }
    }

    /// The camera can drop our values (for example back to 15.6 ms); start from what it really has.
    private func readBack() {
        if let e = get("exposure") {
            rung = exposureLadder.indices.min { abs(exposureLadder[$0] - e) < abs(exposureLadder[$1] - e) } ?? rung
        }
        if let g = get("gain") { gain = g }
        if let b = get("brightness") { brightness = b }
    }

    private func beginCall() {
        faceSum = 0; faceCount = 0; adjustments = 0
        lowestRung = 0; movedDownTo = nil; lastGainMove = nil
        applySettings("call started")
    }

    private func endCall() {
        framesFrom = .distantFuture
        let face = faceCount > 0 ? String(format: "%.0f", faceSum / Double(faceCount)) : "not seen"
        log("camera turned off: average face \(face), \(adjustments) adjustments, " +
            "ended at exposure \(exposureLadder[rung]), gain \(gain), brightness \(brightness)")
    }

    // MARK: Camera controls (control queue)

    /// Contrast and saturation follow how dark the room is: soft contrast in daylight (gentler face
    /// shadows), richer in a room lit only by the screen. Darkness = the gain needed at 15.6 ms.
    private func applyTone(force: Bool = false) {
        let neededGain = rung > normalTopRung ? gain + lowLightOffset : gain
        let darkness = min(1, max(0, Double(neededGain - toneFrom) / Double(toneFull - toneFrom)))
        let contrast = dayContrast + Int((Double(darkTone - dayContrast) * darkness).rounded())
        let saturation = 128 + Int((Double(darkTone - 128) * darkness).rounded())
        guard force || contrast != tone else { return }
        if set("contrast", contrast) && set("saturation", saturation) { tone = contrast }
    }

    private func applySettings(_ reason: String) {
        var ok = true
        for (name, value) in baseSettings { ok = set(name, value) && ok }
        ok = set("exposure", exposureLadder[rung]) && ok
        ok = set("gain", gain) && ok
        ok = set("brightness", brightness) && ok
        applyTone(force: true)
        log("\(reason): settings \(ok ? "applied" : "could not be applied") " +
            "(exposure \(exposureLadder[rung]), gain \(gain), brightness \(brightness))")
    }

    private func verifySettings() {
        guard Date().timeIntervalSince(lastVerify) >= 30 else { return }
        lastVerify = Date()
        guard let aeMode = get("ae-mode") else { return }  // camera not reachable right now
        if aeMode != 1 || get("power-line") != 1 || get("backlight") != 1 {
            applySettings("camera had reset its settings")
        }
    }

    private func reopenUVC() {
        closeUVC()
        uvc = uvc_open(cameraHint)
    }

    private func closeUVC() {
        if let uvc { uvc_close(uvc) }
        uvc = nil
    }

    private func get(_ name: String) -> Int? {
        var value = 0
        for attempt in 0..<2 {
            if uvc == nil || attempt == 1 { reopenUVC() }
            if let uvc, uvc_get(uvc, name, UInt8(UVC_GET_CUR), &value) == 0 { return value }
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

// MARK: - Entry point

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--measure" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("cannot read \(url.path)"); exit(1)
    }
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: image).perform([request])
    guard let face = largestFace(request.results) else { print("no face found"); exit(1) }
    let r = skinRegion(face), w = Double(image.width), h = Double(image.height)
    print("crop=\(Int(r.width * w)):\(Int(r.height * h)):\(Int(r.minX * w)):\(Int((1 - r.maxY) * h))")
    exit(0)
}

let controller = Controller()
controller.start()
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
