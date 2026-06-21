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

- [x] **Audit pass:** ran the full unit + UI suites against `main`. Result: the suite is green;
      the only *failing* assertion was the 025 log case (fixed in #66). The 028 mock-connection
      test was *stale but passing* (asserted the old gating model). No other stale assertions found.
- [x] **Re-baseline the UI smoke suite** for v2.1.0: collapsed-log default (smoke, forced open via
      `--uitest-expand-log`) **+ persisted expand/collapse round-trip** (`testLogExpansionPersists…`,
      driving the real disclosure) for 025; connected device name + status in the sidebar status pill
      for 026 (`testMockConnectionShowsConnectedDeviceNameAndStatus`); the post-028 offline model
      reframed from "gating" to offline-available (`testCoreControlsRenderWithoutConnection`) with the
      device-mirrors-the-red-dot half as a unit test (`SimulationActorAttachTests`). *Menu-bar* device
      name → manual checklist (MenuBarExtra isn't UICTest-queryable).
- [~] **Add UI coverage** — 027 coordinate field + copy + Go-enablement done
      (`testCoordinateEntryEnablesGoAndRevealsCopy`); 027 *place search → Go* → manual (live MapKit
      local search is nondeterministic). 029 reorder/category/auto-pan covered by the
      `SavedItemsLibraryTests` unit suite (logic) + manual checklist (the drag/context-menu UI) —
      XCUITest drag-and-drop and context-menu submenus are the flakiest surface and not worth
      automating here.
- [x] **Confirm the unit suites added this cycle** still pass and are sufficient — full run green,
      incl. `CoordinateFormatTests`, `SavedItemsLibraryTests` (`LibraryOrderTests`/`MapRegionMathTests`),
      `TunnelBrokerReclaimTests`.
- [x] Update [[testing]] (implemented vs TODO) and the manual smoke checklist to match.

## Open questions

- ~~How much of 028's offline model is UI-testable headlessly vs. needs the mock backend extended?~~
  **Resolved.** The *offline-available* half is fully UI-testable (controls render at a plain launch).
  The *mirror-on-connect* half is **not** observable through the UI mock (it swallows locations), so it
  lives in `SimulationActorAttachTests`, which attaches a recording backend at the actor seam — no need
  to extend the shared mock.
- ~~024 is a layout/occlusion fix — assert via accessibility frames, or leave to the manual checklist?~~
  **Resolved: manual checklist.** Occlusion is a visual/geometric property; an accessibility-frame
  assertion would be brittle and wouldn't actually prove "not visually occluded."

## Decisions made along the way

- **025 stale assertion fixed first (the acute symptom).** `testSidebarShowsLogSection`
  failed because epic 025 collapses the log by default, so "View Full Log" no longer
  renders at launch. Re-baselined by forcing the disclosure open via a new
  `--uitest-expand-log` hook (mirrors `--uitest-open-wander`) rather than driving a
  disclosure click — deterministic and leaves the persisted `sidebarLogExpanded`
  preference untouched. Story 2's fuller *collapsed-by-default + persisted round-trip*
  coverage (à la the restore-on-launch test) is still open.
- **025 persistence now driven through the real disclosure.** The round-trip test toggles
  `window.disclosureTriangles.firstMatch` — the sidebar's only disclosure triangle. Clicking the
  "Log" *static text* does **not** toggle a `DisclosureGroup` in an XCUITest List (verified: the
  expand never took); the triangle is the hit target.
- **028 mirror-on-connect is a unit test, not UI.** `MockSimulationBackend.setLocationQuiet` is a
  no-op, so the connected mock can't witness the snap. Rather than complicate the shared mock,
  `SimulationActorAttachTests` uses a local recording backend (serial-queue-guarded like
  `DaemonBridge`) and asserts `attach()` pushes the current red dot, with noise σ pinned to 0 for
  exactness.
- **Drew the automate/manual line at XCUITest's fragile surfaces.** Place search → Go (nondeterministic
  MapKit results), saved-items drag-reorder + context-menu category assignment (XCUITest drag/submenu
  flakiness), menu-bar content (not queryable), and 024 occlusion (visual) are on the manual checklist;
  everything deterministic is automated.

## Bugs / follow-ups found while building

- None. The v2.1.0 features behave as documented; the gap was purely test coverage, now closed for the
  automatable surfaces.

## Acceptance criteria

- [x] Every v2.1.0 feature (024–029, 031) has a current unit and/or UI test; none assert pre-v2.1.0
      behaviour. (024 + the manual-checklist items above are covered by the smoke checklist by design.)
- [x] `xcodebuild test` (unit + UI) passes on a clean checkout with no live session — full suite green
      locally; CI gates it on the PR.
- [x] [[testing]] and the manual smoke checklist reflect the refreshed coverage.
