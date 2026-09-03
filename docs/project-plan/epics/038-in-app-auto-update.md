---
type: epic
id: 038
title: In-app auto-update (Sparkle on Developer ID releases)
status: in-progress
milestone: v2.2.0
issue: 39
opened: 2026-06-24
shipped:
tags: [distribution, packaging, ux]
---

# Epic 038: In-app auto-update (Sparkle on Developer ID releases)

> Feature (#39): TrailMate checks for and installs new versions instead of
> requiring the user to replace the app manually. The owner now has an Apple
> Developer Program membership, but releases remain on GitHub rather than the
> App Store.

## Why

Updates are currently manual: a user must notice a release, download its DMG,
and replace the installed app. Sparkle can provide a native update check,
authenticated download, installation, and relaunch.

The release trust model changed on 2026-09-01. Public artifacts will use a
Developer ID Application certificate, Hardened Runtime, and Apple
notarization. Sparkle's EdDSA signature remains a separate update-feed
authenticity layer; it does not replace Apple's signature or notarization.

The work is deliberately sequenced:

1. Prove the existing app—including the bundled CPython runtime—can be signed,
   notarized, stapled, and launched from a downloaded GitHub release.
2. Only then add Sparkle, its EdDSA key, and an appcast to that stable release
   pipeline.

This avoids debugging framework integration and production code signing at the
same time.

## Goal

From a Developer ID-signed TrailMate build, the user can check for and install
a newer Developer ID-signed, notarized release without leaving the app. The
update is verified by Sparkle before installation and relaunches into the new
version.

## Out of scope

- App Store or Mac App Store submission. App Store Connect is used only to
  issue notary API credentials.
- Independently updating the bundled Python runtime. An update replaces the
  entire `.app`.
- Adding Sparkle before the signing/notarization smoke test has passed.
- Bypassing Gatekeeper or weakening Hardened Runtime/library validation to
  make unsigned code load.

## Stories

- [x] Validate a downloaded GitHub DMG end to end: Developer ID identity,
      secure timestamps, Hardened Runtime, nested Python signatures, accepted
      notarization, stapled ticket, Gatekeeper assessment, and launch.
- [x] Add Sparkle 2 via SPM; wire `SPUStandardUpdaterController` into SwiftUI
      and expose a "Check for Updates…" action.
- [x] Generate the Sparkle EdDSA keypair once; keep the private key out of git
      and add `SUFeedURL` plus `SUPublicEDKey` to the app configuration.
- [x] Extend `packaging/release.sh` and `release.yml` to generate and publish a
      signed appcast and update archive only after notarization succeeds.
- [x] Localize updater UI (English and Traditional Chinese) and expose the
      automatic-check preference in Settings.
- [x] Document update behavior and recovery in `docs/quick-start.md`.

## Open questions

- **Future delta hosting.** GitHub Release assets use a different tag path for
  every version, while `generate_appcast` applies one download prefix to every
  archive loaded in an invocation. Deltas remain disabled until the archives
  have a shared stable URL layout or the pipeline gains a safe per-version URL
  strategy. Full signed updates are the supported path.

## Decisions made along the way

- **Moved into v2.2.0 (2026-08-18, owner's call).** It pairs with
  [[030-area-coverage-routing]], while later map-surface work remains outside
  this release.
- **Developer ID first, Sparkle second (2026-09-01, owner's call).** The paid
  membership removes the old ad-hoc-only constraint. The signing and
  notarization path must pass independently before updater integration starts.
- **GitHub distribution remains.** Developer ID and App Store Connect notary
  credentials do not imply App Store submission.
- **Keep both trust layers.** Apple signing/notarization establishes platform
  trust; Sparkle EdDSA authenticates the update feed and archive.
- **Bootstrap in v2.1.2 (2026-09-02, owner's call).** v2.1.2 is the first
  Sparkle-aware build so the update into v2.2.0 can be tested end to end.
- **Corrected bootstrap in v2.1.3 (2026-09-03).** Public v2.1.2 exposed two
  release defects and cannot self-update. Epic 047 repairs the configuration
  and packaged signature; v2.1.3 replaces it as the v2.2.0 test source.
- **GitHub Pages feed, GitHub Release DMGs.** The stable feed is
  `https://silashsieh.github.io/TrailMate/appcast.xml`; its signed enclosures
  point to versioned `.dmg` assets on GitHub Releases.
- **Use Sparkle's DMG support.** The same notarized DMG supports manual installs
  and full Sparkle updates. Delta generation is disabled until the pipeline can
  preserve per-version GitHub Release URLs while loading historical archives.
- **Consent-first automation.** Sparkle owns first-run update-check consent.
  Settings exposes automatic checks and downloads; neither bypasses Sparkle's
  confirmation before installation and relaunch.
- **Protected EdDSA key.** CI receives the private key only through the
  protected `release` environment. The mode-`600` recovery export remains
  outside the repository; the app and repository contain only the public key.

## Bugs / follow-ups found while building

- [[047-repair-sparkle-bootstrap]] — v2.1.2 omitted Sparkle's required
  pre-extraction verification setting and damaged the app signature while
  staging the DMG.
- The public v2.1.3 bootstrap was successfully installed and reached the signed
  Pages feed on 2026-09-03. Stable v2.2.0 was published on 2026-09-03; using
  that existing v2.1.3 installation to download, install, and relaunch into it
  is the remaining end-to-end test.
- The first v2.2.0 dry run exposed a historical URL bug: loading the v2.1.2 DMG
  while generating v2.1.3 had rewritten its enclosure under the v2.1.3 tag.
  Feed generation now normalizes tag/version pairs, retains historical entries
  without loading their archives, and fails if any full-DMG URL is mismatched.

## Acceptance criteria

- [ ] A clean machine accepts and launches the downloaded GitHub release with
      no Gatekeeper override; its app, nested code, and DMG signatures validate.
- [ ] "Check for Updates…" finds a newer release, downloads it, verifies it,
      installs it, and relaunches into the new version.
- [ ] A tampered update or wrong signing identity is rejected.
- [x] A release publishes a notarized manual-install DMG and a Sparkle-signed
      appcast/archive at a stable feed URL.
- [ ] Re-enable useful deltas after adopting an archive layout or generation
      strategy that preserves correct per-version GitHub Release URLs. Until
      then, every update uses the signed full-DMG fallback.
- [x] Updater UI is localized in English and Traditional Chinese, with an
      automatic-check preference in Settings.
