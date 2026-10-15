#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
EDITION="${APP_EDITION:-direct}"
[[ "$EDITION" == direct || "$EDITION" == app-store ]] || { echo 'APP_EDITION must be direct or app-store.' >&2; exit 1; }
BUILD_ARGS=(-c "$CONFIG" --arch arm64)
ENTITLEMENTS=Resources/Easyshot.entitlements
if [[ "$EDITION" == app-store ]]; then
    BUILD_ARGS+=(--scratch-path .build-app-store -Xswiftc -DAPP_STORE)
    ENTITLEMENTS=Resources/Easyshot-AppStore.entitlements
    if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != "Apple Distribution:"* && "$SIGNING_IDENTITY" != "3rd Party Mac Developer Application:"* && "$SIGNING_IDENTITY" != "Apple Development:"* ]]; then
        echo 'Use an Apple Distribution identity for Store distribution, or Apple Development for local testing.' >&2; exit 1
    fi
fi
# Local direct builds (no SIGNING_IDENTITY) are development builds. macOS keys privacy
# grants (Screen Recording, Accessibility, camera, microphone) to the designated
# requirement. Ad-hoc signatures use the binary's cdhash, which changes on every build,
# so they would re-prompt after each rebuild or version bump. Sign with a stable keychain
# identity instead, and use a separate bundle ID so they never replace the grants of the installed release.
BUNDLE_ID=no.paraply.easyshot
LOCAL_IDENTITY=""
if [[ "$EDITION" == direct && -z "${SIGNING_IDENTITY:-}" ]]; then
    LOCAL_IDENTITY="${LOCAL_SIGNING_IDENTITY:-}"
    for KIND in 'Apple Development:' 'Developer ID Application:'; do
        [[ -n "$LOCAL_IDENTITY" ]] || LOCAL_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -v k="\"$KIND" 'index($0,k){print $2; exit}')"
    done
    [[ "${DEV_BUNDLE:-1}" == 0 ]] || BUNDLE_ID=no.paraply.easyshot.dev
    [[ -n "$LOCAL_IDENTITY" ]] || echo 'warning: no code-signing identity found; ad-hoc builds lose privacy permissions after every rebuild.' >&2
fi
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="${APP_OUTPUT_DIR:-$PWD/dist}/Easyshot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Easyshot" "$APP/Contents/MacOS/Easyshot"
if [[ "$EDITION" == direct ]]; then
    SPARKLE_ROOT="$(bash scripts/fetch-sparkle.sh)"
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_ROOT/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    if [[ -n "$LOCAL_IDENTITY" ]]; then SIGNING_IDENTITY="$LOCAL_IDENTITY" SIGN_TIMESTAMP=--timestamp=none bash scripts/sign-sparkle.sh "$APP"
    else bash scripts/sign-sparkle.sh "$APP"; fi
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The Easyshot Cloud server address is never committed; inject it at build time.
if [[ -n "${EASYSHOT_CLOUD_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :EasyshotCloudURL string $EASYSHOT_CLOUD_URL" "$APP/Contents/Info.plist"
fi
if [[ "$BUNDLE_ID" != no.paraply.easyshot ]]; then
    # Separate name, URL scheme and no Sparkle feed: a development build never updates
    # itself to the release or captures easyshot:// launches meant for the installed app.
    PLIST="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c 'Set :CFBundleName Easyshot Dev' -c 'Set :CFBundleDisplayName Easyshot Dev' \
        -c "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID.capture" -c 'Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 easyshot-dev' -c 'Delete :SUFeedURL' "$PLIST"
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
    SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    # Sparkle's nested helpers were signed explicitly above.
    # Sign nested code explicitly here if the bundle gains any in future.
    codesign "${SIGN_ARGS[@]}" "$APP"
elif [[ -n "$LOCAL_IDENTITY" ]]; then
    codesign --force --sign "$LOCAL_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
    echo "Signed development build $BUNDLE_ID with a stable identity; privacy permissions persist across rebuilds."
else
    SIGN_ARGS=(--force --sign - --identifier "$BUNDLE_ID")
    if [[ "$EDITION" == app-store ]]; then SIGN_ARGS+=(--entitlements "$ENTITLEMENTS"); fi
    codesign "${SIGN_ARGS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
