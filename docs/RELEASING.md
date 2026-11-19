# Releasing Macarok

The `Release macOS DMG` GitHub Actions workflow runs when a tag beginning with `v` is pushed. Release versions use `vMAJOR.MINOR.PATCH`, optionally followed by a prerelease suffix such as `v0.2.1-beta.1`.

## Publish a release

1. Commit the changes and optional English release notes in `docs/releases/VERSION.md`.
2. Push the commit to GitHub.
3. Create and push an annotated tag:

   ```sh
   git tag -a v0.2.1 -m "Macarok 0.2.1"
   git push origin v0.2.1
   ```

The workflow validates the version, runs the complete test suite, builds the Release app, and creates a compressed DMG and its SHA-256 file. It uploads the verified files to a draft GitHub release and publishes it after both assets are attached. Tags containing a prerelease suffix create prereleases. Curated release notes are used when present; otherwise GitHub generates notes.

Before testing, the workflow generates its own synthetic demo library with `--no-codecs` for native rendering checks. Playback codec tests use the committed fixtures in `Tests/MacarokAudioTests/Fixtures`; optional ffmpeg conversions are not required on the runner.

The build uses GitHub's hosted Apple Silicon `xcode-27` runner with Xcode 27.1. Actions and package dependencies are pinned. Dependency caches can fall back across manifest changes for the same OS, architecture, and Xcode version; SwiftPM still resolves the pinned dependencies. The release job uses the repository's automatic `GITHUB_TOKEN`; no personal access token or additional release secret is required. Build jobs have read access to repository contents; only the publishing job receives write access.

Release files are named `Macarok-VERSION-arm64.dmg` and `Macarok-VERSION-arm64.dmg.sha256`. They target Apple Silicon and macOS 14 or later. The full release version is recorded in the app's information string; its numeric version is stored in `CFBundleShortVersionString`, and the workflow run number supplies `CFBundleVersion`.

## Build and inspect locally

```sh
./scripts/package-dmg.sh 0.2.1 3
cd dist
shasum -a 256 -c Macarok-0.2.1-arm64.dmg.sha256
```

The script builds and signs the app, embeds its MIT license and dependency notices, creates the disk image, verifies it, then mounts it read-only to check the app signature, versions, licenses, and Applications link. The tracked `Support/Info.plist` is not changed. An existing DMG or checksum with the same name is never overwritten automatically.

The application is ad-hoc signed by default, without Apple notarization. No Developer ID certificate or Apple credentials are currently configured. Signing and notarization can be added later with dedicated credentials. State this distribution status in release notes.

## Sign with a personal certificate

An ad-hoc signature identifies the app by its code hash, so macOS treats every build as a new app: Keychain asks again for access to saved source credentials, and privacy permissions can be requested again. Signing with one stable certificate keeps the app's designated requirement across updates (`identifier "com.armateurlabs.Macarok" and certificate root = …`), so privacy permissions and a Keychain **Always Allow** carry over. It does not satisfy Gatekeeper for downloaded disk images; that requires an Apple Developer ID and notarization.

Without an Apple Developer Team ID, the login keychain still records each build's code hash in the partition list of the items it reads. Every update, including one signed with the same certificate, therefore asks once per saved item (Last.fm and each server) for the login keychain password. Only a Developer ID signature, which provides a Team ID partition, avoids that prompt.

1. Create the certificate once: **Keychain Access → Certificate Assistant → Create a Certificate…**, name it (for example `Macarok Personal Signing`), identity type **Self-Signed Root**, certificate type **Code Signing**.
2. Export it with its private key as a `.p12` file with a password, and import that file on your other Macs.
3. Sign local builds with it: `MACAROK_SIGNING_IDENTITY="Macarok Personal Signing" ./scripts/build-app.sh release` (or `package-dmg.sh`). `MACAROK_SIGNING_KEYCHAIN` can name a specific keychain. Without the variable, builds stay ad-hoc signed.
4. Let the release workflow use it by adding two repository secrets:

   ```sh
   base64 -i Macarok-Signing.p12 | gh secret set MACAROK_SIGNING_P12_BASE64
   gh secret set MACAROK_SIGNING_P12_PASSWORD
   ```

   The workflow imports the certificate into a temporary keychain, signs the app, and deletes the keychain. Without these secrets it keeps ad-hoc signing.

The first launch after switching from ad-hoc to the certificate asks for Keychain access; choose **Always Allow** so the app is not asked again on each read. As described above, each later update still asks once per saved item for the login keychain password.

A downloaded disk image is still quarantined, so Gatekeeper blocks each new version once. On your own Macs, either approve it in **System Settings → Privacy & Security → Open Anyway**, or remove the quarantine after copying the app:

```sh
xattr -dr com.apple.quarantine /Applications/Macarok.app
```

Building on the Mac itself with `./scripts/build-app.sh` produces an app without quarantine.

To inspect a workflow run, use `gh run list --workflow release.yml` and `gh run view RUN_ID --log-failed`. Failed builds do not publish a release. If asset upload fails, a draft may remain; rerunning the publishing job can reuse a draft only for the same tag. Published releases are never overwritten. The workflow checks that the tag still resolves to the built commit before publishing; never move a published tag.

If workflow configuration needs fixing after a tag was pushed, commit the fix on `main` and use the manual retry input to rebuild that existing tag with the updated workflow:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0
```

The retry checks out the requested tag for the app, tests, packaging scripts, and release notes. The tag stays unchanged, and the publishing job verifies the built commit against it. The workflow run number supplies the new bundle build number.

Release creation uses `--verify-tag` without `--target`: the tag already exists and its commit was checked explicitly. Sending an older commit as `target_commitish` can require workflow-modification permissions when its workflow files differ from the default branch, even for an existing tag. Omitting this unused field lets the automatic token publish without additional credentials. See [GitHub's release API documentation](https://docs.github.com/en/rest/releases/releases#create-a-release).
