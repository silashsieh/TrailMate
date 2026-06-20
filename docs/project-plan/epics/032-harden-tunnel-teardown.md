---
type: epic
id: 032
title: Harden tunnel teardown — force-kill a wedged tunneld
status: done
milestone: v2.1.0
issue:
opened: 2026-06-21
shipped: 2026-06-21
tags: [connection, robustness]
---

# Epic 032: Harden tunnel teardown — force-kill a wedged tunneld

> Root-cause fix for the leak that [[031-reclaim-stale-tunneld]] only mitigates on the next launch.
> Found live this session: quitting TrailMate repeatedly left a root tunneld squatting on port 49151.

## Why

`tm_tunneld.sh`'s `cleanup()` sent the tunneld only a polite `SIGTERM` and then `wait`ed for it. A
`pymobiledevice3 remote tunneld` that is holding a live TUN tunnel **wedges on shutdown** — it
acknowledges `SIGINT` (its HTTP `/shutdown`) and `SIGTERM` but never actually exits — so the wrapper
blocked on `wait` forever and leaked the root daemon on the port. The next launch then couldn't bind
49151, and (since the daemon is root) nothing unprivileged could force it down. Reproduced twice this
session: `/shutdown` returned `200 {"message":"Server shutting down..."}` while the process stayed
alive, and only `kill -9` cleared it.

## Goal

App quit (or host death) always tears the tunnel down — even a wedged tunneld — with no leaked process
on the port and no indefinite hang in the wrapper.

## Out of scope

- The pmd3-internal reason `/shutdown` wedges with an active tunnel (upstream behaviour).
- The app-side reclaim — kept as a best-effort secondary ([[031-reclaim-stale-tunneld]]).

## Stories

- [x] `cleanup()` escalates: `SIGTERM` → short grace (~3s) → `SIGKILL` (uncatchable), then a
      non-blocking `wait`. Runs as root, so it can force-kill its own tunneld child; the kernel
      reclaims the utun interface on process death.

## Decisions made along the way

- **SIGKILL escalation in the privileged wrapper is the durable fix, not the app-side `/shutdown`.**
  An unprivileged app can't force a wedged root tunneld; the root wrapper can. Teardown is made
  reliable at the source, and 031's `/shutdown` reclaim is demoted to best-effort (it only clears a
  *clean* orphan).
- **tunneld is a single process (no children — verified)**, so killing `TUNNELD_PID` suffices; no
  process-group kill needed.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] Quitting TrailMate while a device tunnel is active leaves no tunneld on port 49151.
- [x] The wrapper never blocks indefinitely waiting on a tunneld that won't exit.
