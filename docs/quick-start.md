# Quick Start

Two paths: install the prebuilt DMG, or build from source. The iPhone-side setup is identical either way.

## What you need (either path)

- A Mac on Apple Silicon, macOS 14+ (validated on macOS 26.4).
- An iPhone running iOS 17+ (validated on iOS 26.4).
- A data-capable USB cable for the first pairing. Wi-Fi tunneling works after a one-time USB pair.

-----

## Option A — Install the DMG

For users who just want to run TrailMate.

### 1. Download and open

1. Grab the latest `TrailMate-<version>.dmg` from the [Releases page](https://github.com/silashsieh/TrailMate/releases).
2. Open the DMG and drag `TrailMate.app` to `/Applications`.
3. The DMG is **ad-hoc signed** (no paid Developer ID), so Gatekeeper will refuse a normal double-click on first launch. Use one of:
   - Right-click `TrailMate.app` in Finder → **Open** → **Open** to confirm.
   - Or open System Settings → Privacy & Security → scroll to the "TrailMate was blocked" notice → **Open Anyway**.

### 2. Pair your iPhone (one-time)

1. **Enable Developer Mode** on the iPhone: Settings → Privacy & Security → Developer Mode → toggle on → reboot → confirm with passcode.
2. **Trust this Mac**: plug the iPhone in via USB; tap **Trust** on the iPhone, then enter your passcode.
3. **Mount the developer disk image (DDI)** — one-time per major iOS update. Easiest path:
   - Open Xcode → Window → Devices and Simulators → pick your iPhone. Xcode auto-downloads and mounts the DDI.
   - Alternative: install [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) and run `sudo pymobiledevice3 mounter auto-mount`.

### 3. Connect and teleport

1. Launch TrailMate.
2. The sidebar lists discovered iPhones — pick yours.
3. Click **Connect**. macOS asks for your admin password (the RSD tunnel needs root). Approve once per session.
4. The status pill shows **Connected**.
5. Long-press anywhere on the map → **Teleport here**. Check Apple Maps on the iPhone — your location is now wherever you long-pressed.

Click **Clear** in the sidebar to revert the device to its real GPS.

-----

## Option B — Build from source

For users who want to modify TrailMate or produce their own DMG.

### Prerequisites

- macOS on Apple Silicon, Xcode 26+, Xcode Command Line Tools (`xcode-select --install`).
- ~300 MB free disk (Python bundle + build artifacts).
- A free Apple ID is enough — no paid Developer Program required.

### 1. Clone and build the bundled Python runtime

The app ships a self-contained CPython + `pymobiledevice3` so end users don't need system Python.

```sh
git clone https://github.com/silashsieh/TrailMate.git
cd TrailMate
./packaging/build.sh
```

Output: `TrailMate/PythonResources/` (~210 MB). The python-build-standalone tarball is cached under `packaging/.cache/`, so subsequent runs are fast.

On a fresh clone, the bundle is not yet wired into the Xcode project. See [`packaging/README.md`](../packaging/README.md) for the one-time Xcode steps (folder reference, entitlements, re-sign Run Script phase). Skip this section if you only need to build the DMG via `release.sh`.

### 2. Open and run

1. Open `TrailMate.xcodeproj` in Xcode.
2. Target → Signing & Capabilities → set Team to your free Apple ID (or "Sign to run locally").
3. ⌘R to build and run.

The iPhone-side setup (Developer Mode, trust, DDI mount) is identical to Option A.

### 3. Optional — build your own DMG

```sh
./packaging/release.sh
```

Output: `build/TrailMate-<version>.dmg`, ad-hoc signed. This is what the `release.yml` GitHub Actions workflow runs.

-----

## Common first-run issues

- **"App is damaged and can't be opened"** — Gatekeeper quarantined the unsigned bundle. Strip the quarantine attribute: `xattr -dr com.apple.quarantine /Applications/TrailMate.app`.
- **"Could not find Developer Disk Image"** — the DDI isn't mounted. Connect to Xcode once (Window → Devices and Simulators), wait for the download, then reconnect the device.
- **"Tunnel won't start" / RSD address never arrives** — confirm Developer Mode is on, the cable is data-capable (not power-only), and you've tapped Trust on the iPhone for this Mac.
- **Device appears but Connect fails repeatedly** — quit TrailMate, open Activity Monitor, kill any stray `tm_daemon`, `tm_tunnel`, or `pymobiledevice3` processes, relaunch.
- **Disconnected on wake from sleep** — by design. The DVT session can't survive sleep; click Connect again.
- **Pokémon GO / banking apps don't see the spoofed location** — they read `CLLocationSourceInformation.isSimulatedBySoftware` and reject simulated fixes. This is an OS-level flag we do not (and will not) attempt to suppress.
