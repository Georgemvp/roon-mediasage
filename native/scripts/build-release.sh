#!/usr/bin/env bash
# Build a signed, notarized RoonSage.app + DMG.
#
# Usage (local):
#   cd native
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   APPLE_ID="you@example.com" \
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   APPLE_TEAM_ID="ABCDE12345" \
#   ./scripts/build-release.sh [version]
#
# In GitHub Actions the env vars are injected from secrets; the workflow
# also handles certificate import before calling this script.
set -euo pipefail

# Match the app's own `vX.Y.Z` tags only — an unfiltered `git describe` picks
# up the interleaved `analyzer-v*` / `ios-v*` tags and stamps the wrong version.
VERSION="${1:-$(git describe --tags --abbrev=0 --match='v[0-9]*' 2>/dev/null || echo "0.0.0")}"
VERSION="${VERSION#v}"   # strip leading 'v'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$MACOS_DIR/RoonSage"
ENTITLEMENTS="$MACOS_DIR/Entitlements.plist"
OUTPUT_DIR="$MACOS_DIR/build"

APP_NAME="RoonSage"
BUNDLE_ID="com.roonsage.native"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "▶ Building $APP_NAME $VERSION"
echo ""

# ── 1. Build release binary ───────────────────────────────────────────────────
echo "── Step 1: swift build -c release"
(cd "$PACKAGE_DIR" && swift build -c release --product RoonSage 2>&1)
BINARY="$PACKAGE_DIR/.build/release/RoonSage"

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
echo "── Step 2: assemble .app bundle"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Copy SwiftPM resource bundles (e.g. RoonSage_RoonSageUI.bundle holding the
# Localizable.strings catalogues). Without these, `Bundle.module` fatalErrors at
# launch — the app crashes the instant a localized string (LS/LT) is resolved.
# They sit next to the built binary in .build/release/.
BUILD_DIR="$(dirname "$BINARY")"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
    echo "   bundling $(basename "$bundle")"
    cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done
shopt -u nullglob

# Patch version into Info.plist (robust: rewrite the value after the
# CFBundleShortVersionString/CFBundleVersion keys, whatever it currently is —
# a magic-placeholder sed silently stamps nothing when the template drifts).
awk -v ver="$VERSION" '
  /<key>CFBundleShortVersionString<\/key>/ { print; getline; sub(/<string>[^<]*<\/string>/, "<string>" ver "</string>"); print; next }
  /<key>CFBundleVersion<\/key>/            { print; getline; sub(/<string>[^<]*<\/string>/, "<string>" ver "</string>"); print; next }
  { print }
' "$PACKAGE_DIR/Sources/RoonSage/Info.plist" > "$APP_PATH/Contents/Info.plist"

# App icon (optional — add RoonSage.icns to native/assets/ to include it)
ICON="$MACOS_DIR/assets/RoonSage.icns"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# ── 3. Code sign ─────────────────────────────────────────────────────────────
echo "── Step 3: codesign"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "   SIGN_IDENTITY not set — using ad-hoc signing (local testing only)"
    codesign --deep --force --verbose --sign - "$APP_PATH"
else
    codesign --deep --force --verbose \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$APP_PATH"
fi

# ── 4. Notarize (skipped for ad-hoc) ─────────────────────────────────────────
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "── Step 4: notarize"
    ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait \
        --timeout 90m

    rm "$ZIP_PATH"
    xcrun stapler staple "$APP_PATH"
    echo "   ✓ Notarized and stapled"
else
    echo "── Step 4: skipping notarization (APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID not set)"
fi

# ── 5. Create DMG ─────────────────────────────────────────────────────────────
echo "── Step 5: create DMG"
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# `hdiutil create` attaches a shadow volume while it builds the image, and on a
# CI runner something else can still be holding the freshly-stapled bundle (mds
# indexing it, or a leftover attached device) — which surfaces as
# "hdiutil: create failed - Resource busy" and kills the release. Seen on
# v1.10.228 (2026-08-10); the identical commit produced a DMG on re-run, so it's
# timing, not content. Retry with a short backoff and detach any stale volume of
# ours first, rather than losing a whole release to it.
for attempt in 1 2 3; do
    if hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH"; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "   ✗ hdiutil create failed after 3 attempts" >&2
        rm -rf "$STAGING"
        exit 1
    fi
    echo "   ⚠ hdiutil create failed (attempt $attempt/3) — detaching stale volumes and retrying"
    hdiutil detach "/Volumes/$APP_NAME $VERSION" -force 2>/dev/null || true
    sleep $((attempt * 5))
done

rm -rf "$STAGING"

# Sign the DMG itself (required for notarization of the DMG).
#
# `--timestamp` calls Apple's timestamp service, and THIS call is the one that
# gets refused: it lands right after signing the .app (also timestamped) and a
# full notarytool round-trip, so it is the third request to Apple in a couple of
# minutes and gets throttled with "The timestamp service is not available".
# Failed twice in a row on v1.10.263 (2026-08-22) while step 3 signed the .app
# fine both times and notarization came back Accepted — so it is rate limiting,
# not a broken certificate or an outage. Retry with a growing pause rather than
# losing an otherwise complete release; same shape as the hdiutil retry above,
# but with a longer backoff because a throttle window is seconds, not
# milliseconds.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    for attempt in 1 2 3 4 5; do
        if codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"; then
            break
        fi
        if [[ $attempt -eq 5 ]]; then
            echo "   ✗ DMG codesign failed after 5 attempts" >&2
            exit 1
        fi
        echo "   ⚠ DMG codesign failed (attempt $attempt/5) — waiting for the timestamp service"
        sleep $((attempt * 15))
    done
fi

echo ""
echo "✓ Done: $DMG_PATH"
ls -lh "$DMG_PATH"
