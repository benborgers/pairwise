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
# Steps: build + sign → notarize + staple → zip → sign update → add appcast
# entry → create GitHub release → commit & push appcast.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pairwise-notary}"
REPO="benborgers/pairwise"
TAG="v$VERSION"
ZIP="build/Pairwise-$VERSION.zip"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "error: no Developer ID Application identity in keychain"; exit 1; }

VERSION="$VERSION" ./build.sh

echo "Notarizing…"
ditto -c -k --keepParent build/Pairwise.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Pairwise.app

# Re-zip so the stapled ticket ships in the download.
rm -f "$ZIP"
ditto -c -k --keepParent build/Pairwise.app "$ZIP"

echo "Signing update for Sparkle…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP" | tr -d '\n')  # sparkle:edSignature="…" length="…"

URL="https://github.com/$REPO/releases/download/$TAG/Pairwise-$VERSION.zip"
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

echo "Creating GitHub release $TAG…"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$VERSION" --notes ""

git add appcast.xml
git commit -m "Release $VERSION"
git push

echo
echo "Released $VERSION."
