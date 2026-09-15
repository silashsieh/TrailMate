---
type: epic
id: 046
title: Pin the sidebar Devices section to the top while scrolling
status: open
milestone:
issue: 70
opened: 2026-08-18
shipped:
tags: [ui, sidebar, connection]
---

# Epic 046: Pin the sidebar Devices section to the top while scrolling

> Small sidebar ergonomics fix (#70). Related surfaces already exist —
> [[026-device-name-status-bar]] and [[021-menu-bar-background]]'s menu-bar summary — but
> neither helps while the user is scrolling inside the sidebar with the window open.

## Why

The sidebar is one `List` (`ContentView.swift:44`): `Section("Devices")` at the top — the
device switcher plus connection status (`:45`) — followed by Go to Location, Route, Joystick,
Saved Locations, Saved Routes, and Recordings (`:72`–`:89`). Because the Devices section shares
the scroll container with everything under it, scrolling down to pick a saved location or route
carries the device switcher and its connection status out of view. The user loses sight of which
device they are driving, and whether it is still connected, exactly while they are acting on it.

## Goal

The Devices section stays frozen at the top of the sidebar while the sections below it scroll,
so which device is selected and how its connection is doing is always visible.

## Out of scope

- Redesigning the device switcher rows themselves.
- Any change to the other sidebar sections' contents or order.
- The floating-panel / full-bleed sidebar experiment rejected during epic 037 — the sidebar
  stays a `NavigationSplitView` sidebar.

## Stories

- [ ] Lift the Devices section out of the scrolling `List` into a pinned header above it (or an
      equivalent pinned-header construct), keeping its current rows and behavior.
- [ ] Preserve today's interactions: row selection binds the control surface, context menus,
      Add Device, and the collapsed-log default ([[025-collapse-log-default]]).
- [ ] Keep it sane at small window heights — the pinned header must not crowd out the scrollable
      area.

## Open questions

- Pinned `Section` header inside the `List` vs a separate view above the `List`: the latter is
  simpler to keep visible but has to re-create the sidebar list styling to look native.
- Should the pinned area collapse to a single compact row when several devices are connected?

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Scrolling the sidebar to the bottom keeps the Devices section and connection status
      visible.
- [ ] Selecting a device, Add Device, and the per-row context menus behave as before.
- [ ] The pinned area does not overlap or clip the sections below at the minimum window height.
- [ ] Existing sidebar UI tests still pass (log collapsed by default, saved-item selection).
