---
type: epic
id: 025
title: Collapse the sidebar live log by default
status: done
milestone: v2.1.0
issue: 44
opened: 2026-06-19
shipped: 2026-06-19
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

## Using it

- **To see the log:** in the sidebar, click the **Log** row's disclosure triangle (the
  chevron to the left of the label — always visible) to toggle it open. Expanding it reveals
  the last 20 entries and the **View Full Log** button.
- **For the full log:** once expanded, click **View Full Log** to open the monospaced sheet
  (Copy All / Clear) — unchanged by this epic.
- The open/closed choice is remembered across launches, so once expanded it stays expanded
  until collapsed again.

## Out of scope

- Changing what the log captures or the "View Full Log" sheet.

## Stories

- [x] Collapsible log section (disclosure), collapsed by default.
- [x] Persist the expand/collapse state across launches.

## Open questions

## Decisions made along the way

- First used the native collapsible `Section("Log", isExpanded:)`, then switched to a
  `DisclosureGroup("Log", isExpanded:)` for discoverability: a collapsed macOS sidebar
  `Section` only reveals its show/hide control on hover, so it wasn't obvious the log
  could be opened. `DisclosureGroup` keeps an always-visible disclosure triangle next to
  the label, making the affordance explicit.
- State persists via `@AppStorage("sidebarLogExpanded")` (Bool, default `false`) on
  `SidebarView`, matching the existing menu-bar `@AppStorage` preferences. The binding is
  the same regardless of the wrapping control, so the switch didn't affect persistence.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] Fresh launch shows the log collapsed; expanding it and relaunching preserves the choice.
- [x] Log content and the full-log sheet are unchanged.
