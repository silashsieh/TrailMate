import CoreLocation
import Testing
@testable import TrailMate

struct PositionIntegratorTests {
    private let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)

    @Test func resetSetsPositionAndClearNilsIt() throws {
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        let pos = try #require(integrator.position)
        #expect(pos.latitude == start.latitude)
        #expect(pos.longitude == start.longitude)
        integrator.clear()
        #expect(integrator.position == nil)
    }

    @Test func stepBeforeResetIsNoOp() {
        let integrator = PositionIntegrator()
        integrator.step(vx: 10, vy: 10, dt: 1)
        #expect(integrator.position == nil)
    }

    @Test func zeroVelocityStepLeavesPositionUntouched() throws {
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        integrator.step(vx: 0, vy: 0, dt: 1)
        let pos = try #require(integrator.position)
        #expect(pos.latitude == start.latitude)
        #expect(pos.longitude == start.longitude)
    }

    @Test func oneSecondWalkingSpeedClosedForm() throws {
        // testing.md's closed-form check: 1 s due north at 1.4 m/s moves
        // latitude by exactly 1.4 / 111_320 degrees in the flat model, and
        // the resulting geodesic displacement is 1.4 m within 1%.
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        integrator.step(vx: 0, vy: 1.4, dt: 1)
        let pos = try #require(integrator.position)
        #expect(abs((pos.latitude - start.latitude) - 1.4 / 111_320.0) < 1e-12)
        #expect(pos.longitude == start.longitude)
        let moved = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: pos.latitude, longitude: pos.longitude))
        #expect(abs(moved - 1.4) < 0.014)
    }

    @Test func multipleStepsAccumulateLikeOneBigStep() throws {
        // Pure east motion never changes latitude, so the per-step cos(lat)
        // scale is constant and ten 1 m steps must equal one 10 m step.
        let many = PositionIntegrator()
        many.reset(to: start)
        for _ in 0..<10 {
            many.step(vx: 1, vy: 0, dt: 1)
        }
        let once = PositionIntegrator()
        once.reset(to: start)
        once.step(vx: 10, vy: 0, dt: 1)

        let posMany = try #require(many.position)
        let posOnce = try #require(once.position)
        #expect(abs(posMany.latitude - posOnce.latitude) < 1e-9)
        #expect(abs(posMany.longitude - posOnce.longitude) < 1e-9)
    }
}
