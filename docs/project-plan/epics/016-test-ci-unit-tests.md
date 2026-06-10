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

## Acceptance criteria
- [x] `xcodebuild test` runs a non-empty suite locally and in CI
- [x] Coordinate math + GPX round-trip are covered

## Reference
Suite list and suggested implementation order live in [[testing]].

## Decisions made along the way
- **Separate parallel `test` CI job** rather than a step after `release.sh` in the build job:
  failure isolation (a distinct PR check) and parallel wall-clock, at the cost of a second
  `PythonResources` build (PBS download cached on `packaging/.cache`). (2026-06-10)
- **`TrailMateUITests` skipped in the shared scheme** (and `-skip-testing` in CI as a belt):
  both files are empty templates, and XCUITest needs TCC automation permissions — the classic
  headless flake. Target kept as future scaffolding. (2026-06-10)
- **`LocationNoise` tests are statistical, not seeded** — the RNG isn't injectable; N=10 000
  with tolerances ≥10 standard errors makes flakes practically impossible without touching
  production code. (2026-06-10)
- **`GPXServiceTests` runs `@MainActor`** — `GPXService` inherits the app module's
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; isolating the suite beats loosening the
  production type. (2026-06-10)
- Beyond the epic's two stories, `PositionIntegratorTests` and `LocationNoiseTests` (testing.md
  priorities) were cheap to add in the same pass. `RecorderServiceTests` stays deferred — the
  app-hosted test process shares the real Application Support directory. (2026-06-10)
- First full run happened in CI (PR #32: 56 tests, 0 failures). The local pass used
  `build-for-testing` only because a live TrailMate session was up — the app-hosted test run
  would have launched a second instance of the same bundle id. (2026-06-10)
