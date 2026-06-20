---
type: epic
id: 033
title: Refresh test & UI coverage for everything shipped since v2.0.0
status: open
milestone: v2.2.0
issue:
opened: 2026-06-21
shipped:
tags: [testing, quality]
---

# Epic 033: Refresh test & UI coverage for everything shipped since v2.0.0

> The v2.1.0 cycle (024–029, 031, 032) shipped behaviour changes faster than the suites kept up,
> and CI was down for the whole cycle so nothing gated them. Some new features have no automated
> coverage, and some existing UI assertions now describe pre-v2.1.0 behaviour. Bring the suites
> back in line.

## Why

Every feature added since v2.0.0 should have a current unit test or UI test, and no suite should
assert stale behaviour. Two things drifted:

- **New features without coverage** — 024 (joystick/map-control overlap), 025 (default-collapsed
  log), 026 (device name in the status pill / menu bar), 027 (search-to-go, coordinate entry, copy
  coordinate), 028 (offline control + device-mirrors-the-red-dot-on-connect), 029 (drag-reorder,
  categories, auto-pan).
- **Existing assertions that are now wrong.** `TrailMateUITests` predates the v2.1.0 UI: it checks
  the sidebar Log section + "View Full Log" button, which 025 now collapses by default; and its
  `--uitest-mock-connection` test asserts *connection-gated* UI that 028 made available offline
  (the `.requiresConnection()` gating was removed). These need re-baselining.

## Goal

Each feature shipped since v2.0.0 is covered by a current, passing unit and/or UI test, the existing
suites describe today's behaviour, and the whole thing runs green under CI once the runner is back.

## Out of scope

- New product features — this is test/coverage work only.
- The already-tracked deferred suites (`RecorderServiceTests`, `RouteVMTests`, `DaemonProtocolTests`)
  — leave in [[testing]]'s TODO unless one is directly in a story's path.
- 032's teardown (root, shell, SIGKILL escalation) — not unit-testable in-app; covered by the manual
  smoke checklist ("quit → no orphaned tunneld") instead.

## Stories

- [ ] **Audit pass:** run the full unit + UI suites against current `main`; list every failing or
      stale assertion (start with the 025 log + 028 gating cases above).
- [ ] **Re-baseline the UI smoke suite** for v2.1.0: collapsed-log default + persisted expand/collapse
      (025); connected device name in status pill + menu bar (026); the post-028 offline model
      (controls usable with no device; device snaps to the red dot on connect) via the
      `--uitest-mock-connection` hook, reframed from "gating" to "mirror".
- [ ] **Add UI coverage** for direct location entry (027: search → Go, coordinate field, copy) and
      saved-items library UX (029: reorder persists, category assignment persists, auto-pan frames
      the selection).
- [ ] **Confirm the unit suites added this cycle** still pass and are sufficient
      (`CoordinateFormatTests`, `SavedItemsLibraryTests`, `TunnelBrokerReclaimTests`).
- [ ] Update [[testing]] (implemented vs TODO) and the manual smoke checklist to match.

## Open questions

- How much of 028's offline model is UI-testable headlessly vs. needs the mock backend extended
  (e.g. asserting the device mirrors the red dot on connect without a real device)?
- 024 is a layout/occlusion fix — assert via accessibility frames, or leave to the manual checklist?

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Every v2.1.0 feature (024–029, 031) has a current unit and/or UI test; none assert pre-v2.1.0
      behaviour.
- [ ] `xcodebuild test` (unit + UI) passes on a clean checkout with no live session.
- [ ] [[testing]] and the manual smoke checklist reflect the refreshed coverage.
