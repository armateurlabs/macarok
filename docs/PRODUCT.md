# Product and architecture decisions

Macarok is a native macOS music player inspired by Amarok 1.4. The first release targets personal use and a private beta.

**Current implementation:** a native SwiftUI application with libVLC 4 playback, SQLite persistence, source integrations, and TagLib file operations. Interactive design mockups remain available as a reference. See `docs/TESTING.md` for checks and review procedures.

## Interface and navigation

Preserve a dense, resizable three-panel layout:

- **Library:** source selection, search, and collection browsing.
- **Context:** selected or playing track, album information, lyrics, metadata, and listening statistics.
- **Active Playlist:** the playback queue and its controls.

Provide System, Light, and Dark appearances with readable selections, secondary text, artwork, and dialogs.

Library views include Artists, Albums, Years, Folders, and Tags. Folder browsing follows the source's directory hierarchy; tag browsing uses musical metadata.

Home contains Recently Added, Recently Played, and Most Played. Most Played can show albums, tracks, or artists. Every library view, search, and homepage section belongs to the selected source.

A single click inspects an item. Double-clicking a library track appends it to the active playlist without interrupting playback. Double-clicking a playlist entry plays it. The library double-click action is configurable.

## Sources and connections

The first iteration supports local files, OpenSubsonic servers, and podcasts. Each configured source has a separate library. Playlist entries retain their source references.

Direct cloud-storage access requires a separate feasibility study. Future integrations may include Spotify, Qobuz, Deezer, and Bandcamp. Keep source access modular, with future connector placeholders visibly unavailable. Web radio is outside the initial release.

Support HTTP and HTTPS. Self-signed certificates require explicit acceptance, remembered for the relevant server. Certificate changes require a new decision. Apply a consistent source-specific trust policy to metadata requests, artwork, and audio delivery.

## Playback and controls

Use **libVLC 4 through VLCKit 4**, pinned to a development artifact and checksum. The selected distribution is:

```text
Artifact: VLCKit-4.0-20261109-1916.zip
URL: https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20261109-1916.zip
SHA-256: 1fec7232f88e706f44d9a015133e08d742166eb2666cb44915c9f570bf339463
```

Reference: [VideoLAN's VLCKit package manifest](https://github.com/videolan/vlckit/blob/master/Package.swift). The repository's `Package.swift` pins this binary directly.

Support MP3, FLAC, Ogg Vorbis, and Ogg Opus for local and remote playback. Request original-quality streams where available, without bitrate or output-format tuning controls in the first iteration.

Streaming Buffer has Automatic and Custom modes. Custom buffering specifies a target duration in seconds.

There is no crossfade or crossfade setting. Gapless playback is desirable but does not block the first release.

One repeat button cycles through **None → Playlist → Track → None**. Both active modes use a selected appearance; track repeat adds a "1" indicator.

Shuffle mixes tracks within the selected artist, album, folder including subfolders, or the entire selected-source library.

Support Mac media keys and customizable in-app and global shortcuts. Space toggles playback inside the application when the user is not editing text.

## Library, metadata, and artwork

Use SQLite through GRDB, with FTS5 for library search. Store source references, indexed metadata, playlists, listening history, statistics, external identifiers, and pending metadata changes. Reindexing preserves playlists and listening history.

Model files separately from tracks. A CUE sheet referencing one FLAC produces individual library and playlist tracks with their own boundaries, metadata, and statistics. Preserve the original audio file. Track-specific metadata belongs in the textual CUE sheet; shared album metadata and artwork belong in the audio file.

Use TagLib for metadata reading and writing. Build enrichment around MusicBrainz, with Chromaprint/AcoustID available for identification. Use beets and Picard as workflow references.

Preview proposed changes, preserve unknown tags, and respect personal corrections. Find artwork in embedded metadata and local folders, then through web providers such as Cover Art Archive. Allow selected artwork to be embedded in audio files and optionally saved alongside the album.

Writing tags to remote originals requires a source that provides file-write access; OpenSubsonic library edits must not imply that the server's audio file was modified.

## Development conventions

Use SwiftUI, adding AppKit where necessary. Keep playback, persistence, source access, and metadata processing separate from interface code.

All code, identifiers, comments, and project documentation are written in English.
