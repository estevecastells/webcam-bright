import Foundation

/// What people can change from the menu. Stored in the app's UserDefaults.
public struct Settings: Equatable, Sendable {
    /// Skin brightness to aim for (0-255). Calibrated 2026-11-25: factory 49, tuned shot 105
    /// (looked right), gain 40 200 (washed out).
    public var targetLuma = 115.0
    /// Contrast in daylight: softer face shadows than the camera's 128 (95 still looked natural,
    /// 64 flat and grey; tested 2026-11-25). It rises to `darkTone` in a room lit by the screen.
    public var dayContrast = 100
    /// Mains frequency for anti-flicker: 50 Hz in Europe and most of the world, 60 Hz in most of
    /// the Americas. The default follows the Mac's region.
    public var powerLineHz = Settings.defaultPowerLineHz(region: Locale.current.region?.identifier)
    /// Part of the camera's name (`build/uvcctl list` prints it on its first line). Not in the
    /// menu: the exposure steps and gain range in Tuning.swift are measured on this camera.
    /// `defaults write io.github.estevecastells.webcam-bright cameraName "Brio"` changes it.
    public var cameraName = "C920"

    public static let targetRange = 85.0...145.0
    public static let dayContrastRange = 64...128

    public init() {}

    /// The UVC power-line value: 1 = 50 Hz, 2 = 60 Hz.
    public var powerLine: Int { powerLineHz == 60 ? 2 : 1 }

    /// Regions on 60 Hz mains. Japan is split (50 Hz in the east, 60 Hz in the west) and stays on 50.
    static let sixtyHertzRegions: Set<String> = [
        "US", "CA", "MX", "GT", "BZ", "SV", "HN", "NI", "CR", "PA", "CU", "DO", "HT", "PR", "BS", "TT",
        "CO", "VE", "EC", "PE", "BR", "GY", "SR", "KR", "TW", "PH", "SA", "LR", "GU", "AS", "VI",
    ]

    public static func defaultPowerLineHz(region: String?) -> Int {
        region.map { sixtyHertzRegions.contains($0.uppercased()) } == true ? 60 : 50
    }

    // MARK: Storage

    private enum Key {
        static let targetLuma = "targetLuma", dayContrast = "dayContrast"
        static let powerLineHz = "powerLineHz", cameraName = "cameraName"
    }

    /// Stored values, clamped to what the menu offers; anything missing keeps its default.
    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        var s = Settings()
        if defaults.object(forKey: Key.targetLuma) != nil {
            s.targetLuma = min(targetRange.upperBound, max(targetRange.lowerBound, defaults.double(forKey: Key.targetLuma)))
        }
        if defaults.object(forKey: Key.dayContrast) != nil {
            s.dayContrast = min(dayContrastRange.upperBound, max(dayContrastRange.lowerBound, defaults.integer(forKey: Key.dayContrast)))
        }
        if [50, 60].contains(defaults.integer(forKey: Key.powerLineHz)) {
            s.powerLineHz = defaults.integer(forKey: Key.powerLineHz)
        }
        if let name = defaults.string(forKey: Key.cameraName), !name.isEmpty {
            s.cameraName = name
        }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(targetLuma, forKey: Key.targetLuma)
        defaults.set(dayContrast, forKey: Key.dayContrast)
        defaults.set(powerLineHz, forKey: Key.powerLineHz)
    }

    /// The defaults for everything the menu changes, keeping the camera name.
    public var reset: Settings {
        var s = Settings()
        s.cameraName = cameraName
        return s
    }
}
