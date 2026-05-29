---
type: epic
id: 016
title: Unit tests + test CI job
status: idea
milestone:
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
- [ ] Coordinate-math tests with known-good reference values (per CLAUDE.md "Always do")
- [ ] GPX round-trip test
- [ ] Add an `xcodebuild test` job to `.github/workflows/swift.yml`

## Acceptance criteria
- [ ] `xcodebuild test` runs a non-empty suite locally and in CI
- [ ] Coordinate math + GPX round-trip are covered

## Reference
Suite list and suggested implementation order live in [[testing]].
