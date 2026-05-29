# Backlog

> Triaged but **unscheduled** work — accepted ideas with no milestone yet, plus anything parked
> (`deferred`). Promote an item by setting its `milestone:` in the epic file; it then moves to
> [[roadmap]]. Generated from `epics/` — see [[process]] for the routing rule.

## Unscheduled & deferred

```dataview
TABLE WITHOUT ID file.link AS Epic, status AS Status, issue AS Issue, tags AS Tags
FROM "project-plan/epics"
WHERE type = "epic" AND file.name != "_template" AND status != "done" AND (status = "idea" OR status = "deferred" OR !milestone)
SORT status ASC, id ASC
```

## Static snapshot (for the GitHub reader)

- **Deferred — needs a scope decision:** [[012-multi-device]] (issue #9). Conflicts with the
  [[scope]] non-goal "no multi-device orchestration." Close as `wontfix` or revise scope first.
- **Ideas (carried over from [[phases]] Phase 5):** [[014-readme-screenshots]],
  [[015-localization]], [[016-test-ci-unit-tests]].
