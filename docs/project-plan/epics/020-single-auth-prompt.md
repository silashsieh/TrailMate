---
type: epic
id: 020
title: Enter the admin password once, not every session
status: done
milestone: v2.0.0
issue: 31
opened: 2026-06-10
shipped: 2026-06-14
tags: [connection, ux]
---

# Epic 020: Enter the admin password once, not every session

## Resolution (2026-06-19) — done under v2.0.0; once-ever auth deliberately not pursued

Closed **done under v2.0.0**, with the original "zero prompts" goal **declined, not abandoned** —
the verification spike below confirms it *is* achievable (Approach #1: `pymobiledevice3 remote
tunneld` as a root LaunchDaemon), so this is a deliberate call:

- The concern in #31 — not re-authing constantly — is already met by [[012-multi-device]]'s tunnel
  broker, shipped in **v2.0.0**: one admin prompt per app launch opens every device's tunnel.
  CLAUDE.md's standing constraint already deems **one prompt per session acceptable**.
- All 020 would add is removing *that* one-per-launch prompt, and the only viable free-Apple-ID path
  (Approach #1) needs an **always-running root daemon that idles with tunnels up even when TrailMate
  is closed**. For a single-user local tool, that standing root surface + install/uninstall/launchd
  lifecycle isn't worth saving one click per launch. The device-side spike test (handed to Harry
  below) is therefore **moot** and was not run.
- No 020-specific code shipped; this epic's contribution is the spike (kept below as the record of
  *why*) and this decision. If the calculus changes (e.g. paid signing unlocks SMAppService), open a
  **new** epic linking here — per [[process]], shipped epics aren't reopened.

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

- [x] Verification spike: pinned-version `tunneld` behavior (creation, query, hot-plug, sleep). —
      done; Approach #1 recommended (see Decisions).
- [x] Pick the approach; record it under "Decisions made along the way" with the spike results. —
      Approach #1 identified; **implementation declined** (see Resolution).
- The remaining stories (Settings install/status/remove flow, migrating the connect flow off
  per-session `osascript`, uninstall path + docs) were **not pursued** — see Resolution.

## Open questions

- Security posture: always-running root daemon vs on-demand start — what does the daemon do
  while TrailMate isn't running? (tunneld would idle with tunnels up; sudoers starts nothing.)
- Does a daemon-owned tunnel survive macOS sleep, or does the app still tear down/reconnect
  (features.md: DVT sessions don't survive sleep)?
- OS-update durability: DDI re-mount after iOS/macOS updates still manual — set expectations.

## Decisions made along the way

### Verification spike — 2026-06-19 (pinned pymobiledevice3 9.21.0)

All `tunneld` facts below were read off the **bundled** interpreter
(`PythonResources/python/bin/python3.13`, pmd3 **9.21.0**) and the **live**
root tunneld the running `/Applications` TrailMate already has up — not assumed.
One item (the daemon tunnelling a device in the *launchd system domain*) needs
the real iPhone and is handed to Harry below; everything else is verified.

**Verified against 9.21.0 (CLI + source + live HTTP):**

- `remote tunneld` exists. Flags: `--host` / `--port` (default `127.0.0.1:49151`),
  `-p/--protocol [tcp|quic]` (tcp default on Py≥3.13), `--daemonize/-d`, and
  per-transport toggles `--usb/--wifi/--usbmux/--mobdev2` (+`--no-*`).
- It is `@sudo_required` → `os.geteuid() == 0`. **A root LaunchDaemon satisfies
  this with no prompt** (the prompt today is purely osascript's, not tunneld's).
- HTTP query API (FastAPI/uvicorn), confirmed live against the connected iPhone:
  - `GET /` → `{udid: [{"tunnel-address","tunnel-port","interface"}]}` — the exact
    shape `TunnelBroker.fetchTunnelMap()` already parses.
  - `GET /hello` → `{"message":"Hello, I'm alive"}` — clean liveness probe.
  - `GET /shutdown` (SIGINT-to-self), `/clear_tunnels`, `/cancel?udid=`,
    `/start-tunnel?udid=` also exist. **`/hello` + `/shutdown` give us
    install-status and clean-stop primitives the file-sentinel wrapper lacks.**
- `uvicorn.run()` is a **blocking foreground server** that shuts down cleanly on
  SIGTERM/SIGINT → FastAPI lifespan → `TunneldCore.close()`. Ideal launchd
  citizen: launchd owns the foreground process; `--daemonize` (double-fork via
  the `daemonize` pkg, which *is* bundled) must **not** be used under launchd.
- **Pairing-record resolution is the make-or-break for a system daemon, and it
  favours us:** `get_preferred_pair_record` tries **usbmuxd first**, then iTunes,
  then the home folder. The live device tunnels over USB (interface `…%en9`,
  CDC-NCM), so its pair record comes from **usbmuxd** — a system daemon reachable
  by root **regardless of `$HOME`**. Only the *WiFi/RemotePairing* path reads
  `remote_*` records from `get_homedir()` (= `~$SUDO_USER`, i.e. `/var/root`
  under launchd), so WiFi-only devices are the one path that could regress.
- The root tunneld's listen socket is **not visible to unprivileged `lsof`**
  (verified live) — so install-status detection must use HTTP `/hello`, never a
  port scan.
- Most of candidate #1's behaviour (one process, N devices, hot-plug, ephemeral
  RSD re-query) was **already proven in the 012 spike (2026-06-13)** and is in
  production today via osascript. Epic 020 changes only *who launches tunneld
  and how long it lives*, not the transport.

**Three approaches compared:**

| | One-prompt-ever | Moving parts | Security posture | Fragility |
|---|---|---|---|---|
| **1. tunneld as root LaunchDaemon** | ✅ install writes plist + `launchctl bootstrap system` under one osascript prompt | Lowest — drops the osascript-per-session path entirely; reuses today's tunneld + broker query | Always-running root daemon; idles with tunnels up even when the app is closed. Bounded: tunneld only opens TUN + serves localhost HTTP (no location logic — CLAUDE.md never-do honoured) | Plist embeds the bundle's interpreter path; rewrite on each install. WiFi-only devices need `$HOME` care |
| **2. sudoers NOPASSWD drop-in** | ✅ install drops `/etc/sudoers.d/` rule under one prompt | Low, but keeps the per-session launch + wrapper | App can `sudo` the tunnel silently, but a NOPASSWD rule for an interpreter is a **broad** grant (anything that interpreter can be made to run as root); narrower if scoped to the wrapper, still brittle | **Highest** — rule pins an absolute bundle path; breaks on every app move/version bump. `sudo` syntax errors can lock out admin |
| **3. LaunchDaemon wrapping our own broker** | ✅ same install shape as #1 | Highest — keeps `tm_tunneld.sh` *and* adds daemon plumbing | Same as #1 | Same path fragility as #1 + an extra script to maintain. Only worth it if #1's tunneld fails in the launchd domain |

**Recommendation: Approach #1 — run `pymobiledevice3 remote tunneld` as a root
LaunchDaemon.** It is the smallest net change (the app already runs *this exact*
tunneld and already queries it; we only move the launch from per-session
osascript to a one-time `launchctl bootstrap`), it has clean status/stop
primitives (`/hello`, `/shutdown`), and its one real risk — pairing records in a
non-user context — is resolved in our favour for the USB path by source. #2 is
rejected as the most fragile and the broadest privilege grant; #3 is the
fallback only if the launchd-domain device test fails. SMAppService stays out of
scope (paid signing).

**The one item the desk can't settle (handed to Harry, then STOP):** does a
root tunneld in the **launchd system bootstrap domain** (no Aqua session,
`HOME=/var/root`, no `SUDO_USER`) actually *create the tunnel* to the iPhone,
not just bind and serve `{}`? Source says yes for USB (usbmuxd pair record), but
the launchd context differs enough from osascript-with-admin that it must be
seen once on the real device. Test artifacts written to
`scratchpad/spike-020/` (`com.harry.trailmate.tunneld.spike.plist` +
`run-spike.sh`): they bootstrap a spike daemon on port **49162** (coexists with
the live app on 49151, does not touch TrailMate.app), confirm the device appears
in `GET /`, dump the log on failure, then bootout and delete — leaving zero root
artifacts. **Pending:** Harry runs it and reports PASS/FAIL + log; only then is
the approach confirmed and Phase 2 begins.

**Open-question dispositions (from the spike):**

- *Idle behaviour:* a #1 daemon idles with tunnels up while the app is closed —
  the deliberate trade for promptless reconnect. Acceptable for a single-user
  local tool; documented, with `/shutdown` + uninstall to fully stop it.
- *Sleep:* unchanged from today. tunneld reassigns ephemeral RSD addr+port on
  wake (012 finding); the broker already re-queries per connect, and DVT
  sessions still don't survive sleep (features.md) — daemon ownership doesn't
  change that, the app still reconnects.
- *OS-update durability:* DDI re-mount after iOS/macOS updates stays manual —
  set expectations in docs; out of this epic's reach.

## Bugs / follow-ups found while building

## Acceptance criteria

Resolved by decision, not implementation (see Resolution):

- [x] Auth burden is acceptable: one admin prompt per app launch (v2.0.0's [[012-multi-device]]
      broker), which CLAUDE.md deems acceptable.
- Zero prompts after one-time setup — **not pursued** (Approach #1 viable but declined).
- Settings install/status/removal — **not pursued**.
- [x] Tunnel-down recovery still surfaces in the log — unchanged (no code changed, no regression).
