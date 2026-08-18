---
type: epic
id: 039
title: Fix saved-items drag-reorder (flicker + snap-back)
status: open
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

A user (#68, TrailMate v2.1.0, macOS 26.5) reports the saved-places list can't be reordered: dragging
a row makes the list **flicker continuously**, and **on mouse-up the row snaps back to its original
position** — the move never commits. Reorder was the headline of [[029-saved-items-library-ux]], so
this is a regression in shipped behavior.

The flicker-then-revert signature points at the list's drag model fighting its data source: the
on-screen order is driven from a binding/identity that the drop handler doesn't actually persist (or
persists to a store that re-emits the old order mid-drag), so SwiftUI re-renders the pre-drag order
on every frame and discards the drop. Likely suspects to confirm during the work: the `List`
`onMove`/`.draggable`+`.dropDestination` wiring vs. the saved-items store ordering, item identity
(stable `id` vs. array index), and whether the categories/sections added in 029 changed the move's
index space. macOS 26.5-specific behavior is possible but should be the last hypothesis, not the
first.

## Goal

Dragging a saved place to a new position reorders the list smoothly (no flicker) and the new order
**persists** across the drop, reselection, and app relaunch — both within a category/section and, if
029 allows cross-section moves, across them.

## Out of scope

- Any new library features (new categories model, multi-select drag, etc.) — this is a defect fix to
  restore 029's intended behavior, nothing more.
- Reworking the saved-items persistence format beyond what the fix requires.

## Stories

- [ ] Reproduce on macOS 26.x with several saved places; capture the exact drag/drop + persistence
      path in code (`List` reorder wiring ↔ saved-items store ordering).
- [ ] Fix the order-commit so the drop persists (stable item identity; drop handler writes through to
      the store; the view observes the committed order, not a stale snapshot).
- [ ] Confirm the fix holds with categories/sections present (the structure 029 introduced).
- [ ] Add a regression test for reorder persistence (model-level at minimum; UI test if feasible) —
      ties into [[033-refresh-test-coverage]], which already flags 029 as under-covered.

## Open questions

- Is the flicker a SwiftUI `List` identity bug, or does the store re-emit and clobber the in-flight
  order? (Determines whether the fix is in the view or the store.)
- Does it reproduce only with categories enabled, or also on a flat list? (Scopes the regression to
  the sectioning 029 added.)
- macOS 26.5-specific `List` drag behavior — only investigate if the data-layer hypotheses are ruled
  out.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Dragging a saved place reorders without flicker and the row stays where dropped.
- [ ] The new order survives reselection and app relaunch.
- [ ] A regression test covers reorder persistence.
- [ ] Verified on the reporter's configuration (v2.1.0 repro path, macOS 26.x).
