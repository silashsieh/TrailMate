---
type: epic
id: 019
title: AI tool integration — command layer, CLI, MCP
status: in-progress
milestone: v2.0.0
issue:
opened: 2026-06-10
shipped:
tags: [architecture, ai]
---

# Epic 019: AI tool integration — command layer, CLI, MCP

> Owner-initiated (no inbox issue): from the AI-integration design discussion, 2026-06.
> A full technical survey (MCP vs HTTP vs CLI, IPC mechanisms, localhost-server security,
> Figma/JetBrains precedents) backs the decisions below; ask Claude Code for the survey if
> the rationale needs re-deriving.

## Why

Let AI tools (Claude Code today; Claude Desktop and other MCP clients later) drive TrailMate:
teleport, plan/play routes, query status — on any connected device. With [[012-multi-device]],
the payoff compounds: one agent choreographing several devices ("route A toward the pickup
while B converges from across town") is the scenario-testing capability none of the manual
controls give us.

## Goal

With "AI control" enabled in Settings, an agent can list devices, teleport, plan and play
routes, control playback, and read per-device status through a documented command surface —
without bypassing the simulation core. Off by default; zero attack surface when off.

## Out of scope

- **Joystick over AI.** 20 Hz real-time human control; agents get teleport/route/playback.
- **TCP localhost HTTP server.** Reachable by any webpage → DNS-rebinding/CSRF class
  (CVE-2025-66416/-66414 hit the MCP SDKs' own HTTP transport; JetBrains' port 63342 was the
  2013–16 precedent). The Unix socket gives the same capability with no port to attack.
- **Embedded HTTP-MCP (Figma pattern).** Claude Desktop can't target it, the Swift SDK's HTTP
  server transport is immature, and it inherits the TCP class above.
- **MCP SDKs.** The official Swift SDK is pre-1.0 / Tier 3; the Python SDK drags 29 packages
  with compiled extensions into the bundle re-sign. Hand-roll instead (see Decisions).

## Stories

- [ ] In-app command layer: Unix-domain-socket server inside TrailMate; line-delimited
      protocol in the `tm_daemon.py` style; every command carries `device_id` (UDID);
      dispatch through the same `AppState`/`SimulationActor` API the GUI uses.
- [ ] Settings toggle "Enable AI control" — off by default; socket created/unlinked on toggle;
      stale-socket cleanup on launch.
- [ ] `trailmate` CLI: embedded in `Contents/Helpers/`, PATH symlink installer (VS Code
      pattern), `--json` to stdout / human messages to stderr, distinct exit codes,
      agent-quality `--help` (built on swift-argument-parser).
- [ ] Agent-facing docs: command reference in README/docs + a CLAUDE.md note so Claude Code
      discovers the CLI.
- [ ] Command protocol section in [[architecture]] (same treatment as the daemon protocol).
- [ ] *(optional — when Claude Desktop matters)* stdio MCP shim: hand-rolled JSON-RPC 2.0
      (initialize / tools-list / tools-call, < 500 lines, zero deps), spawned by the AI client,
      relaying to the same socket; registered via a stable symlink, not a bundle path.

## Open questions — answered at planning (2026-06-13)

- **Command granularity** → v1 = `DEVICES`, `TELEPORT <udid>`, `ROUTE <udid>`,
  `PLAY`/`PAUSE`/`STOP`/`SEEK <udid>`, `STATUS`, `CLEAR`. Defer `WANDER` and saved/hand-drawn
  playback-by-name to a follow-up.
- **`status` shape** → one all-devices document with explicit per-device state (so
  "running-but-device-not-connected" is unambiguous and machine-readable).
- **Protocol versioning** → a `VERSION` integer + greeting line on connect (not versioned
  verbs).
- **CLI in v2.0.0?** → yes, behind the off-by-default toggle; its *multi-device* acceptance
  gates on [[012-multi-device]]'s broker (step 5 of the merged plan).

## Detailed design (v2.0.0 planning workflow, 2026-06-13)

- **Server = raw BSD `AF_UNIX`** (the inverse of `DaemonBridge`'s pipe loop) — not FlyingFox,
  not HTTP, not `NWListener`. `accept`/read-loop with `bytes.lines`; per-connection write
  queue; `await MainActor.run` hop to call `DeviceManager.dispatch(udid:command:)` — the
  *same* facade the GUI uses (AI is a command source, never a parallel state owner).
- **`emit()` chokepoint preserved:** every AI command flows through `SimulationActor.emit()`
  (`SimulationActor.swift:444`) exactly like GUI input, so noise + recording always apply.
- **Acceptance subtlety to prove explicitly:** the *recorded* point is CLEAN (pre-noise), the
  *wire* point is NOISY — prove the two separately, not as one assertion.
- **Stale socket:** `SO_REUSEADDR` is a no-op for `AF_UNIX`; `unlink()` before `bind()` on
  launch and on toggle-off/quit. Assert `sun_path < 104` bytes.
- **`swift-argument-parser` is confined to the CLI target**, not the app.
- Pure value types (`CommandProtocol.swift`, `SocketPath.swift`) are buildable before the
  sessionize gate and integrate onto it.

## Decisions made along the way

Pre-seeded from the design discussion (2026-06), so the rationale survives:

- **Unix domain socket over TCP HTTP / XPC / Apple Events.** No port → the browser-reachable
  attack class vanishes; filesystem permissions are the auth. XPC needs a launchd-registered
  Mach service and its peer code-signing verification is unusable ad-hoc. Apple Events' TCC
  automation approval is keyed to code-signing identity → re-prompts on every ad-hoc rebuild.
- **CLI first, MCP shim second.** Claude Code drives CLIs natively via Bash with zero client
  config; MCP only buys reach (Claude Desktop is stdio-only for local servers — its config has
  no URL form). The shim is additive later: another thin client of the same socket.
- **Hand-rolled stdio MCP over the SDKs.** The MCP stdio core (JSON-RPC + 4 handlers) has been
  stable since 2024-11; all spec churn is in HTTP/OAuth we don't use. Revisit the Swift SDK
  at 1.0.
- **Brain stays in the app (no headless daemon).** The AI surface is a second command *source*,
  not a second stateful client; `SimulationActor` is already the headless core, and
  `SimulationBackend` remains the extraction seam if GUI-closed operation ever becomes a goal
  (see scope.md long-term goals).
- **Every command routes through `emitSimulated`.** Noise + recording must apply to AI-driven
  movement; nothing outside a session's `DaemonBridge` ever talks to a `tm_daemon.py`
  (the [[012-multi-device]] two-writers rule).

## Bugs / follow-ups found while building

Adversarial review (2026-06-13, ultracode workflow) found and **fixed before merge**:
SIGPIPE crash on socket write, unbounded read-buffer DoS, fd close/shutdown race,
unbounded `semaphore.wait()` on a wedged tunnel, EINTR write truncation, 0700 socket
perms, quit-time `stop()`/unlink, single-`Window` Dock-reopen (`applicationShouldHandleReopen`),
GUI-only discovery (now scanned from `dispatch`), DEVICES/STATUS shape parity. (See the
review synthesis in the run transcript.)

**Tracked, not yet done (medium/low — none blocking the off-by-default single-device path):**
- [ ] `start()`/`stop()` epoch guard — a fast toggle off→on could spawn an accept loop on a
      reused listen fd; capture an epoch under the lock and bail if stale. Also `continue` on
      `accept()` EINTR vs treating it as fatal.
- [ ] `willClose` activation-policy check is timing-dependent (one main-actor hop may not have
      cleared the closing window's `isVisible`); capture the specific closing `NSWindow` and
      exclude it when counting remaining main windows.
- [ ] `showMenuBarItem` runtime toggle doesn't re-run `applyActivationPolicy` (safe today only
      because you can't be windowless while flipping it). Add `.onChange`.
- [ ] `openMainWindow` raise targets `NSApp.keyWindow`, which may not exist yet — defer one
      runloop or match by identifier.
- [ ] **Multi-device dispatch test** — "device A never moves device B" holds today only because
      there's one `session`; at [[012-multi-device]] add an integration test asserting a
      foreign/not-connected UDID returns the error code and mutates no session.
- [ ] **Docs owed before merge** — add the command-protocol section to `architecture.md` and the
      AI-control entry to `features.md` (CLAUDE.md same-change rule; deferred only because the
      feature isn't merged yet).
- [ ] **`trailmate` CLI (step 12) + MCP shim** still deferred — every "via the CLI" acceptance
      criterion is currently exercisable only over the raw socket (`nc -U`).

## Acceptance criteria

- [ ] With AI control enabled, Claude Code can (via the CLI): list devices, teleport a chosen
      device, plan+play a route on it, seek/pause/stop, and read status — GUI untouched.
- [ ] AI-driven movement shows Gaussian noise and is captured by session recording (proof the
      `emitSimulated` chokepoint is respected).
- [ ] Toggle off → no socket file exists; CLI fails with a clear "AI control disabled" message.
- [ ] App not running → CLI errors cleanly (no hang, no second pymobiledevice3 stack, no sudo
      prompt).
- [ ] Device not connected → commands for it fail with an actionable message; `status` makes
      the state machine-readable.
- [ ] Two devices: command for device A demonstrably never moves device B.
