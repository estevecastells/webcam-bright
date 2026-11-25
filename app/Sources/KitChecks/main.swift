// Checks for the lever logic and the settings: `swift run KitChecks`. Exits non-zero on failure.
// No camera needed: a simple model of the C920 stands in for it.

import Foundation
import WebcamBrightKit

var failures = 0
var passed = 0

func check(_ condition: Bool, _ name: String, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL \(name) (line \(line))")
    }
}

/// A stand-in camera: face brightness from the light in the room and the levers, roughly as
/// measured on the C920 (gain is the main lever, exposure evens out above 3.9 ms, brightness is
/// a gentle offset).
struct FakeCamera {
    var light: Double          // face brightness at gain 0, 15.6 ms, brightness 128
    var perGain: Double        // face brightness per gain unit
    static let exposureEffect = [-60.0, -45, -30, -15, -5, 0, 13]

    func face(_ l: Levers) -> Double {
        let gain = min(l.gain, maxGain)  // past 100 the C920 gets darker; the levers never go there
        return min(255, max(0, light + Double(gain) * perGain + Double(l.brightness - 128) * 0.6
            + Self.exposureEffect[l.rung] * perGain))
    }

    /// Runs measurements until the levers stop moving; returns the moves.
    func settle(_ levers: inout Levers, target: Double = 115, limit: Int = 80) -> [Levers.Move] {
        var moves: [Levers.Move] = []
        for _ in 0..<limit {
            guard let move = levers.adjust(toward: face(levers), target: target, reading: { Levers.Reading() }) else { break }
            moves.append(move)
        }
        return moves
    }
}

// MARK: Daylight against a window: gain alone brings the face up, at 30 fps.

do {
    let camera = FakeCamera(light: 60, perGain: 2)
    var levers = Levers()
    let moves = camera.settle(&levers)
    check(abs(camera.face(levers) - 115) <= deadband, "daylight: face reaches the target (got \(camera.face(levers)))")
    check(!levers.lowLight, "daylight: stays at 15.6 ms and 30 fps")
    check(moves.allSatisfy { $0 == .gain }, "daylight: only gain moves (\(moves))")
    check(moves.count <= 8, "daylight: settles in a few steps (\(moves.count))")
}

// MARK: Dimmed earlier: brightness goes back to neutral before anything else.

do {
    var levers = Levers()
    levers.readBack(Levers.Reading(exposure: 156, gain: 0, brightness: 100))
    let move = levers.adjust(toward: 60, target: 115) { Levers.Reading() }
    check(move == .brightness && levers.brightness == 104, "too dark: brightness first (\(String(describing: move)), \(levers.brightness))")
}

// MARK: A room lit only by the screen: gain to 100, then low-light mode, then gain to 100 again.

do {
    let camera = FakeCamera(light: 20, perGain: 0.5)
    var levers = Levers()
    let moves = camera.settle(&levers)
    check(levers.lowLight && levers.exposure == 312, "dark room: low-light mode (31.2 ms)")
    check(levers.gain == maxGain, "dark room: gain tops out at \(maxGain) (got \(levers.gain))")
    if let on = moves.firstIndex(of: .lowLightOn) {
        check(moves[..<on].allSatisfy { $0 == .gain }, "dark room: gain before low-light mode")
    } else {
        check(false, "dark room: low-light mode came on")
    }
    check(levers.adjust(toward: camera.face(levers), target: 115) { Levers.Reading() } == nil,
          "dark room: nothing left to move")
}

// MARK: Low-light mode ends as soon as there is light for 15.6 ms, even with the face on target.

do {
    var levers = Levers()
    levers.readBack(Levers.Reading(exposure: 312, gain: 30, brightness: 128))
    let move = levers.adjust(toward: 115, target: 115) { Levers.Reading() }
    check(move == .lowLightOff, "low-light exit below gain \(lowLightExitGain)")
    check(levers.exposure == 156 && levers.gain == 30 + lowLightOffset, "low-light exit: 15.6 ms, gain + \(lowLightOffset)")

    var staying = Levers()
    staying.readBack(Levers.Reading(exposure: 312, gain: 60, brightness: 128))
    check(staying.adjust(toward: 115, target: 115) { Levers.Reading() } == nil, "low-light mode stays at gain 60")
}

// MARK: Too bright: less gain, then brightness down in steps of 4, then a shorter exposure, and an
// exposure that proved too dark isn't tried again, so the picture doesn't oscillate.

