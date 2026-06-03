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

- **v1.3.0 — Device positioning & follow:**
  [004 — Read device real GPS (blue dot)](epics/004-read-device-real-gps.md) (foundational,
  needs feasibility check),
  [005 — Restore last simulated location](epics/005-restore-sim-location.md),
  [006 — Follow / center current position](epics/006-follow-current-position.md),
  [013 — Project-management docs](epics/013-project-management-docs.md) (this work).
- **v1.4.0 — Map interaction:**
  [007 — Hand-drawn routes](epics/007-hand-drawn-routes.md),
  [008 — Right-click map menu](epics/008-right-click-map-menu.md).
- **v1.5.0 — Playback & library:**
  [009 — Route loop playback](epics/009-route-loop-playback.md),
  [010 — Rename saved items](epics/010-rename-saved-items.md),
  [011 — Timeline seek](epics/011-timeline-seek.md).
- **Shipped (v1.2.0):**
  [001 — Multi-stop routes](epics/001-multi-stop-routes.md),
  [002 — Wander Nearby](epics/002-wander-nearby.md),
  [003 — Friendly device name](epics/003-friendly-device-name.md).
- **Backlog / deferred:** see [backlog.md](backlog.md).
