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
    private static let modeKey = "WanderPresets.mode"
    private static let laneSpacingMetersKey = "WanderPresets.laneSpacingMeters"

    // First-run defaults: the middle preset on both axes (owner decision,
    // epic 018). Custom-field fallbacks continue past the largest preset,
    // since custom is most useful beyond the preset range.
    static let defaultRadiusMeters: Double = 500
    static let defaultDurationSeconds: TimeInterval = 60 * 60
    static let defaultCustomRadiusMeters: Double = 1000
    static let defaultCustomDurationMinutes: Double = 180
    // Lane spacing default (owner decision, epic 030): tight enough that a
    // sweep of a city block reads as coverage rather than a few passes.
    static let defaultLaneSpacingMeters: Double = 70

    static var radiusIsCustom: Bool {
        get { AppProcessConfiguration.current.defaults.bool(forKey: radiusIsCustomKey) }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: radiusIsCustomKey) }
    }

    static var radiusMeters: Double {
        get { AppProcessConfiguration.current.defaults.object(forKey: radiusMetersKey) as? Double ?? defaultRadiusMeters }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: radiusMetersKey) }
    }

    static var customRadiusMeters: Double {
        get { AppProcessConfiguration.current.defaults.object(forKey: customRadiusMetersKey) as? Double ?? defaultCustomRadiusMeters }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: customRadiusMetersKey) }
    }

    static var durationIsCustom: Bool {
        get { AppProcessConfiguration.current.defaults.bool(forKey: durationIsCustomKey) }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: durationIsCustomKey) }
    }

    static var durationSeconds: TimeInterval {
        get { AppProcessConfiguration.current.defaults.object(forKey: durationSecondsKey) as? Double ?? defaultDurationSeconds }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: durationSecondsKey) }
    }

    static var customDurationMinutes: Double {
        get { AppProcessConfiguration.current.defaults.object(forKey: customDurationMinutesKey) as? Double ?? defaultCustomDurationMinutes }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: customDurationMinutesKey) }
    }

    // Mode and lane spacing persist on the same terms as radius and duration:
    // written on every change so quitting with the sheet open still reopens it
    // the way it was left.
    static var mode: WanderMode {
        get { WanderMode(persisted: AppProcessConfiguration.current.defaults.string(forKey: modeKey)) }
        set { AppProcessConfiguration.current.defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    static var laneSpacingMeters: Double {
        get { AppProcessConfiguration.current.defaults.object(forKey: laneSpacingMetersKey) as? Double ?? defaultLaneSpacingMeters }
        set { AppProcessConfiguration.current.defaults.set(newValue, forKey: laneSpacingMetersKey) }
    }
}
