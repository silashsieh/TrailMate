---
type: epic
id: 012
title: Simultaneous multi-device connection
status: deferred
milestone:
issue: 9
opened: 2026-05-29
shipped:
tags: [architecture, scope-conflict]
---

# Epic 012: Simultaneous multi-device connection

## ⚠️ Scope conflict — needs an owner decision before any work
This directly contradicts a current [[scope]] **non-goal**: *"No multi-device orchestration —
one iPhone at a time."* It is parked as `deferred` (no milestone) rather than scheduled.

**Decision required:** either
- **Close as `wontfix`** — keep the single-device non-goal, or
- **Deliberately revise [[scope]]** — accept multi-device as a goal, then schedule this epic.

Do not start implementation until that decision is recorded here.

## Why
Issue #9: today the architecture is single-device — one `selectedDeviceUDID`, one tunnel, one
simulation. The request is to connect several iPhones at once and run GPS simulation on all of
them (each its own route, or all the same), with per-device control/switching.

## Goal (if accepted)
Multi-device connection: the connection layer (tunnel, daemon, connection state) moves from
single- to multi-device, with UI to control/switch each device.

## Notes
The issue itself flags this as a **large architectural change** to the connection layer. It is
the kind of broad scope expansion that [[scope]] currently rules out by design.

## Open questions
- Is single-device still the intended product boundary? (The deciding question.)
