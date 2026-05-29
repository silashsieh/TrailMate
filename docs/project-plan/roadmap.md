---
type: view
---
# Roadmap

> **This page is generated.** The source of truth is the `epics/` folder — edit epic files,
> not this page. Open in Obsidian with the **Dataview** plugin to see live tables; on GitHub
> the blocks below render as code (that's expected — see [[process]] § Obsidian usage).
>
> Long-term direction and boundaries live in [[scope]] (Vision + Goals / Non-Goals).
> Unscheduled ideas live in [[backlog]]. How work flows: [[process]].

## In progress & scheduled

Epics with a milestone, grouped by the release they're targeting.

```dataview
TABLE WITHOUT ID file.link AS Epic, status AS Status, issue AS Issue
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

- **v1.3.0 — Device positioning & follow:** [[004-read-device-real-gps]] (foundational, needs
  feasibility check), [[005-restore-sim-location]], [[006-follow-current-position]],
  [[013-project-management-docs]] (this work).
- **v1.4.0 — Map interaction:** [[007-hand-drawn-routes]], [[008-right-click-map-menu]].
- **v1.5.0 — Playback & library:** [[009-route-loop-playback]], [[010-rename-saved-items]],
  [[011-timeline-seek]].
- **Shipped (v1.2.0):** [[001-multi-stop-routes]], [[002-wander-nearby]],
  [[003-friendly-device-name]].
- **Backlog / deferred:** see [[backlog]].
