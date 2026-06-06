---
type: epic
id: 008
title: Right-click map menu (replace/augment long-press)
status: done
milestone: v1.3.0
issue: 16
opened: 2026-05-29
shipped: 2026-06-06
tags: [ui, map]
---

# Epic 008: Right-click map menu (replace/augment long-press)

## Why
Issue #16: the destination menu (Teleport / Go directly / Route here / Append direct /
Append route / Wander) is summoned by a 0.5 s long-press, which is awkward with a mouse or
trackpad on macOS. (Long-press was chosen to avoid clashing with the map's pan/zoom gestures.)

## Goal
Summon the same menu with a **right-click (secondary click)** — matching macOS convention and
the app's existing `.contextMenu` rows (Saved Locations / Saved Routes). Long-press may stay
for trackpad users, or be removed.

## Out of scope
- Changing the menu's actions themselves — same set, different trigger.

## Open questions
- ~~Keep long-press as a trackpad fallback, or remove it entirely?~~ **Kept as fallback**
  (decided 2026-06-06): right-click is the primary trigger; long-press keeps existing muscle
  memory and its behavior is untouched.

## Stories
- [x] Right-click gesture that yields the **click location** (a plain `.contextMenu` doesn't
      provide it — need a gesture that exposes click position, then `proxy.convert` → coordinate)
- [x] Wire it to the existing destination menu
- [x] Decide + apply the long-press disposition (keep as fallback or remove)

## Decisions made along the way
- **Two coexisting presentations, by request:** right-click opens a native `.contextMenu` at
  the pointer (consistent with the sidebar rows and D9); long-press keeps the capsule action
  bar unchanged. Same actions, same `AppState` methods behind both.
- **Click location via hover tracking:** `.onContinuousHover(coordinateSpace: .local)` records
  the last pointer position; it's converted with `proxy.convert` lazily at menu time (a stored
  coordinate would go stale if the camera moved under a stationary cursor).
- **No origin → menu still opens**, with "Go directly" / "Route here" disabled. Deliberately
  diverges from long-press's instant-teleport-on-first-press: a right-click should present a
  menu, not perform an action. Teleport and Wander stay enabled.
- **Disconnected → no menu:** the menu builder emits no content unless connected, mirroring
  the long-press guard.

## Acceptance criteria
- [x] Right-click on the map opens the destination menu at the clicked coordinate
- [x] Actions behave identically to the current long-press menu
- [x] No regression to map pan/zoom

## Related
- Gesture arbitration overlaps with [[007-hand-drawn-routes]] (both add map gestures).
