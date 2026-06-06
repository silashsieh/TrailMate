---
type: epic
id: 018
title: Wander Nearby preset options & persistence
status: open
milestone: v1.4.0
issue: 24
opened: 2026-06-07
shipped:
tags: [routing, ui]
---

# Epic 018: Wander Nearby preset options & persistence

## Why
Issue #24 (附近晃晃的預設選項), filed by the owner right after v1.3.0: the Wander Nearby
defaults are too small to be useful — barely walkable even in a city — and re-configuring
the sheet every time is tedious. Today `WanderSheet` offers radius presets 50/100/200 m
(default 100 m) and duration presets 15/30/60 min (default 15 min), all `@State`, so every
sheet open resets to the defaults. New work against shipped [[002-wander-nearby]].

## Goal
The Wander sheet opens with bigger, walk-realistic presets — distance 250/500/750 m + custom,
duration 30/60/120 min + custom — and remembers the last selection (including custom values)
across app relaunches.

## Out of scope
- Changing the wander route-building algorithm itself ([[002-wander-nearby]] core).
- Per-location or per-device preset profiles.

## Stories
- [ ] Replace preset values: distance 250/500/750 m + custom; duration 30/60/120 min + custom
- [ ] Persist last selection (preset or custom, with custom values) in UserDefaults
- [ ] Restore the persisted selection when the sheet opens; fall back to sensible defaults

## Open questions
- The issue says 直徑 (diameter) but the sheet field is labelled Radius — are 250/500/750
  radius or diameter values? Decide before changing labels/values.
- Which preset is the new default on first run (no saved selection)?

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria
- [ ] Sheet shows 250 m / 500 m / 750 m / custom and 30 min / 60 min / 120 min / custom
- [ ] Pick a preset or custom value → quit → relaunch → sheet reopens with that selection
- [ ] Wander route generation behaves identically apart from the new values

## Related
- [[002-wander-nearby]] — the shipped feature this improves (never reopened)
- [[005-restore-sim-location]] — same persist-across-launch pattern (UserDefaults)
