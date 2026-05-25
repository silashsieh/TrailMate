# Technical Architecture

## Layer Diagram

```
┌─────────────────────────────────────────────────┐
│  SwiftUI Views                                  │  Presentation
│  (MapView, Sidebar, Toolbar, Joystick)          │
├─────────────────────────────────────────────────┤
│  View Models (@Observable)                      │  State
│  (AppState, MapVM, RouteVM, JoystickVM)         │
├─────────────────────────────────────────────────┤
│  Services                                       │  Domain
│  ├── LocationSpoofingService                    │
│  ├── NavigationEngine (route playback)          │
│  ├── JoystickInputService (GameController)      │
│  └── DeviceDiscoveryService (USB / Wi-Fi)       │
├─────────────────────────────────────────────────┤
│  DaemonBridge                                   │  IPC
│  (Process mgmt, stdin/stdout protocol)          │
├─────────────────────────────────────────────────┤
│  PrivilegedHelper (SMAppService, runs as root)  │  Privilege
│  (Brings up the RSD tunnel; only this needs     │
│  sudo. Spawned once, kept alive.)               │
├─────────────────────────────────────────────────┤
│  tm_daemon.py (long-lived Python process)       │  Transport
│  ├── pymobiledevice3 tunnel client              │
│  ├── DVT LocationSimulation handle              │
│  └── stdin command loop                         │
├─────────────────────────────────────────────────┤
│  RSD tunnel → iPhone DVT service → CoreLocation │  Device
└─────────────────────────────────────────────────┘
```

## Process Topology

Three OS processes cooperate at runtime:

|Process          |Privilege|Lifetime|Responsibility                             |
|-----------------|---------|--------|-------------------------------------------|
|`TrailMate.app`  |user     |session |UI, state, all logic                       |
|`TrailMateHelper`|root     |session |Open the RSD TUN tunnel; nothing else      |
|`tm_daemon.py`   |user     |session |Persistent pymobiledevice3 + DVT connection|

The helper exists *only* because creating a TUN interface requires root. It does the absolute minimum and exposes a narrow XPC interface (`startTunnel(udid:)`, `stopTunnel()`). All location logic stays in the unprivileged app.

The Python daemon is a *long-lived* subprocess. Spawning `pymobiledevice3` per command costs ~500ms–1s in interpreter cold-start, which would kill the joystick experience. Instead, we spawn it once, keep the DVT connection open, and stream `lat,lon\n` lines into its stdin.

## Daemon Protocol

Line-delimited text over stdin/stdout. Simple, debuggable with `cat`.

**Mac → Daemon (commands):**

```
SET 25.033 121.5654              # teleport (responds OK)
SETQ 25.033 121.5654             # teleport, fire-and-forget (no response; for high-freq playback)
CLEAR                            # stop simulating
HEARTBEAT                        # check the daemon is alive
QUIT                             # graceful shutdown
```

**Daemon → Mac (events):**

```
READY                            # boot complete, DVT connected
OK                               # last command succeeded
ERR <code> <message>             # last command failed
TUNNEL_DOWN                      # RSD tunnel dropped
EXIT                             # graceful shutdown ack
```

No JSON, no length prefixes. If it ever grows, swap to length-prefixed JSON.

## Coordinate Math

All coordinate work is in **EPSG:4326** (lat/lon in degrees, WGS84). For joystick movement and route interpolation, we use the local-flat approximation at the current latitude:

```
meters_per_deg_lat = 111_320
meters_per_deg_lon = 111_320 * cos(lat_in_radians)
```

This is accurate to <0.1% over distances <10km, which covers every realistic single-tick movement. For long routes (>50km), MKDirections gives us a polyline of fine-grained coordinates, so we never need to integrate over long stretches.
