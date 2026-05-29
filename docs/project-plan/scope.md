# Scope: Vision, Goals & Non-Goals

The bounds of what TrailMate is trying to be — and, more importantly, what it isn't. Scope creep gets checked against this document. For *how* work is planned and tracked against this scope, see [process.md](process.md).

## Vision

TrailMate exists to give a single developer **live, real-time control of their own iPhone's
GPS from their Mac** — teleport, route playback, and joystick steering over the iOS 17+ RSD
tunnel — without a paid Apple Developer account, an iOS app, or any anti-detection trickery.
It's the tool the owner wanted for testing location-aware apps against a *real* device (not the
Simulator), built to a quality worth showing as a portfolio piece.

The long-horizon direction stays **deliberately narrow**: deepen *fidelity* — better
positioning awareness, smoother and more flexible routes, more natural movement — rather than
*breadth*. TrailMate is a focused single-user desktop tool, not a fleet simulator or a cloud
service. The Non-Goals below are the load-bearing edges of that vision; new ideas get checked
against them before they become work.

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
