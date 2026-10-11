#!/bin/bash
# Builds Smiley.app into ./dist. Usage: scripts/build-app.sh [--open]
# macOS ties Accessibility / Input Monitoring grants to the code signature. Ad-hoc signing changes on
# every build, so you'd re-grant after each rebuild. To avoid that, create a "Code Signing" certificate
# in Keychain Access (Certificate Assistant → Create a Certificate…) and export SMILEY_SIGN_IDENTITY="<its name>".
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/Smiley.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Smiley "$APP/Contents/MacOS/Smiley"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The desktop pet's sprite atlas (Pet/PetSprites.swift).
cp -R Resources/Pet "$APP/Contents/Resources/Pet"
# App icon, rendered from the same SwiftUI logo the app uses (UI/Logo.swift).
ICONSET="$(mktemp -d)/AppIcon.iconset"
.build/release/Smiley --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Prefer the local "Smiley Dev" identity so macOS permission grants survive rebuilds.
if [[ -z "${SMILEY_SIGN_IDENTITY:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Smiley Dev"'; then
  SMILEY_SIGN_IDENTITY="Smiley Dev"
fi
codesign --force --sign "${SMILEY_SIGN_IDENTITY:--}" --identifier com.jamespratama.smiley "$APP"
echo "Built $APP (signed with ${SMILEY_SIGN_IDENTITY:-ad-hoc identity})"

# Install as the one and only Smiley.app. macOS keeps a single Input Monitoring / Accessibility entry per
# bundle ID; a second copy with a different signature (e.g. an old ad-hoc build) silently steals it on launch.
DEST=/Applications/Smiley.app
pkill -f "Smiley.app/Contents/MacOS/Smiley$" 2>/dev/null || true
# Its model servers outlive it when it is killed this way; stop them so the new build starts its own.
pkill -f "llama-server.*Application Support/Smiley/models" 2>/dev/null || true
rm -rf "$DEST"
# The app was called Flow before the rename. Retire that copy, or it would still open at login and
# answer the same hotkeys. Its data moves over on Smiley's first launch (App/Migration.swift).
pkill -f "Flow.app/Contents/MacOS/Flow$" 2>/dev/null || true
rm -rf /Applications/Flow.app
mv "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "Installed $DEST"
if [[ "${1:-}" == "--open" ]]; then open "$DEST"; fi
