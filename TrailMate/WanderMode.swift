import Foundation

// Which route the Wander sheet generates. Both modes share the selected map
// point and the radius; the rawValue is what lands in UserDefaults, so it stays
// English and stable regardless of the UI language.
enum WanderMode: String, CaseIterable, Hashable {
    case random
    case sweeping

    // An unset, older, or hand-edited preference falls back to Random — the
    // behavior the sheet had before Sweeping existed, so a bad value can never
    // strand the user in a mode they didn't pick.
    nonisolated init(persisted rawValue: String?) {
        self = rawValue.flatMap(WanderMode.init(rawValue:)) ?? .random
    }
}
