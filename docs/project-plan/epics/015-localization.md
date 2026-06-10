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
- [x] Extract hardcoded UI strings
- [x] Add en + zh-Hant string resources
- [ ] Verify layout with longer Chinese strings in the sidebar

## Acceptance criteria
- [ ] Switching system language to zh-Hant localizes all visible UI
- [x] No untranslated user-facing strings

## Decisions made along the way
- **String Catalog (`.xcstrings`), not `.strings` files** — keys are the English source text,
  compiler-extracted (`SWIFT_EMIT_LOC_STRINGS`) and synced with `xcstringstool`. Authored
  headlessly: seed an empty catalog, build to emit `.stringsdata`, `xcstringstool sync` to pull
  the exact compiler keys, then translate. No hand-matched keys. (2026-06-10)
- **Non-literal UI strings were refactored to be extractable** — `String(format:)` UI text became
  `LocalizedStringKey` interpolation or `String(localized:)`; `SearchField`/`ChoiceButton`
  labels became `LocalizedStringKey`; `TransportMode` gained a localized `displayName` while
  `rawValue` stays English (it's persisted). (2026-06-10)
- **Log/diagnostic messages stay English** (epic scope) — `addLog` text, the error enums
  (`DaemonError`/`TunnelError`/`BuilderError`, all log-only), device names, and system error
  descriptions are not localized. (2026-06-10)
- **Verified headless**: build succeeds, the catalog is fully translated with no stale states,
  sync is idempotent, and the built bundle contains `zh-Hant.lproj/Localizable.strings`. The
  runtime visual pass and the longer-string layout AC are left for the owner (native zh-Hant
  speaker), who also reviews the translations in the PR. (2026-06-10)
