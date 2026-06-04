---
type: epic
id: 012
title: Simultaneous multi-device connection
status: open
milestone:
issue: 9
opened: 2026-05-29
shipped:
tags: [architecture]
---

# Epic 012: Simultaneous multi-device connection

> **Scope decision made (2026-06-01):** [[scope]] was revised — Goals now read "Single Mac,
> single user, **multi iPhone**" and the "no multi-device orchestration" non-goal was removed.
> This epic is **accepted and unblocked**, but unscheduled (no milestone) — it's a large
> architectural change and needs deliberate planning before it joins a release.

## Why
Issue #9: today the architecture is single-device — one `selectedDeviceUDID`, one tunnel, one
simulation. The request is to connect several iPhones at once and run GPS simulation on all of
them (each its own route, or all the same), with per-device control/switching.

## Goal
Multi-device connection: the connection layer (tunnel, daemon, connection state) moves from
single- to multi-device, with UI to control/switch each device.

## Open questions
- One daemon process managing N devices vs one daemon per device?
- UI model: device tabs, split view, or a device switcher with one active control surface?
- How do route playback / joystick / recording interact when several simulations run at once?
- Does the privileged tunnel path (sudo prompt) multiply per device?

## Notes
The issue flags this as a **large architectural change** to the connection layer. When this is
picked up, re-read [[architecture]] (daemon protocol, concurrency topology) first and expect
protocol changes — per CLAUDE.md, update `DaemonBridge`, `tm_daemon.py`, and the docs in the
same change.
