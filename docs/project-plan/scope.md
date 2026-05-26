# Scope: Goals & Non-Goals

The bounds of what TrailMate is trying to be — and, more importantly, what it isn't. Scope creep gets checked against this document.

## Goals

- Real-time GPS simulation on a paired iOS 17+ device (validated on iOS 26.4).
- Three coexisting controls: teleport, route, joystick.
- Native macOS look-and-feel: SwiftUI, MapKit, standard NSWindow chrome.
- Single Mac, single iPhone, single user — build-from-source from a free Apple ID.
- Codebase suitable as a portfolio reference (clean architecture, documented decisions).

## Non-Goals

- **No iOS app component.** Everything runs on the Mac. No sideloading, no jailbreak.
- **No anti-detection.** The device reports `CLLocation.sourceInformation.isSimulatedBySoftware == true`. Apps that check for this (e.g. Pokémon GO) will see through us. Not a goal to defeat.
- **No App Store distribution.** Personal tool. Build from source, run unsigned.
- **No cross-platform.** macOS only. Windows users have LocWarp; Linux users have raw pymobiledevice3.
- **No legacy iOS support.** iOS 17 introduced the personalized DDI + RSD tunnel; that's the minimum target. Users on iOS ≤16 should use Schlaubischlump's LocationSimulator.
- **No multi-device orchestration.** One iPhone at a time.
- **No production hardening.** This is a single-user dev tool, not a fleet-simulation platform.
