---
type: epic
id: 028
title: Map operations usable while no device is connected
status: open
milestone: v2.1.0
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

- [ ] Audit which map/library actions are connection-gated; ungate the ones that don't need a
      device (search, save location, plan/save route).
- [ ] Keep device-driving actions clearly disabled (with an affordance) until connected.

## Open questions

- Where to put the "connect to drive" hint so it's discoverable but not nagging.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] With no device connected: search, save a location, and plan+save a route all work.
- [ ] Teleport/play/joystick remain disabled until a device connects, with a clear hint.
