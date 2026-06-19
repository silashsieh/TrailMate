---
type: epic
id: 023
title: trailmate CLI + stdio MCP shim (AI integration follow-up)
status: open
milestone:
issue: 54
opened: 2026-06-19
shipped:
tags: [ai, cli, mcp]
---

# Epic 023: trailmate CLI + stdio MCP shim (AI integration follow-up)

> Follow-up to [[019-ai-integration]]. v2.0.0 shipped the AI command surface as a raw
> `AF_UNIX` command socket; the two planned *client* conveniences — a `trailmate` CLI and a
> stdio MCP shim — were deferred. This epic is their home so they live on the [[backlog]]
> instead of as struck-through lines in a shipped epic. GitHub issue #54 (支援 MCP) is the
> user-facing ask for the MCP half.

## Why

The command socket works today, but an agent must drive it directly over `nc -U`. That's
serviceable for Claude Code (Bash can talk to the socket), but:

- There's no ergonomic CLI — every "via the CLI" acceptance criterion in [[019-ai-integration]]
  is currently met only over the raw socket.
- Stdio-only MCP clients (Claude Desktop and most other MCP hosts) cannot reach TrailMate at
  all — there is no installable server to register. This is issue #54.

Both are *additive thin clients* of the existing socket; nothing in the app's dispatch core
changes.

## Goal

Two clients of the existing command socket:

- A **`trailmate` CLI**: ergonomic verbs over the socket, `--json` to stdout / human messages
  to stderr, distinct exit codes, agent-quality `--help`, installable on PATH.
- A **stdio MCP shim**: hand-rolled JSON-RPC 2.0 (initialize / tools-list / tools-call) that
  relays to the same socket, registerable into Claude Desktop and other MCP hosts.

Both reach the same `AppState.dispatch(_:)` facade through the socket, so the
`SimulationActor.emit()` chokepoint (noise + recording) still applies unchanged.

## Out of scope

- **Any change to the command-socket protocol or the app's dispatch core.** These are
  additive clients only.
- **New command verbs** (`WANDER`, saved/hand-drawn playback-by-name) — a separate follow-up
  already noted in [[019-ai-integration]].
- **The headless-daemon split.** The brain stays in the app (see [[019-ai-integration]]
  Decisions and [[scope]] long-term goals).

## Stories
<!-- Carried forward from 019's deferred stories. -->
- [ ] `trailmate` CLI: separate `swift-argument-parser` executable target, embedded in
      `Contents/Helpers/`, PATH symlink installer (VS Code pattern), `--json`/stderr split,
      distinct exit codes, agent-quality `--help`.
- [ ] CLI packaging in `packaging/build.sh` + re-sign under the host identity (ad-hoc when no
      Developer ID).
- [ ] stdio MCP shim: hand-rolled JSON-RPC 2.0 (initialize / tools-list / tools-call,
      < 500 lines, zero deps), spawned by the AI client, relaying to the same socket;
      registered via a stable symlink, not a bundle path.
- [ ] Docs: CLI command reference + MCP registration steps in README/docs; drop the
      "not yet built" caveats from [[features]] (Deferred / dropped), the [[architecture]]
      Command Protocol section, and CLAUDE.md's "Adding a verb" rule once they ship.

## Open questions

- CLI symlink distribution: where on PATH, and how to handle the unsigned/ad-hoc case
  cleanly for a build-from-source user.
- MCP shim lifecycle: spawned-per-session vs long-lived; how it discovers the socket path
  (and what it reports when the app is off / AI control disabled).
- Ship order: CLI first then MCP shim, per [[019-ai-integration]]'s "CLI first, MCP shim
  second" decision — or both together.

## Decisions made along the way
<!-- Pre-seeded from [[019-ai-integration]]; the full rationale lives there. -->

- **CLI first, MCP shim second.** Claude Code drives CLIs natively via Bash with zero client
  config; MCP only buys reach (Claude Desktop is stdio-only for local servers). The shim is
  additive: another thin client of the same socket.
- **Hand-rolled stdio MCP over the SDKs.** The official Swift SDK is pre-1.0 / Tier 3; the
  Python SDK drags 29 packages with compiled extensions into the bundle re-sign. The stdio
  core (JSON-RPC + 4 handlers) has been stable since 2024-11.
- **Both are thin clients of the existing socket** — the brain stays in the app.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] `trailmate <verb>` drives a connected device end-to-end (list / teleport / route /
      play / pause / stop / seek / status) with `--json` output and distinct exit codes;
      `--help` is agent-usable.
- [ ] CLI errors cleanly when AI control is off or the app isn't running (no hang, no second
      pymobiledevice3 stack, no sudo prompt).
- [ ] The MCP shim registers into Claude Desktop, advertises TrailMate tools via tools-list,
      and a tools-call teleports a connected device through the socket.
- [ ] Docs updated; the "not yet built / deferred" caveats in features.md, architecture.md,
      and CLAUDE.md are removed; GitHub issue #54 closed via `Closes #54`.
