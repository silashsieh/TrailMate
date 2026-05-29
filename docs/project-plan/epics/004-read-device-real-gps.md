---
type: epic
id: 004
title: Read device real GPS (blue dot)
status: open
milestone: v1.3.0
issue: 17
opened: 2026-05-29
shipped:
tags: [positioning]
---

# Epic 004: Read device real GPS (blue dot)

## Why
Issue #17: TrailMate is currently **write-only** to the device — it pushes simulated coordinates
but never reads the iPhone's real GPS back. So the app only ever knows the *simulated* position
(red dot), never where the phone actually is. Unlike Google Maps' single blue dot, TrailMate
conceptually has two positions (real vs simulated) but today only controls the latter.

This is the **foundational capability** that unblocks the "current real location" features in
[[005-restore-sim-location]] and [[006-follow-current-position]].

## Goal
Add a "read the device's current real GPS" capability and render it on the map as a **blue dot**
(à la Google Maps).

## Out of scope
- Continuous high-rate tracking of real GPS (a periodic/poll read is enough to start).
- Anything that changes the [[scope]] non-goals (still single device, still write-side spoofing).

## Open questions
- **Feasibility first (gate for this whole epic):** does `pymobiledevice3` support reading the
  device's live location? This needs a new daemon read-location command. Confirm against the
  pinned version via the CLI before committing to the work — per CLAUDE.md "never invent a
  pmd3 API." If it isn't supported, this epic may shrink to "investigated, not feasible."
- Read cadence: one-shot on demand vs low-rate poll. Mind the 100 ms latency floor only applies
  to the live write path, not real-GPS reads.

## Stories
- [ ] Spike: confirm pmd3 can read device location (CLI proof against pinned version)
- [ ] Daemon: add a read-location command (update DaemonBridge + tm_daemon.py + architecture.md)
- [ ] Map: render the real position as a blue dot, distinct from the simulated red dot
- [ ] Surface read failures in the Log sheet (no silent swallow)

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria
- [ ] With a connected device, the map shows a blue dot at the phone's real location
- [ ] Red (simulated) and blue (real) dots are visually distinct and can coexist
- [ ] Daemon protocol change documented in [[architecture]] in the same change
