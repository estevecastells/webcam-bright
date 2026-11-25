import Foundation

/// What the engine is doing, for the menu. Published on the main thread.
public struct EngineStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case noCamera
        /// Waiting for an app to turn the camera on.
        case idle
        case inCall
        /// The camera uses its own auto exposure. nil: until resumed.
        case paused(until: Date?)
    }

    public enum Access: Equatable, Sendable { case granted, denied, undetermined }

    public var state = State.starting
    public var access = Access.undetermined
    /// The camera being watched, by its full name.
    public var camera: String?
    /// The part of the name it looks for.
    public var cameraHint = ""
    public var picture = CallPicture()
    public var lastCall: CallSummary?
    /// Another copy of WebcamBright that is running (bundle id or path). While it runs this one
    /// leaves the camera alone: two would fight over it.
    public var conflict: String?

    public init() {}

    public var isPaused: Bool {
        if case .paused = state { true } else { false }
    }
}

/// The face and the camera's controls during a call.
public struct CallPicture: Equatable, Sendable {
    /// Skin brightness, 0-255; nil while no face is in view.
    public var face: Double?
    public var target = 115.0
    /// 0.1 ms units.
    public var exposure = exposureLadder[normalTopRung]
    public var gain = 0
    public var brightness = 128
    public var contrast = 100
    public var lowLight = false
    public var adjustments = 0

    public init() {}
}

public struct CallSummary: Equatable, Sendable {
    public var ended: Date
    public var averageFace: Double?
    public var adjustments: Int

    public init(ended: Date, averageFace: Double?, adjustments: Int) {
        self.ended = ended
        self.averageFace = averageFace
        self.adjustments = adjustments
    }
}
