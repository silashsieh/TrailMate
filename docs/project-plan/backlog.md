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
  [044 — macOS system notifications](epics/044-system-notifications.md) (#71),
  [045 — "Keeping Mac awake" indicator while connected](epics/045-keep-awake-indicator.md) (#73),
  [046 — Pin the sidebar Devices section while scrolling](epics/046-pin-sidebar-devices-section.md) (#70).
- **Scheduled out of this list on 2026-09-03:** 042 (#75) and 043 (#72) moved into v2.3.0 — see
  [roadmap](roadmap.md). 043's gating question (reverse the "the user clicks Connect" design) was
  answered: retry is armed between an explicit Connect and an explicit Disconnect, 10 × 5 s.
- **Open inbox items with no epic yet:** #41 (share saved locations & routes — parked pending a
  [scope.md](scope.md) decision on file-export vs cloud sync), #74 (extend the wake assertion to
  offline simulation + a toggle).
