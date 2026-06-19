---
type: epic
id: 025
title: Collapse the sidebar live log by default
status: open
milestone: v2.1.0
issue: 44
opened: 2026-06-19
shipped:
tags: [ui]
---

# Epic 025: Collapse the sidebar live log by default

> Enhancement to the sidebar (reported in #44).

## Why

The sidebar's live log occupies vertical space most of the time it isn't needed. Default it to
collapsed and let the user expand it on demand. (The full "View Full Log" sheet already exists
for deep inspection.)

## Goal

The sidebar log section is collapsed by default and expandable on demand; the choice persists
across launches.

## Out of scope

- Changing what the log captures or the "View Full Log" sheet.

## Stories

- [ ] Collapsible log section (disclosure), collapsed by default.
- [ ] Persist the expand/collapse state across launches.

## Open questions

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Fresh launch shows the log collapsed; expanding it and relaunching preserves the choice.
- [ ] Log content and the full-log sheet are unchanged.
