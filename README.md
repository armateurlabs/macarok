# Macarok

A native macOS music player inspired by Amarok 1.4: a searchable library, rich listening context, and an active playlist in three persistent panels.

**Status:** native macOS application in development. The SwiftUI app includes libVLC 4 playback, a SQLite library, local/OpenSubsonic/podcast sources, CUE tracks, and metadata/artwork editors.

## Download

Get the DMG from [GitHub Releases](https://github.com/armateurlabs/macarok/releases), open it, and drag Macarok to Applications. Release builds currently support Apple Silicon Macs with macOS 14 or later. They are ad-hoc signed and not notarized by Apple; macOS may block the first launch.

## Build and run

Requires macOS 14 or later and Xcode 26 / Swift 6.2 or later. Development is currently verified with Xcode 27.1 on Apple Silicon.

```sh
./scripts/build-app.sh release
open dist/Macarok.app
```

The build script embeds VLCKit, resource bundles, the app icon, notices, and the optional Chromaprint helper, then signs and verifies the application locally. The pinned VLC 4 development archive includes all Apple platforms, so its first download is approximately 910 MB. Subsequent builds use SwiftPM's cache. Set `MACAROK_INCLUDE_FPCALC=0` to omit audio fingerprinting.

Open `Package.swift` in Xcode for development, or use `swift build` and `swift test` from the command line. The app bundle is the recommended way to run the application with its resources and macOS integration.

To build a versioned disk image locally, run `./scripts/package-dmg.sh 0.1.0 1`. Tags such as `v0.1.0` trigger the GitHub Actions release workflow. See [release procedures](docs/RELEASING.md).

## Native application

- Three resizable panels: source-specific library, listening context, and active playlist.
- System, Light, and Dark appearances; artist, album, year, folder, and tag browsing.
- Local MP3, FLAC, Ogg Vorbis, Opus, and other TagLib/VLC formats; OpenSubsonic original streams; RSS/Atom podcasts.
- CUE sheets expose individual tracks without splitting the original audio.
- Persistent playlists, queue, listening history, ratings, and source-isolated search through SQLite/FTS5.
- Double-click to append a track; right-click a track, album, or artist for Play Now; contextual shuffle and a None / Playlist / Track repeat button.
- Mac media keys, configurable local and global shortcuts, and adjustable streaming buffering.
- Metadata cleanup, MusicBrainz release matching with change previews, TagLib file writes, and embedded/local/web artwork.
- Optional recording identification through Chromaprint and AcoustID, using your own application client key stored in Keychain.
- HTTP and HTTPS, with explicit server-specific trust for self-signed certificates shared by library, artwork, and audio requests.

The first release uses separate libraries for each source. Crossfade and quality-tuning controls are outside its scope. Gapless playback is optional. Commercial streaming services appear only as unavailable future connectors.

AcoustID lookup sends a fingerprint and duration after an explicit Identify action. It supports whole local files; individual CUE tracks use artist/album metadata search. Remote edits are local library overlays. Each local file replacement is atomic; an album spanning several files can be partially saved if a later file fails.

See [verification and remaining manual checks](docs/VERIFICATION.md), [testing and synthetic demo data](docs/TESTING.md), [product decisions](docs/PRODUCT.md), and the [direct cloud-storage feasibility study](docs/CLOUD-STORAGE.md).

## Native interface previews

Offscreen renders of the implemented SwiftUI views, using the synthetic demo collection:

![Native Home in light mode](design/native/home-light.png)

![Native CUE album in dark mode](design/native/cue-album-dark.png)

## Explore the mockups

Open the standalone preview on macOS:

```sh
open design/mockups/index.html
```

Use the switcher below the window to compare **Collection** and **Albums**. Both designs support System, Light, and Dark appearances through the monitor/sun/moon button.

- Browse source-specific Home, Artists, Albums, Years, Folders, and Tags views.
- Double-click a library track to append it; double-click a playlist entry to play it.
- Cycle the repeat button through **None → Playlist → Track → None**.
- Inspect CUE tracks, metadata editing, artwork selection, and settings.

The editable source is [macarok-ui.fragment.html](design/mockups/macarok-ui.fragment.html); [index.html](design/mockups/index.html) is the standalone preview.

## Design previews

### Collection · Light

![Collection design in light mode](design/mockups/collection-light.png)

### Albums · Dark

![Albums design in dark mode](design/mockups/albums-dark.png)

## Architecture

`MacarokCore` owns SQLite, indexing, CUE parsing, sources, network trust, streaming buffers, playlists, and metadata lookup. `MacarokAudio` wraps VLCKit 4. `MacarokMetadata` wraps the native TagLib bridge. `MacarokApp` contains the SwiftUI interface and playback orchestration.

Dependencies and binary artifacts are pinned in `Package.swift` and `Package.resolved`. See [third-party notices](Support/ThirdPartyNotices.md).

All code, identifiers, comments, and project documentation are written in English.

## License

Macarok is licensed under the [MIT License](LICENSE). Bundled dependencies retain their own licenses; see [third-party notices](Support/ThirdPartyNotices.md).
