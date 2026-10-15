# Mac App Store preparation

Submission is on hold. Everything in this directory is a local draft. No Store build has been uploaded or submitted for review, and the unsigned preview package cannot be distributed through the Store.

Easyshot will be **free**, published by **Paraply Ventures AS**, team `93627F7C77`, with bundle ID `no.paraply.easyshot` and proposed SKU `easyshot-macos`. The app is Apple Silicon only and requires macOS 26. Release is configured as **manual** in the draft metadata.

## The Store edition

The separate `APP_STORE` build enables App Sandbox. A native folder picker grants access to the capture directory; persistent security-scoped bookmarks restore access on later launches. Previous capture folders retain bookmark access for the local library. Unavailable or corrupt bookmarks do not trigger mounting or UI during restoration. Imported movies are copied into the app container so they remain accessible after relaunch.

The Store edition omits Accessibility-driven automatic scrolling and global keystroke captions. Scrolling capture remains available with manual scrolling and Add Frame. Local capture shortcuts, screen capture, editing, OCR, recording, optional camera/microphone, click effects and preview remain. The direct-download edition retains its existing features. [Apple documents the sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), and [the folder-access workflow](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

The Store bundle includes an in-app privacy policy, a privacy manifest, the Utilities category, and explicit camera/microphone usage descriptions. The app has no network client entitlement, accounts, analytics, advertising or third-party SDKs. Review the drafted “Data Not Collected” answer against the final build before submission. Clipboard and user-chosen sharing/cloud folders are explained in the policy.

## Build and check locally

```sh
scripts/package-app-store.sh --preview
python3 scripts/check-app-store.py --app dist/app-store-preview/Easyshot.app
dist/app-store-preview/Easyshot.app/Contents/MacOS/Easyshot --self-test
```

The preview package is ad-hoc signed and sandboxed for local checks. It is not uploadable. Packaging refuses to overwrite an existing version/build package; move the old preview aside before rebuilding. Local checks do not contact Apple, change the installed app, or use the release secrets.

The preflight checks draft text limits, IDs, price, privacy declarations, PNG screenshot sizes/transparency, architecture, sandbox entitlements, signing, and absence of imported Accessibility/event-posting APIs. Missing public URLs, contacts, screenshots and distribution signing remain visible as pending items. `--ready --app …` fails if these are incomplete. This is an offline preflight; it does not replace Apple's validation or manual testing.

Local verification on October 2, 2026: 35 unit tests, 67 Store-edition offline checks and 64 direct-edition offline checks passed. Both release builds are arm64. The Store self-test ran inside the macOS app container; the preview `.pkg` expanded successfully and is confirmed unsigned. Bundle verification and the offline preflight passed, while the readiness check correctly rejected the unfinished listing/signing fields. No remote Store validation was run.

## Signing when distribution preparation resumes

Developer ID Application is for the GitHub DMG. The Mac App Store package needs **two separate identities** from Paraply:

- `Apple Distribution: Paraply Ventures AS (93627F7C77)` for the app, or the older `3rd Party Mac Developer Application` identity.
- `3rd Party Mac Developer Installer: Paraply Ventures AS (93627F7C77)` for the `.pkg` installer.

Their private keys must be present in the selected keychain. The existing Developer ID certificate and GitHub DMG signing secrets are not substitutes. The existing Paraply Team API key can authenticate later build uploads if its access is still valid; creating an app record needs an appropriate App Store Connect role. [Apple's app signing guidance](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [package signing guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) describe these identities.

Copy [the environment template](app-store/signing.env.example) to `.env.app-store`, fill local paths, and keep that file gitignored. Source it with exported variables:

```sh
set -a
source .env.app-store
set +a
scripts/package-app-store.sh
python3 scripts/check-app-store.py --ready --app dist/app-store/Easyshot.app
```

A Mac App Store provisioning profile is optional for this app's unrestricted entitlements. **TestFlight always requires a suitable profile.** If needed, set `APP_STORE_PROFILE` to a Paraply Mac App Store distribution profile for `no.paraply.easyshot`; it is embedded before signing. Do not supply an iOS, development or another app's profile. [Apple's provisioning explanation](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) covers the macOS exception.

## Listing and public pages

Local drafts are in [app-store](app-store/): metadata, description, review notes, marketing/support/privacy copy, and a nonsecret signing template. Proposed URLs use `https://easyshot.app/`, with `/support/` and `/privacy/` underneath. The domain is registered; the pages, mailbox and hosting are not live yet. URL and email fields deliberately remain blank until they work.

Before submission:

1. Confirm the public domain and monitored support email. Publish the copy, removing its publication notes, and enter reachable HTTPS URLs in `metadata.json`.
2. Add the App Review contact email and phone number.
3. Register the bundle ID and create the macOS app record in Paraply's account. Use the draft SKU, free pricing and manual release. Accept any pending agreements through the account holder. [Apple's app-record instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app) identify the required roles.
4. Complete the age-rating questionnaire, privacy responses and applicable account/trader declarations based on the actual app and publisher.
5. Add real Store-edition screenshots and test permissions and folder access across relaunches.

### Screenshot plan

Use actual compositor-rendered UI, including Liquid Glass, with sample content you may publish. Capture:

1. The compact toolbar and dashed area selector.
2. Window hover selection with its clear target highlight.
3. Annotation editing with arrows, text and redaction.
4. The library or recording UI with no private content visible.

Store PNG screenshots must have no alpha channel and use one of Apple's Mac sizes: **1280×800, 1440×900, 2560×1600 or 2880×1800**. Add relative screenshot paths to `metadata.json`. [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) are the source of these dimensions.

The existing `docs/screenshot.png` is a real user-provided screenshot for the README, but its dimensions and alpha channel do not meet the Store requirements. No replacement Store screenshots have been fabricated. Native AppKit bitmap rendering does not reproduce compositor-rendered Liquid Glass, and computer-use access to Easyshot was not approved, so actual Store UI capture remains a manual step.

### Manual checks before a later upload

Test the packaged sandboxed app: first capture prompts for a folder; chosen folder persists after quitting; changing folders preserves old library access; cancelled/removed folders recover; clipboard and PNG defaults work; imported movies remain editable after relaunch; screen permission denial recovers; recording clearly indicates capture and stops correctly. Check optional audio/camera on real hardware and captures over animated content. The offline self-test cannot verify these external permissions or compositor appearance.

## Later validation and upload

**Do not run these while submission is on hold.** Both validation and upload contact Apple and transmit the signed package. Run only after the hold is lifted and the listing/account/signing preparation above is complete:

```sh
# Remote validation only; this still transmits the package to Apple.
scripts/upload-app-store.sh dist/app-store/Easyshot-1.6.2-11.pkg
# Upload a build for processing; does not submit it for review or release it.
scripts/upload-app-store.sh --upload dist/app-store/Easyshot-1.6.2-11.pkg
```

The script rejects unsigned previews and installers outside the Paraply team before contacting Apple. It copies the API private key into a restricted temporary directory and removes it afterward. It never prints the key. Version/build numbers must be increased if Apple has already received that build. [Apple's upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) explain build processing and supported tools.

After processing, a person must select the build, verify the listing and screenshots, and explicitly submit for review. Uploading is separate from submission, and manual release keeps publication under your control.
