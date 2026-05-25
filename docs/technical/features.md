# Core Features (V1 Scope)

## F1: Device Discovery & Connection

- List USB-paired iPhones via pymobiledevice3 `usbmux list`
- Sidebar device picker
- Mount status indicator (DDI mounted? tunnel up? DVT ready?)
- "Reconnect" button when tunnel drops

## F2: Map View

- Centered, zoomable MapKit view occupying main pane
- Search bar with `MKLocalSearchCompleter` autocomplete
- Click -> place pin -> "Teleport here" / "Set as start" / "Set as end" context menu
- Current simulated position rendered as a distinct marker
- Real device location (if known and recent) rendered as a ghosted secondary marker

## F3: Teleport Mode

- Click on map -> device immediately reports that coordinate
- "Clear" button -> device reverts to real GPS

## F4: Route Mode

- From/To pickers (map clicks or search)
- Transport mode segmented control: Walk / Cycle / Drive
- Speed slider: 0.5x, 1x, 5x, 10x, 100x
- "Calculate Route" -> `MKDirections.calculate()` -> polyline rendered on map
- Playback controls: Play / Pause / Stop / Restart
- Progress bar showing elapsed / remaining
- Interpolation: 10 Hz, smooth movement between MKDirections waypoints

## F5: Joystick Mode

- Hardware game controller via GameController.framework (auto-detected, hot-pluggable)
- On-screen virtual stick as fallback (SwiftUI `DragGesture` inside a circular pad)
- 20 Hz update tick
- Speed cap selector: Walk (1.4 m/s) / Cycle (5 m/s) / Drive (15 m/s) / Custom
- Heading derived from stick angle; magnitude controls speed
- "Recenter" button returns to last teleport location

## F6: Status & Diagnostics

- Tunnel status pill in toolbar (green = up, yellow = mounting, red = down)
- "View Log" sheet showing daemon stdout/stderr
- Copy-coords-to-clipboard from any marker

## F7: Wireless Transport (Wi-Fi tunnel) — Post-V1

V1 assumes a USB-cabled iPhone. Post-V1, support running the RSD tunnel over Wi-Fi so the device can sit untethered on the desk (or across the room).

**Feasibility**: confirmed. `pymobiledevice3` supports Wi-Fi tunnels on iOS 17+; the same `LocationSimulation` DVT instrument is reached over both transports. The daemon and `DaemonBridge` need no changes — they just consume an RSD address + port, which works the same regardless of wire. The work is mostly UX, onboarding docs, and hardening for less-reliable links.

**Two paths depending on iOS version:**

|iOS version       |Tunnel command                                                                                                                            |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------|
|17.0 – 17.3.1     |`sudo python3 -m pymobiledevice3 remote start-tunnel -t wifi`                                                                             |
|17.4+ (incl. 26.4)|`python3 -m pymobiledevice3 lockdown wifi-connections on` (one-time, persists), then `sudo python3 -m pymobiledevice3 lockdown start-tunnel`|

Both emit an RSD address + port — exactly what the sidebar already accepts.

**Prerequisites:**

- Device must have been paired to this Mac at least once over USB (Wi-Fi tunnels cannot bootstrap trust from scratch).
- Mac and iPhone on the same LAN, or otherwise routable to each other.
- Tunnel process still needs root (TUN interface) — same as USB.

**Implementation tasks (in suggested order):**

1. Update README onboarding with the Wi-Fi command for our target (iOS 17.4+).
2. Add a "Transport: USB / Wi-Fi" picker to the sidebar. Purely cosmetic in v1 of this feature — it drives which `start-tunnel` hint the UI shows. The daemon path doesn't change.
3. Strengthen daemon liveness handling (Wi-Fi flaps more than USB):
    - `tm_daemon.py`: detect DVT session drop and emit `ERR 12 session lost`; consider a self-driven heartbeat (or rely on the existing `HEARTBEAT` command if the Swift side polls).
    - `DaemonBridge`: surface that as a transition to `.disconnected` with a "Wi-Fi dropped" log entry, instead of the current silent stall.
4. Fold both transports into the eventual `PrivilegedHelper` (Phase 4): helper accepts `--transport wifi|usb|auto` and runs the right `start-tunnel` invocation, so the sudo prompt happens once at install rather than at every `start-tunnel`.

**Caveats:**

- Session liveness rule still applies: if Wi-Fi flaps or the device sleeps, the DVT session drops and the iPhone reverts to real GPS. Apple's design; not bypassable.
- `wifi-connections on` is a persistent device-side toggle — flipping it once per device is fine; just remember it exists when debugging "why does this device behave differently?"

**References:**

- [pymobiledevice3 iOS 17 tunnels guide](https://github.com/doronz88/pymobiledevice3/blob/master/docs/guides/ios17-tunnels.md)

## Out of V1 (deferred)

- GPX import/export (Phase 4)
- Saved waypoints / route library (Phase 4)
- Altitude / heading / speed overrides (research first; CoreLocation derives most of these)
- Multi-device fan-out
- Recording real movement and replaying it
- Friction simulation (signal dropouts, accuracy variation)
