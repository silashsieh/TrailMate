---
type: epic
id: 044
title: macOS system notifications for background-relevant events
status: open
milestone:
issue: 71
opened: 2026-08-18
shipped:
tags: [ux, notifications, lifecycle]
---

# Epic 044: macOS system notifications for background-relevant events

> Accepted but unscheduled (2026-08-18). Pairs with [[021-menu-bar-background]] — the value
> exists precisely because TrailMate now keeps running with its window closed. Also the delivery
> channel [[043-auto-reconnect]] needs when it gives up, and it only works if the process
> survives the event at all ([[042-survive-closed-daemon-pipe]]).

## Why

The app uses no notification framework today — `UserNotifications` has zero hits in the repo.
Events like a device dropping off show up only in the sidebar status, the menu-bar summary, and
the log, so in menu-bar/background mode (or when the user has walked away) a drop goes unnoticed
until they come back to the app. The simulation is silently dead in the meantime.

## Goal

Important events reach the user through a macOS notification even when the main window is
closed and TrailMate is in the background, with abnormal disconnect as the driving case — and
without becoming noisy when the app is right there in front of them.

## Out of scope

- In-app presentation of the same events (sidebar, menu-bar summary, log) — already shipped.
- Recovering from the events being reported — [[043-auto-reconnect]].
- Any remote/push delivery; local notifications only (no cloud — [[scope]]).

## Stories

- [ ] Notification plumbing: authorization request, graceful handling of a denied/undetermined
      state (fall back to today's in-app surfaces, never nag).
- [ ] ⭐ Abnormal disconnect (`TUNNEL_DOWN` / daemon failure) — the primary case; names the
      device when more than one session exists.
- [ ] Connect failure after retries.
- [ ] Route playback finished (only when loop is off).
- [ ] Route-deviation auto-stop (>200 m for over 10 s).
- [ ] Auto-reconnect outcome — success / gave up — if [[043-auto-reconnect]] is accepted.
- [ ] Suppress sleep-caused disconnects: frequent, expected, and pure noise.
- [ ] Suppress (or route to an in-app presentation) while the app is frontmost.
- [ ] Per-category toggles in Settings.

## Open questions

- Where do the toggles live in the existing Settings window ([[017-settings-window]]) — their
  own pane or a section of General?
- Does a notification carry actions (e.g. "Reconnect", "Open TrailMate"), or is it
  informational only for v1?
- Which categories default to on? Suggested: abnormal disconnect on, the rest off.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] With the main window closed, an abnormal disconnect produces a system notification naming
      the affected device.
- [ ] Nothing is delivered twice: frontmost-app events do not fire both a notification and the
      in-app surface.
- [ ] Sleep-induced disconnects produce no notification.
- [ ] Denying notification permission degrades to today's behavior with no repeated prompts.
- [ ] Every category can be turned off in Settings and stays off across launches.
