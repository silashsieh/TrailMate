---
type: epic
id: 043
title: Automatically retry the connection after an abnormal disconnect
status: open
milestone: v2.3.0
issue: 72
opened: 2026-08-18
shipped:
tags: [connection, ux]
---

# Epic 043: Automatically retry the connection after an abnormal disconnect

> **Scheduled into v2.3.0 (2026-09-03).** The request (#72) asked to reverse a deliberate design
> decision; the owner made that call — see Decisions. Depends on [[042-survive-closed-daemon-pipe]]:
> today the app can die of SIGPIPE on the same event, and a dead process has nothing to reconnect.

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

**Auto-reconnect is armed by an explicit Connect and disarmed only by an explicit Disconnect.**
Inside that window, any connection the app loses on its own recovers itself: TrailMate retries
**10 times, 5 seconds apart** (≈50 s), without user action. If all 10 fail it stops and settles
into the ordinary disconnected state. An intentional Disconnect never reconnects, and a
re-authorization is never forced silently.

## Out of scope

- Surviving the drop in the first place — [[042-survive-closed-daemon-pipe]].
- The out-of-app notification when retries are exhausted — [[044-system-notifications]].
- Any always-on privileged helper to avoid the password entirely — declined in
  [[020-single-auth-prompt]].

## Stories

- [ ] Arm on explicit Connect; disarm on explicit Disconnect. Only `expectingExit` (user
      Disconnect) suppresses retry — every other loss of connection inside that window retries.
- [ ] Retry policy: **10 attempts at a fixed 5 s interval**, then stop and settle into the
      disconnected state — never retry forever at a device that is powered off or unplugged.
      The attempt counter resets after any successful reconnect, so a later drop gets a fresh 10.
- [ ] Surface the *reconnecting* state in **both** places: the status string (sidebar row
      `statusText`, `ContentView.swift:1545`, and the menu-bar item, `MenuBarStatusView.swift`)
      **and** beside the Connect/Disconnect control (`ContentView.swift:60`), including which
      attempt is running (e.g. "Reconnecting… 3/10").
- [ ] While retrying, the Connect/Disconnect button becomes **Cancel retry**. Clicking it stops
      scheduling further attempts and disarms auto-reconnect for the session; an attempt already
      in flight is *not* force-killed — it is allowed to run to its timeout, after which the
      device settles into the ordinary disconnected state and the button returns to Connect.
- [ ] During that wind-down the button reads **"Cancelling…"** and is disabled, so the control
      never claims an action it is no longer offering.
- [ ] Once the attempts are exhausted (or cancelled), show the ordinary disconnected state with
      the reason.
- [ ] Skip silently when re-authorization would be needed: prompt the user instead of popping an
      admin dialog on its own.
- [ ] Sub-case — wake from sleep runs the **same** policy (10 × 5 s, same UI, same Cancel).
      Sleep is currently a graceful disconnect (`willSleep` disconnects and releases the wake
      token) with no wake handler, so waking needs a manual Connect today; `willSleep` must be
      reclassified as an app-initiated drop rather than an `expectingExit` one, and a wake
      handler must start the retry loop. tunneld survives sleep and `connect()` re-queries the
      RSD endpoint (which tunneld reassigns across sleep/wake — see the `TunnelBroker` comment),
      so reconnect-on-wake is password-free like any other retry.
- [ ] Settings toggle; off = today's behavior, for users who prefer to reconnect by hand.
- [ ] Localize the new strings ("Reconnecting… n/10", "Cancel retry", "Cancelling…") in the
      String Catalog for en + zh-Hant — see [[015-localization]].

## Open questions

## Decisions made along the way

- **The "user clicks Connect" decision is reversed inside an explicitly-connected session
  (2026-09-03, owner's call).** The armed window runs from an explicit Connect to an explicit
  Disconnect; inside it, a connection the app loses on its own must restore itself. The
  explicit-Connect design still holds for the *first* connection of a session — this is
  recovery, not discovery.
- **Retry policy fixed at 10 attempts × 5 s, no backoff (2026-09-03, owner's call).** A flat
  interval over an exponential curve: the realistic causes (lid close, Wi-Fi blip, USB reseat)
  clear in seconds or not at all, so a ~50 s window at a predictable cadence beats a curve that
  spends its budget waiting. Exhaustion is not an error state of its own — it lands in the
  ordinary disconnected state, which the user can Connect out of by hand.
- **Retry state is visible in two places, and Cancel lives on the Connect/Disconnect control
  (2026-09-03, owner's call).** The status string and the area beside the button both show it —
  the status string is where the user already looks for connection state, and the button area is
  where they will reach to stop it. Reusing the existing control (rather than adding a separate
  Cancel) keeps one action surface per session, matching the "this is the action surface" comment
  at `ContentView.swift:58`.
- **Cancel is graceful, not a kill (2026-09-03, owner's call).** It stops the *loop*; an attempt
  already in flight runs to its timeout and then lands in the disconnected state. Cancelling is a
  deliberate user action, so — like an explicit Disconnect — it disarms auto-reconnect for the
  session; reconnecting afterwards is a manual Connect, which re-arms it.
- **The button reads a disabled "Cancelling…" during the wind-down (2026-09-03, owner's call).**
  The three button states are therefore Connect → Cancel retry → Cancelling… → Connect, so the
  control always names what will happen if it is pressed, and names nothing while it is inert.
- **Wake from sleep reconnects under the same policy (2026-09-03, owner's call).** Sleep is not
  an explicit Disconnect, so it stays inside the armed window: on wake the tunnel retries
  10 × 5 s with the same status strings and the same Cancel retry control. No separate
  reconnect-on-wake path and no separate policy — one retry loop, one set of states. This
  requires `willSleep` to stop taking the `expectingExit` path.
- **Scheduled into v2.3.0 (2026-09-03) alongside [[042-survive-closed-daemon-pipe]]**, which
  fixes the crash on the same disconnect path this epic has to recover from.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] A drop with tunneld still alive reconnects without user action and without an admin prompt.
- [ ] A user-initiated Disconnect never triggers a reconnect.
- [ ] A device that stays unreachable produces exactly 10 attempts at ~5 s spacing, then stops in
      the ordinary disconnected state — no eleventh attempt, no error-only dead end.
- [ ] A reconnect that succeeds on attempt *n* cancels the remaining attempts and resets the
      counter for the next drop.
- [ ] While retrying, the attempt state is visible in the status string *and* beside the
      Connect/Disconnect control, and the button reads "Cancel retry".
- [ ] Cancel retry schedules no further attempt; the in-flight one finishes on its own timeout,
      after which the session is plainly disconnected and the button reads Connect again.
- [ ] Between the cancel press and that settle, the button reads a disabled "Cancelling…".
- [ ] After a cancel, nothing reconnects on its own until the user presses Connect.
- [ ] Sleeping and waking the Mac reconnects the device under the same 10 × 5 s policy, with the
      same status strings and Cancel retry control, and without an admin prompt.
- [ ] The Settings toggle off reproduces today's manual behavior exactly.
