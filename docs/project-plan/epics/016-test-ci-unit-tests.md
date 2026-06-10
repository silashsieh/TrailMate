---
type: epic
id: 016
title: Unit tests + test CI job
status: in-progress
milestone: v1.6.0
issue:
opened: 2026-05-29
shipped:
tags: [testing, ci]
---

# Epic 016: Unit tests + test CI job

## Why
Carried over from [[phases]] Phase 5 "Pending": the test target is empty and `swift.yml` only
builds (`release.sh`), never runs `xcodebuild test`. [[testing]] already specifies the intended
suites and a priority order.

## Goal
Land a first bar of automated tests and wire a test job into CI.

## Out of scope
- Full coverage of every suite in [[testing]] at once — start with the highest-value ones.

## Stories
- [x] Coordinate-math tests with known-good reference values (per CLAUDE.md "Always do")
- [x] GPX round-trip test
- [x] Add an `xcodebuild test` job to `.github/workflows/swift.yml`
- [x] UI smoke tests (owner request during PR #32 review)

## Acceptance criteria
- [x] `xcodebuild test` runs a non-empty suite locally and in CI
- [x] Coordinate math + GPX round-trip are covered

## Reference
Suite list and suggested implementation order live in [[testing]].

## Decisions made along the way
- **Separate parallel `test` CI job** rather than a step after `release.sh` in the build job:
  failure isolation (a distinct PR check) and parallel wall-clock, at the cost of a second
  `PythonResources` build (PBS download cached on `packaging/.cache`). (2026-06-10)
- **UI tests were first skipped in the shared scheme** (empty templates, TCC-flake risk), then
  the owner asked for real ones in PR review: a device-/data-free smoke suite now covers
  launch, sidebar Log section, and the Settings window. It runs in its own CI job
  (`ui-test`) so an automation flake never taints the unit-test signal; the unit `test` job
  still passes `-skip-testing:TrailMateUITests`. (2026-06-10)
- **Persistence is verified through real relaunches** (owner request): the settings toggle and
  the Wander presets are changed in the UI, the app is terminated and relaunched, and the
  restored values asserted. Both tests put user preferences back as they found them. (2026-06-10)
- **DEBUG-only mock connection** (owner request — "many features are only available after
  connect"): `--uitest-mock-connection` + `MockSimulationBackend` (the mock the
  `SimulationBackend` protocol doc anticipated) let UI tests exercise connected-gated flows
  with no device, tunnel, admin prompt, or daemon. `AppState.daemonBridge` was widened from
  `DaemonBridge?` to `(any SimulationBackend)?` — the only non-additive production change.
  (2026-06-10)
- **`LocationNoise` tests are statistical, not seeded** — the RNG isn't injectable; N=10 000
  with tolerances ≥10 standard errors makes flakes practically impossible without touching
  production code. (2026-06-10)
- **`GPXServiceTests` runs `@MainActor`** — `GPXService` inherits the app module's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; isolating the suite beats loosening the
  production type. (2026-06-10)
- Beyond the epic's two stories, `PositionIntegratorTests` and `LocationNoiseTests` (testing.md
  priorities) were cheap to add in the same pass. `RecorderServiceTests` stays deferred — the
  app-hosted test process shares the real Application Support directory. (2026-06-10)
- First full run happened in CI (PR #32: 56 tests, 0 failures) because a live TrailMate
  session was up — the app-hosted test run would have launched a second instance of the same
  bundle id. Verified locally afterwards (56/56, twice) once the owner quit the session.
  (2026-06-10)
