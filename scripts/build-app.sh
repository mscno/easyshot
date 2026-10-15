#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
EDITION="${APP_EDITION:-direct}"
[[ "$EDITION" == direct || "$EDITION" == app-store ]] || { echo 'APP_EDITION must be direct or app-store.' >&2; exit 1; }
BUILD_ARGS=(-c "$CONFIG" --arch arm64)
ENTITLEMENTS=Resources/Shotglass.entitlements
if [[ "$EDITION" == app-store ]]; then
    BUILD_ARGS+=(--scratch-path .build-app-store -Xswiftc -DAPP_STORE)
    ENTITLEMENTS=Resources/Shotglass-AppStore.entitlements
    if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "Apple Distribution:"* && "$SIGNING_IDENTITY" != "3rd Party Mac Developer Application:"* && "$SIGNING_IDENTITY" != "Apple Development:"* ]]; then
        echo 'Use an Apple Distribution identity for Store distribution, or Apple Development for local testing.' >&2; exit 1
    fi
fi
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="${APP_OUTPUT_DIR:-$PWD/dist}/Shotglass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Shotglass" "$APP/Contents/MacOS/Shotglass"
if [[ "$EDITION" == direct ]]; then
    SPARKLE_ROOT="$(bash scripts/fetch-sparkle.sh)"
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_ROOT/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    bash scripts/sign-sparkle.sh "$APP"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The Shotglass Cloud server address is never committed; inject it at build time.
if [[ -n "${SHOTGLASS_CLOUD_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ShotglassCloudURL string $SHOTGLASS_CLOUD_URL" "$APP/Contents/Info.plist"
fi
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ "$EDITION" == app-store ]]; then
    for KEY in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUSendProfileInfo SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do /usr/libexec/PlistBuddy -c "Delete :$KEY" "$APP/Contents/Info.plist"; done
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.utilities' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleSupportedPlatforms array' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleSupportedPlatforms:0 string MacOSX' "$APP/Contents/Info.plist"
    if [[ -n "${APP_STORE_PROFILE:-}" ]]; then
        cp "$APP_STORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
    else
        rm -f "$APP/Contents/embedded.provisionprofile"
    fi
fi
if [[ "$EDITION" == direct ]]; then rm -f "$APP/Contents/embedded.provisionprofile"; fi
mkdir -p "$APP/Contents/Resources/Raycast"
cp integrations/raycast/*.sh "$APP/Contents/Resources/Raycast/"
swift scripts/make-icon.swift "$APP/Contents/Resources"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier no.paraply.shotglass --options runtime --timestamp --entitlements "$ENTITLEMENTS")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    # Sparkle's nested helpers were signed explicitly above.
    # Sign nested code explicitly here if the bundle gains any in future.
    codesign "${SIGN_ARGS[@]}" "$APP"
else
    SIGN_ARGS=(--force --sign - --identifier no.paraply.shotglass)
    if [[ "$EDITION" == app-store ]]; then SIGN_ARGS+=(--entitlements "$ENTITLEMENTS"); fi
    codesign "${SIGN_ARGS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
