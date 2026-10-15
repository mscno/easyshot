#!/bin/bash
# Build -> sign -> notarize/staple app -> DMG -> sign -> notarize/staple DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set your Developer ID Application identity; see docs/RELEASING.md.}"
: "${NOTARY_PROFILE:?Set a notarytool keychain profile; see docs/RELEASING.md.}"
command -v dmgbuild >/dev/null || { echo 'Install dmgbuild==1.6.7 first.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a numeric x.y.z app version.' >&2; exit 1; }
RELEASE_DIR="$PWD/dist/release"
APP="$RELEASE_DIR/Easyshot.app"
DMG="$RELEASE_DIR/Easyshot-$VERSION-AppleSilicon.dmg"
[[ ! -e "$DMG" ]] || { echo "Release DMG already exists: $DMG. Move it aside to rebuild." >&2; exit 1; }
AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then AUTH_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
# Fail before building or touching artifacts if notarization credentials are not ready.
xcrun notarytool history "${AUTH_ARGS[@]}" --output-format json >/dev/null
APP_EDITION=direct APP_OUTPUT_DIR="$RELEASE_DIR" bash scripts/build-app.sh release
[[ "$(lipo -archs "$APP/Contents/MacOS/Easyshot")" == arm64 ]] || { echo 'Expected Apple Silicon only.' >&2; exit 1; }
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || { echo 'A Developer ID Application certificate is required.' >&2; exit 1; }
[[ "$SIGNATURE" == *"TeamIdentifier=93627F7C77"* ]] || { echo 'Easyshot must be signed by Paraply Ventures AS.' >&2; exit 1; }
# All artifacts produced for upload contain signatures and public tickets, never keys.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easyshot-notary.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK_DIR/Easyshot.zip"
bash scripts/notarize.sh "$WORK_DIR/Easyshot.zip" app "$RELEASE_DIR"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
STAGED_DMG="$WORK_DIR/Easyshot-$VERSION-AppleSilicon.dmg"
bash scripts/make-dmg.sh "$APP" "$STAGED_DMG"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --timestamp)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
codesign "${SIGN_ARGS[@]}" "$STAGED_DMG"
bash scripts/notarize.sh "$STAGED_DMG" dmg "$RELEASE_DIR"
xcrun stapler staple "$STAGED_DMG"
xcrun stapler validate "$STAGED_DMG"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$STAGED_DMG"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGED_DMG"
ditto "$STAGED_DMG" "$DMG"
(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
python3 scripts/generate-appcast.py "$APP" "$DMG" mscno/easyshot
(cd "$RELEASE_DIR" && shasum -a 256 appcast.xml >> SHA256SUMS.txt)
echo "Release ready: $DMG"
