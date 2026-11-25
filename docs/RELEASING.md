# Releasing

Releases are built and published by `.github/workflows/release.yml` when a version tag is pushed.

1. Bump `VERSION` (for example `0.3.0`).
2. If the panel changed, run `make screenshots`.
3. Check that `make build` and `make check` pass, then commit: `Release v0.3.0`.
4. Tag and push:
   ```sh
   git tag v0.3.0 && git push origin main v0.3.0
   ```
5. The workflow checks that the tag matches `VERSION`, runs the checks, builds and smoke-tests the app, signs it, and publishes a GitHub release with:
   - `WebcamBright-macos-arm64.zip`: the menu bar app, with `uvcctl` inside
   - `SHA256SUMS`
   - `SHA256SUMS.sig`: the Ed25519 signature the in-app updater checks, made with the `UPDATE_SIGNING_KEY` secret. The workflow fails rather than publish an unsigned release.
6. Check it: `WEBCAMBRIGHT_DOWNLOAD_ONLY=1 bash scripts/get.sh` downloads the latest release and verifies it without installing anything.

Asset names carry no version, so `releases/latest/download/<asset>` always resolves to the newest release. `scripts/get.sh` and the in-app updater depend on this.

To build the same zip locally, run `scripts/package-release.sh` (output goes to `dist/`; it doesn't sign the checksums).

## In-app updates

The app checks `releases/latest` 15 seconds after launch and then every 6 hours. With **Install updates automatically** on (the default), it downloads the zip and verifies `SHA256SUMS.sig` against the public keys in `UpdateConfig.publicKeys` (`app/Sources/WebcamBrightKit/Updater.swift`). Then it checks the zip's checksum, bundle identifier, version and code signature, swaps the app bundle and relaunches. Relaunching hands the camera back for a moment, so an update waits until no call is running.

To try a release JSON without publishing one, open the app with `open --env WEBCAMBRIGHT_UPDATE_FEED=file:///path/release.json /Applications/WebcamBright.app`.

## Repository secrets

| Secret | What it is | Backup (login keychain, generic password) |
| --- | --- | --- |
| `UPDATE_SIGNING_KEY` | Ed25519 private key for `SHA256SUMS.sig` (base64 raw) | `WebcamBright update signing key` |
| `WEBCAMBRIGHT_SIGNING_P12` | The "WebcamBright Release Signing" code signing identity, a base64 `.p12` | `WebcamBright release signing p12 (base64)` |
| `WEBCAMBRIGHT_SIGNING_P12_PASSWORD` | Its password | `WebcamBright release signing p12 password` |

A secret can't be read back from GitHub, so keep the backups. To restore one: `security find-generic-password -s "<name>" -w | gh secret set <SECRET> -R estevecastells/webcam-bright`.

## Code signing

The app is signed with a self-signed certificate, "WebcamBright Release Signing". It is not a Developer ID, so a browser download still needs a one-time **Open Anyway** (`get.sh` avoids it because `curl` doesn't set the quarantine flag). It does give the app a stable designated requirement. macOS ties the camera permission to it, so the permission survives updates. An ad-hoc signature changes with every build, and macOS would ask again after each one. That's why the workflow refuses to publish without the identity.

The signing key never shares a job with build code:

- The `build` job builds and tests with no secrets and uploads an ad-hoc-signed app.
- The `sign` job checks out only `app/WebcamBright.entitlements`. It imports the identity non-extractable into a temporary keychain that only `codesign` may use, re-signs the app with the hardened runtime, and deletes the keychain.
- The `publish` job signs `SHA256SUMS` with `UPDATE_SIGNING_KEY` and runs nothing but the repository's own `scripts/sign-update.swift`.

`scripts/build-app.sh` uses the same identity when it is in your keychain, so a local `make install` and the releases share the camera permission. Contributors without it get "WebcamBright Local Signing" (`scripts/make-signing-cert.sh`) or an ad-hoc signature.

## Rotating the update signing key

Installed apps only accept a release signed by a key in `UpdateConfig.publicKeys`, so a new key needs one bridging release:

1. Generate a pair with `swiftc -O -o /tmp/sign-update scripts/sign-update.swift && /tmp/sign-update --generate` and back up the private key in the keychain.
2. Put the new public key first in `UpdateConfig.publicKeys`, keeping the current one after it, and release as usual. That release is still signed with the current secret.
3. Once it's published, replace the `UPDATE_SIGNING_KEY` secret with the new private key. Later releases are signed with it, and the old public key can be dropped from the list.

Replacing the code signing certificate makes macOS ask for the camera once more, after the update that brings it.
