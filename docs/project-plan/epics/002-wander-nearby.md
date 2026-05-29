---
type: epic
id: 002
title: Wander Nearby
status: done
milestone: v1.2.0
issue: 2
opened: 2026-05-27
shipped: 2026-05-27
tags: [routing]
---

# Epic 002: Wander Nearby

> Backfilled for the historical record. Full implementation log is [[phases]] Phase 12.

## Why
Issue #2 (加入附近晃晃功能): a way to wander a defined area without picking a specific
destination.

## Goal
A long-press action — **Wander nearby…** — opening a sheet (radius + duration). A builder
chains walking hops between random nearby points until the walked distance matches the
duration, suppressing zig-zag retracing.

## Outcome
Shipped in PR #5 (`feat: add Wander Nearby (issue #2)`), released in v1.2.0.
`WanderRouteBuilder`; loads via the existing route-playback path. See [[phases]] Phase 12 for
the build notes and [[features]] (Map-driven travel) for current behavior.
