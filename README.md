# TrailMate

> *A native macOS companion for simulating real-time GPS location on iOS devices.*

-----

## Project Description

TrailMate is a personal-use SwiftUI macOS application that controls an iPhone's GPS location in real time. It is designed for iOS developers and testers who need to exercise location-dependent code paths without physically moving — testing a ride-share pickup flow, a weather widget in another timezone, an AR walking experience, or a store-locator from across the world.

TrailMate offers three ways to control the device's location, all available at the same time:

- **Teleport** — click anywhere on the map to instantly set the device's location.
- **Route** — enter From/To, calculate a walking/cycling/driving route, and play it back at configurable speed.
- **Joystick** — drive the device's location in real time with a game controller or on-screen virtual stick.

These coexist rather than being mutually exclusive: teleport to a starting point, play a route, then grab the joystick to deviate from it — no mode switch required.

The Mac acts as a controller; the iPhone reports the simulated coordinates to every app on the device through standard CoreLocation. No app is installed on the iPhone, and no jailbreak is required. The Python runtime ships bundled inside the app, so there's nothing to install on the Mac side either.

-----

## Quick Start

See [docs/quick-start.md](docs/quick-start.md) for the install-the-DMG path and the build-from-source path, plus iPhone pairing and common first-run issues.

-----

## Target Users & Use Cases

Representative use cases:

- *"I need to test that my app's geofencing fires correctly when the user enters Da'an district."*
- *"My app behaves weirdly when the user is moving at driving speed in a tunnel. I need to simulate that without a car."*
- *"I want to step through a 5km walking route to verify my distance tracker stays accurate."*
- *"I'm reviewing a CoreLocation bug report from a user in Osaka — I need to put my dev device there."*

-----

## Documentation

See [docs/README.md](docs/README.md) for the full documentation index — architecture, features, tech stack, decisions, project plan, and development notes.

-----

## Built with Claude

TrailMate was developed in collaboration with [Claude Code](https://claude.com/claude-code) (Anthropic). Architecture decisions, design discussions, and a substantial share of the code and documentation were produced through iterative pair-programming sessions. See [`CLAUDE.md`](CLAUDE.md) for the standing instructions given to Claude agents working in this repo, and the git log for per-commit co-authorship trailers.

-----

## Related Projects

Other tools that do roughly the same thing — Mac/desktop apps that simulate GPS on a real iPhone over the lockdown/DVT channel. Worth a look if TrailMate doesn't fit your setup.

- [LocWarp](https://github.com/keezxc1223/locwarp) — closest sibling; documented the iOS 26.4 quirks we hit
- [SimVirtualLocation](https://github.com/nexron171/SimVirtualLocation) — reference architecture we cribbed from

For underlying libraries, frameworks, and Apple platform docs, see [docs/technical/tech-stack.md](docs/technical/tech-stack.md#references).
