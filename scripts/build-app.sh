#!/bin/bash
# Builds Flow.app into ./dist. Usage: scripts/build-app.sh [--open]
# macOS ties Accessibility / Input Monitoring grants to the code signature. Ad-hoc signing changes on
# every build, so you'd re-grant after each rebuild. To avoid that, create a "Code Signing" certificate
# in Keychain Access (Certificate Assistant → Create a Certificate…) and export FLOW_SIGN_IDENTITY="<its name>".
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/Flow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Flow "$APP/Contents/MacOS/Flow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon, rendered from the same SwiftUI logo the app uses (UI/Logo.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
.build/release/Flow --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Prefer the local "Flow Dev" identity so macOS permission grants survive rebuilds.
if [[ -z "${FLOW_SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Flow Dev"'; then
  FLOW_SIGN_IDENTITY="Flow Dev"
fi
codesign --force --sign "${FLOW_SIGN_IDENTITY:--}" --identifier ai.liquid.flow "$APP"
echo "Built $APP (signed with ${FLOW_SIGN_IDENTITY:-ad-hoc identity})"

# Install as the one and only Flow.app. macOS keeps a single Input Monitoring / Accessibility entry per
# bundle ID; a second copy with a different signature (e.g. an old ad-hoc build) silently steals it on launch.
DEST=/Applications/Flow.app
pkill -f "Flow.app/Contents/MacOS/Flow$" 2>/dev/null || true
rm -rf "$DEST"
mv "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Installed $DEST"
if [[ "${1:-}" == "--open" ]]; then open "$DEST"; fi
