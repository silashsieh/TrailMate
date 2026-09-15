import Testing
@testable import TrailMate

// Epic 031: the stale-tunneld reclaim loop. Exercises the decision logic with an
// injected probe/shutdown so it needs no networking or a real tunneld.
@MainActor
struct TunnelBrokerReclaimTests {

    // Fake tunneld: reports alive until asked to shut down, then alive for
    // `diesAfter` more probes before reporting gone.
    final class FakeTunneld {
        let initiallyAlive: Bool
        let diesAfter: Int
        private(set) var shutdownCalls = 0
        private var probesAfterShutdown = 0
        init(alive: Bool, diesAfter: Int = 1) { initiallyAlive = alive; self.diesAfter = diesAfter }
        func isAlive() -> Bool {
            guard shutdownCalls > 0 else { return initiallyAlive }
            probesAfterShutdown += 1
            return probesAfterShutdown < diesAfter
        }
        func shutdown() { shutdownCalls += 1 }
    }

    @Test func skipsShutdownWhenNothingIsListening() async {
        let fake = FakeTunneld(alive: false)
        let freed = await TunnelBroker.reclaimStaleTunneld(
            isAlive: { fake.isAlive() }, shutdown: { fake.shutdown() },
            pollInterval: .milliseconds(1), timeout: .milliseconds(50))
        #expect(freed)                      // port already free
        #expect(fake.shutdownCalls == 0)    // no orphan → never shuts anything down
    }

    @Test func reclaimsAStaleTunneld() async {
        let fake = FakeTunneld(alive: true, diesAfter: 2)
        let freed = await TunnelBroker.reclaimStaleTunneld(
            isAlive: { fake.isAlive() }, shutdown: { fake.shutdown() },
            pollInterval: .milliseconds(1), timeout: .seconds(1))
        #expect(freed)                      // saw it go after /shutdown
        #expect(fake.shutdownCalls == 1)
    }

    @Test func reportsFailureWhenTunneldWontDie() async {
        let fake = FakeTunneld(alive: true, diesAfter: .max)   // never frees
        let freed = await TunnelBroker.reclaimStaleTunneld(
            isAlive: { fake.isAlive() }, shutdown: { fake.shutdown() },
            pollInterval: .milliseconds(1), timeout: .milliseconds(50))
        #expect(!freed)                     // caller lets the bind error surface
        #expect(fake.shutdownCalls == 1)
    }
}
