import Foundation

/// The camera controls WebcamBright moves and the rules for moving them. Nothing here talks to
/// the camera, so the order of the levers can be checked without one (`swift run KitChecks`).
public struct Levers: Equatable, Sendable {
    public internal(set) var rung = normalTopRung
    public internal(set) var gain = 0
    public internal(set) var brightness = 128
    public private(set) var gainPerUnit = gainPerUnitStart
    var lowestRung = 0          // a rung that proved too dark this call is not tried again
    var movedDownTo: Int?
    var lastGainMove: GainMove?

    struct GainMove: Equatable, Sendable {
        let delta: Int
        let faceBefore: Double
    }

    public enum Move: String, Sendable {
        case gain, brightness, exposure
        case lowLightOn = "low-light mode on"
        case lowLightOff = "low-light mode off"
    }

    /// What the camera really has, read just before a move.
    public struct Reading: Sendable {
        public var exposure: Int?, gain: Int?, brightness: Int?
        public init(exposure: Int? = nil, gain: Int? = nil, brightness: Int? = nil) {
            self.exposure = exposure
            self.gain = gain
            self.brightness = brightness
        }
    }

    public init() {}

    public var exposure: Int { exposureLadder[rung] }
    /// 31.2 ms: about 25 fps instead of 30.
    public var lowLight: Bool { rung > normalTopRung }

    /// A new call: forget what the last one learned about which exposure is too dark.
    public mutating func beginCall() {
        lowestRung = 0
        movedDownTo = nil
        lastGainMove = nil
    }

    /// The camera can drop our values (for example back to 15.6 ms); start from what it really has.
    public mutating func readBack(_ r: Reading) {
        if let e = r.exposure {
            rung = exposureLadder.indices.min { abs(exposureLadder[$0] - e) < abs(exposureLadder[$1] - e) } ?? rung
        }
        if let g = r.gain { gain = g }
        if let b = r.brightness { brightness = b }
    }

    /// One measurement of the face (or of the whole picture when there is no face): moves at most
    /// one lever and returns it, or returns nil when the face is close enough or nothing is left to
    /// move. `reading` is asked for what the camera has just before a move.
    public mutating func adjust(toward measured: Double, target: Double, reading: () -> Reading) -> Move? {
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
            return .lowLightOff
        }
        let error = target - measured
        guard abs(error) > deadband else { return nil }
        readBack(reading())
        let gainBefore = gain
        let gainStep = max(1, min(8, Int((abs(error) / gainPerUnit * 0.6).rounded())))
        let move: Move

        let topRung = exposureLadder.count - 1
        if error > 0 {  // too dark: undo dimming, longer exposure up to 30 fps, gain, then low-light mode
            if let down = movedDownTo, rung == down { lowestRung = min(rung + 1, normalTopRung) }
            movedDownTo = nil
            if brightness < brightnessRange.upperBound {
                brightness = min(brightnessRange.upperBound, brightness + brightnessStep); move = .brightness
            } else if rung < normalTopRung {
                rung += 1; move = .exposure
            } else if rung == normalTopRung && gain < lowLightGain {
                gain = min(lowLightGain, gain + gainStep); move = .gain
            } else if rung == normalTopRung {
                rung = topRung; gain = max(0, gain - lowLightOffset); move = .lowLightOn
            } else if gain < maxGain {
                gain = min(maxGain, gain + gainStep); move = .gain
            } else { return nil }
        } else {        // too bright: less gain first (low-light mode ends above), dim gently, then shorter exposure
            if gain > 0 {
                gain = max(0, gain - gainStep); move = .gain
            } else if brightness > brightnessRange.lowerBound {
                brightness = max(brightnessRange.lowerBound, brightness - brightnessStep); move = .brightness
            } else if rung > lowestRung {
                rung -= 1; brightness = brightnessRange.upperBound; movedDownTo = rung; move = .exposure
            } else { return nil }
        }
        if move == .gain { lastGainMove = GainMove(delta: gain - gainBefore, faceBefore: measured) }
        return move
    }

    /// The controls a move changed, in the order the camera gets them.
    public func controls(for move: Move) -> [(String, Int)] {
        switch move {
        case .gain: [("gain", gain)]
        case .brightness: [("brightness", brightness)]
        case .lowLightOff: [("exposure", exposure), ("gain", gain)]
        case .exposure, .lowLightOn: [("exposure", exposure), ("gain", gain), ("brightness", brightness)]
        }
    }

    /// Contrast and saturation follow how dark the room is: soft contrast in daylight (gentler face
    /// shadows), richer in a room lit only by the screen. Darkness = the gain needed at 15.6 ms.
    public func tone(dayContrast: Int) -> Tone {
        let neededGain = lowLight ? gain + lowLightOffset : gain
        let darkness = min(1, max(0, Double(neededGain - toneFrom) / Double(toneFull - toneFrom)))
        return Tone(contrast: dayContrast + Int((Double(darkTone - dayContrast) * darkness).rounded()),
                    saturation: 128 + Int((Double(darkTone - 128) * darkness).rounded()))
    }
}

public struct Tone: Equatable, Sendable {
    public var contrast: Int
    public var saturation: Int

    public init(contrast: Int, saturation: Int) {
        self.contrast = contrast
        self.saturation = saturation
    }
}
