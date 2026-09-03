import Testing
@testable import TrailMate

struct MonotonicTimeSourceTests {
    @Test func manualClockAdvancesElapsedTimeAndWakesAtDeadline() async {
        let clock = ManualMonotonicClock()
        let source = clock.timeSource
        let start = source.now
        let sleeper = Task {
            try await source.sleep(for: .seconds(5))
        }

        for _ in 0..<100 where clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        #expect(clock.pendingSleepCount == 1)

        clock.advance(by: .seconds(4))
        #expect(source.elapsed(since: start) == .seconds(4))
        #expect(clock.pendingSleepCount == 1)

        clock.advance(by: .seconds(1))
        await #expect(throws: Never.self) {
            try await sleeper.value
        }
        #expect(source.elapsed(since: start) == .seconds(5))
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func manualSleepCancellationIsImmediate() async {
        let clock = ManualMonotonicClock()
        let source = clock.timeSource
        let sleeper = Task {
            try await source.sleep(for: .seconds(50))
        }

        for _ in 0..<100 where clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        #expect(clock.pendingSleepCount == 1)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
        #expect(clock.pendingSleepCount == 0)
        #expect(clock.now == .zero)
    }
}
