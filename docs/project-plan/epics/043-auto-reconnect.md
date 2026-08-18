---
type: epic
id: 043
title: Automatically retry the connection after an abnormal disconnect
status: open
milestone:
issue: 72
opened: 2026-08-18
shipped:
tags: [connection, ux]
---

# Epic 043: Automatically retry the connection after an abnormal disconnect

> **Open and unscheduled (2026-08-18).** The request (#72) asks to reverse a deliberate design
> decision, so it needs an explicit owner call before it can be scheduled — see Open questions. Depends on [[042-survive-closed-daemon-pipe]]: today the app can die of
> SIGPIPE on the same event, and a dead process has nothing to reconnect.

## Why

Not auto-reconnecting is currently **intentional**. On an abnormal drop (`DaemonBridge` sees
`TUNNEL_DOWN`, or the daemon exits) `DeviceSession` tears the connection state down, shows
"Error: Tunnel down", writes a log line, and then waits for a manual Connect —
`handleDaemonExit` says so in as many words ("Don't auto-restart — the user clicks Connect"),
and an early Reconnect button was dropped at planning (`features.md` deferred). #72 asks for
the opposite: retry automatically instead of clicking Connect every time.

What has changed since that decision, per the reporter's survey, is that most of the cost is
gone:

- The privileged tunneld is **not** torn down on a drop and `ensureRunning()` is idempotent, so
  a reconnect while tunneld is alive **does not re-prompt for the admin password**.
- A user-initiated Disconnect takes the `expectingExit` path, so intentional and abnormal drops
  are already distinguishable.
- The app holds a wake assertion while connected (`PreventUserIdleSystemSleep`, verified), so
  drops are not idle sleep — the real causes are lid close, manual sleep, Wi-Fi, or USB.
- After reconnecting, the device re-syncs to the current red dot (D11 / [[028-map-while-disconnected]]),
  so the post-reconnect state is safe.

## Goal

An abnormal drop recovers itself: TrailMate retries a bounded number of times with backoff and
comes back connected without user action, while an intentional Disconnect never reconnects and
a re-authorization is never forced silently.

## Out of scope

- Surviving the drop in the first place — [[042-survive-closed-daemon-pipe]].
- The out-of-app notification when retries are exhausted — [[044-system-notifications]].
- Any always-on privileged helper to avoid the password entirely — declined in
  [[020-single-auth-prompt]].

## Stories

- [ ] Trigger only on abnormal drops; `expectingExit` (user Disconnect) never retries.
- [ ] Bounded retry with backoff; give up, stop, and report — never retry forever at a device
      that is powered off or unplugged.
- [ ] Skip silently when re-authorization would be needed: prompt the user instead of popping an
      admin dialog on its own.
- [ ] Sub-case — wake from sleep: sleep is a graceful disconnect (`willSleep` disconnects and
      releases the wake token) and there is no wake handler today, so waking needs a manual
      Connect. tunneld survives sleep and `connect()` re-queries the RSD endpoint (which tunneld
      reassigns across sleep/wake — see the `TunnelBroker` comment), so reconnect-on-wake should
      also be password-free.
- [ ] Settings toggle; off = today's behavior, for users who prefer to reconnect by hand.

## Open questions

- **Does the owner want to reverse the "user clicks Connect" decision at all?** That call gates
  this epic; until then it stays an idea. If the answer is no, drop it and keep #72 closed with
  the rationale.
- Retry count and backoff curve; does a retry attempt block the UI or run quietly in the
  background?
- Should reconnect-on-wake ship on its own even if general auto-retry is declined? It is the
  most predictable case and the least likely to fight the user.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] An abnormal drop with tunneld still alive reconnects without user action and without an
      admin prompt.
- [ ] A user-initiated Disconnect never triggers a reconnect.
- [ ] Retries are bounded; exhaustion leaves a clear, reportable stop state.
- [ ] The Settings toggle off reproduces today's manual behavior exactly.
