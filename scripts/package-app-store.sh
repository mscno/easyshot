#!/bin/bash
# Builds a local Mac App Store package. Never uploads or submits it.
set -euo pipefail
cd "$(dirname "$0")/.."
PREVIEW=false
if [[ "${1:-}" == --preview ]]; then PREVIEW=true; shift; fi
[[ $# == 0 ]] || { echo 'Usage: package-app-store.sh [--preview]' >&2; exit 1; }
OUTPUT="$PWD/dist/app-store"
if $PREVIEW; then
    OUTPUT="$PWD/dist/app-store-preview"
    STORE_IDENTITY=''
else
    : "${APP_STORE_SIGNING_IDENTITY:?Set an Apple Distribution or Mac App Distribution identity.}"
    : "${APP_STORE_INSTALLER_IDENTITY:?Set a Mac Installer Distribution identity.}"
    [[ "$APP_STORE_SIGNING_IDENTITY" == "Apple Distribution:"* || "$APP_STORE_SIGNING_IDENTITY" == "3rd Party Mac Developer Application:"* ]] || { echo 'Expected App Store app distribution identity.' >&2; exit 1; }
    [[ "$APP_STORE_INSTALLER_IDENTITY" == "3rd Party Mac Developer Installer:"* ]] || { echo 'Expected Mac Installer Distribution identity.' >&2; exit 1; }
    [[ "$APP_STORE_SIGNING_IDENTITY" == *"(93627F7C77)" && "$APP_STORE_INSTALLER_IDENTITY" == *"(93627F7C77)" ]] || { echo 'Both Store identities must belong to Paraply Ventures AS.' >&2; exit 1; }
    STORE_IDENTITY="$APP_STORE_SIGNING_IDENTITY"
fi
APP_EDITION=app-store APP_OUTPUT_DIR="$OUTPUT" SIGNING_IDENTITY="$STORE_IDENTITY" \
    SIGNING_KEYCHAIN="${APP_STORE_SIGNING_KEYCHAIN:-}" bash scripts/build-app.sh release
APP="$OUTPUT/Easyshot.app"
[[ "$(lipo -archs "$APP/Contents/MacOS/Easyshot")" == arm64 ]] || exit 1
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PKG="$OUTPUT/Easyshot-$VERSION-$BUILD.pkg"
[[ ! -e "$PKG" ]] || { echo "Package already exists: $PKG. Move it aside to rebuild." >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/easyshot-store.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
codesign -d --entitlements :- "$APP" > "$WORK/entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$WORK/entitlements.plist")" == true ]] || { echo 'App Sandbox is missing.' >&2; exit 1; }
ARGS=(--component "$APP" /Applications)
if ! $PREVIEW; then
    SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
    [[ "$SIGNATURE" == *"TeamIdentifier=93627F7C77"* ]] || { echo 'App signature is not from Paraply.' >&2; exit 1; }
    ARGS+=(--sign "$APP_STORE_INSTALLER_IDENTITY" --timestamp)
    if [[ -n "${APP_STORE_SIGNING_KEYCHAIN:-}" ]]; then ARGS+=(--keychain "$APP_STORE_SIGNING_KEYCHAIN"); fi
fi
productbuild "${ARGS[@]}" "$WORK/Easyshot.pkg"
pkgutil --expand "$WORK/Easyshot.pkg" "$WORK/expanded"
test -f "$WORK/expanded/Distribution"
if ! $PREVIEW; then pkgutil --check-signature "$WORK/Easyshot.pkg"; fi
cp "$WORK/Easyshot.pkg" "$PKG"
if $PREVIEW; then echo "Unsigned local preview only: $PKG"; else echo "Store package ready for separate validation/upload: $PKG"; fi
