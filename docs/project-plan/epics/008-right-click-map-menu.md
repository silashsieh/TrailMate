---
type: epic
id: 008
title: Right-click map menu (replace/augment long-press)
status: open
milestone: v1.3.0
issue: 16
opened: 2026-05-29
shipped:
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
- Keep long-press as a trackpad fallback, or remove it entirely?

## Stories
- [ ] Right-click gesture that yields the **click location** (a plain `.contextMenu` doesn't
      provide it — need a gesture that exposes click position, then `proxy.convert` → coordinate)
- [ ] Wire it to the existing destination menu
- [ ] Decide + apply the long-press disposition (keep as fallback or remove)

## Acceptance criteria
- [ ] Right-click on the map opens the destination menu at the clicked coordinate
- [ ] Actions behave identically to the current long-press menu
- [ ] No regression to map pan/zoom

## Related
- Gesture arbitration overlaps with [[007-hand-drawn-routes]] (both add map gestures).
