#!/bin/bash
# Validation is the default. Upload requires an explicit --upload invocation.
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION=--validate-app
if [[ "${1:-}" == --upload ]]; then ACTION=--upload-app; shift; fi
[[ $# == 1 && -f "$1" ]] || { echo 'Usage: upload-app-store.sh [--upload] /path/to/signed.pkg' >&2; exit 1; }
: "${APP_STORE_API_KEY_PATH:?Set the path to an App Store Connect .p8 key.}"
: "${APP_STORE_API_KEY_ID:?Set the App Store Connect key ID.}"
: "${APP_STORE_API_ISSUER_ID:?Set the App Store Connect issuer ID.}"
[[ "$1" == *.pkg && -f "$APP_STORE_API_KEY_PATH" ]] || { echo 'Expected a .pkg and an existing .p8 key.' >&2; exit 1; }
# Refuse unsigned preview packages before contacting Apple.
SIGNATURE="$(pkgutil --check-signature "$1")"
[[ "$SIGNATURE" == *"3rd Party Mac Developer Installer:"* && "$SIGNATURE" == *"(93627F7C77)"* ]] || { echo 'Expected a Paraply-signed Mac App Store installer package.' >&2; exit 1; }
umask 077
KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easyshot-store-key.XXXXXX")"
trap 'rm -rf "$KEY_DIR"' EXIT
cp "$APP_STORE_API_KEY_PATH" "$KEY_DIR/AuthKey_$APP_STORE_API_KEY_ID.p8"
API_PRIVATE_KEYS_DIR="$KEY_DIR" xcrun altool "$ACTION" -f "$1" -t macos \
    --api-key "$APP_STORE_API_KEY_ID" --api-issuer "$APP_STORE_API_ISSUER_ID"
