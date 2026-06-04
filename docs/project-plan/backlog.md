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

- **Accepted, unscheduled:**
  [012 — Simultaneous multi-device](epics/012-multi-device.md) (issue #9). Unblocked by the
  2026-06-01 [scope.md](scope.md) revision (multi-iPhone is now a goal); large architectural
  change, needs deliberate planning before joining a release.
- **Ideas (carried over from [phases.md](phases.md) Phase 5):**
  [014 — README screenshots & GIF](epics/014-readme-screenshots.md),
  [015 — Localization (en + zh-Hant)](epics/015-localization.md),
  [016 — Unit tests + test CI](epics/016-test-ci-unit-tests.md).
