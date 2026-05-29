---
type: epic
id: 009
title: Route loop playback
status: open
milestone: v1.5.0
issue: 10
opened: 2026-05-29
shipped:
tags: [playback]
---

# Epic 009: Route loop playback

## Why
Issue #10: route playback (`NavigationEngine`) stops after one pass — no looping.

## Goal
Auto-loop on completion, with two selectable modes:
1. **Restart** — A→B finishes, replay A→B.
2. **Ping-pong** — A→B finishes, walk back B→A, repeat.

Optionally a loop count (including infinite).

## Stories
- [ ] Loop-mode setting (restart / ping-pong) in the playback controls
- [ ] `NavigationEngine` re-arms on completion per the selected mode
- [ ] Optional loop count (incl. infinite); stop ends cleanly

## Open questions
- For ping-pong, reverse the existing polyline in place vs re-derive — reversing in place is
  cheaper and keeps timing symmetric.

## Acceptance criteria
- [ ] Restart mode replays from A indefinitely (or N times) until Stop
- [ ] Ping-pong reverses smoothly at each end with no jump
- [ ] Loop count honored; Stop always clears
