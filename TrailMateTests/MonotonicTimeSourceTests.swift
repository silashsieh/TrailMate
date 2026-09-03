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

    @Test func cancellationDuringContinuationRegistrationCannotLoseWakeup() async {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let clock = ManualMonotonicClock(beforeContinuationRegistration: {
            entered.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        let source = clock.timeSource
        let sleeper = Task {
            try await source.sleep(for: .seconds(50))
        }

        var enteredIterator = entered.stream.makeAsyncIterator()
        _ = await enteredIterator.next()
        #expect(clock.outstandingSleepCount == 1)
        #expect(clock.pendingSleepCount == 0)

        sleeper.cancel()
        for _ in 0..<100 where clock.outstandingSleepCount != 0 {
            await Task.yield()
        }
        #expect(clock.outstandingSleepCount == 0)

        release.continuation.yield()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
        #expect(clock.outstandingSleepCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }
}
