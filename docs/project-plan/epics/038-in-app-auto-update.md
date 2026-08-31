---
type: epic
id: 038
title: In-app auto-update (Sparkle on Developer ID releases)
status: open
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

- [ ] Validate a downloaded GitHub DMG end to end: Developer ID identity,
      secure timestamps, Hardened Runtime, nested Python signatures, accepted
      notarization, stapled ticket, Gatekeeper assessment, and launch.
- [ ] Add Sparkle 2 via SPM; wire the SwiftUI-native path—`SPUUpdater` plus
      `SPUStandardUserDriver`—and expose a "Check for Updates…" action.
- [ ] Generate the Sparkle EdDSA keypair once; keep the private key out of git
      and add `SUFeedURL` plus `SUPublicEDKey` to the app configuration.
- [ ] Extend `packaging/release.sh` and `release.yml` to generate and publish a
      signed appcast and update archive only after notarization succeeds.
- [ ] Localize updater UI (English and Traditional Chinese) and expose the
      automatic-check preference in Settings.
- [ ] Document update behavior and recovery in `docs/quick-start.md`.

## Open questions

- **Stable appcast location.** GitHub release asset URLs are versioned; choose
  GitHub Pages or another fixed HTTPS URL before setting `SUFeedURL`.
- **Archive format.** Decide whether Sparkle consumes a notarized ZIP of the
  app while the DMG stays the manual-install artifact, or whether the selected
  Sparkle tooling supports the desired DMG feed cleanly.
- **Delta health across Python bumps.** A bundled-runtime change invalidates
  most of a delta; verify the appcast safely falls back to a full update.
- **Automatic-check default and cadence.** Choose an HIG-consistent default
  suitable for a single-user tool.
- **Key handling in CI.** Decide how the Sparkle EdDSA private key is backed up,
  rotated, and exposed only to the protected release environment.

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

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] A clean machine accepts and launches the downloaded GitHub release with
      no Gatekeeper override; its app, nested code, and DMG signatures validate.
- [ ] "Check for Updates…" finds a newer release, downloads it, verifies it,
      installs it, and relaunches into the new version.
- [ ] A tampered update or wrong signing identity is rejected.
- [ ] A release publishes a notarized manual-install DMG and a Sparkle-signed
      appcast/archive at a stable feed URL.
- [ ] Normal releases produce useful deltas when the bundled Python runtime has
      not changed and fall back safely when it has.
- [ ] Updater UI is localized in English and Traditional Chinese, with an
      automatic-check preference in Settings.
