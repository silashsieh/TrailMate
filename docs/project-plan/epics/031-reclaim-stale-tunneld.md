---
type: epic
id: 031
title: Reclaim a stale tunneld before launching a new one
status: done
milestone: v2.1.0
issue:
opened: 2026-06-20
shipped: 2026-06-20
tags: [connection, robustness]
---

# Epic 031: Reclaim a stale tunneld before launching a new one

> Robustness follow-up found in this session: a leaked `pymobiledevice3 remote tunneld` from a
> dead Debug build was squatting on port 49151, which makes a fresh launch fail to bind. Builds on
> the [[020-single-auth-prompt]] spike, which verified tunneld's `/hello` and `/shutdown` HTTP
> endpoints on the pinned pmd3.

## Why

`TunnelBroker.ensureRunning()` only guards on an in-process `isRunning` flag, so it never notices a
tunneld left over from a previous run. `tm_tunneld.sh`'s parent-watch is meant to clean up on host
death, but it can leak (a SIGKILL'd app, or the trap not running). A leftover tunneld holds port
49151; the next launch's `pymobiledevice3 remote tunneld` then fails to bind and the connect
surfaces a start error — the user has to manually `sudo kill` the orphan.

## Goal

At a fresh launch, before spawning a new tunneld, detect a stale one already on the port and
reclaim it — without a password prompt — so device connects "just work" after a crash/leak.

## Out of scope

- The leak itself (hardening `tm_tunneld.sh`'s watchdog) — a separate concern; reclaim is the safety net.
- Adopting a healthy external tunneld's tunnels (we don't own its lifecycle) — we reclaim, not adopt.

## Stories

- [x] Probe tunneld liveness over localhost HTTP (`/hello`) before launching.
- [x] If present, reclaim via `GET /shutdown` (unprivileged — no sudo) and wait until the port frees.
- [x] If it won't free within a short window, fall through to the launch path so the existing
      bind-failure error still surfaces (no silent hang).
- [x] Unit-test the reclaim loop with an injected probe/shutdown (no networking).

## Decisions made along the way

- **Reclaim via tunneld's own `/shutdown`, not `sudo kill`.** The endpoint is localhost HTTP, so an
  unprivileged TrailMate can stop a root tunneld with no auth prompt — verified in the 020 spike.
  Killing the root PID would need a password and defeats the promptless-reconnect goal.
- **Any HTTP answer on the port = stale.** At a fresh launch we own no tunneld (`isRunning` is
  false), so anything answering on the port is by definition not ours and safe to reclaim.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] With a leftover tunneld on the port, a fresh launch reclaims it and connects with no manual kill.
- [x] With no tunneld present, launch is unchanged (one extra fast localhost probe).
- [x] If reclaim fails, the launch still surfaces a clear error rather than hanging.
