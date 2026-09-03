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

# Preserve the existing feed so Sparkle retains release history. Do not load
# historical DMGs into this invocation: generate_appcast accepts one download
# URL prefix and rewrites every loaded archive with it, which would point old
# archives at the current release tag. Full updates remain available; delta
# generation stays disabled until archives have a shared stable URL layout.
if curl --fail --silent --show-error --location "$FEED_URL" \
    --output "$APPCAST_DIR/appcast.xml"; then
    echo "→ Preserving existing appcast history"
    perl -0pi -e \
        's{https://github\.com/silashsieh/TrailMate/releases/download/v[^/"]+/TrailMate-([0-9]+\.[0-9]+\.[0-9]+)\.dmg}{https://github.com/silashsieh/TrailMate/releases/download/v$1/TrailMate-$1.dmg}g' \
        "$APPCAST_DIR/appcast.xml"
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
    --maximum-deltas 0 \
    "$APPCAST_DIR"

xmllint --noout "$APPCAST_DIR/appcast.xml"
grep -Fq "$RELEASE_DOWNLOAD_ROOT/v$VERSION/$(basename "$DMG_PATH")" \
    "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain the current release archive"
grep -Fq "sparkle:edSignature=" "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain an EdDSA archive signature"
grep -Fq "<!-- sparkle-signatures:" "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast does not contain an EdDSA feed signature"
perl -0ne '
    while (m{https://github\.com/silashsieh/TrailMate/releases/download/v([^/"]+)/TrailMate-([0-9]+\.[0-9]+\.[0-9]+)\.dmg}g) {
        die "Release tag v$1 does not match TrailMate-$2.dmg\n" if $1 ne $2;
        $count++;
    }
    END { die "Generated appcast contains no versioned TrailMate DMG URLs\n" unless $count }
' "$APPCAST_DIR/appcast.xml" \
    || die "Generated appcast contains an invalid release archive URL"

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
