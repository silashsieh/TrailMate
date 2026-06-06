---
type: epic
id: 018
title: Wander Nearby preset options & persistence
status: in-progress
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
- [x] Replace preset values: distance 250/500/750 m + custom; duration 30/60/120 min + custom
- [x] Persist last selection (preset or custom, with custom values) in UserDefaults
- [x] Restore the persisted selection when the sheet opens; fall back to sensible defaults

## Open questions
*(both settled 2026-06-07 — see Decisions)*

## Decisions made along the way
- **250/500/750 are radius values.** The 直徑 in issue #24 was the owner's typo for 半徑;
  the issue body was corrected on 2026-06-07. The "Radius" label stays as-is.
- **First-run default is 500 m / 60 min** — the middle preset on both axes (owner decision).
- **Persist on every selection change, not on Start.** The AC's sequence is pick → quit →
  relaunch with no Start step, and the [[005-restore-sim-location]] pattern records
  continuously. Custom text is persisted only once it parses to a positive number, so a
  half-typed value never clobbers the last good one.
- **Custom-field fallbacks (never used custom before): 1000 m / 180 min** — continue past the
  largest preset, since custom is most useful beyond the preset range.
- State lives in a new `WanderPresetPersistence` enum (UserDefaults statics, mirroring
  `SimulatedPositionPersistence`); `WanderSheet.init` is the restore point since the sheet
  is created per presentation.
- **Custom rows get a slider alongside the text field** (owner request during review).
  Radius 50–2000 m, duration 5–240 min, on a **log₁₀ scale** (second owner request) — more
  knob travel for small values — snapping dragged values to two significant figures, the
  log-scale analogue of a fixed step. The text field stays the source of truth (it feeds
  persistence and resolution) and still accepts values outside the slider range; the slider
  is a binding view over the text.

## Bugs / follow-ups found while building

## Acceptance criteria
- [x] Sheet shows 250 m / 500 m / 750 m / custom and 30 min / 60 min / 120 min / custom
- [ ] Pick a preset or custom value → quit → relaunch → sheet reopens with that selection
      *(needs on-device verification by the owner)*
- [ ] Wander route generation behaves identically apart from the new values
      *(needs on-device verification by the owner)*

## Related
- [[002-wander-nearby]] — the shipped feature this improves (never reopened)
- [[005-restore-sim-location]] — same persist-across-launch pattern (UserDefaults)
