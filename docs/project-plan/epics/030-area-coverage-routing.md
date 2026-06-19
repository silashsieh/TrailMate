---
type: epic
id: 030
title: Area serpentine coverage routing
status: open
milestone: v2.3.0
issue: 47
opened: 2026-06-19
shipped:
tags: [routing, map]
---

# Epic 030: Area serpentine coverage routing

> Feature (#47): box-select an area on the map and auto-generate a dense, non-repeating path
> that covers it (a serpentine / boustrophedon "mow the lawn" route). Builds on
> [[007-hand-drawn-routes]] and the existing routing/playback pipeline.

## Why

For coverage-style testing (walk every street / cover a region) the user wants to draw an area
and get a route that sweeps it, rather than hand-placing waypoints.

## Goal

Select a rectangular (or drawn) area; the app generates a serpentine coverage path within it at
a configurable lane spacing, loadable like any other route (play, record, export).

## Out of scope

- Optimal-coverage / TSP solving — a simple boustrophedon sweep at a chosen lane spacing is
  enough; no routing-engine rewrite.
- Road-aware coverage (follow actual streets) — possible later; v1 is geometric.

## Stories

- [ ] Area selection on the map (box-select / drawn polygon).
- [ ] Generate a serpentine path at a configurable lane spacing; clip to the area.
- [ ] Hand the path to the routing/playback pipeline (play, record, save, export).

## Open questions

- Geometric sweep vs road-snapped (MapKit has no area-coverage primitive — geometric first).
- Lane-spacing default and units.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Selecting an area produces a non-repeating coverage path that visibly sweeps it.
- [ ] The path plays back and exports like a normal route.
