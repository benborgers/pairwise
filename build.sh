#!/bin/bash
# Build Pairwise.app — release binary wrapped in an app bundle and ad-hoc
# signed, so macOS grants camera / microphone / screen-recording permissions.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Pairwise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pairwise "$APP/Contents/MacOS/Pairwise"
cp App/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

# Ad-hoc signing gives the app a new code identity every build, which
# invalidates the previous Screen Recording grant — macOS then fails silently
# instead of re-prompting. Resetting makes the permission prompt appear again.
tccutil reset ScreenCapture dev.benborgers.pairwise >/dev/null 2>&1 || true

echo
echo "Built $APP"
echo "Run:  open $APP"
echo "Note: screen sharing re-prompts for permission after every rebuild (ad-hoc signing)."
