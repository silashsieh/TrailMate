---
type: epic
id: 047
title: Repair the Sparkle bootstrap and DMG integrity checks
status: done
milestone: v2.1.3
issue:
opened: 2026-09-03
shipped: 2026-09-03
tags: [distribution, packaging, bug]
---

# Epic 047: Repair the Sparkle bootstrap and DMG integrity checks

> Hotfix follow-up to [[038-in-app-auto-update]] after validating the public
> v2.1.2 bootstrap artifact.

## Why

The published v2.1.2 app cannot start Sparkle because it requires a signed feed
without also enabling verification before archive extraction. Separately, the
exported app passed code-signature verification, but the app copied into the
finished DMG did not. The release pipeline verified the outer DMG and therefore
did not catch the damaged nested app.

## Goal

Publish a manually installed v2.1.3 bootstrap whose updater can start safely and
whose exact app inside the finished DMG retains a valid Developer ID signature,
then use it to test the update to v2.2.0.

## Out of scope

- Publishing or changing the contents of v2.2.0.
- Changing the Sparkle keypair, feed URL, or GitHub Pages architecture.
- Repairing already-installed v2.1.2 copies in place; they require one manual
  replacement because their updater cannot start.

## Stories

- [x] Enable Sparkle's pre-extraction verification alongside the required
  signed-feed policy.
- [x] Preserve bundle metadata while staging the app into the DMG.
- [x] Verify the staged app and the exact app mounted from the finished DMG.
- [x] Add automated coverage for the paired Sparkle security settings.
- [x] Pass the protected Developer ID signing, notarization, and appcast dry run.
- [x] Manually install v2.1.3 and confirm **Check for Updates…** reaches the
      signed feed without a configuration error.
- [x] Complete the v2.1.3 → v2.2.0 download, installation, and relaunch smoke test.

## Open questions

- None for the repair. Delta generation is disabled and its future URL/hosting
  strategy remains tracked by epic 038.

## Decisions made along the way

- Use `ditto --rsrc --extattr` for bundle staging because macOS app bundles rely
  on metadata that a generic recursive copy is not required to preserve.
- Treat the mounted app as the release integrity boundary: a Developer ID build
  fails unless the app users receive passes deep, strict signature validation.
- Cut build 11 as v2.1.3. v2.1.2 remains immutable and is documented as a
  broken bootstrap that must be replaced manually once.
- Stable v2.2.0 was published on 2026-09-03 with the corrected signed feed. The
  installed v2.1.3 bootstrap downloaded, verified, installed, and relaunched
  into v2.2.0 successfully.

## Bugs / follow-ups found while building

- The v2.1.2 public DMG is notarized, but its contained app fails deep, strict
  code-signature verification after staging.

## Acceptance criteria

- [x] The built app contains both `SURequireSignedFeed = true` and
  `SUVerifyUpdateBeforeExtraction = true`.
- [x] A signed dry run verifies the exported app, staged app, finished DMG, and
      app mounted from that DMG before uploading artifacts.
- [x] A clean v2.1.3 install enables **Check for Updates…** without a fatal
      updater configuration error.
- [x] The public v2.1.3 DMG passes Gatekeeper and the installed app passes
      deep, strict code-signature verification.
- [x] v2.1.3 downloads, verifies, installs, and relaunches into v2.2.0.
