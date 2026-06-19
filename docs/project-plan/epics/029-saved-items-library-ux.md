---
type: epic
id: 029
title: Saved-items library UX — reorder, categorize, auto-pan on select
status: open
milestone: v2.2.0
issue: 46
opened: 2026-06-19
shipped:
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

- [ ] Drag-to-reorder saved locations and routes; persist order (#46).
- [ ] User-defined categories / grouping for saved items; persist (#46).
- [ ] Auto-pan (and frame) the map to a saved item on selection (#53).

## Open questions

- Categories: flat tags vs folders. Start with simple sections/folders.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Reordering persists across launches; items can be assigned to a category.
- [ ] Selecting a saved location/route moves the map to it.
