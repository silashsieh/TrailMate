---
type: epic
id: 020
title: Enter the admin password once, not every session
status: open
milestone: v2.1.0
issue: 31
opened: 2026-06-10
shipped:
tags: [connection, ux]
---

# Epic 020: Enter the admin password once, not every session

## Why

Issue #31 (「輸入一次密碼即可」): today every session pays one `osascript … with administrator
privileges` prompt to open the RSD tunnel. The ask is to enter the password **once** — at
setup — and never again, not once per launch.

Sequencing note: [[012-multi-device]] (v2.0.0) already keeps multi-device at *one prompt per
session* via the tunnel broker (one privileged process opens N tunnels). This epic takes the
remaining step: once per session → once ever. It lands after 012 so the broker shape is known.

## Goal

After a one-time setup (a single admin prompt), TrailMate connects to any number of devices
across launches and reboots with **zero** password prompts. Uninstalling the privileged piece
is documented and clean.

## Out of scope

- **SMAppService packaged helper.** The documented-proper path, but it needs paid signing —
  stays parked under scope.md → Long-term goals "as signing constraints allow". This epic
  works within the free-Apple-ID constraint.
- Weakening the privilege boundary: location logic stays out of whatever runs as root
  (CLAUDE.md never-do).

## Candidate approaches (verify before choosing)

Per the CLAUDE.md rule — never assert an unverified pymobiledevice3 API; run the CLI first:

1. **`pymobiledevice3 remote tunneld` as a root LaunchDaemon.** One admin prompt installs a
   plist + the daemon; it should auto-create tunnels for all connected devices (hot-plug
   included) and expose per-device RSD info for the app to query. Would replace
   `tm_tunnel.sh`/broker wholesale. **Verify against the pinned version**: subcommand exists,
   query API shape, behavior across sleep/unplug.
2. **sudoers drop-in** scoped `NOPASSWD` to exactly the tunnel command (bundled-interpreter
   path) — one prompt to install the rule; the app then runs the tunnel via `sudo` silently.
   Smallest moving part; fragile if the bundle path changes per release.
3. **Root LaunchDaemon wrapping our own broker script** (the 012 broker, installed instead of
   re-launched) — if tunneld doesn't verify.

## Stories

- [ ] Verification spike: pinned-version `tunneld` behavior (creation, query, hot-plug, sleep).
- [ ] Pick the approach; record it under "Decisions made along the way" with the spike results.
- [ ] One-time setup flow in the app (Settings: "Install privileged helper…" / status / remove).
- [ ] Migrate connect flow off per-session `osascript`; delete or fall back gracefully.
- [ ] Uninstall path + docs (quick-start + features).

## Open questions

- Security posture: always-running root daemon vs on-demand start — what does the daemon do
  while TrailMate isn't running? (tunneld would idle with tunnels up; sudoers starts nothing.)
- Does a daemon-owned tunnel survive macOS sleep, or does the app still tear down/reconnect
  (features.md: DVT sessions don't survive sleep)?
- OS-update durability: DDI re-mount after iOS/macOS updates still manual — set expectations.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Fresh boot → launch TrailMate → connect N devices: zero password prompts (after the
      one-time setup).
- [ ] Setup, status, and removal all visible in Settings; removal leaves no root artifacts.
- [ ] Tunnel-down recovery still surfaces in the log (no silently dead tunnels).
