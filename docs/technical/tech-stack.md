# Tech Stack

|Layer            |Choice                                                 |Rationale                                              |
|-----------------|-------------------------------------------------------|-------------------------------------------------------|
|Language (host)  |Swift 6                                                |Modern concurrency, strict typing                      |
|UI               |SwiftUI                                                |Native, fast iteration, no AppKit boilerplate          |
|Map              |MapKit + MKDirections                                  |Free, no API key, built-in routing                     |
|Joystick input   |GameController.framework                               |First-party, supports MFi / DualShock / Xbox / Joy-Cons|
|IPC              |NSXPCConnection (for helper), Process+pipe (for Python)|Standard, well-documented                              |
|Privileged helper|SMAppService (macOS 13+)                               |Modern replacement for SMJobBless                      |
|Device transport |pymobiledevice3 (pinned, vendored)                     |Only mature library supporting iOS 17+ RSD tunnel      |
|Python runtime   |python-build-standalone, bundled in app                |Self-contained; no system Python dependency            |
|Project gen      |XcodeGen                                               |`project.yml` is reviewable; .xcodeproj is generated   |
|Tests            |Swift Testing + XCTest                                 |Swift Testing for new code; XCTest for legacy interop  |

## Versions Targeted

- macOS 26.4 (Tahoe / "26") on Apple Silicon
- iOS 26.4 on a paired iPhone with Developer Mode enabled
- Xcode 26.x
- Python 3.13 (bundled), pymobiledevice3 >= 9.12
