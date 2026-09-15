# Tech Stack

|Layer            |Choice                                                 |Rationale                                              |
|-----------------|-------------------------------------------------------|-------------------------------------------------------|
|Language (host)  |Swift 6                                                |Modern concurrency, strict typing                      |
|UI               |SwiftUI                                                |Native, fast iteration, no AppKit boilerplate          |
|Map              |MapKit + MKDirections                                  |Free, no API key, built-in routing                     |
|Joystick input   |GameController.framework                               |First-party, supports MFi / DualShock / Xbox / Joy-Cons|
|IPC              |Process + pipe (stdin/stdout to the Python daemon)     |Standard, well-documented                              |
|Privilege escalation|`osascript … with administrator privileges`         |One auth dialog per session; an SMAppService helper remains deferred (see features.md)|
|Device transport |pymobiledevice3 (pinned, vendored)                     |Only mature library supporting iOS 17+ RSD tunnel      |
|Python runtime   |python-build-standalone, bundled in app                |Self-contained; no system Python dependency            |
|Project file     |Hand-managed `.xcodeproj`                              |No XcodeGen; the project is edited directly            |
|Tests            |Swift Testing + XCTest                                 |Swift Testing for new code; XCTest for legacy interop  |
|Localization     |String Catalog (`.xcstrings`), compiler-extracted      |en + zh-Hant; no `.strings` files, follows system language|
|Distribution     |Developer ID + Hardened Runtime + Apple notarization   |Gatekeeper-compatible GitHub releases; no App Store submission|
|Updates          |Sparkle 2.9.6 + EdDSA-signed GitHub Pages appcast      |Native in-app updates from notarized GitHub Release DMGs|

## Versions Targeted

- macOS 26.4 (Tahoe / "26") on Apple Silicon
- iOS 26.4 on a paired iPhone with Developer Mode enabled
- Xcode 26.x
- Python 3.13 (bundled), pymobiledevice3 9.30.1 (pinned in `packaging/build.sh`)
- Sparkle 2.9.6 (exact Swift Package pin)

## References

Underlying libraries, frameworks, and platform documentation TrailMate builds on.

**Device transport**

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) — Python client for iOS lockdown/DVT services; provides the RSD tunnel and `simulate-location` handle
- [libimobiledevice](https://libimobiledevice.org/) — older C library; not used directly, but historical reference for the lockdown protocol

**Apple frameworks**

- [MapKit](https://developer.apple.com/documentation/mapkit) — map rendering, search, directions
- [GameController.framework](https://developer.apple.com/documentation/gamecontroller) — MFi / DualShock / Xbox / Joy-Con input
- [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation) — the `isSimulatedBySoftware` flag that exposes spoofed coordinates to apps that check

**Runtime packaging**

- [python-build-standalone](https://github.com/indygreg/python-build-standalone) — self-contained Python distribution we bundle into the app
- [Sparkle](https://github.com/sparkle-project/Sparkle) — update checks, EdDSA verification, installation, relaunch, and appcast tooling
