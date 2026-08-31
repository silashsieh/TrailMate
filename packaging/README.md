# Release packaging and signing

`packaging/build.sh` produces `PythonResources/`, a self-contained CPython
runtime plus `pymobiledevice3`. `packaging/release.sh` archives the macOS app,
exports it, verifies its signature, and packages it as
`build/TrailMate-<version>.dmg`.

Sparkle is intentionally not part of this pipeline yet. Developer ID signing
and notarization must be working first.

## Prerequisites

- macOS on Apple Silicon with Xcode 26 and its command-line tools.
- About 300 MB free for the Python bundle and build output.
- For public GitHub releases: an active Apple Developer Program membership and
  a `Developer ID Application` certificate exported with its private key as a
  password-protected `.p12`.
- For notarization: a **team** App Store Connect API key (`.p8`), its key ID,
  and the team's issuer ID. App Store Connect is only the credential issuer for
  Apple's notary service here; TrailMate is not submitted to the App Store.

## Build the bundled Python runtime

```sh
./packaging/build.sh
```

The output is `PythonResources/` (about 210 MB). The
python-build-standalone archive is cached under `packaging/.cache/`.

To bump Python deliberately:

```sh
PBS_TAG=20260510 PY_VERSION=3.13.13 ./packaging/build.sh
```

Find available builds in the
[python-build-standalone releases](https://github.com/astral-sh/python-build-standalone/releases).

## Xcode signing configuration

The project is already wired for the bundled runtime:

- `PythonResources/` is copied into the app's Resources directory.
- Hardened Runtime is enabled for Debug and Release.
- `TrailMate.entitlements` contains no runtime exceptions. CPython does not
  require the JIT or unsigned-executable-memory entitlements in this app.
- The `Re-sign embedded Python binaries` build phase signs every Python
  executable, `.dylib`, and `.so` with the host app's identity. Developer ID
  builds use secure timestamps; ad-hoc builds use `--timestamp=none`. A nested
  signing failure stops the build.
- Xcode's user-script sandbox is disabled for this project because the phase
  must discover and rewrite a dynamic set of copied files under
  `CODESIGNING_FOLDER_PATH`. This affects build-script access only; the shipped
  app still uses Hardened Runtime and keeps its runtime entitlements minimal.
- Debug uses `Apple Development`; Release defaults to
  `Developer ID Application`. `release.sh` passes the exact certificate hash
  and team explicitly so CI cannot choose another similarly named identity.

## Credential-free local build

Ordinary source and pull-request builds do not need production credentials:

```sh
SKIP_PYTHON=1 SIGNING_MODE=ad-hoc ./packaging/release.sh
```

This is an explicit fallback for build verification, not the public release
path.

## Developer ID build from the owner's certificate

The Developer ID identity is currently installed and usable in the Mac's
keychain, so the shortest validated local path is:

```sh
SKIP_PYTHON=1 SIGNING_MODE=developer-id NOTARIZE=0 ./packaging/release.sh
```

The script selects a valid `Developer ID Application` identity for team
`M8M8MCWC7X`. To validate the portable path used by CI instead, supply the
exported certificate explicitly.

The current certificate bundle is outside the repository at
`/Users/harry/Documents/cert/Certificates.p12`. The release script imports it
into a random, temporary keychain and deletes that keychain on exit. It never
modifies the login keychain.

```sh
SKIP_PYTHON=1 \
SIGNING_MODE=developer-id \
CERTIFICATE_P12_PATH=/Users/harry/Documents/cert/Certificates.p12 \
NOTARIZE=0 \
./packaging/release.sh
```

When run in a terminal, the script prompts for the `.p12` password without
echoing it. Do not put the password directly in shell history. For local
automation, set `CERTIFICATE_P12_PASSWORD_FILE` to a mode-`600` file containing
only the password.

The script rejects a certificate that is not a usable Developer ID Application
identity or does not belong to `APPLE_TEAM_ID` (defaulted from the Xcode
project). It then verifies the exported app and DMG with `codesign`.

## Notarize the DMG

After obtaining the App Store Connect team issuer ID, enable the second stage:

```sh
SKIP_PYTHON=1 \
SIGNING_MODE=developer-id \
CERTIFICATE_P12_PATH=/Users/harry/Documents/cert/Certificates.p12 \
NOTARIZE=1 \
NOTARY_KEY_PATH=/Users/harry/Documents/cert/AuthKey_MFY89S6CBP.p8 \
APPLE_API_KEY_ID=MFY89S6CBP \
APPLE_API_ISSUER_ID=<team-issuer-uuid> \
./packaging/release.sh
```

The script submits with `notarytool`, waits for acceptance, staples the ticket,
and validates the result with `stapler` and `spctl`. An individual API key is
not supported by `notarytool`; use a team key.

Protect the private files on disk:

```sh
chmod 600 /Users/harry/Documents/cert/Certificates.p12
chmod 600 /Users/harry/Documents/cert/AuthKey_MFY89S6CBP.p8
```

## GitHub Actions release environment

The `release.yml` workflow runs only on GitHub's managed `macos-26` arm64
runner. It uses a protected environment named `release`, recreates the `.p12`
and `.p8` under `RUNNER_TEMP`, and imports the certificate into the same
temporary-keychain path as local builds. No certificate or private key belongs
in git, an artifact, a cache, or a workflow log.

GitHub currently lists the `macos-26` arm64 image as public preview in its
[hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Create the environment and values with `gh`:

```sh
gh api --method PUT repos/{owner}/{repo}/environments/release

base64 -i /Users/harry/Documents/cert/Certificates.p12 \
  | gh secret set MACOS_CERTIFICATE_P12_BASE64 --env release
gh secret set MACOS_CERTIFICATE_PASSWORD --env release
gh secret set APPLE_NOTARY_KEY_P8 --env release \
  < /Users/harry/Documents/cert/AuthKey_MFY89S6CBP.p8

gh variable set APPLE_TEAM_ID --env release --body M8M8MCWC7X
gh variable set APPLE_NOTARY_KEY_ID --env release --body MFY89S6CBP
gh variable set APPLE_NOTARY_ISSUER_ID --env release --body <team-issuer-uuid>
```

`gh secret set MACOS_CERTIFICATE_PASSWORD` prompts securely when no input is
piped. First prove that the runner can import the `.p12` and reproduce the
Developer ID signature. Signing-only is the safe default: it neither requires
the notary values nor creates a GitHub release.

```sh
gh workflow run release.yml --ref main \
  -f signing_only=true
gh run watch
```

After the team issuer ID is configured, request the full release explicitly:

```sh
gh workflow run release.yml --ref main \
  -f signing_only=false
```

Configure required reviewers for the `release` environment if the repository
plan supports them, and dispatch full releases only from a reviewed `main`.
The full path fails closed when a secret, variable, signature, notarization, or
stapling step is missing or invalid; it will not publish an ad-hoc or
unnotarized fallback.

## Primary references

- [Apple: Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub: Install an Apple certificate on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub: Deployment environments and protected secrets](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
