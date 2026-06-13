---
type: epic
id: 012
title: Simultaneous multi-device connection
status: in-progress
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

## Detailed design (v2.0.0 planning workflow, 2026-06-13)

Grounded in the current code: `AppState.swift` (~1074 lines) fuses three layers the refactor
splits — **app-global** (→ `DeviceManager`: tunnel broker, discovery, stale sweep, selected
device, noise σ, restore-on-launch, log, `GCController`), **per-device** (→ `DeviceSession`:
connectionStatus, RSD addr/port, its `SimulationActor` + `SimulationStateBridge` +
`DaemonBridge`, events tasks, route/playback state — `transportMode`/`customSpeedKmh`/
`speedMultiplier`/`loopMode`/`loopCount` — persisted position), and the **control surface**
(drives the *selected* session). The D7 actor seam is already clean per-instance.

**Structural routing guarantee (top risk, made structural not runtime):** each `DeviceSession`
holds its `DaemonBridge` **private**; `DeviceManager` exposes `teleport(udid:…)`-style facade
methods that resolve `sessions[udid]` and forward. A `SimulationActor` only ever talks to the
backend injected at its own `attach(backend:)`. "A's coordinate reaches B's daemon" is then
impossible by construction. `dispatch` (used by [[019-ai-integration]]) **must never read
`selectedDeviceUDID`** — that's GUI/joystick state only. `tm_daemon.py`'s line protocol is
**unchanged** (device identity is structural — one daemon per RSD addr/port).

**Four shared sinks** are the real refactor work beyond actor replication: (1)
`SimulationStateBridge` → per-session; (2) `RecorderService` → split `RecordingCapture`
(per-session) / `RecordingsLibrary` (app-wide); (3) `SimulatedPositionPersistence` →
UDID-keyed; (4) `GCController`/joystick → single observer on `DeviceManager`, input bound to
the selected session only (switch = stop old engine + start new). `RoutingService` is a
**stateless app-level shared service** (the MapKit throttle is per-process; per-session buys
nothing); route *output* is per-session. Stale-daemon `pkill -f tm_daemon.py` is **cold-start
orphan cleanup only** — per-device reconnect kills only that session's `Process`.

**Tunnel broker — `remote tunneld`. SPIKE PASSED (2026-06-13) → GO.** Generalize
`TunnelSupervisor` → `TunnelBroker`: reuse the existing `osascript` elevation + parent-PID
watch + `.stop` sentinel, but launch `pymobiledevice3 remote tunneld` instead of one
`lockdown start-tunnel`; the app queries `GET /` for the per-UDID RSD map. One prompt, N
tunnels, hot-plug. The fallback (N `start-tunnel` sessions) is **not needed** — see result.

#### Spike result (2026-06-13, macOS 26.5 / 3 Wi-Fi-paired devices)
- ✅ One `sudo … remote tunneld` launch tunneled **all three** devices; `GET /` returned the
  per-UDID map (`tunnel-address`, `tunnel-port`, `interface: usbmux-<UDID>-Network`).
- ✅ **Sleep → wake recovered every tunnel with NO new auth prompt** (the decisive test).
- ✅ A tunneld `(address,port)` drove a real device via `tm_daemon.py` + `SETQ` (DVT-usable).
- ⚠️ **Load-bearing constraint: the RSD endpoint is EPHEMERAL.** Every address *and* port
  **changed** on wake (e.g. `…0005…` `fd15:…:65106` → `fd6c:…:65107`). So:
  - The broker resolves **UDID → current `(address,port)` by querying `tunneld GET /` at
    connect time, every time**. Never cache/persist the RSD endpoint.
  - `DeviceSession` keys on the **UDID** (stable); it holds no fixed address. Connect = look up
    the live address, then spawn the daemon against it.
  - Sleep drops the DVT session anyway (existing disconnect-on-sleep flow); reconnect just
    re-queries `tunneld`. The current flow is compatible — the only change is "don't reuse the
    old address."
  - `tunneld` returns a **list per UDID**; pick the `usbmux-<UDID>-Network` entry.
- `TunnelBroker` surface becomes: `ensureRunning()` (launch tunneld once, the one prompt) +
  `rsdEndpoint(udid:) async -> (address, port)?` (query `GET /`). Port `49151` configurable.

### Spike commands (run 2026-06-13 — kept for reference)
Against the bundled interpreter, same env `tm_tunnel.sh` exports:
```
PR=/Users/harry/Documents/pikmin/TrailMate/PythonResources
sudo PYTHONHOME=$PR/python PYTHONPATH=$PR/python-libs PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1 \
  $PR/python/bin/python3.13 -m pymobiledevice3 remote tunneld --port 49151 -p tcp
curl -s http://127.0.0.1:49151/          # expect {udid:[{tunnel-address,tunnel-port,interface}]}
```
Then on macOS 26.4 / iOS 26.4: (a) plug 2nd iPhone → re-`GET /` shows it (hot-plug);
(b) unplug → gone; (c) **sleep→wake→re-`GET /` recovers tunnels with NO new auth dialog**
(the decisive test choosing `tunneld` over per-device start-tunnel); (d) take an
`(address,port)` from `GET /`, run `tm_daemon.py <address> <port>`, push a `SETQ`, confirm the
dot moves — proves a tunneld tunnel is DVT-usable. `tunneld` returns a **list per UDID** (pick
the usbmux/USB TCP entry); make the port configurable (49151 may collide).

### Open-question answers
- **Restore seeding before connect** → use the last-selected UDID's slot.
- **Log lines** → one app-wide store, device-tagged prefix per line.
- **Multi-transport pick** → the `usbmux-<UDID>-Network` entry (confirmed in the 2026-06-13 spike).

## Notes
The issue flags this as a **large architectural change** to the connection layer. When this is
picked up, re-read [[architecture]] (daemon protocol, concurrency topology) first — per
CLAUDE.md, update `DaemonBridge`, `tm_daemon.py`, and the docs in the same change. With the
per-device-daemon answer above, the daemon *protocol* should not need device fields; the
changes concentrate in the Swift connection layer.
