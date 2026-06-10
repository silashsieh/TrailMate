---
type: epic
id: 015
title: Localization scaffold (en + zh-Hant)
status: in-progress
milestone: v1.6.0
issue:
opened: 2026-05-29
shipped:
tags: [i18n]
---

# Epic 015: Localization scaffold (en + zh-Hant)

## Why
Carried over from [[phases]] Phase 5 "Pending": no `.lproj` / `Localizable.strings`. The owner
is a native zh-Hant speaker, so en + zh-Hant is low-effort, high-value.

## Goal
Localize all user-facing strings to en + zh-Hant; app follows system locale.

## Out of scope
- Languages beyond en + zh-Hant (defer until asked). Log messages stay English (debugging).

## Stories
- [ ] Extract hardcoded UI strings
- [ ] Add en + zh-Hant string resources
- [ ] Verify layout with longer Chinese strings in the sidebar

## Acceptance criteria
- [ ] Switching system language to zh-Hant localizes all visible UI
- [ ] No untranslated user-facing strings
