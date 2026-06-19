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

- **To see the log:** in the sidebar, click the **Log** section header — its disclosure
  control (the chevron/triangle next to the title; macOS also shows a "Show/Hide" affordance
  on hover) toggles the section open. Expanding it reveals the last 20 entries and the
  **View Full Log** button.
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

- Used the native collapsible `Section("Log", isExpanded:)` rather than wrapping the
  contents in a `DisclosureGroup`. The sidebar is a `.sidebar`-style `List` where every
  other entry is a `Section`; keeping Log a section makes its header the disclosure
  control and stays visually consistent with the rest of the sidebar.
- State persists via `@AppStorage("sidebarLogExpanded")` (Bool, default `false`) on
  `SidebarView`, matching the existing menu-bar `@AppStorage` preferences.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] Fresh launch shows the log collapsed; expanding it and relaunching preserves the choice.
- [x] Log content and the full-log sheet are unchanged.
