# Backlog

> Triaged but **unscheduled** work — accepted ideas with no milestone yet, plus anything parked
> (`deferred`). Promote an item by setting its `milestone:` in the epic file; it then moves to
> [roadmap.md](roadmap.md). Generated from `epics/` — see [process.md](process.md) for the
> routing rule.

## Unscheduled & deferred

```dataview
TABLE WITHOUT ID file.link AS Epic, status AS Status, issue AS Issue, tags AS Tags
FROM "project-plan/epics"
WHERE type = "epic" AND file.name != "_template" AND status != "done" AND status != "dropped" AND (status = "idea" OR status = "deferred" OR !milestone)
SORT status ASC, id ASC
```

## Static snapshot (for the GitHub reader)

- **Accepted, unscheduled** — triaged 2026-08-18 from the 2026-08-07 inbox, deliberately left
  without a milestone:
  [042 — Survive a closed daemon pipe (SIGPIPE kills the whole app)](epics/042-survive-closed-daemon-pipe.md) (#75, bug),
  [043 — Auto-reconnect after an abnormal disconnect](epics/043-auto-reconnect.md) (#72 — asks to
  reverse the deliberate "the user clicks Connect" design; gated on that call),
  [044 — macOS system notifications](epics/044-system-notifications.md) (#71),
  [045 — "Keeping Mac awake" indicator while connected](epics/045-keep-awake-indicator.md) (#73),
  [046 — Pin the sidebar Devices section while scrolling](epics/046-pin-sidebar-devices-section.md) (#70).
- **Open inbox items with no epic yet:** #41 (share saved locations & routes — parked pending a
  [scope.md](scope.md) decision on file-export vs cloud sync), #74 (extend the wake assertion to
  offline simulation + a toggle).
