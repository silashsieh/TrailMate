---
type: epic
id: 042
title: Survive a closed daemon pipe — turn SIGPIPE into a recoverable disconnect
status: open
milestone: v2.3.0
issue: 75
opened: 2026-08-18
shipped:
tags: [bug, connection, robustness, daemon]
---

# Epic 042: Survive a closed daemon pipe — turn SIGPIPE into a recoverable disconnect

> Crash-class defect reported in #75 with the diagnosis already done. Blocks the other
> disconnect-resilience work: [[043-auto-reconnect]] has nothing to reconnect and
> [[044-system-notifications]] has nobody left to notify if the process is gone.

## Why

When the peer of the daemon/tunnel pipe closes — device drops off, tunnel down, or the daemon
exits — the **whole app process dies of SIGPIPE** instead of degrading to one displayable,
recoverable disconnect. The user sees TrailMate vanish: menu-bar presence, running simulation,
and the AI command socket with it.

The reporter's evidence (#75) rules out the alternatives and names the cause:

- No crash report at the time (no TrailMate `.ips` in either DiagnosticReports) and no
  matching JetsamEvent — so neither a Swift trap nor memory pressure.
- Two independent unified-log confirmations of signal 13: `launchd: … exited due to SIGPIPE`
  and `FrontBoard: RBSProcessExitStatus domain:signal(2) code:SIGPIPE(13)`.
- The app's last line is `Foundation: Encountered write failure 32 Broken pipe` (errno 32 =
  peer closed) at that same instant.
- Display sleep, not system sleep, so `handleSystemSleep`'s graceful-disconnect path never ran.

Root cause in code, verified on `main`: every write to the daemon pipe is an unguarded
`FileHandle.write` — `DaemonBridge.swift:156` (commands), `:176` (the continuous `SETQ`
position emit while connected), `:190` (`QUIT`). Darwin's default for writing to a closed peer
is a fatal SIGPIPE. The app already defends the AI command socket against exactly this with
`SO_NOSIGPIPE` (`CommandServer.swift:180-184`, whose comment states the behavior), but the
daemon pipe has no equivalent and there is no process-wide `signal(SIGPIPE, SIG_IGN)` anywhere
in the repo. So the next write after the peer closes kills the process *before* the existing
`TUNNEL_DOWN` / daemon-exit teardown can run.

## Goal

A closed daemon pipe becomes a normal disconnect: the write fails with EPIPE, the session runs
its existing teardown, the user sees "Tunnel down" in the sidebar and log, and **the app stays
alive** — menu bar, other sessions, and the command socket unaffected.

## Out of scope

- Automatically reconnecting afterwards — [[043-auto-reconnect]].
- Notifying the user out-of-app when it happens — [[044-system-notifications]].
- The wedged-tunneld teardown work already shipped in [[032-harden-tunnel-teardown]].
- Any change to the graceful sleep path (`handleSystemSleep`), which was not implicated.

## Stories

- [ ] Stop the fatal signal: ignore SIGPIPE process-wide (`signal(SIGPIPE, SIG_IGN)`) and/or
      set `F_SETNOSIGPIPE` on the daemon pipe's fds — `FileHandle`/`Pipe` have no socket-level
      `SO_NOSIGPIPE`, so it has to happen at the fd layer.
- [ ] Make every daemon-pipe write EPIPE-aware: the three `DaemonBridge` write sites report the
      failure instead of trapping, and route it into the existing disconnect teardown — matching
      how `CommandServer` already treats a dead client.
- [ ] Surface it like any other drop: sidebar status, `TrailMateError` case, and a log line (the
      CLAUDE.md rule — never swallow `TUNNEL_DOWN` silently).
- [ ] Unit test: a write to a pipe whose read end is closed yields a disconnect, not a
      termination — the session ends in the error state and the process survives.
- [ ] Multi-device check: one session's pipe closing leaves the other session connected and
      simulating.

## Open questions

- Process-wide `SIG_IGN` vs per-fd `F_SETNOSIGPIPE`: the per-fd form is narrower, but the
  process-wide form also covers any future pipe/socket write. Decide whether to do both.
- Does the emit path (`:176`) need to stop *itself* on the first EPIPE, or is the teardown
  triggered by `TUNNEL_DOWN` / daemon-exit fast enough to stop it?

## Decisions made along the way

- **Scheduled into v2.3.0 (2026-09-03, owner's call).** Filed unmilestoned on 2026-08-18;
  pulled into the correctness release alongside [[043-auto-reconnect]] — a crash on a closed
  daemon pipe is the same disconnect path auto-retry has to recover from, so the two are
  worth building together.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Closing the daemon pipe's peer during an active session (device unplugged / tunnel down /
      daemon killed) leaves the app running; the session shows a disconnect and can be
      reconnected by hand.
- [ ] No `signal(SIGPIPE)` termination in the unified log for that scenario; the write failure
      is visible in the app's own log instead.
- [ ] Other connected sessions, the menu-bar item, and the AI command socket all survive.
- [ ] Regression test covers the closed-peer write.
