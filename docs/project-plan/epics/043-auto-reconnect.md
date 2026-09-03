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

**Auto-reconnect is armed by an explicit Connect and disarmed by an intentional Disconnect or
Cancel retry.** While the Settings toggle enables the policy, any connection the app loses on its
own inside that window recovers itself: TrailMate retries
**10 times**, with each attempt beginning after a full **5-second post-failure delay**, without user
action. The triggering abnormal disconnect starts the delay before attempt 1; after attempts 1–9
fail, each failure starts a fresh delay before the next attempt. Attempt 10's failure settles
immediately into the ordinary disconnected state — there is no useless final delay. Attempt runtime
is additional to the delay, so this is not a fixed 50-second wall-clock window. An intentional
Disconnect never reconnects, and a re-authorization is never forced silently.

## Out of scope

- Surviving the drop in the first place — [[042-survive-closed-daemon-pipe]].
- The out-of-app notification when retries are exhausted — [[044-system-notifications]].
- Any always-on privileged helper to avoid the password entirely — declined in
  [[020-single-auth-prompt]].

## Stories

- [ ] Arm on explicit Connect; disarm on explicit Disconnect or Cancel retry. Only intentional
      user actions suppress an armed retry — every app-observed loss inside that window retries
      while the Settings policy is enabled.
- [ ] Retry policy: **10 attempts, each after a fixed 5 s post-failure delay**, then stop and settle
      into the disconnected state — never retry forever at a device that is powered off or unplugged.
      The first delay starts when the abnormal drop is observed; later delays start only after the
      preceding attempt has failed, so attempts never overlap and attempt runtime does not consume
      the five seconds. Attempt 10 fails directly to disconnected with no final delay. The attempt
      counter resets after any successful reconnect, so a later drop gets a fresh 10.
- [ ] Split the existing connection machinery into a single-attempt primitive and its callers'
      policies. Explicit Connect may retain its current startup retry behavior; auto-reconnect must
      invoke exactly one prompt-free connection attempt per numbered retry and must not nest the
      existing three-attempt loop.
- [ ] Surface the *reconnecting* state in **both** places: the status string (sidebar row
      `statusText`, `ContentView.swift:1545`, and the menu-bar item, `MenuBarStatusView.swift`)
      **and** beside the Connect/Disconnect control (`ContentView.swift:60`), including which
      attempt is running (e.g. "Reconnecting… 3/10").
- [ ] While retrying, the Connect/Disconnect button becomes **Cancel retry**. Clicking it stops
      scheduling further attempts and disarms auto-reconnect for the session; an attempt already
      in flight is *not* force-killed — it is allowed to run to its timeout, after which the
      device settles into the ordinary disconnected state and the button returns to Connect.
- [ ] Cancellation during the five-second delay settles immediately and prevents the pending
      attempt. Cancellation during an in-flight attempt follows the graceful wind-down above; when
      that attempt fails or times out, no five-second delay and no subsequent attempt are scheduled.
- [ ] During that wind-down the button reads **"Cancelling…"** and is disabled, so the control
      never claims an action it is no longer offering.
- [ ] Once the attempts are exhausted (or cancelled), show the ordinary disconnected state with
      the reason.
- [ ] Skip silently when re-authorization would be needed: prompt the user instead of popping an
      admin dialog on its own.
- [ ] Sub-case — wake from sleep runs the **same** ten-attempt, five-second post-failure-delay
      policy (same UI, same Cancel).
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
  (2026-09-03, owner's call).** The armed window starts with an explicit Connect and ends with an
  explicit Disconnect or Cancel retry; inside it, a connection the app loses on its own must
  restore itself while the Settings policy is enabled. The
  explicit-Connect design still holds for the *first* connection of a session — this is
  recovery, not discovery.
- **Retry policy fixed at 10 attempts with a 5 s post-failure delay, no backoff (2026-09-03,
  owner's call).** The abnormal drop starts the delay before attempt 1; each failed attempt starts
  the next five-second delay, and attempt 10's failure settles immediately. Attempt duration is not
  part of the delay, so the total wall time is the sum of ten attempt runtimes plus ten pre-attempt
  delays rather than a promised ~50-second window. A flat delay over an exponential curve keeps the
  cadence predictable for brief Wi-Fi/USB interruptions. Exhaustion is not an error state of its
  own — it lands in the ordinary disconnected state, which the user can Connect out of by hand.
- **Auto-reconnect counts single attempts, not the existing nested startup loop (2026-09-03).**
  `DeviceSession.connect()` currently contains its own three-attempt startup policy. The reusable
  connection operation must be factored so each displayed `n/10` maps to exactly one daemon/tunnel
  attempt; otherwise the UI count, cancellation boundary, and ten-attempt acceptance criterion would
  all be false.
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
  ten times with the same five-second post-failure delay, status strings, and Cancel retry control.
  No separate reconnect-on-wake path and no separate policy — one retry loop, one set of states.
  This requires `willSleep` to stop taking the `expectingExit` path.
- **Scheduled into v2.3.0 (2026-09-03) alongside [[042-survive-closed-daemon-pipe]]**, which
  fixes the crash on the same disconnect path this epic has to recover from.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] A drop with tunneld still alive reconnects without user action and without an admin prompt.
- [ ] A user-initiated Disconnect never triggers a reconnect.
- [ ] A device that stays unreachable produces exactly 10 non-overlapping attempts. Attempt 1 starts
      about 5 s after the triggering failure; attempts 2–10 each start about 5 s after the preceding
      attempt finishes with failure. Attempt 10 settles immediately into the ordinary disconnected
      state — no final wait, no eleventh attempt, and no error-only dead end.
- [ ] A reconnect that succeeds on attempt *n* cancels the remaining attempts and resets the
      counter for the next drop.
- [ ] While retrying, the attempt state is visible in the status string *and* beside the
      Connect/Disconnect control, and the button reads "Cancel retry".
- [ ] Cancel retry schedules no further attempt; the in-flight one finishes on its own timeout,
      after which the session is plainly disconnected and the button reads Connect again.
- [ ] Cancel during a post-failure delay prevents the pending attempt immediately; cancel during an
      attempt allows only that attempt to finish and schedules neither a delay nor another attempt.
- [ ] Between the cancel press and that settle, the button reads a disabled "Cancelling…".
- [ ] After a cancel, nothing reconnects on its own until the user presses Connect.
- [ ] Sleeping and waking the Mac reconnects the device under the same ten-attempt,
      five-second post-failure-delay policy, with the same status strings and Cancel retry control,
      and without an admin prompt.
- [ ] The Settings toggle off reproduces today's manual behavior exactly.
