---
type: epic
id: 028
title: Map operations usable while no device is connected
status: in-progress
milestone: v2.2.0
issue: 45
opened: 2026-06-19
shipped:
tags: [ui, map]
---

# Epic 028: Map operations usable while no device is connected

> Enhancement (#45): let the user search, browse, and save locations/routes without a device
> connected — decouple the map/library UI from connection state.

## Why

Several map actions (search, save a location/route) are gated on a live connection today, but
they're useful for planning before connecting. The simulation obviously needs a device; the
map and library work don't.

## Goal

Search, pan/zoom, save locations, and plan/save routes all work with no device connected. Only
the actions that actually drive a device (teleport, play, joystick) require a connection.

## Out of scope

- Any change to what requires a connection to *simulate* (driving the device).

## Stories

- [x] Audit which map/library actions are connection-gated; ungate the ones that don't need a
      device (search, save location, plan/save route).
- [x] Keep device-driving actions clearly disabled (with an affordance) until connected.

## Open questions

- ~~Where to put the "connect to drive" hint so it's discoverable but not nagging.~~ Resolved
  per-surface (see Decisions): a hover hint on each gated control, and the map's existing
  status pill for the map-driven-travel surface.

## Decisions made along the way

- **One affordance: `.requiresConnection()` (`ContentView.swift`).** A view modifier that disables
  the wrapped control and attaches a discreet `.help` hover hint ("Connect a device to drive it")
  while disconnected, untouched once connected — Apple-HIG "discoverable, not nagging" (D9). It
  reads `appState.connectionStatus.isConnected`, the existing source of truth; no parallel flag.
  Wraps only device-*driving* controls (today: Play). Reusable for 029's click-to-teleport rows.
- **Blanket section-gate → per-action gate.** `SidebarView` no longer hides the whole planner
  behind `if isConnected`. `RouteSection` always renders; the only driving control in it (Play)
  carries `.requiresConnection()`.
- **`JoystickSection` stays *hidden* (not disabled-with-hint) while disconnected.** It is a
  pure status row for a control that auto-arms on connect (no Start button — D10/features); an
  inert disabled row would be noise, not a useful affordance. The mission explicitly kept it gated.
- **Map right-click / long-press destination menu stays connection-gated as a whole**, rather
  than shown with every item disabled. Every action in it drives the device or needs a live
  origin (Teleport, Go directly, Route here, Append, Wander), so a disconnected menu would be
  entirely disabled — a HIG anti-pattern — and `.help` tooltips don't render inside a
  `contextMenu` anyway. The map already shows a persistent, discoverable status pill, now reading
  "Connect a device to drive it", which is the discoverable affordance for that surface. The
  complex long-press gesture arbitration (draw mode, immediate-teleport-when-no-origin) is left
  untouched to avoid regressions.
- **"Save a location" already worked offline.** `SavedLocationsSection` renders on a *present
  position* (`simulatedCoordinate != nil`, e.g. the restored launch position), never on a
  connection, so saving the current location offline already worked and is preserved. The real
  gap (#45) was the route planner; saving an *arbitrary searched* coordinate with no position is
  027's new-search/coordinate-UI territory and out of scope here.

## Bugs / follow-ups found while building

- Saved-location rows (`SavedLocationRow`, owned by epic 029) still call `teleportToWaypoint`
  unconditionally; tapping one while disconnected is a silent no-op (the model-level
  `teleport` guard absorbs it) with no visible hint. When 029 reworks the saved-items sections
  it should adopt `.requiresConnection()` on click-to-teleport for a consistent affordance.

## Acceptance criteria

- [x] With no device connected: search, save a location, and plan+save a route all work.
- [x] Teleport/play/joystick remain disabled until a device connects, with a clear hint.
