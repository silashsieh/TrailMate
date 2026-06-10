---
type: epic
id: 021
title: Menu bar presence & background mode
status: open
milestone: v2.0.0
issue:
opened: 2026-06-10
shipped:
tags: [ui, lifecycle]
---

# Epic 021: Menu bar presence & background mode

> Owner-initiated (no inbox issue): from the AI-integration design discussion, 2026-06.
> Companion to [[019-ai-integration]] — agent-driven control is what makes background
> operation useful, and a menu bar app is the cheap form of "runs without the GUI in the
> way" (the headless-daemon split stays deferred; see 019's Decisions).

## Why

Once an agent can drive TrailMate ([[019-ai-integration]]), the main window is often just in
the way: the simulation core doesn't need it (D7 — `SimulationActor` runs off MainActor; the
map is an observer of the 2 Hz snapshot push). But the app process must stay alive for the
command socket. The Ollama/Claude Desktop pattern fits: close the window, keep a status item
in the menu bar, the app lives on in the background.

## Goal

TrailMate can run windowless: a menu bar item shows live state (devices connected, playback)
and offers quick actions; closing the main window keeps simulation, recording, and AI control
running; the window reopens from the menu bar item. Behavior is controlled from Settings.

## Out of scope

- **No headless daemon.** The brain stays in the app; this epic only changes the app's
  window/Dock lifecycle, not the process topology.
- **No lifecycle changes below the UI.** Sleep still tears down tunnels/DVT; the connect
  flow (and its admin prompt, until [[020-single-auth-prompt]]) is unchanged.

## Stories

- [ ] `MenuBarExtra` scene: status summary (per-device connection + playback) and quick
      actions — Open TrailMate, Pause/Stop, Disconnect, AI-control toggle, Quit.
- [ ] Keep-running-windowless: closing the main window leaves simulation + command socket
      live; "Open TrailMate" restores the window (`openWindow` + `NSApp.activate`).
- [ ] Activation-policy handling: window open → `.regular`; window closed → `.accessory`
      (Dock icon hides, menu bar item remains); flip back on reopen.
- [ ] Settings: show/hide menu bar item (`isInserted`), Dock-icon behavior.
- [ ] *(optional)* Open at login via `SMAppService.mainApp.register()` — free-Apple-ID safe;
      pairs with [[020-single-auth-prompt]] for a zero-touch start once prompts are gone.
- [ ] Verify the App Nap activity token covers the windowless case (long route playback with
      no window, lid open).
- [ ] Docs: features.md + quick-start describe the menu bar mode.

## Open questions

- Menu bar style: plain dropdown (`.menu`) vs panel (`.window`)? Start with `.menu`; the
  panel only earns its keep if we want a mini-map or richer status.
- Default posture: Dock icon always (Claude Desktop style) vs accessory-when-window-closed
  (Ollama style)? Leaning dynamic; Settings makes it reversible either way.
- Should the 2 Hz snapshot push pause when nothing observes it, or is it cheap enough to
  leave alone? (Likely leave alone — measure first.)

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Start a route, close the main window: playback continues (device keeps moving), the
      menu bar item reflects "playing", and AI commands over the socket still work.
- [ ] Reopen from the menu bar item: window returns with correct live state; no duplicate
      windows, no focus glitches after the activation-policy flip.
- [ ] Menu bar item disabled in Settings → behavior matches today's (window-only app).
- [ ] Quit from the menu bar item disconnects cleanly (daemons, tunnels, socket — same path
      as quitting the app today).
