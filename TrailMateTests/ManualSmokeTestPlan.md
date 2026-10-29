# v2.3.0 manual smoke plan

Run this checklist after the integrated unit and UI suites pass. It covers only behavior that needs a real device, macOS system UI, live MapKit, visual inspection, or release signing. Deterministic cases in [Epic 033](../docs/project-plan/epics/033-refresh-test-coverage.md) remain automated release gates; a pass here does not waive a failing test.

**Release outcome (2026-10-29):** v2.3.0/build 13 was published with the owner's authorization
before this formal signed-app matrix and the production Sparkle upgrade were completed. Blank
status cells below remain unverified. Record later results with their actual date and artifact;
the [release-readiness record](../docs/project-plan/v2.3.0-release-readiness.md) holds the
published artifact and CI evidence.

## Run record and prerequisites

| Field | Record before starting |
|---|---|
| Owner and date | `…` |
| Candidate commit, version/build, artifact SHA-256 | `…` |
| Artifact kind and path | `Developer ID signed/notarized DMG` / `ad-hoc debug copy`; `…` |
| macOS, iOS, device connection | `…`; record two device labels for multi-device rows |
| Clean test account and data root | `…`; record the account and its TrailMate Application Support path |
| Existing personal TrailMate session | Confirm stopped before any app launch, app-hosted test, tunnel manipulation, or sleep test |
| Evidence directory | `…`; keep screenshots, redacted logs, GPX names, and timestamps together |

- **WP10** owns functional rows F01–F20; the **release owner/WP11** owns packaging rows R01–R05. Mark each row `Pass`, `Fail`, or `Blocked`, with a timestamp and evidence link. A missing second device or unavailable signing credential is `Blocked`, not `Pass`. Record the issue and rerun the affected row after a fix.
- Use a clean test macOS account and disposable saved items/recordings. Back up any test fixtures before deleting them. Do not use the owner's personal Application Support directory, defaults, AI socket, or tunnel-control files as fixtures. Obtain the test-run lease and stop the personal instance before app-hosted/UI suites; this plan never authorizes launching a competing app while the personal instance is active.
- Use a supported iOS 17+ device with Developer Mode, trust/pairing, and the personalized Developer Disk Image ready. Prepare two devices for multi-session rows, a hardware controller for F06, USB and Wi-Fi connectivity, and a way to inspect each iPhone's displayed location. Enable Wi-Fi pairing over USB once before F03. Use a separate test account or machine for clean-install/update rows.
- **Developer ID release candidate:** run every functional row against the exact app mounted from the signed, notarized candidate DMG or its installation in the clean account. Record the DMG hash. Retest critical rows F02–F05, F08–F13, and F18 after the final public artifact is available.
- **Ad-hoc debug copy:** useful for isolated exploratory UI checks, but it cannot prove Developer ID signing, notarization, Gatekeeper, or Sparkle's production update path. An ad-hoc `build-for-testing` bundle can also fail to launch embedded Python if the host app and `TrailMate.debug.dylib` or Python extension modules have incompatible signatures. Before interpreting a failed discovery result, verify the copied app launches and its bundled device lister runs successfully; do not infer a device or permission defect from a `DYLD`/library-validation failure. Installing the copy in `/Applications` is not a substitute for correct signing.

## Functional matrix

Record `status · time · evidence` in the last column for each row. Use test-only names such as `Smoke-A` and `Smoke-B`; redact UDIDs, coordinates of private places, and account paths in shared evidence.

