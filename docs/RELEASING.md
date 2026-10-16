# Releasing Easyshot

The release path builds an Apple Silicon app, signs with **Developer ID Application** and Hardened Runtime, notarizes and staples the app, builds a Finder disk image with the app and an Applications shortcut, then signs, notarizes and staples the DMG. Final signature, ticket and Gatekeeper checks must pass before the DMG and checksum are uploaded as an Actions artifact. Pushing a version tag publishes the matching DMG, checksum and signed update feed as a stable GitHub release. Creating a draft release manually is also supported. No Mac App Store submission or installer package is involved.

Easyshot's bundle ID is `no.paraply.easyshot`. The app bundle, code-signing identifier and Raycast launch commands use this ID. Changing the bundle ID does not require a new Developer ID certificate or notarization API key.

Easyshot releases use **Paraply Ventures AS**, Apple developer team `93627F7C77`, with signing identity `Developer ID Application: Paraply Ventures AS (93627F7C77)`. The GitHub secrets are configured for this team.

On the configured Mac, signing credentials are stored outside the repository in `$HOME/Library/Application Support/Easyshot/Signing/Paraply-93627F7C77`. The notarization profile is `easyshot-paraply` in that directory's `easyshot-signing.keychain-db`. For a local release, unlock this dedicated keychain, then set:

```sh
EASYSHOT_SIGNING_DIR="$HOME/Library/Application Support/Easyshot/Signing/Paraply-93627F7C77"
security unlock-keychain -p "$(cat "$EASYSHOT_SIGNING_DIR/keychain-password")" \
  "$EASYSHOT_SIGNING_DIR/easyshot-signing.keychain-db"
export SIGNING_IDENTITY='Developer ID Application: Paraply Ventures AS (93627F7C77)'
export SIGNING_KEYCHAIN="$EASYSHOT_SIGNING_DIR/easyshot-signing.keychain-db"
export NOTARY_KEYCHAIN="$SIGNING_KEYCHAIN"
export NOTARY_PROFILE=easyshot-paraply
```

Keep a secure backup of the `.p12`, its `certificate-password` file, and the `.p8` API key from that directory. Their contents must stay outside Git, release artifacts, logs and chat.

