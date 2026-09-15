---
type: epic
id: 029
title: Saved-items library UX — reorder, categorize, auto-pan on select
status: done
milestone: v2.1.0
issue: 46
opened: 2026-06-19
shipped: 2026-06-20
tags: [ui, library]
---

# Epic 029: Saved-items library UX — reorder, categorize, auto-pan on select

> Merged enhancement: **#46** (drag-reorder & categorize saved locations/routes) and **#53**
> (auto-pan the map to a saved item when it's selected). Both are saved-library usability;
> builds on [[010-rename-saved-items]]. (Frontmatter `issue:` carries #46; #53 is the second
> issue this epic closes.)

## Why

The saved locations/routes lists are flat and fixed-order, and selecting an item doesn't move
the map to it. As the library grows this gets unwieldy.

## Goal

- Drag-reorder saved locations and routes; group them into user-defined categories.
- Selecting a saved item pans/zooms the map to it.

## Out of scope

- Cross-device/cloud sync of the library (single-user, local — see [[scope]]).

## Stories

- [x] Drag-to-reorder saved locations and routes; persist order (#46).
- [x] User-defined categories / grouping for saved items; persist (#46).
- [x] Auto-pan (and frame) the map to a saved item on selection (#53).

## Open questions

- ~~Categories: flat tags vs folders.~~ Resolved: folders (sidebar sections) — see Decisions.

## Decisions made along the way

- **Folders, not flat tags** — each item has one optional `category` (a folder
  name); ungrouped items sit under the existing top-level header, and each folder
  renders as its own `List` section. Matches the existing two-section layout and
  HIG (System Settings groups). One folder per item keeps the model simple.
- **Native `List.onMove` drag, per the mission** — no custom drag-and-drop.
  Reorder is *within a section*; moving an item *between* folders is the row's
  context-menu **Category** submenu (assign existing / new / remove). `.onMove`
  reorders within a `ForEach`, so cross-section drag isn't a native gesture —
  the menu covers it.
- **Folders are derived from the items, not free-standing** (start-simple). A
  folder exists while ≥1 item references it and disappears when emptied; folder
  names are alphabetized. No separate category store, no empty-folder persistence
  — revisit only if users ask for it.
- **Location order = the stored array; route order = a sidecar.** Locations
  already persist as an ordered `[SavedWaypoint]` in `UserDefaults`, so reorder is
  an array move (+ the new `category` field, `decodeIfPresent` for old data).
  Routes are per-file JSON with no inherent order, so a sidecar `order.json` in
  the routes dir holds the drag order — one tiny write per reorder vs. rewriting
  every route file. The loader skips `order.json` and sorts by it; routes not yet
  in the sidecar (fresh saves, pre-029 libraries) lead newest-first, preserving
  the prior default.
- **Reorder logic mapped through global slots** (`LibraryOrder.moveWithinGroup`):
  `.onMove` reports offsets relative to a folder's rows, mapped back onto the
  matching slots in the global array so reordering one folder never disturbs
  another. Pure + unit-tested.
- **Auto-pan via a one-shot `AppState.mapFocus` request** the `MapArea` camera
  observes (#53). A fresh `id` per selection re-pans even on the same item; a
  selection disengages Follow (it takes camera control). A location frames a
  ~1.2 km box; a route frames its padded bounding region (`MapRegionMath`,
  unit-tested per the coordinate-math rule). Selecting a location stays additive
  — it still teleports when connected, and now also frames even while
  disconnected.

## Bugs / follow-ups found while building

- None.

## Acceptance criteria

- [x] Reordering persists across launches; items can be assigned to a category.
- [x] Selecting a saved location/route moves the map to it.
