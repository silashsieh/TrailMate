#!/usr/bin/env bash
# Build TrailMate.app for Release and pack it into a DMG.
#
# Steps:
#   1. Rebuild PythonResources/ via packaging/build.sh (unless SKIP_PYTHON=1).
#   2. xcodebuild archive (Release, ad-hoc signing — README ships unsigned).
#   3. xcodebuild -exportArchive → build/export/TrailMate.app.
#   4. hdiutil create → build/TrailMate-<version>.dmg with /Applications symlink.
#
# Overrides:
#   VERSION=1.0          # marketing version stamped on the DMG filename + volname
#   SKIP_PYTHON=1        # skip step 1 (reuse existing PythonResources/)
#   SIGN_IDENTITY="-"    # codesign identity; "-" = ad-hoc (default)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/TrailMate.xcarchive"
EXPORT_DIR="$BUILD/export"
STAGE="$BUILD/dmg-stage"

SCHEME="TrailMate"
PROJECT="$ROOT/TrailMate.xcodeproj"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Pull MARKETING_VERSION from the project unless VERSION is overridden.
if [ -z "${VERSION:-}" ]; then
    VERSION="$(xcodebuild -project "$PROJECT" -showBuildSettings -scheme "$SCHEME" \
        -configuration Release 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
    VERSION="${VERSION:-1.0}"
fi

DMG="$BUILD/TrailMate-$VERSION.dmg"

# 1. Bundled Python (skip if already built and SKIP_PYTHON=1).
if [ "${SKIP_PYTHON:-0}" = "1" ]; then
    echo "→ Skipping python bundle rebuild (SKIP_PYTHON=1)"
    [ -d "$ROOT/PythonResources/python" ] || {
        echo "✗ PythonResources/ missing — run without SKIP_PYTHON=1 first"
        exit 1
    }
else
    echo "→ Building PythonResources/"
    "$ROOT/packaging/build.sh"
fi

# 2. Archive.
mkdir -p "$BUILD"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE" "$DMG"

echo "→ Archiving Release build"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    archive

# 3. Export the .app. Manual signing + CODE_SIGNING_ALLOWED=NO above leaves
# the archive ad-hoc-signed; we just need a copy-only export here.
EXPORT_PLIST="$BUILD/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>mac-application</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

echo "→ Exporting .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"

APP="$EXPORT_DIR/TrailMate.app"
[ -d "$APP" ] || { echo "✗ Export did not produce $APP"; exit 1; }

# 4. Stage + create DMG. /Applications symlink gives the standard drag-to-install UX.
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

echo
echo "✓ DMG ready: $DMG"
du -sh "$DMG"
