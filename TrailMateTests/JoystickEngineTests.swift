import Testing
@testable import TrailMate

struct JoystickEngineTests {
    @Test func deadZoneInputReturnsNilContribution() {
        let engine = JoystickEngine(controllerSample: { nil })
        engine.start(baseSpeed: 1.4)
        engine.updateStickInput(x: 0.05, y: 0.05)

        #expect(engine.tick() == nil)
    }

    @Test func aboveDeadZoneInputStillReturnsVelocity() throws {
        let engine = JoystickEngine(controllerSample: { nil })
        engine.start(baseSpeed: 2.0)
        engine.updateStickInput(x: 1, y: 0)

        let tick = try #require(engine.tick())
        #expect(abs(tick.vx - 2.0) < 1e-9)
        #expect(abs(tick.vy) < 1e-9)
    }
}
