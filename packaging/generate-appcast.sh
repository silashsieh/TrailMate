#!/usr/bin/env bash
# Generate TrailMate's signed Sparkle feed and the GitHub Pages payload.
# Run this only after release.sh has produced a signed and notarized DMG.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
PROJECT="$ROOT/TrailMate.xcodeproj/project.pbxproj"
APPCAST_DIR="$BUILD/appcast"
PAGES_DIR="$BUILD/update-site"
FEED_URL="${SPARKLE_FEED_URL:-https://silashsieh.github.io/TrailMate/appcast.xml}"
RELEASE_DOWNLOAD_ROOT="https://github.com/silashsieh/TrailMate/releases/download"

die() {
    echo "✗ $*" >&2
    exit 1
}

project_setting() {
    local key="$1"
    awk -F' = ' -v key="$key" \
        '$1 ~ key { gsub(/[; ]/, "", $2); print $2; exit }' \
        "$PROJECT"
}

VERSION="${VERSION:-$(project_setting MARKETING_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(project_setting CURRENT_PROJECT_VERSION)}"
DMG_PATH="${DMG_PATH:-$BUILD/TrailMate-$VERSION.dmg}"
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$BUILD/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"

[ -n "$VERSION" ] || die "Could not read MARKETING_VERSION"
[ -n "$BUILD_NUMBER" ] || die "Could not read CURRENT_PROJECT_VERSION"
[ -f "$DMG_PATH" ] || die "Update archive not found: $DMG_PATH"
[ -x "$GENERATE_APPCAST" ] || die "Sparkle generate_appcast tool not found: $GENERATE_APPCAST"
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || die "SPARKLE_ED_PRIVATE_KEY is required"

rm -rf "$APPCAST_DIR" "$PAGES_DIR"
mkdir -p "$APPCAST_DIR" "$PAGES_DIR"

# Preserve the existing feed and full archives so Sparkle can retain history
# and generate deltas. Only enclosure URLs from this repository are trusted.
if curl --fail --silent --show-error --location "$FEED_URL" \
    --output "$APPCAST_DIR/appcast.xml"; then
    while IFS= read -r archive_url; do
        case "$archive_url" in
            "$RELEASE_DOWNLOAD_ROOT"/*/*.dmg) ;;
            *)
                echo "→ Skipping unexpected archive URL from existing appcast"
                continue
                ;;
        esac

        archive_name="$(basename "${archive_url%%\?*}")"
        [ -n "$archive_name" ] || continue
        if [ ! -f "$APPCAST_DIR/$archive_name" ]; then
            echo "→ Downloading prior update archive: $archive_name"
            curl --fail --silent --show-error --location "$archive_url" \
                --output "$APPCAST_DIR/$archive_name"
        fi
    done < <(perl -ne 'while (/url="([^"]+\.dmg(?:\?[^"]*)?)"/g) { print "$1\n" }' \
        "$APPCAST_DIR/appcast.xml")
else
    rm -f "$APPCAST_DIR/appcast.xml"
    echo "→ No existing appcast found; creating the bootstrap feed"
fi

cp "$DMG_PATH" "$APPCAST_DIR/$(basename "$DMG_PATH")"

echo "→ Generating signed Sparkle appcast"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "$RELEASE_DOWNLOAD_ROOT/v$VERSION/" \
    --link "https://github.com/silashsieh/TrailMate/releases/tag/v$VERSION" \
    --versions "$BUILD_NUMBER" \
    --maximum-versions 3 \
    --maximum-deltas 5 \
    "$APPCAST_DIR"

xmllint --noout "$APPCAST_DIR/appcast.xml"
grep -Fq "$RELEASE_DOWNLOAD_ROOT/v$VERSION/$(basename "$DMG_PATH")" \
    "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain the current release archive"
grep -Fq "sparkle:edSignature=" "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain an EdDSA archive signature"
grep -Fq "<!-- sparkle-signatures:" "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain an EdDSA feed signature"

cp "$APPCAST_DIR/appcast.xml" "$PAGES_DIR/appcast.xml"
touch "$PAGES_DIR/.nojekyll"
cat > "$PAGES_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TrailMate Updates</title>
<h1>TrailMate Updates</h1>
<p>The signed Sparkle update feed is available at <a href="appcast.xml">appcast.xml</a>.</p>
<p>Installers and release notes are published on <a href="https://github.com/silashsieh/TrailMate/releases">GitHub Releases</a>.</p>
HTML

echo "✓ Signed appcast: $APPCAST_DIR/appcast.xml"
echo "✓ GitHub Pages payload: $PAGES_DIR"
