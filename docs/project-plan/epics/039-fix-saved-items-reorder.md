---
type: epic
id: 039
title: Fix saved-items drag-reorder (flicker + snap-back)
status: in-progress
milestone: v2.3.0
issue: 68
opened: 2026-06-24
shipped:
tags: [bug, ui, library]
---

# Epic 039: Fix saved-items drag-reorder (flicker + snap-back)

> Bug (#68) against the drag-reorder shipped in [[029-saved-items-library-ux]] (v2.1.0). Per
> [[process]], a defect in a shipped epic is *new* work, not a reopen — this epic links back to 029
> rather than editing it.

## Why

A user (#68, TrailMate v2.1.0, macOS 26.5) reports the saved-locations list can't be reordered:
dragging a row makes the list **flicker continuously**, and **on mouse-up the row snaps back to its
original position** — the move never commits. Reorder was the headline of
[[029-saved-items-library-ux]], so this is a regression in shipped behavior. Saved routes expose
the same visible contract through almost-identical `List`/`ForEach.onMove` wiring, but persist their
order through a different store; both libraries therefore have to be checked even though the report
names locations.

The flicker-then-revert signature points at the list's drag model fighting its data source: the
on-screen order is derived from a filtered array for each section while the drop callback mutates a
different, app-global array. A SwiftUI refresh during the gesture may therefore re-present the old
derived order before the move commits. The exact paths to trace are deliberately different:

- **Locations:** `SavedLocationsSection` filtered `ForEach` → `AppState.moveWaypoints` →
  `LibraryOrder.moveWithinGroup` → encode the complete array into `UserDefaults`.
- **Routes:** `SavedRoutesSection` filtered `ForEach` → `AppState.moveRoutes` →
  `SavedRoutesStore.move` → write the complete UUID sequence to `order.json`.

The current pure `LibraryOrderTests` prove the offset transform but cannot prove that SwiftUI calls
it, that the view keeps a stable order during the drag, or that the persisted store reloads the same
order. Likely suspects to confirm during the work: filtered section snapshots, row identity, the
`Button`/tap gesture on each row competing with the drag, observation-driven view invalidation while
the red dot is emitting, and an index-space mismatch introduced by categories. macOS 26.5-specific
`List` behavior is possible but should be the last hypothesis, not the first.

## Goal

Dragging a saved location or saved route to a new position within its current section reorders the
list smoothly (no flicker), does not activate the row, and **persists** across the drop, reselection,
category round-trips, and app relaunch.

## Out of scope

- Any new library features (new categories model, multi-select drag, etc.) — this is a defect fix to
  restore 029's intended behavior, nothing more.
- Dragging directly between sections. Epic 029 moves an item between categories through the row's
  Category context menu; this epic preserves that boundary and only repairs within-section reorder.
- Reworking the saved-items persistence format beyond what the fix requires.

## Stories

- [ ] Reproduce on current `main` on macOS 26.x. Exercise locations and routes separately, first in
      the ungrouped section and then with at least two populated categories. Record whether the
      failure requires an attached device, an active route/joystick, or merely an idle red-dot emit.
- [ ] Trace one drag through each complete view-to-storage path above. Establish whether `onMove`
      fires, whether it receives section-relative offsets, whether the in-memory order changes once,
      and whether a view refresh or store reload restores the pre-drag order.
- [x] Fix the smallest ownership/identity boundary responsible for the failure. The committed order
      must be the single source rendered by the section for the rest of the gesture; do not introduce
      a second view-local order that can drift from `AppState` / `SavedRoutesStore`.
- [ ] Confirm both row interaction styles remain correct: dragging a location must not teleport, and
      dragging a route must not load it. Rename, delete, Category assignment, and tap-to-select/load
      must remain unchanged.
- [x] Add persistence regression coverage above the already-green pure transform tests. Locations
      must round-trip through an isolated `UserDefaults` suite and routes through a temporary
      `SavedRoutesStore` base directory / `order.json`; neither test may touch the user's real
      Application Support data.
- [ ] Add a focused XCUITest for the original drag path if macOS accessibility can drive it reliably.
      If it remains flaky, keep the storage tests automated and make the exact macOS drag matrix a
      mandatory manual release check in [[testing]] / [[033-refresh-test-coverage]].

## Open questions

- Is the flicker a SwiftUI `List` identity bug, or does the store re-emit and clobber the in-flight
  order? (Determines whether the fix is in the view or the store.)
- Does it reproduce only with categories enabled, or also in the ungrouped section? (Scopes the
  regression to the sectioning 029 added.)
- Do periodic `SimulationStateBridge` updates invalidate the containing sidebar during the drag?
  Compare disconnected/idle, connected/idle, and active playback before changing the data layer.
- macOS 26.5-specific `List` drag behavior — only investigate if the data-layer hypotheses are ruled
  out.

## Decisions made along the way

- **Cover saved locations and saved routes, but only within a section (2026-09-03).** The issue was
  reported against locations, while epic 029 promises the same reorder behavior for both libraries.
  Their views are parallel but their persistence paths are not, so both must pass. Cross-section drag
  remains out of scope; Category assignment is the supported way to move between sections.
- **A pure `LibraryOrder` test is not sufficient regression coverage (2026-09-03).** Those tests are
  already green while the user-visible operation fails. Automated coverage must cross each storage
  seam, and the real drag remains a UI test or mandatory manual release check.
- **Replace filtered `ForEach.onMove` state with stable-ID drag/drop (2026-09-03).** Static tracing
  ruled out the section-relative offset transform: Apple's `onMove` contract makes those offsets
  relative to the filtered `ForEach`, and the existing pure cases already prove that mapping. The
  unstable boundary was the `List`'s private reorder state: each section supplied a freshly filtered
  value, while unrelated sidebar observation and actionable row gestures could reconstruct that
  dynamic content before `onMove` committed, producing the visible flicker/snap-back. Each row now
  starts a namespaced stable-UUID drag and each `ForEach` accepts an indexed drop; only the store
  commits the resulting UUID-before-UUID move. Library type and category membership are validated,
  so cross-library and cross-section drops are no-ops. No view-local order was added.
- **Keep the original drag as the v2.3.0 manual gate unless WP9 proves XCUITest reliable
  (2026-09-03).** WP2 adds deterministic row accessibility identifiers and store-level regression
  tests but does not edit the WP9-owned UI test file. The candidate UI fixture must seed two
  ungrouped and two categorized locations/routes with fixed UUIDs under the isolated UI-test
  defaults/runtime root. Drag the first row onto the section end with
  `press(forDuration:thenDragTo:)`, assert accessibility order and relaunch order, and assert the
  selected coordinate/loaded route did not change. If AppKit exposes no stable insertion target,
  execute that same matrix manually for disconnected-idle and active-simulation states.

## Bugs / follow-ups found while building

- **Original report resolved in v2.3.0 (2026-10-30 owner confirmation).** The owner confirmed
  that #68's saved-location reorder failure is fixed in the public release, so the issue was
  closed as completed. This confirms the reported symptom, not the full location-and-route
  category/relaunch matrix below. Keep this epic in progress until F08 is executed against the
  signed app and its remaining acceptance criteria are recorded.

## Acceptance criteria

- [ ] Saved locations and saved routes both reorder without flicker in the ungrouped section and in
      populated category sections; the row stays where dropped.
- [ ] Dragging never triggers the row's normal action (location teleport or route load).
- [ ] The new order survives reselection, moving the item out of and back into its category, and an
      app relaunch.
- [x] Isolated persistence tests cover the location `UserDefaults` path and route `order.json` path;
      the existing pure offset tests remain green.
- [ ] The original drag path is covered by a reliable XCUITest or is explicitly executed as a
      mandatory manual release check.
- [ ] Verified on current `main` on macOS 26.x, including the reporter's saved-location reproduction.
