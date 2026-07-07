#!/bin/zsh
# Builds, signs, notarizes, and packages Bloom into a shareable DMG, then
# generates a Sparkle appcast and publishes everything as a GitHub release.
#
# One-time setup:
#   xcrun notarytool store-credentials bloom-notary \
#       --apple-id <apple-id-email> --team-id HFXABN57R2
#   Sparkle EdDSA private key lives in the login keychain ("Private key for
#   signing Sparkle updates"); generate_appcast reads it automatically.
#
# Usage: script/release.sh <version> [--skip-notarize]
#   e.g. script/release.sh 0.4.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: script/release.sh <version> [--skip-notarize]}"
IDENTITY="Developer ID Application: Aman Chaudhary (HFXABN57R2)"
PROFILE="bloom-notary"
REPO="amanfromsolan/bloom"
BUILD_DIR="build/release"
APP="$BUILD_DIR/Build/Products/Release/Bloom.app"
DMG="$HOME/Downloads/Bloom-$VERSION.dmg"

# Sparkle compares CFBundleVersion, so it must increase monotonically with
# each release: 0.4.0 -> 400, 1.2.3 -> 10203.
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUM=$((MAJOR * 10000 + MINOR * 100 + PATCH))

echo "==> Building Release v$VERSION (build $BUILD_NUM) with hardened runtime"
xcodebuild -project Bloom.xcodeproj -scheme Bloom -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM=HFXABN57R2 \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    build | grep -E "error|warning: Signing|BUILD" || true

codesign --verify --deep --strict "$APP"
echo "==> Signed as: $(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1)"

echo "==> Packaging DMG"
STAGE="$(mktemp -d)/Bloom"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Bloom" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "${2:-}" == "--skip-notarize" ]]; then
    echo "==> Skipped notarization. DMG at $DMG (unnotarized, not published)."
    exit 0
fi

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"

echo "==> Generating Sparkle appcast"
SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="$(mktemp -d)"
cp "$DMG" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --maximum-deltas 0

echo "==> Publishing GitHub release v$VERSION"
gh release create "v$VERSION" \
    "$DMG" \
    "$APPCAST_DIR/appcast.xml" \
    --repo "$REPO" \
    --title "Bloom v$VERSION" \
    --generate-notes

echo "==> Done: https://github.com/$REPO/releases/tag/v$VERSION"
