---
type: epic
id: 026
title: Show the connected device name in the status bar
status: open
milestone: v2.1.0
issue: 40
opened: 2026-06-19
shipped:
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

- [ ] Show the connected device's friendly name in the sidebar status pill.
- [ ] Show it in the `MenuBarExtra` summary alongside the connection/playback state.
- [ ] Multi-device: the name reflects the active/selected session.

## Open questions

- Truncation/length budget for long device names in the narrow menu bar item.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] After connecting, the device name appears in both the status pill and the menu bar summary.
- [ ] Disconnected state reads clearly with no stale name.
- [ ] With two devices, the displayed name tracks the active session.
