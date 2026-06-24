---
type: epic
id: 038
title: In-app auto-update (Sparkle, EdDSA-signed, no paid account)
status: open
milestone: v2.2.0
issue: 39
opened: 2026-06-24
shipped:
tags: [distribution, packaging, ux]
---

# Epic 038: In-app auto-update (Sparkle, EdDSA-signed, no paid account)

> Feature (#39): the app checks for and installs new versions itself, instead of the user
> re-downloading the DMG by hand. Builds on the existing release pipeline (`packaging/release.sh`
> + the `release.yml` workflow that already uploads a DMG to a `v<version>` GitHub release) and
> the Settings home from [[017-settings-window]]; a step toward the "dependability" /
> production-hardening long-term goal in [[scope]].

## Why

Updates today are fully manual: the user must notice a release, re-download the DMG, and drag it
over the old app. For a tool meant for long, unattended sessions that friction means users run
stale builds. #39 asks for in-app "check and install a new version."

The whole design is decided by one standing constraint: **no paid Apple Developer account**, so
the app is **ad-hoc-signed and not notarized** (`packaging/release.sh` ships `SIGN_IDENTITY="-"`,
`CODE_SIGNING_ALLOWED=NO`). Almost all macOS auto-update guidance assumes Developer ID +
notarization; that path is out. What makes auto-update viable anyway is the **quarantine
attribute**, not code signing:

- macOS fires Gatekeeper's "Apple could not verify this app…" prompt off the `com.apple.quarantine`
  xattr that a *browser* stamps on downloads. An update **downloaded and installed by the running
  app** carries no quarantine xattr, so Gatekeeper's first-launch assessment does **not** re-fire on
  it — an app with no quarantine attribute is allowed to run even when only ad-hoc-signed. This is
  exactly how Sparkle delivers updates to non-notarized apps.
- Update *authenticity* is verified by **Sparkle's EdDSA (ed25519) signature** on the archive, which
  works **independently of Apple's Developer ID program** — no paid account needed. `generate_keys`
  makes the keypair (private key in the login Keychain, public key in `Info.plist`); `generate_appcast`
  signs each archive.

So the model is: **the user endures the one-time Gatekeeper dance on the DMG once per machine; every
update after that installs and launches with no prompt.** Stated plainly so expectations are set —
this epic makes *updates* smooth, it does **not** make *first install* smooth.

Our setup is favorable for Sparkle once notarization is off the table:

- **Not sandboxed** (entitlements are only `allow-jit` + `allow-unsigned-executable-memory`), which
  avoids Sparkle 2's sandboxed-app XPC-service / `-spks`/`-spki` mach-lookup-entitlement dance.
- **We already increment `CFBundleVersion`** (`CURRENT_PROJECT_VERSION`, currently `8`) — the value
  Sparkle uses to decide an update is available.
- **Delta updates matter here.** The bundled CPython + pymobiledevice3 (~210 MB) dominate the bundle
  and rarely change; `generate_appcast` emits binary deltas so a normal update ships only the changed
  Swift binary, not the whole bundle.

## Goal

From a running TrailMate the user can check for and install a newer version without leaving the app:
a "Check for Updates…" action, an automatic background check (opt-in, surfaced in Settings), a
signed download verified before install, and a relaunch into the new build — with no Gatekeeper
prompt on the updated build. Releases are produced by the existing pipeline with one added step that
signs the archive and publishes the appcast.

## Out of scope

- **Notarization / Developer ID signing.** It's the only thing that would smooth *first* install, but
  it needs the paid account this project doesn't have ([[scope]] "build from source, run unsigned").
  Not in this epic.
- **Fixing the first-launch Gatekeeper experience.** Unchanged by self-update (see Why). At most we
  *document* the current macOS 26 steps; we don't try to defeat them.
- **Independently updating the bundled Python** (partial/component updates). Updates replace the whole
  `.app`; a Python/pmd3 bump rides along in the next full release.
- **MAS / any non-goal distribution channel.**

## Stories

- [ ] Add Sparkle 2 via SPM; wire the SwiftUI-native path — `SPUUpdater` (logic) + `SPUStandardUserDriver`
      (UI), not `SPUStandardUpdaterController` — and a "Check for Updates…" menu/Settings action.
- [ ] Generate the EdDSA keypair once (`generate_keys`); add `SUFeedURL` + `SUPublicEDKey` to `Info.plist`.
- [ ] Add `com.apple.security.cs.disable-library-validation` to `TrailMate.entitlements` and confirm
      Sparkle.framework loads under the ad-hoc Hardened Runtime build (Library Validation otherwise
      blocks loading an ad-hoc-signed framework).
- [ ] Extend `packaging/release.sh` to run `generate_appcast` (signs the DMG, builds deltas) and
      hook it into the existing `release.yml` workflow so a tagged release publishes the DMG +
      `appcast.xml` to a stable feed URL.
- [ ] Localize the updater UI strings (en + zh-Hant) per [[015-localization]]; expose the auto-check
      toggle + cadence in the Settings window ([[017-settings-window]]).
- [ ] Document the one-time macOS 26 first-run Gatekeeper steps (System Settings ▸ Privacy & Security
      ▸ "Open Anyway", authenticate, relaunch) in `docs/quick-start.md`.

## Open questions

- **Where does `appcast.xml` live so the feed URL is stable?** GitHub release *asset* URLs are
  per-tag; Sparkle needs one fixed `SUFeedURL`. Candidates: GitHub Pages, or a fixed-name asset on a
  dedicated long-lived release. Decide before wiring `SUFeedURL`.
- **Delta health across interpreter bumps.** A `PBS_TAG`/`PY_VERSION` bump changes ~210 MB and
  invalidates the delta, forcing one full download for that release. Acceptable (rare), but confirm
  `generate_appcast` degrades to a full update cleanly rather than shipping a broken delta.
- **Auto-check default + cadence.** Opt-in vs on-by-default, and check interval. Lean opt-in/HIG-
  standard given the single-user, privacy-conscious stance.
- **Does the re-signed embedded-Python step interact with Sparkle's installer?** The new bundle
  arrives already ad-hoc-signed from CI; verify Sparkle's swap doesn't disturb those signatures.

## Decisions made along the way

- **EdDSA over Developer ID for update trust.** No paid account, so Apple-signature continuity isn't
  available; ed25519 on the archive is the verification path and needs no Apple enrollment.
- **Accept that first-run Gatekeeper is unchanged.** Self-update is justified by smooth *subsequent*
  updates (quarantine-free install), not by fixing first launch — which only notarization would.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] "Check for Updates…" finds a newer published build, downloads it, verifies the EdDSA signature,
      installs, and relaunches into the new version.
- [ ] The updated build launches with **no** Gatekeeper prompt (quarantine-free install verified on
      a clean macOS 26 machine/VM).
- [ ] A normal release ships a **delta** (not the full ~210 MB) when only the Swift binary changed.
- [ ] Sparkle.framework loads in the ad-hoc Hardened Runtime build (no Library Validation failure).
- [ ] Updater UI is localized (en + zh-Hant); auto-check toggle present in Settings.
- [ ] `release.sh` + `release.yml` publish the DMG and a signed `appcast.xml` to the stable feed URL.
