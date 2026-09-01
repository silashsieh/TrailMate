#!/usr/bin/env bash
# Build TrailMate.app for Release and pack it into a DMG.
#
# The default remains ad-hoc signing so ordinary CI/build verification does not
# need production credentials. Developer ID mode is selected automatically when
# CERTIFICATE_P12_PATH or a non-ad-hoc SIGN_IDENTITY is provided.
#
# Common overrides:
#   VERSION=2.2.0                    DMG filename and volume version
#   SKIP_PYTHON=1                    reuse the existing PythonResources/
#   SIGNING_MODE=ad-hoc              force the credential-free build path
#   SIGNING_MODE=developer-id        require Developer ID signing
#   SIGN_IDENTITY="Developer ID Application: ..."  use an installed identity
#   APPLE_TEAM_ID=M8M8MCWC7X         defaults to DEVELOPMENT_TEAM in Xcode
#
# Importing a .p12 for this invocation only:
#   CERTIFICATE_P12_PATH=/path/to/cert.p12
#   CERTIFICATE_P12_PASSWORD_FILE=/secure/path/to/password
#   # or CERTIFICATE_P12_PASSWORD in non-interactive CI
#
# Optional notarization (Developer ID mode only):
#   NOTARIZE=1
#   NOTARY_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
#   APPLE_API_KEY_ID=XXXXXXXXXX
#   APPLE_API_ISSUER_ID=00000000-0000-0000-0000-000000000000

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/TrailMate.xcarchive"
EXPORT_DIR="$BUILD/export"
EXPORT_PLIST="$BUILD/ExportOptions.plist"
STAGE="$BUILD/dmg-stage"
DEVELOPER_ID_INTERMEDIATE="$ROOT/packaging/certificates/DeveloperIDG2CA.pem"

SCHEME="TrailMate"
PROJECT="$ROOT/TrailMate.xcodeproj"

SIGNING_MODE="${SIGNING_MODE:-auto}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
CERTIFICATE_P12_PATH="${CERTIFICATE_P12_PATH:-}"
CERTIFICATE_P12_PASSWORD_FILE="${CERTIFICATE_P12_PASSWORD_FILE:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

NOTARIZE="${NOTARIZE:-auto}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER_ID="${APPLE_API_ISSUER_ID:-}"

TEMP_KEYCHAIN=""
SIGNING_TEMP_DIR=""
ORIGINAL_KEYCHAINS=()
EXPORT_METHOD=""

die() {
    echo "✗ $*" >&2
    exit 1
}

cleanup_signing_keychain() {
    if [ -n "$TEMP_KEYCHAIN" ]; then
        if [ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]; then
            security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
        fi
        security delete-keychain "$TEMP_KEYCHAIN" >/dev/null 2>&1 || true
    fi
    if [ -n "$SIGNING_TEMP_DIR" ] && [ -d "$SIGNING_TEMP_DIR" ]; then
        rm -rf "$SIGNING_TEMP_DIR"
    fi
}

trap cleanup_signing_keychain EXIT

