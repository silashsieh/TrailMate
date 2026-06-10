import Foundation

// In-app UI language choice. `.system` follows the system language (falling
// back to the development region, English, when no system language matches a
// known region); the others force one language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    // Endonyms stay in their own script (Apple's own language list does the
    // same); only "System Default" is localized.
    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .traditionalChinese: "繁體中文"
        }
    }
}

// Persists the language choice and mirrors it into the standard AppleLanguages
// UserDefaults key. Foundation binds the bundle's localization at process
// launch, so a change takes effect on the next launch — not live. `.system`
// removes the override so the app tracks the system language again.
enum LanguagePreference {
    private static let overrideKey = "AppLanguageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: overrideKey),
                  let lang = AppLanguage(rawValue: raw) else { return .system }
            return lang
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.rawValue, forKey: overrideKey)
            switch newValue {
            case .system:
                defaults.removeObject(forKey: appleLanguagesKey)
            case .english, .traditionalChinese:
                defaults.set([newValue.rawValue], forKey: appleLanguagesKey)
            }
        }
    }
}
