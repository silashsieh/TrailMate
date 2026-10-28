import Testing
@testable import TrailMate

@MainActor
struct ActivationPolicyDecisionTests {
    @Test(arguments: [false, true], [false, true])
    func openWindowAlwaysKeepsDock(menuBarShown: Bool, hideDockWhenClosed: Bool) {
        #expect(ActivationPolicyDecision.decide(
            windowVisible: true,
            menuBarShown: menuBarShown,
            hideDockWhenClosed: hideDockWhenClosed
        ) == .regular)
    }

    @Test(arguments: [false, true])
    func hiddenMenuBarAlwaysKeepsDock(hideDockWhenClosed: Bool) {
        #expect(ActivationPolicyDecision.decide(
            windowVisible: false,
            menuBarShown: false,
            hideDockWhenClosed: hideDockWhenClosed
        ) == .regular)
    }

    @Test func closedWindowHidesDockOnlyWhenRequestedWithMenuBar() {
        #expect(ActivationPolicyDecision.decide(
            windowVisible: false, menuBarShown: true, hideDockWhenClosed: true
        ) == .accessory)
        #expect(ActivationPolicyDecision.decide(
            windowVisible: false, menuBarShown: true, hideDockWhenClosed: false
        ) == .regular)
    }
}
