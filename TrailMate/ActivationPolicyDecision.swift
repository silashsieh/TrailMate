import Foundation

// AppDelegate maps this decision to NSApplication.ActivationPolicy. A closed
// window may hide the Dock icon only while a menu-bar entry can reopen it.
nonisolated enum ActivationPolicyDecision {
    case regular
    case accessory

    static func decide(
        windowVisible: Bool,
        menuBarShown: Bool,
        hideDockWhenClosed: Bool
    ) -> Self {
        if windowVisible || !menuBarShown { return .regular }
        return hideDockWhenClosed ? .accessory : .regular
    }
}
