---
type: epic
id: 028
title: Use the map and simulate a position while no device is connected
status: in-progress
milestone: v2.2.0
issue: 45
opened: 2026-06-19
shipped:
tags: [ui, map, simulation]
---

# Epic 028: Use the map and simulate a position while no device is connected

> Enhancement (#45): let the user search, browse, save, plan — **and control the simulated
> position (red dot)** — without a device connected. A device, once connected, mirrors the red
> dot and snaps to it on connect.

## Why

Map and planning actions (search, save a location/route) were gated on a live connection but are
useful before connecting. Beyond planning, the owner asked for the **simulated position itself**
to be controllable offline: teleport / route / joystick should move the red dot with no device,
and connecting a device should make it jump to wherever the red dot is and follow from there.
That turns the connection into a *mirror* of a live local state rather than a precondition for
simulating — see [[decisions#D11]].

## Goal

Everything except literally driving a physical device works offline: search, pan/zoom, save
locations, plan/save routes, **and** teleport / route playback / joystick — all move the local
red dot. Connecting a device mirrors the red dot immediately (snaps on connect, follows after);
disconnecting reverts the device to real GPS but leaves the red dot put and controllable.

## Out of scope

- The AI command socket stays device-addressed by `connectedUDID` and still rejects commands to
  a not-connected device — offline control is a GUI affordance, not a remote one.
- Per-UDID position restore (still a single global last-position — D10 scope cut).

## Stories

- [x] Audit which map/library actions are connection-gated; ungate the ones that don't need a
      device (search, save location, plan/save route).
- [x] ~~Keep device-driving actions clearly disabled (with an affordance) until connected.~~
      Superseded: those actions now drive the local red dot instead of being disabled.
- [x] Make the simulated position a live local state: teleport / route playback / joystick move
      the red dot offline; a connected device mirrors it and snaps to it on connect; disconnect
      keeps the red dot.

## Open questions

- ~~Where to put the "connect to drive" hint so it's discoverable but not nagging.~~ Moot once
  driving works offline — there's nothing to gate. The map status pill now just reads "Local
  position" vs "Simulating" (informational), alongside the existing green/grey connection dot.

## Decisions made along the way

- **The simulated position is a live local state; the device is a mirror.** This is the load-
  bearing decision, recorded in full at [[decisions#D11]]. `SimulationActor` runs
  its loops for the session's whole lifetime (`startEngine`/`stopEngine`), and `attach`/`detach`
  only swap the device backend in/out — attach re-emits the current coordinate so the device
  snaps to the red dot on connect; detach keeps the loops and position so the dot survives a
  disconnect. `emit()` writes the bridge unconditionally and the device only via `backend?`.
- **First approach (gating) was superseded.** The initial cut decoupled only the *UI*: a
  `.requiresConnection()` modifier disabled teleport/play/joystick with a discreet hint while
  disconnected, the map menu opened with its items dimmed, etc. When the owner asked for the red
  dot itself to be controllable offline, that gating became wrong — the controls simply work now —
  so the modifier, its hint copy, and the disconnected hint row were removed. Joystick arms on
  *selection* (not selection + connection); idle jitter is gated on a live backend so the offline
  preview doesn't drift; session removal/quit routes through `DeviceSession.shutdown()` so the
  now-always-running engine doesn't leak.
- **"Save a location" already worked offline.** `SavedLocationsSection` renders on a *present
  position* (`simulatedCoordinate != nil`), never on a connection, so saving the current location
  offline already worked and is preserved. Saving an *arbitrary searched* coordinate with no
  position is 027's new-search/coordinate-UI territory and out of scope here.

## Bugs / follow-ups found while building

- Saved-location rows (`SavedLocationRow`, owned by epic 029) call `teleportToWaypoint`, which now
  works offline too (it moves the red dot) — no change needed, and the affordance is consistent
  with the rest of the map. 029 can treat these as ordinary offline-capable controls.
- Record / Follow on the map overlay now show whether or not a device is connected, like the
  rest of the map controls: Record captures the local red-dot path (the recorder appends on every
  `emit()`, device or not) and Follow tracks the dot's camera. Both already worked at the model
  level — only the overlay had hidden them while disconnected.

## Acceptance criteria

- [x] With no device connected: search, save a location, plan+save a route, **and** teleport /
      play a route / drive the joystick all work, moving the local red dot.
- [x] Connecting a device snaps it to the current red dot and then follows it; disconnecting
      reverts the device to real GPS but leaves the red dot controllable.
