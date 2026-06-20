---
type: epic
id: 026
title: Show the connected device name in the status bar
status: done
milestone: v2.1.0
issue: 40
opened: 2026-06-19
shipped: 2026-06-20
tags: [ui, connection]
---

# Epic 026: Show the connected device name in the status bar

> Enhancement (reported in #40). Companion to [[003-friendly-device-name]] (name in the picker)
> and [[021-menu-bar-background]] (menu bar status summary).

## Why

Today the status surface shows only state — "Playing", "Disconnected", etc. — not *which*
device. With multi-device ([[012-multi-device]]) the connected device's name is the piece of
context the user actually wants at a glance. Confirmed not currently shown (the `MenuBarExtra`
summary carries playback/connection state, no device name).

## Goal

Once connected, the connected device's friendly name is visible in the status surface — the
sidebar status pill and the `MenuBarExtra` summary.

## Out of scope

- Per-device controls beyond showing the name (those live in the multi-device switcher).

## Stories

- [x] Show the connected device's friendly name in the sidebar status surface.
- [x] Show it in the `MenuBarExtra` summary alongside the connection/playback state.
- [x] Multi-device: the name reflects the active/selected session.

## Open questions

- ~~Truncation/length budget for long device names in the narrow menu bar item.~~
  Resolved: cap at 24 chars with an ellipsis in `MenuBarStatusView.truncated(_:max:)`.

## Decisions made along the way

- **Single source of truth:** added one accessor `AppState.connectedDeviceName: String?`
  in the per-device forwards section, returning the selected session's `deviceName`
  only while it is `.connected` (nil otherwise). All status surfaces read this, so a
  disconnect can't leave a stale name and multi-device naturally tracks the active session.
- **Sidebar was already mostly there.** `DeviceSwitcherRow` already renders
  `session.deviceName` per row, so the real gap was (a) the menu bar (state only, no name)
  and (b) no emphasis on which row is active. The sidebar change is therefore weight-only:
  the active session's name is `.semibold`. No new pill was added, and the map's hint pill
  (route/connection hint, not device identity) is deliberately left alone — out of this
  epic's boundary.
- Menu bar format leads with the (truncated) name when connected:
  `"<name> · <connection> · <activity>"`, falling back to the prior
  `"<connection> · <activity>"` when there is no connected name.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] After connecting, the device name appears in both the sidebar switcher and the menu bar summary.
- [x] Disconnected state reads clearly with no stale name (`connectedDeviceName` returns nil).
- [x] With two devices, the displayed name tracks the active session (it forwards `selectedSession`).
