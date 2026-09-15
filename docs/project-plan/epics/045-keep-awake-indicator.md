---
type: epic
id: 045
title: Show a "keeping Mac awake" indicator while connected
status: open
milestone:
issue: 73
opened: 2026-08-18
shipped:
tags: [ui, power, connection]
---

# Epic 045: Show a "keeping Mac awake" indicator while connected

> Pure visibility work: the behavior already exists and is verified — only the UI is missing.
> The *coverage* of the wake assertion (offline simulation) and an opt-out switch are a separate
> request, #74, deliberately not folded in here.

## Why

TrailMate already keeps the Mac awake while a device is connected: `SimulationActor.attach()`
takes `beginActivity(.userInitiated)` with `idleSystemSleepDisabled`
(`SimulationActor.swift:151`) and `detach()` releases it (`:165`). It is observable from
outside — with a device connected, `pmset -g assertions` lists
`pid …(TrailMate): PreventUserIdleSystemSleep named: "TrailMate simulation loop"`.

But nothing in the UI says so, so a user who doesn't know runs `caffeinate` by hand as
insurance — redundant for idle sleep for the whole time they are connected.

## Goal

While any device is connected, the UI visibly states that TrailMate is holding off idle sleep —
one app-wide indicator (any connected device implies it), not one per device — so the user can
stop running `caffeinate` themselves.

## Out of scope

- Extending the assertion to offline simulation (playback / joystick / recording with no device)
  or adding a switch to disable it — issue #74, not yet filed as an epic.
- Anything about *why* a device dropped; recovery is [[043-auto-reconnect]]'s territory.
- Clamshell close and manually chosen Sleep: `.userInitiated` blocks **idle system sleep** only;
  those paths are stopped by neither a power assertion nor `caffeinate`, so they are outside what
  the app can claim.

## Stories

- [ ] One app-wide indicator, driven by "at least one session connected" rather than per-session
      state — status bar or a small sidebar glyph with a tooltip.
- [ ] Copy that states the boundary honestly: idle sleep is held off; lid-close and manual sleep
      are not.
- [ ] Localize it (en + zh-Hant, per [[015-localization]]).

## Open questions

- Status bar vs sidebar glyph vs both — follow HIG (D9); a menu-bar-extra line may be the more
  natural home given [[021-menu-bar-background]].
- Does it belong in the menu-bar summary too, where the window may be closed entirely?

## Decisions made along the way

- One indicator for the app, not per device: the assertion's effect is global, so a per-session
  badge would imply a distinction that doesn't exist (from #73).

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] With a device connected, the indicator is visible and its state matches
      `pmset -g assertions`.
- [ ] It disappears when the last session disconnects.
- [ ] Multi-device: one indicator, not one per session.
- [ ] Localized in en + zh-Hant; wording does not over-claim (no "prevents sleep" absolutes).
