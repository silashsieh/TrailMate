---
type: epic
id: 021
title: Menu bar presence & background mode
status: done
milestone: v2.0.0
issue:
opened: 2026-06-10
shipped: 2026-06-14
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

- [x] `MenuBarExtra` scene: status summary (per-device connection + playback) and quick
      actions — Open TrailMate, Pause/Stop, Disconnect, AI-control toggle, Quit.
- [x] Keep-running-windowless: closing the main window leaves simulation + command socket
      live; "Open TrailMate" restores the window (`openWindow` + `NSApp.activate`).
- [x] Activation-policy handling: window open → `.regular`; window closed → `.accessory`
      (Dock icon hides, menu bar item remains); flip back on reopen.
- [x] Settings: show/hide menu bar item (`isInserted`), Dock-icon behavior.
- [ ] **(deferred — optional)** Open at login via `SMAppService.mainApp.register()` — free-Apple-ID safe;
      pairs with [[020-single-auth-prompt]] for a zero-touch start once prompts are gone.
- [x] Verify the App Nap activity token covers the windowless case (long route playback with
      no window, lid open).
- [x] Docs: features.md + quick-start describe the menu bar mode.

## Open questions — answered at planning (2026-06-13)

- **Menu bar style** → start `.menu` (plain dropdown); `.window` panel only if we later want a
  mini-map / richer status.
- **Default posture** → accessory-when-window-closed (Ollama style), with a Settings override.
- **2 Hz snapshot push when unobserved** → leave alone; measure first.

## Detailed design (v2.0.0 planning workflow, 2026-06-13)

- **`WindowGroup` → `Window(id: "main")`** — a single reopenable instance, not a multiplying
  group. Reopen path: set `.regular` → `NSApp.activate` → `openWindow(id: "main")` →
  `orderFrontRegardless`.
- **Activation policy is programmatic** (`.regular` on window-appear, `.accessory` on
  `NSWindow.willCloseNotification`) in `AppDelegate` — **no `LSUIElement`** (that would force
  accessory always).
- **`applicationShouldTerminateAfterLastWindowClosed = false`** — closing the window keeps the
  app (and the AI socket + simulation) alive.
- **App Nap token stays connection-scoped** (held `attach`→`detach`), NOT window-scoped and
  NOT relocated — it already covers the windowless case because the root `@State` survives
  window close. Step is verify-only (long route, no window, lid open), no code change expected.
- **Unreachable-app guard:** never allow "hide menu bar item" while `.accessory` with no
  window (no Dock icon + no menu item = invisible, unquittable). Couple the toggle with
  forcing a Dock icon, or disallow hiding while windowless.
- **Quick-action targets = the selected session.** Quit handshake fans out over
  `DeviceManager.sessions` (save-all + disconnect-all).
- **Single-owner note (orchestration):** this epic's agent owns `TrailMateApp.swift` and
  `SettingsView.swift` — the two merge hot-spots — integrating 019's quit-unlink + AI-control
  `Section` (handed over as a self-contained subview) and 012's quit fan-out in one pass.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] Start a route, close the main window: playback continues (device keeps moving), the
      menu bar item reflects "playing", and AI commands over the socket still work.
- [x] Reopen from the menu bar item: window returns with correct live state; no duplicate
      windows, no focus glitches after the activation-policy flip.
- [x] Menu bar item disabled in Settings → behavior matches today's (window-only app).
- [x] Quit from the menu bar item disconnects cleanly (daemons, tunnels, socket — same path
      as quitting the app today).
