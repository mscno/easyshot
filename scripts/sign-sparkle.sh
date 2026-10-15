#!/bin/bash
set -euo pipefail
FRAMEWORK="$1/Contents/Frameworks/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { echo 'Missing embedded Sparkle framework' >&2; exit 1; }
ARGS=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    ARGS+=(--options runtime "${SIGN_TIMESTAMP:---timestamp}")
    if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
fi
mkdir -p "$1/Contents/Resources"
cp licenses/Sparkle.txt "$1/Contents/Resources/Sparkle-LICENSE.txt"
# Sign inside out; do not deep-sign or disable Library Validation.
for CODE in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign "${ARGS[@]}" "$CODE"
done
codesign --verify --deep --strict "$FRAMEWORK"