| ID / owner | Steps | Expected result | Status · time · evidence |
|---|---|---|---|
| F01 · WP10 | Cold launch with no device; choose an offline session. Build or import a route, play and stop it, move with the virtual stick, save a location and route, copy a coordinate and paste it into the coordinate field. | No-device state is clear; offline controls work; the red dot and saved items persist as designed; pasted coordinate parses. | `…` |
| F02 · WP10 | Attach device A by USB; refresh discovery and explicitly Connect. Accept the first administrator authorization if needed. | A appears within about 5 s as USB; one expected prompt starts the tunnel; the correct friendly name and Connected status appear. | `…` |
| F03 · WP10 | With Wi-Fi pairing enabled, disconnect USB, reboot A if needed, refresh discovery, and connect through Wi-Fi. | A appears as Wi-Fi and can simulate through the tunnel; stale/duplicate picker rows do not select a different device. | `…` |
| F04 · WP10 | Teleport to five disposable city coordinates; inspect the location on A after each. Disconnect and reconnect with a red dot already set. | Each location reaches A; the final offline red dot is mirrored on reconnect rather than reset. | `…` |
| F05 · WP10 | Use live place search, choose a result, then calculate a road route between two nonprivate test places and play it at 10×. | Search selection moves/frames the red dot; live MapKit routing produces a plausible road polyline; playback reaches the intended endpoint on the Mac and device. | `…` |
| F06 · WP10 | Connect a hardware controller and steer; repeat with the virtual stick and focused-map WASD/arrow keys. While a route plays, steer perpendicular, then press Rejoin. | Smooth movement reaches A; off-route distance appears beyond 5 m; Rejoin returns to the polyline. | `…` |
| F07 · WP10 | With the virtual stick active during playback and an off-route indicator visible, visually inspect zoom, compass, stick, and indicator at ordinary and narrow window sizes. | Map controls remain reachable; controls and off-route text do not cover each other. | `…` |
| F08 · WP10 | Create two locations and two routes ungrouped, plus two of each in **each of two populated categories**. Drag within every section while disconnected/idle, then during active simulation. Reselect, move an item out and back through Category, and relaunch. | No flicker/snap-back; drop commits within its section; a dragged location does not teleport and a dragged route does not load; order and category survive all transitions. Tapping a saved item still frames it; rename/delete still work. | `…` |
| F09 · WP10 | On the map choose Wander nearby → Sweeping at 500 m / 70 m. Check the square-side/lane caption and distance/time, Start, then scrub, loop, Record, Save Route, and Export GPX. Switch to Random and test a duration preset. | Sweeping starts at the west end of the southern lane and traverses the square lane by lane; all shared route controls work. Random keeps its road-routed, auto-play behavior. | `…` |
| F10 · WP10 | Connect A and B. Start recording both and create different movement on each. Switch selection repeatedly; stop A first, continue B, then stop B. Inspect both GPX files and replay/export/delete one test recording. | Two disjoint traces/files and accurate counters; selecting B hides A's active flag/count without stopping A; replay/export/delete and the library index work. | `…` |
| F11 · WP10 | Start a test recording, then quit without Stop. Relaunch, start another and remove that session without Stop. | Neither unfinished capture has a GPX file or index entry; only explicit Stop persists. | `…` |
| F12 · WP10 | While A records and B simulates, cause A's tunnel/daemon to fail. Keep A selected through recovery, then select B. Inspect A's eventual stopped recording. | TrailMate remains alive; A's local red dot/capture survive and its eventual file has one continuous trace, without duplicate points or a second capture; B remains connected and moving. | `…` |
| F13 · WP10 | With A and B connected, close A's daemon pipe or stop A's daemon; also exercise a tunnel-down case. Inspect TrailMate's log and the system's termination record. Query the test account's AI socket and menu-bar item afterward. | A shows a visible reason and only one teardown; there is no TrailMate SIGPIPE termination; B, local controls, AI socket, and menu bar remain usable. A can recover or be explicitly reconnected. | `…` |
| F14 · WP10 | With auto-reconnect on, drop A while tunneld remains authorized. Time from the observed loss to attempt 1, then force failures through exhaustion; inspect each attempt in the sidebar/status surface and logs. Repeat a drop that succeeds on attempt *n*, then a later drop. | First attempt begins about 5 s after loss; up to 10 non-overlapping single attempts start about 5 s after each prior failure; attempt 10 settles without a final delay/11th try. Success stops retries and resets the next window to 1/10. No automatic admin prompt appears. | `…` |
| F15 · WP10 | During a reconnect delay press Cancel retry; repeat while an attempt is in flight. Then explicitly Connect and Disconnect. Turn the Settings auto-reconnect toggle off and cause another drop. | Delay cancellation is immediate; in-flight cancellation shows disabled Cancelling… until that attempt settles, then schedules no next attempt. Cancel and explicit Disconnect disarm; the toggle off leaves manual Connect behavior. | `…` |
| F16 · WP10 | With A explicitly connected and auto-reconnect on, sleep and wake the Mac; repeat after disabling the toggle. Watch endpoint refresh, status, and authorization. | Wake starts the same fresh 1/10 recovery window after its post-failure delay, using the new endpoint without an unrequested admin prompt; with the toggle off, it stays in manual recovery. | `…` |
| F17 · WP10 | Close the main window during an active test session; use the menu-bar item to inspect A's friendly name/status/activity, Pause/Resume/Stop, Disconnect, and reopen. Exercise the Dock visibility preference and reopen route. | One main window returns; simulation and the test AI socket stay alive while closed; menu-bar summary follows the selected session and clears stale names on disconnect; app remains reachable with each preference. | `…` |
| F18 · WP10 | Toggle automatic update checks/downloads in Settings, relaunch, and use Check for Updates… from the app menu. | Preferences persist; command opens Sparkle's normal UI and reaches the configured stable feed. This is a UI/feed check, not an update-install pass. | `…` |
| F19 · WP10 | Explicitly Disconnect A while B remains connected. Quit the app with a live tunnel, including a test-owned tunnel that ignores graceful shutdown if this can be arranged safely. Inspect only processes attributable to this run, including root tunneld and daemon children, and port 49151. | No reconnect follows the intentional disconnect; B stays usable until quit; no test-run orphaned `tm_daemon`, `tm_tunneld`, or `pymobiledevice3` remains or holds port 49151. A wedged child is force-killed after the wrapper's short grace period rather than hanging quit. | `…` |
| F20 · WP10 | Repeat the critical offline, discovery, route, recording, failure, reconnect, and menu-bar rows on the clean account's installed signed release candidate. | Behavior matches the tested candidate; no dependency on a debug-only launch fixture or the developer's personal data. | `…` |

