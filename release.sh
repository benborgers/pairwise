#!/bin/bash
# Release a new version of Pairwise with Sparkle auto-updates.
#
#   ./release.sh 1.1
#
# Requires:
#   - A "Developer ID Application" certificate in the keychain.
#   - Notarization credentials stored once via:
#       xcrun notarytool store-credentials pairwise-notary \
#         --apple-id benborgers@hey.com --team-id <TEAMID>
#   - The Sparkle EdDSA private key in the login keychain (generate_keys).
#
# Ships a DMG rather than a zip: zips of the app were mangled by Archive
# Utility (xattrs on Sparkle's symlinks materialized as ._* AppleDouble files
# inside the framework, which Gatekeeper rejects as unsealed contents). A DMG
# needs no extraction and gives users the drag-to-Applications flow, which
# also clears quarantine properly so Sparkle isn't blocked by app
# translocation. Sparkle 2 installs updates from DMGs natively.
#
# Steps: build + sign → dmg → notarize + staple → sign update → add appcast
# entry → create GitHub release → commit & push appcast.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pairwise-notary}"
REPO="benborgers/pairwise"
TAG="v$VERSION"
DMG="build/Pairwise-$VERSION.dmg"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
[[ -n "$IDENTITY" ]] \
  || { echo "error: no Developer ID Application identity in keychain"; exit 1; }

VERSION="$VERSION" ./build.sh

echo "Creating DMG…"
STAGING=build/dmg-staging
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Pairwise.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Pairwise" -srcfolder "$STAGING" -format UDZO "$DMG"
rm -rf "$STAGING"
codesign -f --timestamp -s "$IDENTITY" "$DMG"

echo "Notarizing…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "Signing update for Sparkle…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG" | tr -d '\n')  # sparkle:edSignature="…" length="…"

URL="https://github.com/$REPO/releases/download/$TAG/Pairwise-$VERSION.dmg"
PUBDATE=$(date -R)
ITEM="    <item>\\
      <title>$VERSION</title>\\
      <pubDate>$PUBDATE</pubDate>\\
      <sparkle:version>$VERSION</sparkle:version>\\
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>\\
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\\
      <enclosure url=\"$URL\" $SIGNATURE type=\"application/octet-stream\"/>\\
    </item>"
sed -i '' "s|    <!-- releases -->|    <!-- releases -->\\
$ITEM|" appcast.xml

echo "Creating GitHub release ${TAG}..."
gh release create "$TAG" "$DMG" --repo "$REPO" --title "$VERSION" --notes ""

git add appcast.xml
git commit -m "Release $VERSION"
git push

echo
echo "Released $VERSION."
