# Risks & Mitigations

Ongoing risks for the current product. Update when a mitigation changes or a new risk surfaces.

|Risk                                                  |Likelihood|Impact                                   |Mitigation                                                                                                                                  |
|------------------------------------------------------|----------|-----------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
|iOS major-version DDI / RSD upload instability        |Medium    |Connect fails until the DDI is re-mounted|We do not auto-mount; surface a "please mount via Xcode first" UX. Toggling Developer Mode off and on often clears stuck state.             |
|pymobiledevice3 API breaking change in a minor version|Medium    |Daemon stops working                     |Pin to a known-good version (see [tech-stack.md](../technical/tech-stack.md)). Bump deliberately and run a smoke pass.                      |
|Apple changes the RSD protocol in a future iOS        |Medium    |Breaks everything                        |Inevitable. Monitor pymobiledevice3 releases. We're not unique — every spoofer breaks here.                                                 |
|`osascript` admin prompt UX is jarring                |Medium    |Annoying                                 |Accepted: one prompt per session. A packaged SMAppService helper would remove it but needs paid signing (see deferred items in features.md).|
|Tunnel drops mid-session                              |Medium    |Bad UX                                   |Tunnel-down / daemon-exit callbacks tear live state down automatically; UI surfaces the drop within ~1 s; user re-Connects.                 |
|Wi-Fi tunnel drops more often than USB                |Medium    |Session ends → iPhone reverts to real GPS|Same tunnel-down path as USB; UI reflects within ~1 s. Auto-reconnect is not implemented; user re-Connects manually.                        |
|`isSimulatedBySoftware == true` visible to apps       |Certain   |Some apps detect the spoof               |Documented limitation. Not a goal to defeat.                                                                                                |
|Game-controller incompatibility                       |Low       |Joystick unusable for some controllers   |On-screen virtual stick and WASD / arrow-key input are always available as fallback.                                                        |
|Bundled Python runtime breaks on a macOS upgrade      |Low       |App won't launch after OS update         |python-build-standalone is well-maintained; smoke-test on each macOS major before tagging a release.                                        |
|pymobiledevice3 license obligations (e.g. LGPL/GPL)   |Low       |Legal                                    |Verify the bundled pymobiledevice3 license is compatible with TrailMate's MIT before publishing a release. Re-verify on dep bumps.          |
