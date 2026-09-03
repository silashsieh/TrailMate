---
type: epic
id: 033
title: Refresh test & UI coverage for everything shipped since v2.0.0
status: open
milestone: v2.3.0
issue:
opened: 2026-06-21
shipped:
tags: [testing, quality]
---

# Epic 033: Refresh test & UI coverage for everything shipped since v2.0.0

> The first pass re-baselined the v2.1.0 UI and added focused tests for 024–031. A second audit on
> 2026-09-03 compared every shipped v2.0.0–v2.2.0 contract (plus the v2.1.3 updater repair) against
> the actual 133 unit tests and 11 UI tests on `main`. The suites cover the pure math well, but
> several app-level ownership, persistence, IPC, and lifecycle paths still have no regression test.

## Why

Every feature added since v2.0.0 should have a current automated test at the lowest deterministic
seam, and no suite should assert stale behaviour. Three things drifted:

- **New features without coverage** — 024 (joystick/map-control overlap), 025 (default-collapsed
  log), 026 (device name in the status pill / menu bar), 027 (search-to-go, coordinate entry, copy
  coordinate), 028 (offline control + device-mirrors-the-red-dot-on-connect), 029 (drag-reorder,
  categories, auto-pan).
- **Existing assertions that are now wrong.** `TrailMateUITests` predates the v2.1.0 UI: it checks
  the sidebar Log section + "View Full Log" button, which 025 now collapses by default; and its
  `--uitest-mock-connection` test asserts *connection-gated* UI that 028 made available offline
  (the `.requiresConnection()` gating was removed). These need re-baselining.
- **Green helper tests overstate app coverage.** Examples: `LibraryOrderTests` proves array-offset
  math but neither saved-items persistence path; `CommandProtocolTests` proves parsing while most
  `AppState.dispatch` verbs and the Unix socket server are untested; and the 10 Hz timing constants
  are asserted without directly proving idle suppression or display-push cadence.

## Goal

Each deterministic behavior shipped from v2.0.0 through v2.2.0 is covered at the layer where a
regression would occur: pure unit test for algorithms, app-hosted unit test for ownership and
persistence, XCUITest for user wiring, and an explicit release smoke item only where hardware,
system UI, network services, or signing make automation unsuitable. The v2.3.0 correctness epics
must also land the tests specified in their own acceptance criteria before this epic closes.

## Out of scope

- New product features — this is test/coverage work only.
- Retrofitting every pre-v2.0.0 feature solely to raise a coverage percentage. Older code is included
  only when a post-v2.0.0 behavior depends on it or the implementation is already being changed.
- Live `MKLocalSearch` / `MKDirections`, macOS menu-bar querying, visual occlusion, a real iPhone,
  sleep/wake, authorization UI, Developer ID signing/notarization, and a production Sparkle update.
  These remain explicit smoke/release checks; deterministic logic beneath them is still unit-tested.
- 032's real root/shell/SIGKILL escalation. It remains the manual "quit → no orphaned tunneld"
  check, although ordinary pipe/exit state transitions belong in automated tests for 042/043.

## Stories