do {
    var levers = Levers()
    levers.readBack(Levers.Reading(exposure: 156, gain: 6, brightness: 128))
    check(levers.adjust(toward: 200, target: 115) { Levers.Reading() } == .gain && levers.gain == 0, "too bright: gain first")
    for _ in 0..<13 { _ = levers.adjust(toward: 200, target: 115) { Levers.Reading() } }
    check(levers.brightness == brightnessRange.upperBound && levers.exposure == 78,
          "too bright: brightness down to 80, then 7.8 ms with brightness back at 128")
    // 7.8 ms turns out too dark: back to 15.6 ms, and 7.8 ms is off the table for this call.
    check(levers.adjust(toward: 60, target: 115) { Levers.Reading() } == .exposure && levers.exposure == 156,
          "too dark again: back to 15.6 ms")
    var moves: [Levers.Move] = []
    for _ in 0..<20 { if let m = levers.adjust(toward: 200, target: 115, reading: { Levers.Reading() }) { moves.append(m) } }
    check(!moves.contains(.exposure), "no second try at 7.8 ms in the same call (\(moves))")
    levers.beginCall()
    check(levers.adjust(toward: 200, target: 115) { Levers.Reading() } == .exposure, "a new call may try 7.8 ms again")
}

// MARK: Bright room: the face comes down to the target and the levers stop.

do {
    let camera = FakeCamera(light: 190, perGain: 2)
    var levers = Levers()
    let moves = camera.settle(&levers)
    check(moves.count < 80, "bright room: the levers stop moving")
    check(!levers.lowLight, "bright room: no low-light mode")
}

// MARK: Gain step size is learned from what the face did.

do {
    var levers = Levers()
    _ = levers.adjust(toward: 60, target: 115) { Levers.Reading() }   // gain +8 at 2 per unit
    let before = levers.gainPerUnit
    _ = levers.adjust(toward: 60 + 8 * 4, target: 115) { Levers.Reading() }  // it moved 4 per unit
    check(before == gainPerUnitStart && abs(levers.gainPerUnit - 3) < 0.001, "gain per unit learned: \(levers.gainPerUnit)")
}

// MARK: The camera's real values win over the remembered ones.

do {
    var levers = Levers()
    levers.readBack(Levers.Reading(exposure: 150, gain: 12, brightness: 120))
    check(levers.exposure == 156 && levers.gain == 12 && levers.brightness == 120, "read back: nearest exposure step")
    var dropped = Levers()
    dropped.readBack(Levers.Reading(exposure: 312, gain: 80, brightness: 128))
    // The camera fell back to 15.6 ms on its own: the next move starts from there.
    _ = dropped.adjust(toward: 60, target: 115) { Levers.Reading(exposure: 156, gain: 80, brightness: 128) }
    check(dropped.exposure == 156 && dropped.gain > 80, "read back before moving")
}

// MARK: Tone follows the room: daylight contrast, rising to 140 in a screen-lit room.

do {
    var levers = Levers()
    levers.readBack(Levers.Reading(exposure: 156, gain: 20, brightness: 128))
    check(levers.tone(dayContrast: 100) == Tone(contrast: 100, saturation: 128), "tone: daylight")
    levers.readBack(Levers.Reading(gain: 80))
    check(levers.tone(dayContrast: 100) == Tone(contrast: 120, saturation: 134), "tone: halfway")
    levers.readBack(Levers.Reading(gain: 100))
    check(levers.tone(dayContrast: 100) == Tone(contrast: 140, saturation: 140), "tone: screen light")
    levers.readBack(Levers.Reading(exposure: 312, gain: 50))
    check(levers.tone(dayContrast: 100) == Tone(contrast: 100, saturation: 128), "tone: low-light mode counts its offset")
    levers.readBack(Levers.Reading(exposure: 156, gain: 0))
    check(levers.tone(dayContrast: 128).contrast == 128, "tone: follows the daylight contrast setting")
}

// MARK: Settings

do {
    check(Settings.defaultPowerLineHz(region: "ES") == 50, "50 Hz in Spain")
    check(Settings.defaultPowerLineHz(region: "US") == 60, "60 Hz in the US")
    check(Settings.defaultPowerLineHz(region: nil) == 50, "50 Hz without a region")
    var s = Settings()
    s.powerLineHz = 60
    check(s.powerLine == 2, "60 Hz is UVC power-line 2")

    let suite = "webcam-bright.kitchecks.\(getpid())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    s.targetLuma = 120
    s.dayContrast = 96
    s.save(to: defaults)
    check(Settings.load(from: defaults) == s, "settings round-trip")
    defaults.set(500.0, forKey: "targetLuma")
    defaults.set(10, forKey: "dayContrast")
    defaults.set(55, forKey: "powerLineHz")
    let clamped = Settings.load(from: defaults)
    check(clamped.targetLuma == Settings.targetRange.upperBound && clamped.dayContrast == Settings.dayContrastRange.lowerBound,
          "stored values are clamped")
    check(clamped.powerLineHz == Settings().powerLineHz, "an odd mains frequency falls back to the default")
    check(Settings().targetLuma == 115 && Settings().dayContrast == 100, "defaults are the measured values")
}

print(failures == 0 ? "All \(passed) checks passed" : "\(failures) of \(passed + failures) checks failed")
exit(failures == 0 ? 0 : 1)
