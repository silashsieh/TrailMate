---
type: epic
id: 010
title: Rename saved locations & routes
status: in-progress
milestone: v1.4.0
issue: 11
opened: 2026-05-29
shipped:
tags: [library]
---

# Epic 010: Rename saved locations & routes

## Why
Issue #11: Saved Locations / Saved Routes each only offer Load, Replay, Delete. A name is fixed
at save time — to rename you must delete and re-save.

## Goal
Rename an existing saved location or route in place.

## Out of scope
- Folders / tags / search and other advanced library management — explicitly deferred until
  there are enough saved items to warrant it (a future epic, not this one).

## Stories
- [ ] Rename action (context menu / inline) on saved locations
- [ ] Rename action on saved routes
- [ ] Persist the new name (same store as the existing items)

## Open questions
- ~~Inline rename (Finder-style) or alert-with-TextField (the app's existing naming pattern)?~~
  Resolved 2026-06-07 with Harry: inline rename — see Decisions.

## Decisions made along the way
- **Inline rename over alert-with-TextField** (Harry, 2026-06-07). Context-menu **Rename**
  turns the row label into a focused TextField; Enter commits, Esc cancels, click-away
  commits (Finder behavior). HIG-native rename won over reusing the Save Location /
  Save as Route… alert pattern — those name a *new* item, where a dialog is fine; renaming
  an existing one is the canonical inline gesture ([[../technical/decisions|decisions]] D9:
  Apple conventions set defaults).
- **Plain `Button("Rename")` instead of `RenameButton`/`.renameAction`**: the sidebar rows
  are custom buttons, not selectable `List` rows, so there is no selection environment for
  `.renameAction` to bind to; a plain button renders identically.
- **Empty / whitespace-only name cancels the rename** (reverts to the old name), matching
  Finder. Names are trimmed; duplicates stay allowed, same as at save time.
- **No store-format change.** Waypoints: mutate the element in `savedWaypoints` +
  `persistWaypoints()` (same UserDefaults JSON). Routes: copy with new name through the
  existing `SavedRoutesStore.save()` — same `<id>.json` file, overwritten atomically.

## Bugs / follow-ups found while building

## Acceptance criteria
- [ ] Renaming a saved item updates its label and survives relaunch
- [ ] No change to Load / Replay / Delete behavior