- [x] **Initial v2.1.0 audit pass:** ran the full unit + UI suites against `main`. Result: the suite is green;
      the only *failing* assertion was the 025 log case (fixed in #66). The 028 mock-connection
      test was *stale but passing* (asserted the old gating model). No other stale assertions were
      found in that narrow UI re-baseline.
- [x] **Re-baseline the UI smoke suite** for v2.1.0: collapsed-log default (smoke, forced open via
      `--uitest-expand-log`) **+ persisted expand/collapse round-trip** (`testLogExpansionPersists…`,
      driving the real disclosure) for 025; connected device name + status in the sidebar status pill
      for 026 (`testMockConnectionShowsConnectedDeviceNameAndStatus`); the post-028 offline model
      reframed from "gating" to offline-available (`testCoreControlsRenderWithoutConnection`) with the
      device-mirrors-the-red-dot half as a unit test (`SimulationActorAttachTests`). *Menu-bar* device
      name → manual checklist (MenuBarExtra isn't XCUITest-queryable).
- [~] **Initial UI additions** — 027 coordinate field + copy + Go-enablement done
      (`testCoordinateEntryEnablesGoAndRevealsCopy`); 027 *place search → Go* → manual (live MapKit
      local search is nondeterministic). 029 reorder/category/auto-pan covered by the
      `SavedItemsLibraryTests` unit suite only at the pure-math layer; the persistence and real drag
      gap is now owned by [[039-fix-saved-items-reorder]].
- [x] **Confirm the unit suites added in the initial cycle** still pass — full run green, incl.
      `CoordinateFormatTests`, `SavedItemsLibraryTests` (`LibraryOrderTests`/`MapRegionMathTests`),
      and `TunnelBrokerReclaimTests`. The second audit below narrows what those helper suites prove.
- [~] Update [[testing]] (implemented vs TODO) and the manual smoke checklist to match. The initial
      v2.1.0 inventory is present; it now links to the second-audit matrix and must be updated again
      as each missing suite lands.
- [x] **Second static audit (2026-09-03):** traced v2.0.0–v2.2.0 and v2.1.3 acceptance criteria
      through production entry points and each test body. Found the gaps below; a green run alone
      cannot expose them because no current test executes those paths.

## Coverage gaps found on 2026-09-03

| Area | What is covered today | Missing regression coverage | Required home |
|---|---|---|---|
| **Multi-session ownership (012, 026)** | `CommandDispatchTests` proves a TELEPORT for A does not move B and STATUS lists both. The UI connects one mock device. | Add/remove invariants (the collection never empties), selected-session fallback, joystick re-homing, tuning fan-out/seeding for a new session, independent route/playback state, and `connectedDeviceName` clearing/tracking selection. Add a two-mock-device XCUITest that switches rows and proves the shared controls/status follow the selected session. | New `AppStateSessionTests` plus a deterministic two-device UI launch hook. |
| **AI socket and dispatch (019)** | Command parsing/JSON encoding is thorough; dispatch tests only TELEPORT, STATUS enumeration, and unknown/not-connected errors. | Positive and failure cases for DEVICES, ROUTE, PLAY, PAUSE, STOP, SEEK clamping, CLEAR, CONNECT, and DISCONNECT; CONNECT idempotency and must-not-steal-GUI-selection; per-device status fields. The actual `CommandServer` has no test for create/unlink, `0700` directory, greeting, fragmented/multiple lines, oversized input, client disconnect, toggle off, stale socket, or stop/start epoch behavior. Also prove AI movement records the clean point while the backend receives the noisy one—the shipped acceptance claim is currently manual only. | Expand `CommandDispatchTests`; add a temporary-path socket harness and fake dispatcher/backend. |
| **Connection/discovery lifecycle (012, 031, 032)** | `TunnelBrokerReclaimTests` covers only the extracted stale-reclaim loop; one XCUITest reaches connected through a mock backend. | `DeviceDiscoveryService` JSON parsing (USB/Wi-Fi/malformed rows), `TunnelBroker` UDID-map selection/error cases, `DaemonBridge` READY/command/timeout/EOF/exit behavior, and `DeviceSession` state transitions for explicit disconnect, unexpected daemon exit, tunnel-down, sleep, and one-session-fails/other-survives. | Pure parser extraction where possible; finish the fake-pipe/session harness with [[042-survive-closed-daemon-pipe]] and retry-state coverage with [[043-auto-reconnect]]. Real authorization/tunnel teardown stays manual. |
| **Offline control workflow (027, 028)** | The UI proves the sections render offline and typed coordinates enable Go; actor tests prove attach mirrors the current red dot. | Existence is not operation: no test proves an offline session can build/load/play/stop a route, drive the joystick, save a location/route, retain its dot through disconnect, then mirror the final dot on reconnect. Coordinate Copy is only checked for button appearance, not pasteboard content. Search-result selection remains manual, but success/failure state transitions can use an injected search/router seam. | Replace the stale `RouteVMTests` idea with `DeviceSessionRouteTests` using an injected `RoutingService`; add focused offline XCUITests with canned data. |
| **Saved-item persistence and row wiring (029)** | `SavedItemsLibraryTests` covers `LibraryOrder` transforms and `MapRegionMath`. | Neither the waypoint `UserDefaults` JSON nor route files/`order.json` round-trip in a test; save/load/delete/rename/category compatibility are uncovered. No UI test crosses drag/context-menu/tap wiring, and the shipped drag is now known broken. | [[039-fix-saved-items-reorder]] owns isolated persistence tests for both stores and a reliable drag XCUITest or mandatory manual matrix. Include legacy route JSON without category/planner fields. |
| **Recording (multi-device risk inherited from 012)** | `GPXServiceTests` covers XML generation/parsing; actor tests merely construct the shared recorder. | No test executes start/append/stop/delete/index reload, timestamp ownership, concurrent recording, selected-session visibility, or quit discard. | [[040-per-session-recording]] replaces the obsolete `RecorderServiceTests` TODO with `RecordingCaptureTests` and temporary-directory `RecordingsLibraryTests`, including its two-session/UI contracts. |
| **Simulation loop and performance (034, 035)** | Dead-zone and deviation math are tested; timing constants and “device emits while UI is throttled” are tested. | Directly assert disconnected-idle produces no emit/snapshot churn, connected idle re-emits at the intended cadence, active joystick display pushes cap at 10 Hz, playback pushes cap at 2 Hz, Rejoin resets deviation, and >200 m for >10 s emits one route-abort and stops playback. Timing tests need an injected clock/tick driver rather than long sleeps. | Expand actor-level tests around a recording backend, bridge spy, and controllable clock/tick source. |
| **Background and updater UI (021, 038, 047)** | XCUITest sees the two update toggles; `UpdaterConfigurationTests` pins the paired Sparkle security keys. Production release checks covered the signed update. | No test proves update preference round-trips, the “Check for Updates…” command exists/enables correctly, menu/Dock preferences cannot make the app unreachable, closing/reopening uses one main window, or menu-bar summary/actions follow the selected session. | XCUITest update/menu/Dock preference round-trips; extract the menu summary/activation decision into pure presenters for unit tests. `MenuBarExtra` interaction and the signed update remain release-smoke items. |

### Test-isolation defect found during the audit

`AppState(defaults:)` accepts an isolated defaults suite, but still constructs `RecorderService` and
`SavedRoutesStore` with fixed production Application Support paths. Existing `CommandDispatchTests`
and `SweepAreaHandoffTests` therefore read the user's real recording/route indexes during setup.
Separately, several XCUITests claim to restore preferences but reset language, Wander, and Log to
factory values rather than the exact prior values. Before adding more app-hosted/UI coverage:

- inject all filesystem roots (`RecordingsLibrary`, `SavedRoutesStore`, socket) and use one temporary
  test root per test;
- use isolated defaults where the app-hosted seam permits it;
- make XCUITests snapshot and restore the exact values they mutate, or add a DEBUG-only isolated
  preferences domain so parallel/suite-order execution cannot alter personal settings.

## Release-level implementation plan

The architecture, worktree ownership, dependency graph, merge waves, and release gates for all
five v2.3.0 epics live in [[v2.3.0-design]]. This epic owns the audited coverage backlog and
cross-cutting quality gate; it does not own the implementation plans for 039, 040, 042, or 043.

## Remaining (keeps this epic open)

The table above is the automated closure backlog. Keep these checks manual because the missing
dependency is the environment rather than a unit seam:

- live MapKit place search and road routing;
- real USB/Wi-Fi discovery, admin authorization, device simulation, sleep/wake, and root/SIGKILL
  teardown;
- MenuBarExtra interaction and 024's visual map-control occlusion;
- signed/notarized DMG integrity and the production Sparkle download/install/relaunch path;
- the 039 drag matrix only if XCUITest remains unreliable after the data-source fix.

Everything else in the gap table is deterministic and must not be waived to the manual checklist.

## Open questions

- ~~How much of 028's offline model is UI-testable headlessly vs. needs the mock backend extended?~~
  **Resolved.** The *offline-available* half is fully UI-testable (controls render at a plain launch).
  The *mirror-on-connect* half is **not** observable through the UI mock (it swallows locations), so it
  lives in `SimulationActorAttachTests`, which attaches a recording backend at the actor seam — no need
  to extend the shared mock.
- ~~024 is a layout/occlusion fix — assert via accessibility frames, or leave to the manual checklist?~~
  **Resolved: manual checklist.** Occlusion is a visual/geometric property; an accessibility-frame
  assertion would be brittle and wouldn't actually prove "not visually occluded."
- ~~Do the old three deferred suite names remain outside this epic?~~ **Resolved: no.** `RouteVM`
  does not exist—the behavior lives in `DeviceSession`; recording is being replaced by epic 040;
  and daemon pipes are directly changed by epics 042/043. Use current ownership and build those
  tests where the v2.3 implementation creates the required seams.
- Can the saved-items drag be reliable under XCUITest after 039 fixes the data source? Try one focused
  test. If accessibility still cannot drive it reliably, document the observed limitation and keep
  the full drag matrix as a release gate rather than adding a flaky CI test.

## Decisions made along the way

- **025 stale assertion fixed first (the acute symptom).** `testSidebarShowsLogSection`
  failed because epic 025 collapses the log by default, so "View Full Log" no longer
  renders at launch. Re-baselined by forcing the disclosure open via a new
  `--uitest-expand-log` hook (mirrors `--uitest-open-wander`) rather than driving a
  disclosure click — deterministic and leaves the persisted `sidebarLogExpanded`
  preference untouched. The fuller *collapsed-by-default + persisted round-trip* coverage
  subsequently landed in `testLogExpansionPersistsAcrossRelaunch`.
- **025 persistence now driven through the real disclosure.** The round-trip test toggles
  `window.disclosureTriangles.firstMatch` — the sidebar's only disclosure triangle. Clicking the
  "Log" *static text* does **not** toggle a `DisclosureGroup` in an XCUITest List (verified: the
  expand never took); the triangle is the hit target.
- **028 mirror-on-connect is a unit test, not UI.** `MockSimulationBackend.setLocationQuiet` is a
  no-op, so the connected mock can't witness the snap. Rather than complicate the shared mock,
  `SimulationActorAttachTests` uses a local recording backend (serial-queue-guarded like
  `DaemonBridge`) and asserts `attach()` pushes the current red dot, with noise σ pinned to 0 for
  exactness.
- **Drew the automate/manual line at XCUITest's fragile surfaces.** Live place search → Go
  (nondeterministic MapKit results), MenuBarExtra interaction (not reliably queryable), and 024
  occlusion (visual) stay on the manual checklist. Saved-items drag/context-menu wiring gets one
  focused retry after 039 fixes the data source; deterministic state and persistence beneath every
  one of these surfaces remain automated work.
- **Coverage is contract-based, not percentage-based (2026-09-03).** A touched-line percentage would
  reward broad view rendering while missing the dangerous boundaries: UDID routing, selected-session
  ownership, filesystem persistence, socket/pipe failure, and quit behavior. Epic closure is based on
  the explicit matrix above.
- **Feature epics own tests for behavior they change (2026-09-03).** Epics 039, 040, 042, and 043
  keep their detailed test cases. Epic 033 tracks them as release dependencies instead of creating
  duplicate implementations; their checkboxes count only after the tests actually land and pass.
- **No automated test may touch personal state (2026-09-03).** Reading production Application
  Support is already enough to make results machine-dependent; writing it is worse. Filesystem,
  defaults, clock, router, discovery, backend, and socket dependencies must be injectable at the
  narrowest owner needed by the test.

## Bugs / follow-ups found while building

- The second audit found that `AppState` tests using isolated `UserDefaults` still read production
  recording/route directories because those two services have fixed roots. Treat the injectable
  roots in 039/040 as a prerequisite before expanding app-hosted tests.
- Epic 039 documents a real saved-items reorder failure even though the pure `LibraryOrderTests`
  suite is green. This is the concrete proof that helper-only coverage cannot close a UI contract.

## Acceptance criteria

- [ ] Every deterministic gap in the 2026-09-03 matrix has a passing test, including all advertised
      AI dispatch verbs/socket lifecycle and the core multi-session collection/selection invariants.
- [ ] App-hosted tests use isolated defaults and temporary filesystem/socket roots; UI tests leave
      every mutated preference exactly as they found it. No test reads or writes the user's TrailMate
      Application Support data.
- [ ] Offline route/playback/save behavior is tested as behavior—not merely as visible controls—and
      the simulation-loop idle, cadence, deviation, and abort contracts have actor-level coverage.
- [ ] Epics 039, 040, 042, and 043 land and pass their specified persistence, recording, pipe-failure,
      and retry-policy tests, including multi-device isolation.
- [ ] XCUITest covers two-device selection/control binding and updater/menu-Dock preference behavior;
      every environment-bound remainder appears in the written release smoke checklist with an owner
      and expected result.
- [ ] `xcodebuild test` (unit + UI) passes on a clean checkout with no live session, and [[testing]]
      accurately lists the implemented suites and remaining manual gates.
