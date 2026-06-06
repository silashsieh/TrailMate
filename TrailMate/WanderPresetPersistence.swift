import Foundation

// Persists the Wander sheet's last selection (preset or custom, with the
// custom values) across launches — same UserDefaults pattern as
// SimulatedPositionPersistence (epic 005). Saved on every change rather than
// on Start, so pick → quit → relaunch restores the selection even when no
// wander was launched (epic 018).
enum WanderPresetPersistence {
    private static let radiusIsCustomKey = "WanderPresets.radiusIsCustom"
    private static let radiusMetersKey = "WanderPresets.radiusMeters"
    private static let customRadiusMetersKey = "WanderPresets.customRadiusMeters"
    private static let durationIsCustomKey = "WanderPresets.durationIsCustom"
    private static let durationSecondsKey = "WanderPresets.durationSeconds"
    private static let customDurationMinutesKey = "WanderPresets.customDurationMinutes"

    // First-run defaults: the middle preset on both axes (owner decision,
    // epic 018). Custom-field fallbacks continue past the largest preset,
    // since custom is most useful beyond the preset range.
    static let defaultRadiusMeters: Double = 500
    static let defaultDurationSeconds: TimeInterval = 60 * 60
    static let defaultCustomRadiusMeters: Double = 1000
    static let defaultCustomDurationMinutes: Double = 180

    static var radiusIsCustom: Bool {
        get { UserDefaults.standard.bool(forKey: radiusIsCustomKey) }
        set { UserDefaults.standard.set(newValue, forKey: radiusIsCustomKey) }
    }

    static var radiusMeters: Double {
        get { UserDefaults.standard.object(forKey: radiusMetersKey) as? Double ?? defaultRadiusMeters }
        set { UserDefaults.standard.set(newValue, forKey: radiusMetersKey) }
    }

    static var customRadiusMeters: Double {
        get { UserDefaults.standard.object(forKey: customRadiusMetersKey) as? Double ?? defaultCustomRadiusMeters }
        set { UserDefaults.standard.set(newValue, forKey: customRadiusMetersKey) }
    }

    static var durationIsCustom: Bool {
        get { UserDefaults.standard.bool(forKey: durationIsCustomKey) }
        set { UserDefaults.standard.set(newValue, forKey: durationIsCustomKey) }
    }

    static var durationSeconds: TimeInterval {
        get { UserDefaults.standard.object(forKey: durationSecondsKey) as? Double ?? defaultDurationSeconds }
        set { UserDefaults.standard.set(newValue, forKey: durationSecondsKey) }
    }

    static var customDurationMinutes: Double {
        get { UserDefaults.standard.object(forKey: customDurationMinutesKey) as? Double ?? defaultCustomDurationMinutes }
        set { UserDefaults.standard.set(newValue, forKey: customDurationMinutesKey) }
    }
}
