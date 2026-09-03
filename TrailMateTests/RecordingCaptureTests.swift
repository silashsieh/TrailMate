import CoreLocation
import Foundation
import Testing
@testable import TrailMate

struct RecordingCaptureTests {
    @Test func timestampsUseOneWallAnchorAndMonotonicElapsed() throws {
        let clock = ManualMonotonicClock()
        let wallStart = Date(timeIntervalSince1970: 1_750_000_000)
        let wallClock = WallClockProbe(first: wallStart, later: wallStart.addingTimeInterval(-3_600))
        var capture = RecordingCapture(
            monotonicTime: clock.timeSource,
            wallNow: { wallClock.now() }
        )

        capture.start()
        clock.advance(by: .seconds(2))
        capture.append(CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654))
        clock.advance(by: .milliseconds(1_500))
        capture.append(CLLocationCoordinate2D(latitude: 25.0335, longitude: 121.5650))

        #expect(capture.status == .init(isActive: true, pointCount: 2))
        let stopped = capture.stop()
        let draft = try #require(stopped)
        #expect(wallClock.callCount == 1)
        #expect(draft.startedAt == wallStart)
        #expect(draft.points.map(\.timestamp) == [
            wallStart.addingTimeInterval(2),
            wallStart.addingTimeInterval(3.5),
        ])
        #expect(capture.status == .init(isActive: false, pointCount: 0))
    }

    @Test func startIsIdempotentAndDiscardDropsTheDraft() {
        let clock = ManualMonotonicClock()
        let wallStart = Date(timeIntervalSince1970: 1_750_000_100)
        var capture = RecordingCapture(monotonicTime: clock.timeSource, wallNow: { wallStart })

        capture.start()
        clock.advance(by: .seconds(1))
        capture.append(CLLocationCoordinate2D(latitude: 1, longitude: 2))
        capture.start()

        #expect(capture.status == .init(isActive: true, pointCount: 1))
        capture.discard()
        #expect(capture.status == .init(isActive: false, pointCount: 0))
        #expect(capture.stop() == nil)
    }
}

private nonisolated final class WallClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Date
    private let later: Date
    private var calls = 0

    init(first: Date, later: Date) {
        self.first = first
        self.later = later
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls == 1 ? first : later
    }
}