Signing and notarization avoid the unidentified-developer/cannot-check-for-malicious-software block. macOS can still display its normal downloaded-app first-open confirmation. Screen Recording and optional camera/microphone/Accessibility permissions still apply. See [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Sign and release from this Mac

1. Confirm your certificate is installed:

   ```sh
   security find-identity -v -p codesigning
   ```

   Use the identity named **Developer ID Application**, not Apple Development or Apple Distribution. If needed, create it in Xcode → Settings → Accounts → your team → Manage Certificates, or [Apple Developer → Certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates). No Developer ID Installer certificate is needed for a drag-to-Applications DMG.

2. Create an [app-specific password](https://support.apple.com/en-us/102654) in your Apple Account. In your own Terminal, store it in Keychain:

   ```sh
   xcrun notarytool store-credentials easyshot \
     --apple-id 'YOUR_APPLE_ACCOUNT_EMAIL' \
     --team-id 'YOUR_TEAM_ID'
   ```

   `notarytool` prompts for the app-specific password and validates it. Your normal Apple Account password is not used. The profile name `easyshot` contains the notarization credentials, not the signing certificate. [Apple's command-line guide](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool) describes this setup.

3. Install the DMG layout tool and run the release:

   ```sh
   python3 -m venv .release-venv
   source .release-venv/bin/activate
   python3 -m pip install 'dmgbuild==1.6.7'

   SIGNING_IDENTITY='Developer ID Application: YOUR NAME (YOUR_TEAM_ID)' \
   NOTARY_PROFILE=easyshot \
   bash scripts/release.sh
   ```

   This uses the signing identity already in your keychain. It creates `dist/release/Easyshot.app`, `dist/release/Easyshot-<version>-AppleSilicon.dmg` and `SHA256SUMS.txt`. Your installed app and the normal `dist/Easyshot.app` development build are not replaced. The app is notarized first so its ticket travels with it when dragged out of the DMG, including offline installation. Each submission can wait up to **90 minutes** by default; override with `NOTARY_TIMEOUT` if needed. The script records each submission ID before waiting and retains public status/log JSON files in `dist/release`. If a submission is rejected, inspect the log; if it times out, check that existing ID with `xcrun notarytool info ID --keychain-profile easyshot` before submitting again. A timeout does not cancel Apple's processing.

   The DMG builder refuses to overwrite an existing image. Move an earlier DMG aside to retry the same version. `Resources/Info.plist` supplies the version and build number.

4. Upload the accepted DMG and checksum to a draft release:

   ```sh
   gh release create v1.6.2 \
     dist/release/Easyshot-1.6.2-AppleSilicon.dmg \
     dist/release/SHA256SUMS.txt \
     --repo mscno/easyshot --target master \
     --title 'Easyshot 1.6.2' --draft
   ```

   Use the actual app version for future releases. Test the downloaded DMG on another Mac, review the release, then click **Publish release**. This repository is public: published stable releases and their update feeds are available without signing in. [GitHub's release guide](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) explains draft and repository visibility.

## Automate through GitHub Actions

The **Release signed DMG** workflow runs on pushes to `master`, version tags (`v*`), and manually from the Actions tab, on an Apple Silicon `macos-26` runner. It runs Swift unit tests and notarization control-flow tests, imports signing credentials into a temporary keychain, runs the same release script, uploads the verified DMG and checksum as an Actions artifact, and removes the temporary credentials. It does not sign pull requests or other branches. There is no path filter: rewriting the single-commit `master` history prevents GitHub from reliably comparing changed files. The DMG layout uses [dmgbuild](https://github.com/dmgbuild/dmgbuild), which writes Finder settings without automating Finder.

Open a successful run and download **Easyshot-<version>-AppleSilicon** from its Artifacts section or its summary link. Extract the artifact ZIP, verify `SHA256SUMS.txt`, open the DMG, and drag the app into Applications. Artifacts are retained for 30 days and require a GitHub account. A failed notarization publishes only available public diagnostic JSON, never a release DMG or signing credentials. [GitHub's artifact guide](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts) explains downloading them.

The job allows 210 minutes for the two notarization waits and packaging. Builds from `master` can repeat the same version and only upload an artifact. A version-tag build requires the tag to match `CFBundleShortVersionString`, then publishes the verified DMG, checksum and signed appcast together as the latest stable release. A separate optional job creates a **draft** release when requested by the manual workflow input.

Set these repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 of your exported Developer ID Application identity (`.p12`, including its private key). |
| `CERTIFICATE_PASSWORD` | Password you chose when exporting that `.p12`. |
| `SIGNING_IDENTITY` | Full Developer ID Application identity name, or its SHA-1 fingerprint from `security find-identity`. |
| `NOTARY_API_KEY_BASE64` | Base64 of an App Store Connect **team** API private key (`.p8`). |
| `NOTARY_KEY_ID` | The API key's Key ID. |
| `NOTARY_ISSUER_ID` | The API key's Issuer ID. |

Export the signing identity in **Keychain Access → login → My Certificates**: expand Developer ID Application to confirm the private key is present, select the certificate and private key, then export as `.p12` with a password. A `.cer` alone cannot sign on a GitHub runner. [GitHub's certificate guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) covers the temporary-keychain approach.

For notarization, go to **App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys**, generate a key named Easyshot Notarization with Developer access, and download the `.p8` once. Record its Key ID and Issuer ID. The workflow uses a team key so it also works with older `notarytool` versions. [Apple's API key instructions](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/) cover access and key generation. No App Store listing is required.

Upload files directly to GitHub secrets through the CLI without printing their contents:

```sh
base64 -i /path/to/DeveloperID.p12 | gh secret set CERTIFICATE_P12_BASE64 --repo mscno/easyshot
base64 -i /path/to/AuthKey_KEYID.p8 | gh secret set NOTARY_API_KEY_BASE64 --repo mscno/easyshot
```

Set the other values in GitHub's secrets form, or use interactive `gh secret set NAME --repo mscno/easyshot`. Certificate passwords and private keys belong in GitHub Secrets/Keychain, not this repo or chat. The key files and local release venv are ignored by Git.

After adding secrets, `master` pushes produce an artifact automatically. To publish a stable update, bump both version and build number in `Resources/Info.plist`, commit it on `master`, then push an annotated tag matching the version (for example `v2.0.2`). The tag workflow publishes the release only after signing, notarization and verification succeed. Never move an existing published tag.

To build an artifact manually, choose **Actions → Release signed DMG → Run workflow**, leaving the branch as `master` and **Create draft release** unchecked. Alternatively:

```sh
gh workflow run release.yml --repo mscno/easyshot --ref master
```

For an optional draft release, select **Also create a versioned draft GitHub release**, or pass `-f create_draft_release=true` to the CLI command. This mode derives the tag from `CFBundleShortVersionString`, rejects an existing release/tag, and creates the tag against the exact built commit after the artifact is uploaded. Bump both version and build number in `Resources/Info.plist` before a new versioned release. Review the generated draft and test its DMG before publishing it. Do not move published version tags when amending `master`; old downloads should continue to identify their original source.

## Local verification without notarization credentials

To check the Finder layout without publishing or claiming notarization:

```sh
bash scripts/build-app.sh release
source .release-venv/bin/activate
bash scripts/make-dmg.sh dist/Easyshot.app dist/Easyshot-preview.dmg
```

This is a preview DMG containing the locally signed development build. It is not suitable for warning-free distribution. `release.sh` never skips notarization and only copies the final release DMG into `dist/release` after all checks pass.

## Sparkle updates

The direct-download app embeds Sparkle 2.10.0, including its signed installer helpers. `scripts/sign-sparkle.sh` signs each nested component before the framework and app. Keep Library Validation enabled.

Set `SPARKLE_PRIVATE_KEY` in GitHub Actions secrets to the base64-encoded 32-byte Ed25519 seed matching `SUPublicEDKey`. Keep a secure backup outside Git. For local signing set `SPARKLE_KEY_FILE` to a protected file containing that value. Existing Apple signing/notarization secrets are unchanged.

After notarization and stapling, `scripts/generate-appcast.py` signs the final DMG and feed with Sparkle's pinned tools, verifies both signatures, and adds the feed checksum. Version-tag releases publish `appcast.xml` alongside the matching DMG automatically. For a manual draft release, publish the matching DMG and feed together. The app uses GitHub's latest stable release asset URL. Never edit a signed feed after signing or overwrite a published DMG. Bump both the marketing version and build number for every update.