warn_if_private_file_is_exposed() {
    local path="$1"
    local label="$2"
    local mode

    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    if [ -n "$mode" ] && [ $((8#$mode & 8#077)) -ne 0 ]; then
        echo "⚠ $label is readable by group or other users (mode $mode); use chmod 600."
    fi
}

read_p12_password() {
    if [ -n "$CERTIFICATE_P12_PASSWORD_FILE" ]; then
        [ -f "$CERTIFICATE_P12_PASSWORD_FILE" ] || die "Certificate password file not found: $CERTIFICATE_P12_PASSWORD_FILE"
        IFS= read -r CERTIFICATE_P12_PASSWORD < "$CERTIFICATE_P12_PASSWORD_FILE" || true
    elif [ "${CERTIFICATE_P12_PASSWORD+x}" = x ]; then
        : # Already supplied by the environment (the CI path).
    elif [ -r /dev/tty ]; then
        IFS= read -r -s -p "Developer ID .p12 password: " CERTIFICATE_P12_PASSWORD < /dev/tty
        echo > /dev/tty
    else
        die "Set CERTIFICATE_P12_PASSWORD_FILE or CERTIFICATE_P12_PASSWORD for a non-interactive build"
    fi
}

import_developer_id_certificate() {
    local keychain_password
    local identity_line
    local imported_identity
    local keychain

    [ -f "$CERTIFICATE_P12_PATH" ] || die "Certificate not found: $CERTIFICATE_P12_PATH"
    warn_if_private_file_is_exposed "$CERTIFICATE_P12_PATH" "Developer ID .p12"
    read_p12_password

    SIGNING_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trailmate-signing.XXXXXX")"
    TEMP_KEYCHAIN="$SIGNING_TEMP_DIR/signing.keychain-db"
    keychain_password="$(uuidgen)-$(uuidgen)"

    while IFS= read -r keychain; do
        [ -n "$keychain" ] && ORIGINAL_KEYCHAINS+=("$keychain")
    done < <(security list-keychains -d user \
        | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')

    security create-keychain -p "$keychain_password" "$TEMP_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"
    security unlock-keychain -p "$keychain_password" "$TEMP_KEYCHAIN"
    [ -f "$DEVELOPER_ID_INTERMEDIATE" ] \
        || die "Developer ID intermediate certificate not found: $DEVELOPER_ID_INTERMEDIATE"
    security import "$DEVELOPER_ID_INTERMEDIATE" \
        -t cert -f pemseq \
        -k "$TEMP_KEYCHAIN" >/dev/null
    security import "$CERTIFICATE_P12_PATH" \
        -P "$CERTIFICATE_P12_PASSWORD" \
        -t agg -f pkcs12 \
        -T /usr/bin/codesign \
        -k "$TEMP_KEYCHAIN" >/dev/null
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$keychain_password" \
        "$TEMP_KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$TEMP_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"

    identity_line="$(security find-identity -v -p codesigning "$TEMP_KEYCHAIN" \
        | awk '/Developer ID Application:/ { print; exit }')"
    imported_identity="$(awk '{ print $2 }' <<< "$identity_line")"
    [ -n "$imported_identity" ] || die "The .p12 contains no usable Developer ID Application identity"

    if [[ "$identity_line" != *"($APPLE_TEAM_ID)"* ]]; then
        die "The imported Developer ID identity does not belong to team $APPLE_TEAM_ID"
    fi

    # Use the certificate hash so another similarly named identity cannot be
    # selected accidentally from a persistent keychain.
    SIGN_IDENTITY="$imported_identity"
    unset CERTIFICATE_P12_PASSWORD
    echo "→ Imported Developer ID identity into an ephemeral keychain"
}

select_installed_developer_id_identity() {
    local identities
    local identity_line

    identities="$(security find-identity -v -p codesigning)"
    if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "Developer ID Application" ]; then
        identity_line="$(awk '/Developer ID Application:/ { print; exit }' <<< "$identities")"
        SIGN_IDENTITY="$(awk '{ print $2 }' <<< "$identity_line")"
    else
        identity_line="$(grep -F "$SIGN_IDENTITY" <<< "$identities" | head -1 || true)"
    fi

    [ -n "$SIGN_IDENTITY" ] && [ -n "$identity_line" ] \
        || die "No usable Developer ID Application identity is installed"
    [[ "$identity_line" == *"Developer ID Application:"* ]] \
        || die "SIGN_IDENTITY is not a Developer ID Application identity"
    [[ "$identity_line" == *"($APPLE_TEAM_ID)"* ]] \
        || die "The selected Developer ID identity does not belong to team $APPLE_TEAM_ID"
}

# Read the project values once. These settings do not access signing credentials.
BUILD_SETTINGS="$(xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -showBuildSettings)"

if [ -z "${VERSION:-}" ]; then
    VERSION="$(awk -F' = ' '/ MARKETING_VERSION / { print $2; exit }' <<< "$BUILD_SETTINGS")"
    [ -n "$VERSION" ] || die "Could not read MARKETING_VERSION from the Xcode project"
fi

if [ -z "$APPLE_TEAM_ID" ]; then
    APPLE_TEAM_ID="$(awk -F' = ' '/ DEVELOPMENT_TEAM / { print $2; exit }' <<< "$BUILD_SETTINGS")"
fi

case "$SIGNING_MODE" in
    auto)
        if [ -n "$CERTIFICATE_P12_PATH" ] || { [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; }; then
            SIGNING_MODE="developer-id"
        else
            SIGNING_MODE="ad-hoc"
        fi
        ;;
    ad-hoc|developer-id) ;;
    *) die "SIGNING_MODE must be auto, ad-hoc, or developer-id" ;;
esac

if [ "$SIGNING_MODE" = "developer-id" ]; then
    [ -n "$APPLE_TEAM_ID" ] || die "APPLE_TEAM_ID is required for Developer ID signing"
    if [ -n "$CERTIFICATE_P12_PATH" ]; then
        import_developer_id_certificate
    else
        select_installed_developer_id_identity
    fi
else
    SIGN_IDENTITY="-"
fi

case "$NOTARIZE" in
    auto)
        if [ "$SIGNING_MODE" = "developer-id" ] \
            && [ -n "$NOTARY_KEY_PATH" ] \
            && [ -n "$APPLE_API_KEY_ID" ] \
            && [ -n "$APPLE_API_ISSUER_ID" ]; then
            NOTARIZE=1
        else
            NOTARIZE=0
        fi
        ;;
    0|1) ;;
    *) die "NOTARIZE must be auto, 0, or 1" ;;
