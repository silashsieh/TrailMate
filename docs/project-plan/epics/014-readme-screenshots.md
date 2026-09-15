---
type: epic
id: 014
title: README screenshots & GIF demo
status: open
milestone: v2.4.0
issue:
opened: 2026-05-29
shipped:
tags: [docs]
---

# Epic 014: README screenshots & GIF demo

## Why
Carried over from [[phases]] Phase 5 "Pending": the README is text-only. A portfolio-quality
README wants screenshots and a short GIF demo of teleport / route / joystick.

## Goal
Add screenshots and a GIF demo to the top-level README (end-user facing).

## Stories
- [ ] Capture screenshots (map, route playback, joystick)
- [ ] Record a short GIF demo
- [ ] Embed in README

## Decisions made along the way

- **Re-scheduled to v2.4.0 (2026-09-03, owner's call).** Moved out of v2.3.0 together with
  [[023-cli-mcp-shim]]. The screenshots are worth more once the v2.4.0 map-surface work
  ([[037-mkmapview-idle-cpu]]) has landed, so they capture the final map UI rather than a
  surface about to be replaced.

## Acceptance criteria
- [ ] README shows current UI with at least one motion demo
