---
type: epic
id: 017
title: Standalone Settings window
status: in-progress
milestone: v1.5.0
issue: 20
opened: 2026-06-01
shipped:
tags: [ui, settings]
---

# Epic 017: Standalone Settings window

## Why
Issue #20: every setting currently lives in the sidebar, but some are set-and-forget (e.g. GPS
delta) — once configured they're never touched again, yet they occupy sidebar space. Like any
standard app, set-once configuration belongs in a separate Settings window so the sidebar can
focus on route-related work.

## Goal
A standalone Settings window (standard macOS `Settings` scene, opens with ⌘,) holding the
set-and-forget options. The sidebar keeps only the live, session-relevant controls.

## Out of scope
- Adding *new* settings — this epic only relocates and organizes what exists.
- Per-device profiles or settings sync.

## Stories
- [x] Inventory current sidebar settings; classify set-and-forget vs live session controls
- [x] Add a SwiftUI `Settings` scene (⌘, / app menu → Settings…)
- [x] Move set-and-forget options (GPS delta, …) into it; group sensibly
- [x] Slim the sidebar to live controls only

## Open questions
*(resolved — see the split decision below)*

## Decisions made along the way
- **Inventory result (2026-06-07):** exactly four persisted settings have sidebar UI; everything
  else in the sidebar is session-only state (device picker, planner fields, playback
  multiplier/loop — session-scoped by design) or data (waypoints/routes/recordings).
  | Setting | Sidebar home | UserDefaults key | Classification |
  |---|---|---|---|
  | GPS noise σ slider | Connection | `noiseSigmaMeters` | set-and-forget |
  | Restore last location on launch | Connection (parked by [[005-restore-sim-location]]) | `SimulatedPosition.restoreOnLaunch` | set-and-forget |
  | Transport mode picker | Route | `transportMode` | live session control |
  | Custom speed km/h | Route | `customSpeedKmh` | live session control |
- **The split (2026-06-07, user decision):** move GPS noise σ and the launch-restore toggle
  only. Transport mode + custom km/h stay in the Route section — they are picked per-route,
  drive the MKDirections transport type, and cap the joystick speed, so they're live session
  controls despite being persisted. ("Calibrated speeds" stay put.)
- **Map camera, simulated position lat/lon, and wander presets are not settings** — they're
  auto-persisted state with no explicit control (camera, red dot) or sheet-local recall
  (wander); none relocate.
- **Single pane, no tabs (2026-06-07):** two settings don't justify a tab bar. A grouped
  `Form` at fixed size, sections "Realism" (σ) and "Launch" (restore toggle). The σ slider
  gains a one-line caption since it lost its Connection-section context — explanatory text,
  not a new setting. `SettingsView` binds to the same `AppState` properties the sidebar
  controls did (the Settings scene shares the app's single `AppState` instance), so the
  persistence keys and live-propagation paths are untouched.

## Acceptance criteria
- [ ] ⌘, opens a Settings window with the relocated options
- [ ] Relocated settings persist and behave identically to before
- [ ] Sidebar contains only route/session controls
