---
type: view
---
# Roadmap

> **This page is generated.** The source of truth is the `epics/` folder — edit epic files,
> not this page. Open in Obsidian with the **Dataview** plugin to see live tables; on GitHub
> the blocks below render as code (that's expected — see
> [process.md § Obsidian usage](process.md#obsidian-usage)).
>
> Long-term direction and boundaries live in [scope.md](scope.md) (Vision + Goals / Non-Goals).
> Unscheduled ideas live in [backlog.md](backlog.md). How work flows: [process.md](process.md).

## In progress & scheduled

Epics with a milestone, grouped by the release they're targeting.

```dataview
TABLE rows.file.link AS Epic, rows.status AS Status, rows.issue AS Issue
FROM "project-plan/epics"
WHERE type = "epic" AND file.name != "_template" AND status != "done" AND status != "idea" AND milestone
SORT milestone ASC, id ASC
GROUP BY milestone AS Milestone
```

## Recently shipped

```dataview
TABLE WITHOUT ID file.link AS Epic, milestone AS Release, shipped AS Shipped, issue AS Issue
FROM "project-plan/epics"
WHERE type = "epic" AND file.name != "_template" AND status = "done"
SORT shipped DESC
LIMIT 10
```

## Static snapshot (for the GitHub reader)

Dataview can't render on GitHub, so here's the current picture in prose. Keep it loosely in
sync at release cuts; the epic files remain authoritative.

- **v2.2.0 — Coverage routing:**
  [030 — Area serpentine coverage routing](epics/030-area-coverage-routing.md).
- **Shipped (v2.1.0 — 2026-06-20) — UI polish, offline use & direct location entry:**
  [024 — Fix joystick/map-control overlap](epics/024-joystick-map-control-overlap.md),
  [025 — Collapse the sidebar log by default](epics/025-collapse-log-default.md),
  [026 — Connected device name in the status bar](epics/026-device-name-status-bar.md),
  [027 — Direct location entry (search-to-go + coordinates)](epics/027-direct-location-entry.md),
  [028 — Map & simulated position usable while disconnected](epics/028-map-while-disconnected.md),
  [029 — Saved-items library UX (reorder, categorize, auto-pan)](epics/029-saved-items-library-ux.md),
  [031 — Reclaim a stale tunneld before launching](epics/031-reclaim-stale-tunneld.md),
  [032 — Harden tunnel teardown (force-kill a wedged tunneld)](epics/032-harden-tunnel-teardown.md).
- **Shipped (v2.0.0 — 2026-06-14) — Multi-device & AI control:**
  [012 — Simultaneous multi-device](epics/012-multi-device.md),
  [019 — AI tool integration (command socket layer; CLI & MCP deferred)](epics/019-ai-integration.md),
  [020 — Single admin prompt per session (once-ever declined; satisfied by 012's broker)](epics/020-single-auth-prompt.md),
  [021 — Menu bar presence & background mode](epics/021-menu-bar-background.md).
  Cross-epic build plan: [v2.0.0-design.md](v2.0.0-design.md).
- **Shipped (v1.6.0 — 2026-06-11) — Localization, testing & Wi-Fi fix:**
  [015 — Localization (en + zh-Hant)](epics/015-localization.md),
  [016 — Unit tests + test CI](epics/016-test-ci-unit-tests.md),
  [022 — Wi-Fi device discovery fix](epics/022-wifi-device-discovery.md).
- **Shipped (v1.5.0 — 2026-06-08) — Advanced routing & settings:**
  [007 — Hand-drawn routes](epics/007-hand-drawn-routes.md),
  [017 — Standalone Settings window](epics/017-settings-window.md).
- **Shipped (v1.4.0 — 2026-06-07) — Playback, library & wander UX:**
  [009 — Route loop playback](epics/009-route-loop-playback.md),
  [010 — Rename saved items](epics/010-rename-saved-items.md),
  [011 — Timeline seek](epics/011-timeline-seek.md),
  [018 — Wander Nearby presets & persistence](epics/018-wander-nearby-presets.md).
- **Shipped (v1.3.0 — 2026-06-06) — Positioning & map ergonomics:**
  [005 — Restore last simulated location](epics/005-restore-sim-location.md),
  [006 — Follow / center current position](epics/006-follow-current-position.md),
  [008 — Right-click map menu](epics/008-right-click-map-menu.md),
  [013 — Project-management docs](epics/013-project-management-docs.md).
- **Shipped (v1.2.0):**
  [001 — Multi-stop routes](epics/001-multi-stop-routes.md),
  [002 — Wander Nearby](epics/002-wander-nearby.md),
  [003 — Friendly device name](epics/003-friendly-device-name.md).
- **Backlog / deferred:** see [backlog.md](backlog.md).
