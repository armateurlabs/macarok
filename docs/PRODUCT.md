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

### Current OpenSubsonic catalog loading

Connecting a server retrieves its album list in pages of 500. Each page's albums are imported before requesting the next page. Each completed album is committed immediately to SQLite, and the first album is published before the next request. Later UI updates are coalesced to roughly 750 ms, with catalog snapshots read off the main thread. Browsing, search, and adding tracks to the queue are available while the rest of the catalog loads. This does not request a server-side file scan.

SQLite retains the indexed titles, artists, albums, tags, durations, remote IDs, paths, and cover references. Startup and source switching display this cached catalog immediately; an explicit Refresh currently repeats the complete metadata traversal. Audio files are requested only for playback, through an in-memory streaming buffer. Cover images are fetched on demand and stored in the separate Artwork cache.

Cancellation or a later request failure keeps both the previous cache and newly committed albums usable. Missing-track reconciliation runs only after a successful complete retrieval and updates only availability differences. An interrupted import remains marked incomplete across restarts; Refresh traverses the catalog again. Remote cover caches survive refresh while their cover IDs remain unchanged.

Folder browsing builds a cancellable snapshot off the main thread. Each track path is resolved once and its folder prefixes are assembled in one pass, rather than rescanning every track for each folder. A source/revision guard prevents an older snapshot from appearing after a source change or a newer catalog update.

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
