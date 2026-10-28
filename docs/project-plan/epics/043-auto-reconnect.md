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

- [x] Arm on explicit Connect; disarm on explicit Disconnect or Cancel retry. Only intentional
      user actions suppress an armed retry — every app-observed loss inside that window retries
      while the Settings policy is enabled.
- [x] Retry policy: **10 attempts, each after a fixed 5 s post-failure delay**, then stop and settle
      into the disconnected state — never retry forever at a device that is powered off or unplugged.
      The first delay starts when the abnormal drop is observed; later delays start only after the
      preceding attempt has failed, so attempts never overlap and attempt runtime does not consume
      the five seconds. Attempt 10 fails directly to disconnected with no final delay. The attempt
      counter resets after any successful reconnect, so a later drop gets a fresh 10.
- [x] Split the existing connection machinery into a single-attempt primitive and its callers'
      policies. Explicit Connect may retain its current startup retry behavior; auto-reconnect must
      invoke exactly one prompt-free connection attempt per numbered retry and must not nest the
      existing three-attempt loop.
- [x] Surface the *reconnecting* state in **both** places: the status string (sidebar row
      `statusText`, `ContentView.swift:1545`, and the menu-bar item, `MenuBarStatusView.swift`)
      **and** beside the Connect/Disconnect control (`ContentView.swift:60`), including which
      attempt is running (e.g. "Reconnecting… 3/10").
- [x] While retrying, the Connect/Disconnect button becomes **Cancel retry**. Clicking it stops
      scheduling further attempts and disarms auto-reconnect for the session; an attempt already
      in flight is *not* force-killed — it is allowed to run to its timeout, after which the
      device settles into the ordinary disconnected state and the button returns to Connect.
- [x] Cancellation during the five-second delay settles immediately and prevents the pending
      attempt. Cancellation during an in-flight attempt follows the graceful wind-down above; when
      that attempt fails or times out, no five-second delay and no subsequent attempt are scheduled.
- [x] During that wind-down the button reads **"Cancelling…"** and is disabled, so the control
      never claims an action it is no longer offering.
- [x] Once the attempts are exhausted (or cancelled), show the ordinary disconnected state with
      the reason.
- [x] Skip silently when re-authorization would be needed: prompt the user instead of popping an
      admin dialog on its own.
- [x] Sub-case — wake from sleep runs the **same** ten-attempt, five-second post-failure-delay
      policy (same UI, same Cancel).
      Sleep is currently a graceful disconnect (`willSleep` disconnects and releases the wake
      token) with no wake handler, so waking needs a manual Connect today; `willSleep` must be
      reclassified as an app-initiated drop rather than an `expectingExit` one, and a wake
      handler must start the retry loop. tunneld survives sleep and `connect()` re-queries the
      RSD endpoint (which tunneld reassigns across sleep/wake — see the `TunnelBroker` comment),
      so reconnect-on-wake is password-free like any other retry.
- [x] Settings toggle; off = today's behavior, for users who prefer to reconnect by hand.
- [x] Localize the new strings ("Reconnecting… n/10", "Cancel retry", "Cancelling…") in the
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
- **One attempt seam, one commit path (2026-09-25, WP5).** `DeviceSession.connectOnce` performs
  exactly one tunnel-endpoint + daemon-start attempt through a new `DeviceConnectionAttempter`
  protocol (`LiveDeviceConnectionAttempter` wraps the shared `TunnelBroker` and spawns a
  `DaemonBridge`; tests inject a scriptable fake). Explicit Connect keeps its three-try startup
  loop *over* that primitive, retrying only a failed daemon start; every numbered auto-reconnect
  attempt is one call with `promptPolicy: .neverPrompt`. Explicit, automatic, and UI-test-mock
  connects all commit through the same `commitLiveBackend`, so a session keeps one
  `SimulationActor` and one recording capture across every reconnect.
- **A promptless attempt that would need authorization ends the window at once (2026-09-25).**
  `.neverPrompt` requires `TunnelBroker.isRunning`; otherwise the attempt throws
  `authorizationRequired`, the session settles into `Error: Authentication required` with a log
  line pointing at Connect, and no further attempt is scheduled. It is not counted as one of ten.
- **A cancelled in-flight attempt that succeeds anyway stays connected but disarmed (2026-09-25).**
  Cancel retry is a deliberate disarm, so honoring it means no *automatic* recovery until the
  next explicit Connect — not throwing away a connection that already landed. The log says so.
- **The Settings toggle is read when recovery would start, not mid-window (2026-09-25).** A loss
  or wake checks `autoReconnectEnabled` once; turning it off while "Reconnecting… n/10" is showing
  does not stop that window — Cancel retry does. Default is on; the key is absent-means-on so an
  unwritten preference never silently disables the policy.
