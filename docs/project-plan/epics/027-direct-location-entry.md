---
type: epic
id: 027
title: Direct location entry — search-to-go and coordinate field
status: open
milestone: v2.2.0
issue: 42
opened: 2026-06-19
shipped:
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

- [ ] Search result → "Go here" (teleport) without consuming a route endpoint slot (#42).
- [ ] Coordinate entry field (lat, lon) → teleport (#52).
- [ ] Copy a point's coordinates (current position / map selection) to the clipboard (#52).

## Open questions

- Coordinate input formats to accept (decimal degrees; DMS later?). Decimal degrees first.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Searching a place and choosing "Go" teleports the device there; the route fields are untouched.
- [ ] Typing lat/lon teleports; copy yields a paste-able coordinate string.
