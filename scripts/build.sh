#!/bin/bash
# Build the direct-download edition and sign it so macOS privacy grants survive rebuilds.
#   scripts/build.sh            -> build/Pourtype.app, signed with the first "Apple Development" identity
#   SIGN_ID=<sha1|name> scripts/build.sh
#   CONFIG=AppStore scripts/build.sh   -> the sandboxed configuration (local check only;
#                                         App Store uploads go through Xcode Organizer / archive)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Release}"
python3 scripts/l10n.py check
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Pourtype.xcodeproj -scheme Pourtype -configuration "$CONFIG" \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="build/dd/Build/Products/$CONFIG/Pourtype.app"
ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}' )}"
ENT=Direct.entitlements; [ "$CONFIG" = AppStore ] && ENT=AppStore.entitlements
HASH="$(security find-identity -v -p codesigning | grep -F "$ID" | head -1 | awk '{print $2}')"
codesign --force --deep --options runtime --timestamp=none --entitlements "$ENT" --sign "${HASH:-$ID}" "$APP"
codesign --verify --strict "$APP" && echo "signed: $APP ($ID)"
rm -rf build/Pourtype.app && cp -R "$APP" build/Pourtype.app
