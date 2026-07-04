#!/bin/bash
# Build Pairwise.app — release binary wrapped in an app bundle with the
# Sparkle framework embedded.
#
# Signing: uses your "Developer ID Application" identity if one is in the
# keychain (hardened runtime, ready for notarization), otherwise falls back
# to ad-hoc signing for local development.
#
# Env:
#   VERSION=1.2  overrides CFBundleShortVersionString/CFBundleVersion.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-}"

swift build -c release

SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

APP=build/Pairwise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Pairwise "$APP/Contents/MacOS/Pairwise"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  # Sparkle's nested executables must be signed individually — --deep is
  # unreliable with the hardened runtime.
  codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
  codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK/Versions/B/Autoupdate"
  codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK/Versions/B/Updater.app"
  codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK"
  codesign -f -s "$IDENTITY" -o runtime --entitlements App/Pairwise.entitlements "$APP"
else
  echo "No Developer ID Application identity found — ad-hoc signing (dev only)."
  codesign -f -s - "$FRAMEWORK"
  codesign -f -s - "$APP"
  # Ad-hoc signing gives the app a new code identity every build, which
  # invalidates the previous Screen Recording grant — macOS then fails silently
  # instead of re-prompting. Resetting makes the permission prompt appear again.
  tccutil reset ScreenCapture dev.benborgers.pairwise >/dev/null 2>&1 || true
fi

echo
echo "Built $APP"
echo "Run:  open $APP"
