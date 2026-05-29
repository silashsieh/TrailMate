---
type: epic
id: 001
title: Multi-stop route planning
status: done
milestone: v1.2.0
issue: 1
opened: 2026-05-27
shipped: 2026-05-27
tags: [routing]
---

# Epic 001: Multi-stop route planning

> Backfilled for the historical record. Implementation detail lives in the commit/PR; this
> file exists so the system has a complete epic history and the [[roadmap]] "shipped" view is real.

## Why
Issue #1 (支援多中途點路線): the route planner only supported a single From → To pair.
Users wanted to chain several stops into one continuous route.

## Goal
From/To search with an **Add Stop** affordance; `MKDirections` legs are concatenated into one
playable polyline.

## Outcome
Shipped in PR #4 (`feat: multi-stop route planning (closes #1)`), released in v1.2.0.
See [[features]] (Route playback) for current behavior.