esac

if [ "$NOTARIZE" = 1 ]; then
    [ "$SIGNING_MODE" = "developer-id" ] || die "Notarization requires Developer ID signing"
    [ -f "$NOTARY_KEY_PATH" ] || die "Notary API key not found: $NOTARY_KEY_PATH"
    [ -n "$APPLE_API_KEY_ID" ] || die "APPLE_API_KEY_ID is required for notarization"
    [ -n "$APPLE_API_ISSUER_ID" ] || die "APPLE_API_ISSUER_ID is required for notarization"
    warn_if_private_file_is_exposed "$NOTARY_KEY_PATH" "App Store Connect API key"
fi

DMG="$BUILD/TrailMate-$VERSION.dmg"

# 1. Bundled Python (skip if already built and SKIP_PYTHON=1).
if [ "${SKIP_PYTHON:-0}" = 1 ]; then
    echo "→ Skipping python bundle rebuild (SKIP_PYTHON=1)"
    [ -d "$ROOT/PythonResources/python" ] \
        || die "PythonResources/ missing — run without SKIP_PYTHON=1 first"
else
    echo "→ Building PythonResources/"
    "$ROOT/packaging/build.sh"
fi

# 2. Archive.
mkdir -p "$BUILD"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE" "$DMG"
rm -f "$EXPORT_PLIST"

echo "→ Archiving Release build ($SIGNING_MODE)"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        archive
else
    # The credential-free path is intentionally kept for PR/build CI.
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        archive
fi

# 3. Export the app using a method that matches the archive's signing mode.
if [ "$SIGNING_MODE" = "developer-id" ]; then
    EXPORT_METHOD="developer-id"
else
    EXPORT_METHOD="mac-application"
fi
plutil -create xml1 "$EXPORT_PLIST"
plutil -insert method -string "$EXPORT_METHOD" "$EXPORT_PLIST"
plutil -insert signingStyle -string manual "$EXPORT_PLIST"
if [ "$SIGNING_MODE" = "developer-id" ]; then
    plutil -insert signingCertificate -string "$SIGN_IDENTITY" "$EXPORT_PLIST"
    plutil -insert teamID -string "$APPLE_TEAM_ID" "$EXPORT_PLIST"
fi

echo "→ Exporting .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP="$EXPORT_DIR/TrailMate.app"
[ -d "$APP" ] || die "Export did not produce $APP"

if [ "$SIGNING_MODE" = "developer-id" ]; then
    echo "→ Verifying Developer ID signatures"
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign -d --verbose=4 "$APP" 2>&1 \
        | awk '/^Authority=|^TeamIdentifier=|^Runtime Version=/'
fi

# 4. Stage and create the drag-to-install DMG.
echo "→ Staging DMG contents"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "→ Creating $DMG"
hdiutil create \
    -volname "TrailMate $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format ULFO \
    "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

if [ "$SIGNING_MODE" = "developer-id" ]; then
    echo "→ Signing DMG"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

if [ "$NOTARIZE" = 1 ]; then
    echo "→ Submitting DMG to Apple's notary service"
    xcrun notarytool submit "$DMG" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait --timeout 1h

    echo "→ Stapling notarization ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=4 \
        "$DMG"
fi

echo
if [ "$SIGNING_MODE" = "developer-id" ] && [ "$NOTARIZE" = 1 ]; then
    echo "✓ Developer ID signed and notarized DMG ready: $DMG"
elif [ "$SIGNING_MODE" = "developer-id" ]; then
    echo "✓ Developer ID signed DMG ready (not notarized): $DMG"
else
    echo "✓ Ad-hoc DMG ready: $DMG"
fi
du -sh "$DMG"
