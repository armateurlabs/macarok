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

Home contains Recently Added, Recently Played, and Most Played. Most Played has separate horizontal Tracks, Artists, and Albums rows, each showing up to eight entries. Every library view, search, homepage section, and library shuffle follows the selected library scope.

The three panels share a 42-point bar header and a full-width bottom divider. Library search/navigation sits below its header. Album artwork is square; captions reserve two title lines and one artist line. The permanent Context / Lyrics selector preserves context navigation when switching modes. Sources can be added directly from Settings while the main window is closed; the presenting window owns connection and certificate dialogs.

A single click inspects an item. Double-clicking a library track appends it to the active playlist without interrupting playback. Double-clicking a playlist entry plays it. The library double-click action is configurable.

Double-clicking an artist or album always appends its complete selection, including when search shows only some matching tracks. The configurable double-click preference applies to individual tracks. Artist, album, and track context menus offer Add After Current Track, which inserts the selection in order immediately after the current queue entry without interrupting it. Without a current entry, the selection appends to the queue. Repeated copies receive independent queue identities.

Right-click a track, album, or artist to choose Play Now. It appends the selection to the active playlist and immediately starts its first track. Album and artist actions resolve the complete selection even when search shows only some matching tracks.

Clear Playlist removes every entry except the current one, preserving its playback state and position. This also keeps a paused or still-loading current track. Without a current entry, it empties the playlist.

Search retains the selected library presentation: artist/album hierarchy, albums, years, folders, or tags. The query persists across tabs; clearing it restores the complete source catalog. Home listening history remains scoped to the complete selected source.

## Sources and connections

The application supports local files, OpenSubsonic servers, and podcasts. Existing single-source selection remains the default. The optional All Sources scope combines cached indexes without starting network scans. Artists group by case/whitespace-normalized name. Albums and tracks remain distinct copies with source labels, and Folders has one root per source. Playlist entries, credentials, history, artwork, file writes, and lyrics retain their actual source references.

Scope selection persists across launches and migrates the former selected-source preference. Adding/removing sources preserves All Sources. Show in Library keeps All Sources when it includes the selected track. Snapshot and search publication checks both scope and source-list revision. All Sources refresh runs source jobs serially, publishes partial progress, preserves committed caches, continues after individual failures, and summarizes errors. Each included local source has its own watcher and coalesced rescan request.

Direct cloud-storage access requires a separate feasibility study. Future integrations may include Spotify, Qobuz, and Deezer. Bandcamp already works when exposed through OpenSubsonic; there is no separate Bandcamp connector. Keep source access modular, with future connector placeholders visibly unavailable. Web radio is outside the initial release.

Support HTTP and HTTPS. Self-signed certificates require explicit acceptance, remembered for the relevant server. Certificate changes require a new decision. Apply a consistent source-specific trust policy to metadata requests, artwork, and audio delivery.

### Current OpenSubsonic catalog loading

Connecting a server retrieves its album list in pages of 500. Each page's albums are imported before requesting the next page. Each completed album is committed immediately to SQLite, and the first album is published before the next request. Later UI updates are coalesced to roughly 750 ms, with catalog snapshots read off the main thread. Browsing, search, and adding tracks to the queue are available while the rest of the catalog loads. This does not request a server-side file scan.

SQLite retains the indexed titles, artists, albums, tags, durations, remote IDs, paths, and cover references. Startup and source switching display this cached catalog immediately; an explicit Refresh currently repeats the complete metadata traversal. Audio files are requested only for playback, through an in-memory streaming buffer. Cover images are fetched on demand and stored in the separate Artwork cache.

Cancellation or a later request failure keeps both the previous cache and newly committed albums usable. Missing-track reconciliation runs only after a successful complete retrieval and updates only availability differences. An interrupted import remains marked incomplete across restarts; Refresh traverses the catalog again. Remote cover caches survive refresh while their cover IDs remain unchanged.

All library navigation reads an immutable `LibrarySnapshot` prepared off the main thread. Albums, artists, years, tags, statistics, folder trees, and folder membership are grouped once per catalog revision. View bodies consume ready arrays and lookups; collapsed groups create their children only when opened. Each track path is resolved once and its folder prefixes are assembled in one pass.

SQLite reads and search-result preparation run in cancellable background tasks. Repeated reloads for one source coalesce behind one worker; source changes cancel the previous request and clear its displayed data immediately. Source/request guards reject obsolete results and errors. `LibraryBackgroundWorker` serializes catalog, metadata, queue, rating, and history writes away from the UI. Refresh generations reject obsolete catalog writes, while queue revisions prevent an older save from replacing a newer one. Normal application termination waits for the queue save.

Remote artwork completion uses a targeted album/source/cover-ID update instead of rereading the entire catalog. Existing artwork choices are preserved, queued artwork is updated, and visible library reloads are coalesced.

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

The playback engine samples VLC's actual clock on a main-run-loop timer registered in common modes, keeping the timeline updated while an AppKit menu is open. It does not extrapolate elapsed time. This avoids depending on VLCKit's notification timer, which the pinned version registers only in the default mode (see [the upstream implementation](https://github.com/videolan/vlckit/blob/master/Sources/Playback/VLCMediaPlayer.m)). Polling stops on pause, stop, completion, error, media replacement, and engine destruction.

There is no crossfade or crossfade setting. Gapless playback is desirable but does not block the first release.

One repeat button cycles through **None → Playlist → Track → None**. Both active modes use a selected appearance; track repeat adds a "1" indicator.

Shuffle mixes tracks within the selected artist, album, folder including subfolders, or the entire selected library scope.

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
