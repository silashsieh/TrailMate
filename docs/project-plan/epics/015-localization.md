---
type: epic
id: 015
title: Localization scaffold (en + zh-Hant)
status: done
milestone: v1.6.0
issue:
opened: 2026-05-29
shipped: 2026-06-11
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
- [x] In-app Language picker (System Default / English / 繁體中文) in the Settings window
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
- **In-app Language picker** (owner request) — Settings-window override (System Default /
  English / 繁體中文) on top of system-language following. Writes the standard `AppleLanguages`
  key via `LanguagePreference`; applies on next launch, not live (`String(localized:)` binds the
  launch-time bundle, and relaunching mid-session would drop a live device connection). The
  picker says so. Covered by a relaunch UI test that only toggles System Default ↔ English, so
  a missed reset can't leave other suites facing a non-English UI. (2026-06-10)
- **Verified headless**: build succeeds, the catalog is fully translated with no stale states,
  sync is idempotent, the built bundle contains `zh-Hant.lproj/Localizable.strings`, and all 63
  tests pass. The runtime visual pass and the longer-string layout AC are left for the owner
  (native zh-Hant speaker), who also reviews the translations in the PR. (2026-06-10)
