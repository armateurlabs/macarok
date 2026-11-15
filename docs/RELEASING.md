# Releasing Macarok

The `Release macOS DMG` GitHub Actions workflow runs when a tag beginning with `v` is pushed. Release versions use `vMAJOR.MINOR.PATCH`, optionally followed by a prerelease suffix such as `v0.2.0-beta.1`.

## Publish a release

1. Commit the changes and optional English release notes in `docs/releases/VERSION.md`.
2. Push the commit to GitHub.
3. Create and push an annotated tag:

   ```sh
   git tag -a v0.1.0 -m "Macarok 0.1.0"
   git push origin v0.1.0
   ```

The workflow validates the version, runs the complete test suite, builds the Release app, and creates a compressed DMG and its SHA-256 file. It uploads the verified files to a draft GitHub release and publishes it after both assets are attached. Tags containing a prerelease suffix create prereleases. Curated release notes are used when present; otherwise GitHub generates notes.

The build uses GitHub's hosted Apple Silicon `xcode-27` preview runner with Xcode 27.1. Actions and package dependencies are pinned. The release job uses the repository's automatic `GITHUB_TOKEN`; no personal access token or additional release secret is required. Build jobs have read access to repository contents; only the publishing job receives write access.

Release files are named `Macarok-VERSION-arm64.dmg` and `Macarok-VERSION-arm64.dmg.sha256`. They target Apple Silicon and macOS 14 or later. The full release version is recorded in the app's information string; its numeric version is stored in `CFBundleShortVersionString`, and the workflow run number supplies `CFBundleVersion`.

## Build and inspect locally

```sh
./scripts/package-dmg.sh 0.1.0 1
cd dist
shasum -a 256 -c Macarok-0.1.0-arm64.dmg.sha256
```

The script builds and signs the app, embeds its MIT license and dependency notices, creates the disk image, verifies it, then mounts it read-only to check the app signature, versions, licenses, and Applications link. The tracked `Support/Info.plist` is not changed. An existing DMG or checksum with the same name is never overwritten automatically.

The application is ad-hoc signed, without Apple notarization. No Developer ID certificate or Apple credentials are currently configured. Signing and notarization can be added later with dedicated credentials. State this distribution status in release notes.

To inspect a workflow run, use `gh run list --workflow release.yml` and `gh run view RUN_ID --log-failed`. Failed builds do not publish a release. If asset upload fails, a draft may remain; rerunning the publishing job can reuse a draft only when it targets the same tag and exact commit. Published releases are never overwritten. The workflow also checks that the tag still resolves to the built commit before publishing; never move a published tag.
