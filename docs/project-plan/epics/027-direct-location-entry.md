---
type: epic
id: 027
title: Direct location entry — search-to-go and coordinate field
status: done
milestone: v2.1.0
issue: 42
opened: 2026-06-19
shipped: 2026-06-20
tags: [ui, map, positioning]
---

# Epic 027: Direct location entry — search-to-go and coordinate field

> Merged enhancement covering **#42** (search a place → go there directly) and **#52** (enter
> raw coordinates to position; copy a point's coordinates). Both are "name a place and go,"
> independent of the route start/end fields. (Frontmatter `issue:` carries #42; #52 is the
> second issue this epic closes.)

## Why

Location search today is bound to route endpoints; the user can't just search a place and
teleport there. And there's no way to position by raw lat/lon, nor to copy a point's
coordinates back out. Both are "direct location entry" gaps.

## Goal

- Search a place and teleport the connected device there directly (not only as a route endpoint).
- Enter raw coordinates to teleport; copy the current/selected coordinate to the clipboard.

## Out of scope

- Route planning changes — the existing From/To search stays.

## Stories

- [x] Search result → "Go here" (teleport) without consuming a route endpoint slot (#42).
- [x] Coordinate entry field (lat, lon) → teleport (#52).
- [x] Copy a point's coordinates (current position / map selection) to the clipboard (#52).

## Open questions

- ~~Coordinate input formats to accept (decimal degrees; DMS later?).~~ Resolved: decimal
  degrees only this epic; DMS is out of scope (noted in scope above).

## Decisions made along the way

- **A new "Go to Location" sidebar section, not a second route field.** The place search and the
  coordinate field live in their own section above Route so they read as direct positioning, not
  route planning — and they reuse the existing teleport path (`AppState.goToSearchResult` /
  `goToCoordinate` → `selectedSession.teleport`), so they're not connection-gated and a connected
  device mirrors the red dot, consistent with [[028-map-while-disconnected]] / [[decisions#D11]].
  No new daemon command or AI verb was added.
- **Search-result tap teleports directly** (the result row *is* the "Go here" affordance), unlike
  the route From/To fields where a pick just fills the slot. The standalone `placeSearch` is its
  own `LocationSearch`, so the route fields are untouched.
- **Decimal-degree parsing is a pure, nonisolated helper** (`CoordinateFormat`) so the exact code
  the UI runs is unit-tested without launching the app — mirrors `MapRegionMath`. It accepts a
  comma or whitespace separator, tolerates whitespace/signed values, and range-checks lat/lon;
  `string(from:)` formats at 6 dp and round-trips through `parse`. Copy uses `NSPasteboard`.

## Bugs / follow-ups found while building

- None.

## Acceptance criteria

- [x] Searching a place and choosing "Go" teleports the device there; the route fields are untouched.
- [x] Typing lat/lon teleports; copy yields a paste-able coordinate string.