- **Sleep abandons an active window; wake always starts a fresh ten (2026-09-25).** tunneld
  reassigns every endpoint across sleep/wake, so resuming a half-spent window would be stale. An
  in-flight attempt is never task-cancelled (the tunnel query and daemon start are not
  cancellation-safe); it settles on its own and, if it lands a backend after the window was
  abandoned, that backend is stopped and never committed. The wake target is the UDID that was
  connected at sleep, and the drop target is the UDID that was connected at loss — never the
  picker's current value.
- **The settled reason is the most recent failure (2026-09-25).** Exhaustion and a cancel during
  an attempt show that attempt's error; a cancel during the first delay shows the drop's reason
  (`Tunnel down`, `Daemon crashed (exit n)`, …). Exhaustion logs
  "Reconnect gave up after 10 attempts — press Connect to try again."
- **Lifecycle flips are synchronous; mirror operations are chained (2026-09-25, after review).**
  Review found two races in the first cut: sleep stored its wake target only after awaiting the
  daemon's QUIT, so a wake landing mid-teardown found nothing to retry; and a commit published
  the backend before awaiting the sim's attach, so a Disconnect or sleep during that await could
  detach and stop it and the commit then re-attached a dead backend. Now every teardown
  (Disconnect, loss, sleep, removal) flips its state before its first await and bumps a
  `backendEpoch`; all attach/detach/stop calls run through one session-owned FIFO chain
  (`mirrorChain`), so a teardown issued during a commit's attach always detaches after it; and a
  commit wires the mirror first, then publishes synchronously only if its attempt's epoch is
  unchanged, otherwise it stops the backend. Sleep also abandons an explicit Connect still in
  flight (never armed, so no wake recovery). A second review pass closed two more gaps: the
  commit rechecks the epoch after its first actor hop, in the same turn that queues the attach
  (a teardown during that hop had already chained its detach, so an attach queued behind it
  would re-mirror an orphan), and a stale-after-attach backend is stopped *behind* the chained
  detach; and `connect()` claims `.connecting` and its epoch before waiting for the prior
  teardown, so a second Connect is refused and a sleep/Disconnect during that wait is noticed.
  The backend being attached is registered as pending before the attach is queued. Teardown
  takes that backend into its own detach/stop operation, so Disconnect and a subsequent Connect
  cannot overtake its daemon stop. Covered by the seven "Lifecycle races" tests.
- **Recovery is projected, not duplicated (2026-09-25).** `ConnectionStatus` gains
  `.reconnecting(attempt:maxAttempts:)` and `.cancellingRetry`; every surface (sidebar row, the
  control area, the map hint, the menu bar) reads the same `recoveryText`. AI `STATUS` reports
  `state: "reconnecting"` / `"cancelling"` plus `attempt`/`maxAttempts`; an explicit Connect (GUI
  or `CONNECT <udid>`) while a window is open is a no-op, because the window owns the controls.

## Bugs / follow-ups found while building

- **WP10 shared-doc handoff (2026-09-25).** `features.md` §Connection (line 13: sleep now
  reconnects on wake; line 196: the dropped "Reconnect button" note is superseded by this epic),
  `risks.md` Wi-Fi row ("Auto-reconnect is not implemented" is no longer true),
  `architecture.md` Command Protocol (new `STATUS` state values `reconnecting`/`cancelling` and
  `attempt`/`maxAttempts` fields) and the DeviceSession row of the layer diagram (connection
  lifecycle now includes the recovery window), `testing.md` suite table
  (`DeviceSessionReconnectTests`, shared fakes `FakeDeviceConnectionAttempter` /
  `FakeSimulationBackend`) and manual smoke item 11 (sleep/wake now expects
  "Reconnecting… 1/10" after wake, not a plain disconnected state), and
  `decisions.md` if the owner wants the reversal recorded there.
- **Startup retry pause moved onto the shared clock (2026-09-25).** Explicit Connect's 3 s pause
  between daemon-start tries now uses `MonotonicTimeSource` instead of `Task.sleep`, so it is
  deterministic in tests. Same production duration.
- **Hosted unit-test roots accumulate (2026-09-25).** Each test-host process creates
  `/tmp/com.sh.TrailMate.Tests.<pid>` through the WP1 fallback and nothing removes it (18 were
  present after the WP5 runs). Not caused by this epic; WP10 may want a cleanup policy.
- **Menu bar shows the attempt wording only.** No Cancel retry quick action was added there —
  the epic places Cancel on the sidebar's Connect/Disconnect control. Revisit if wanted.

## Acceptance criteria

Unit coverage is `TrailMateTests/DeviceSessionReconnectTests.swift` (manual clock + scripted
attempt seam, no tunnel/daemon/prompt). The boxes are ticked by the WP10 manual gate on a real
device; each line names the test that proves its deterministic half.

