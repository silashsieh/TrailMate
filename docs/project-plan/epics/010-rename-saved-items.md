---
type: epic
id: 010
title: Rename saved locations & routes
status: open
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

## Acceptance criteria
- [ ] Renaming a saved item updates its label and survives relaunch
- [ ] No change to Load / Replay / Delete behavior