For F13 and F19, capture the app log plus a process snapshot before and after. Distinguish the test account's processes from any unrelated process; never kill the owner's personal session to create a test condition. For F14, use observed attempt timestamps; attempt runtime adds to the 5-second interval. F16 replaces the older expectation that wake leaves the session disconnected when automatic recovery is enabled.

## Packaging and production update

These rows require release credentials and the final candidate; an ad-hoc copy cannot pass them. Record workflow URL/run ID and artifact hashes.

| ID / owner | Steps | Expected result | Status · time · evidence |
|---|---|---|---|
| R01 · WP11 | After WP10 sign-off, verify `MARKETING_VERSION=2.3.0`, a new build number, and attributed release notes. Run `release.yml` with `dry_run=true`. | Workflow passes and retains private candidate artifacts without publishing stable. | `…` |
| R02 · WP11 | Inspect the exported app, staged copy, finished DMG, and **exact app mounted from that DMG**. Verify deep code signatures, Team ID, notarization/stapling, Gatekeeper assessment, and version/build. Inspect signed appcast and archive/tag/filename version pairing. | Every stage has valid Developer ID identity and integrity; notarized DMG opens on a clean account; appcast points to matching signed full DMG. | `…` |
| R03 · WP11 | Install the dry-run/manual artifact on a clean test account and execute F20; record any app or bundled-Python launch error. | Critical real-device and system UI checks pass from the installed signed artifact. | `…` |
| R04 · WP11 | With owner sign-off, publish stable from `main` (`dry_run=false`, `beta=false`). Inspect GitHub Release assets and the deployed Pages appcast. | Public tag, version/build, DMG, and appcast agree; the exact signed full DMG is downloadable. | `…` |
| R05 · WP11 | Start from stable v2.2.0 in a clean account. Use Check for Updates… through feed discovery, download, signature verification, install, and relaunch; separately install the manual GitHub DMG. | Sparkle relaunches into v2.3.0 with the new build and retained preferences; manual DMG works if Pages is unavailable. Record any rejected update as a failure, not a skipped check. | `…` |

## Sign-off

WP10 records any failed or blocked functional row and the affected artifact/commit before handing off to WP11. WP11 retains the matrix, redacted evidence, workflow run IDs, signed artifact hashes, and production update result in the release-readiness report. Rerun affected automated and manual rows after any post-gate code or packaging change. The release is ready only when the integrated automated gate, every applicable functional row, and R01–R05 are complete.
