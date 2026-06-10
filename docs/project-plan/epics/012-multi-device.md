---
type: epic
id: 012
title: Simultaneous multi-device connection
status: open
milestone: v2.0.0
issue: 9
opened: 2026-05-29
shipped:
tags: [architecture]
---

# Epic 012: Simultaneous multi-device connection

> **Scope decision made (2026-06-01):** [[scope]] was revised — Goals now read "Single Mac,
> single user, **multi iPhone**" and the "no multi-device orchestration" non-goal was removed.
>
> **Scheduled (2026-06-10) into v2.0.0**, together with [[019-ai-integration]] (the AI command
> layer is designed device-addressed from day one, so the two land in the same release). The
> planning the earlier note asked for is below under "Planning notes".

## Why
Issue #9: today the architecture is single-device — one `selectedDeviceUDID`, one tunnel, one
simulation. The request is to connect several iPhones at once and run GPS simulation on all of
them (each its own route, or all the same), with per-device control/switching.

## Goal
Multi-device connection: the connection layer (tunnel, daemon, connection state) moves from
single- to multi-device, with UI to control/switch each device.

## Open questions — answered at planning (2026-06-10)

- **One daemon process managing N devices vs one daemon per device?** → **One per device.**
  Each `DeviceSession` owns its own `DaemonBridge` → `tm_daemon.py`. The line protocol stays
  unchanged (no device field in `SETQ`), one daemon crash doesn't take down the other devices,
  and there's no head-of-line blocking across devices on a shared stdin at N×20 Hz. Cost is N
  small Python processes — fine for the few-device ceiling below.
- **UI model: tabs, split view, or a switcher?** → **Switcher.** Shared map shows all devices
  (color-coded markers + route lines); the sidebar device list selects which device the single
  control surface (route panel, joystick) drives. Tabs/split deferred until the switcher proves
  insufficient.
- **How do route playback / joystick / recording interact at N?** → Each `DeviceSession` owns
  its own `SimulationActor` (engines, noise, recording — the D5 20 Hz aggregator becomes
  per-session). Joystick is a human control: it binds to the *selected* device only.
- **Does the sudo prompt multiply per device?** → **No.** One privileged tunnel broker, started
  once (one prompt per session), opens/closes N tunnels on demand — `tm_tunnel.sh` generalized,
  or pymobiledevice3's `remote tunneld` if it verifies against the pinned version (it should
  auto-tunnel all connected devices incl. hot-plug — **verify the CLI first**, per CLAUDE.md).
  Going from once-per-session to once-ever is [[020-single-auth-prompt]] (v2.1.0).

## Planning notes (2026-06-10)

Target model: `DeviceManager` (@MainActor, keyed by **UDID, never index**) owning N
`DeviceSession`s, each = `SimulationActor` + `SimulationBackend` + `DaemonBridge` + per-device
UI state. D7's `SimulationBackend` protocol is the seam — the refactor is "make actor+backend
per-session instead of singleton".

Sequencing (each step shippable):
1. **Sessionize the singletons** — `DeviceSession`/`DeviceManager` with a collection of size 1;
   behavior identical to today. Extract a `RoutingService` protocol while in the route code
   (D4 already names it; MapKit stays the default kernel — its per-Mac throttle is the
   multi-device risk that would trigger self-hosted OSRM later).
2. **N-up the lifecycle** — tunnel broker (one prompt, N tunnels), per-device daemon,
   UDID-keyed reconnect, sleep teardown for all sessions.
3. **N-up the UI** — markers/route lines per device, sidebar switcher, per-device status.
4. **Device-addressed command layer** — lands as [[019-ai-integration]].

New top correctness risk: **device-routing** — a command for device A must reach device A's
daemon. Keep every path UDID-keyed end to end; sending A's coordinate to B's DVT handle is a
silent, baffling bug. The single-device two-writers rule generalizes: nothing talks to a
`tm_daemon.py` except its own session's `DaemonBridge`.

Practical ceiling: designed for *a few* devices (N × 20 Hz loops + N daemons are trivial on
Apple Silicon), not dozens — say so in user-facing docs when this ships.

## Notes
The issue flags this as a **large architectural change** to the connection layer. When this is
picked up, re-read [[architecture]] (daemon protocol, concurrency topology) first — per
CLAUDE.md, update `DaemonBridge`, `tm_daemon.py`, and the docs in the same change. With the
per-device-daemon answer above, the daemon *protocol* should not need device fields; the
changes concentrate in the Swift connection layer.