- [ ] A drop with tunneld still alive reconnects without user action and without an admin prompt.
      — `armedDropReconnectsAfterFiveSecondsWithoutPromptOnTheSameActorAndCapture` (every
      recovery attempt carries `.neverPrompt`; same actor and capture survive);
      `recoveryThatWouldNeedAuthorizationSettlesWithoutPrompting`. Manual: real tunneld reuse.
- [ ] A user-initiated Disconnect never triggers a reconnect.
      — `explicitDisconnectNeverReconnects`; `unarmedLossStaysInTheManualState`.
- [ ] A device that stays unreachable produces exactly 10 non-overlapping attempts. Attempt 1 starts
      about 5 s after the triggering failure; attempts 2–10 each start about 5 s after the preceding
      attempt finishes with failure. Attempt 10 settles immediately into the ordinary disconnected
      state — no final wait, no eleventh attempt, and no error-only dead end.
      — `unreachableDeviceMakesExactlyTenNonOverlappingAttemptsThenSettles` (nothing fires at
      4.999 s, one attempt at 5.000 s, no timer while an attempt runs, no sleep after attempt 10).
- [ ] A reconnect that succeeds on attempt *n* cancels the remaining attempts and resets the
      counter for the next drop.
      — `successOnAttemptNResetsTheCounterForTheNextDrop`.
- [ ] While retrying, the attempt state is visible in the status string *and* beside the
      Connect/Disconnect control, and the button reads "Cancel retry".
      — `recoveryStatesProjectTheAttemptForEverySurface` (shared `recoveryText`); the sidebar
      `ReconnectControls` / switcher row / menu bar / map hint wiring is a WP9 UI-test candidate
      (identifiers `connection.reconnectStatus`, `connection.cancelRetry`). Manual until then.
- [ ] Cancel retry schedules no further attempt; the in-flight one finishes on its own timeout,
      after which the session is plainly disconnected and the button reads Connect again.
      — `cancelDuringInFlightAttemptShowsCancellingThenSettlesWithoutScheduling`.
- [ ] Cancel during a post-failure delay prevents the pending attempt immediately; cancel during an
      attempt allows only that attempt to finish and schedules neither a delay nor another attempt.
      — `cancelDuringDelaySettlesImmediatelyAndPreventsThePendingAttempt`;
      `cancelDuringInFlightAttemptShowsCancellingThenSettlesWithoutScheduling`;
      `cancelledInFlightAttemptThatSucceedsConnectsButStaysDisarmed`.
- [ ] Between the cancel press and that settle, the button reads a disabled "Cancelling…".
      — `.cancellingRetry` asserted in the two in-flight cancel tests; the disabled control itself
      is a WP9 UI check.
- [ ] After a cancel, nothing reconnects on its own until the user presses Connect.
      — both cancel tests advance the clock an hour and count no attempt; Connect re-arms.
- [ ] Sleeping and waking the Mac reconnects the device under the same ten-attempt,
      five-second post-failure-delay policy, with the same status strings and Cancel retry control,
      and without an admin prompt.
      — `sleepThenWakeRunsTheSamePolicyWithTheSameControls`;
      `sleepDuringRecoveryStartsAFreshWindowOnWakeAndDiscardsTheStaleAttempt`;
      `wakeDoesNothingWithoutAnArmedSessionOrWithThePolicyOff`. Manual: real
      `NSWorkspace` sleep/wake notifications and tunneld endpoint reassignment.
- [ ] The Settings toggle off reproduces today's manual behavior exactly.
      — `policyOffReproducesManualBehaviorAndPersists` (also proves the on-by-default and the
      persisted key).
- Per-session isolation (from [[v2.3.0-design]] §2.4): `retryStateIsSessionScopedAndSelectionDoesNotLeakOrMutateIt`,
  `sessionRemovalAbandonsRecoveryAndDiscardsItsRecording`. Explicit Connect's retained startup
  policy: `explicitConnectRetriesOnlyDaemonStartOnTheSharedClockAndMayPrompt`. Lifecycle races
  (review, 2026-09-25): `wakeDuringTheSleepTeardownStillReconnectsAfterTheTeardownFinishes`,
  `disconnectWhileAReconnectCommitIsWiringTheMirrorNeverPublishesTheStaleBackend`,
  `sleepWhileAnExplicitConnectIsInFlightDiscardsItsBackend`,
  `sleepDuringTheStartupRetryPauseAbandonsTheConnect`,
  `disconnectWhileACommitAwaitsTheActorBeforeAttachNeverAttachesTheStaleBackend`,
  `sleepWhileConnectWaitsForThePriorTeardownAbandonsIt`, `aSecondConnectWhileOneIsWaitingIsRefused`.
