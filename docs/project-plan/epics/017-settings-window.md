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
- [ ] Inventory current sidebar settings; classify set-and-forget vs live session controls
- [ ] Add a SwiftUI `Settings` scene (⌘, / app menu → Settings…)
- [ ] Move set-and-forget options (GPS delta, …) into it; group sensibly
- [ ] Slim the sidebar to live controls only

## Open questions
- Exact split: which settings count as set-and-forget? (Decide during the inventory story —
  candidates per the issue: GPS noise/delta; likely also calibrated speeds.)

## Acceptance criteria
- [ ] ⌘, opens a Settings window with the relocated options
- [ ] Relocated settings persist and behave identically to before
- [ ] Sidebar contains only route/session controls
