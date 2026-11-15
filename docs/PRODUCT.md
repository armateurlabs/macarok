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

Home contains Recently Added, Recently Played, and Most Played. Most Played has separate horizontal Tracks, Artists, and Albums rows, each showing up to eight entries. Recently Played displays a fixed Last Played date in English and the local time zone. Every library view, search, homepage section, and library shuffle follows the selected library scope. All Sources adds a separate Radio Favorites section; stations do not enter music rankings.

The three panels share a 42-point bar header and a full-width bottom divider. Library search/navigation sits below its native macOS source picker, which shows source icons and the checked selection. The title bar omits the redundant left app title and refresh button. Album artwork is square; captions reserve two title lines and one artist line. Sources can be added directly from Settings while the main window is closed; the presenting window owns connection and certificate dialogs.

The central panel has two centered segmented menu rows with stable heights. Home / Playing selects the main view. Home offers All, Recently added, Recently played, and Most played, filtering the displayed sections. Playing offers Context, Lyrics, and Edit metadata; Context retains its Overview / Tags detail choice. Track changes update the central playback context without changing these menu selections or the library's browsing scope. Home keeps its selected filter while playback advances.

An active metadata or artwork editor pins its original track and draft while playback continues. Switching to Home does not discard an unfinished metadata session. Returning to Playing restores that editor; finishing it catches up with the current track. Saving a metadata draft changes only its edited fields, retaining newer artwork, listening history, and unrelated concurrent tag corrections.

A single click inspects an item. Double-clicking a library track, album, or artist starts its first available track when the active playlist is empty. With an existing playlist, individual tracks follow the Track double-click preference: Add to Playlist, Add After Current Track, or Play Now. Double-clicking a playlist entry plays that existing entry.

Double-clicking an artist or album always appends its complete selection, including when search shows only some matching tracks. The configurable double-click preference applies to individual tracks. Artist, album, and track context menus offer Add After Current Track, which inserts the selection in order immediately after the current queue entry without interrupting it. Without a current entry, the selection appends to the queue. Repeated copies receive independent queue identities.

Right-click a track, album, or artist to choose Play Now. It appends the selection to the active playlist and immediately starts its first track. Album and artist actions resolve the complete selection even when search shows only some matching tracks.

Clear Playlist preserves the exact current entry and position while playing, opening, or buffering. When paused, stopped, failed, or without a current entry, it empties the playlist. Shuffle, repeat, clear, and the save/export menu appear at both the top and bottom of the playlist panel.

Playlist content edits support native Undo / Redo in their normal order: adding, inserting, removing, moving, shuffling, clearing, and loading a saved playlist. Undo preserves entry identities and updated metadata; it does not autoplay or seek. An existing live entry continues if it survives the restored queue, and stops if the undo removes it. Text fields and editors retain their own native undo behavior. Queue undo history is cleared when sources are removed.

Search retains the selected library presentation: artist/album hierarchy, albums, years, folders, or tags. The query persists across tabs; clearing it restores the complete source catalog. Home listening history remains scoped to the complete selected source.

## Sources and connections

The application supports local files, OpenSubsonic servers, Bandcamp through OpenSubsonic, podcasts, and Internet radio. Existing single-source selection remains the default. The optional All Sources scope combines cached indexes without starting network scans. Artists group by case/whitespace-normalized name. Albums and tracks remain distinct copies with source labels, and Folders has one root per source. Playlist entries, credentials, history, artwork, file writes, and lyrics retain their actual source references.

Scope selection persists across launches and migrates the former selected-source preference. Adding/removing sources preserves All Sources. Show in Library keeps All Sources when it includes the selected track. Snapshot and search publication checks both scope and source-list revision. All Sources refresh runs source jobs serially, publishes partial progress, preserves committed caches, continues after individual failures, and summarizes errors. Each included local source has its own watcher and coalesced rescan request.

The source catalog includes a Bandcamp preset for `https://bandcamp.com/api/subsonic`, generated Subsonic username/password fields, and official setup links. Qobuz, Deezer, and Spotify have no playback or account connection in Macarok and do not appear in Add Source. Direct cloud-storage access remains a separate feasibility study. See [source setup and availability](SOURCES.md).

Podcast discovery offers Podcast Index by default and an Apple Podcasts selector. Search returns publisher feeds; Use Feed fills the subscription sheet, and Subscribe retrieves the chosen RSS/Atom feed. Search has cancellation, caching, rate limits, and explicit errors. Direct feed entry remains available.

Internet Radio is a persistent source with Stations and Favorites views, URL entry, and Radio Browser directory filters for name, country, language, and tags. Stations remain separate from music albums, artists, and statistics. Direct streams and bounded M3U/PLS resolution are supported; HLS is explicitly unsupported. ICY broadcast metadata is stripped from audio and displayed as live information. Live playback has no seek timeline or saved resume offset. Pause closes the live connection; resume reconnects. Disconnections expose an explicit Reconnect action, without an automatic retry loop.

Support HTTP and HTTPS. Self-signed certificates require explicit acceptance, remembered for the relevant server. Certificate changes require a new decision. Apply a consistent source-specific trust policy to metadata requests, artwork, and audio delivery.

### Current OpenSubsonic catalog loading

Connecting a server retrieves its album list in pages of 500. Each page's albums are imported before requesting the next page. Each completed album is committed immediately to SQLite, and the first album is published before the next request. Later UI updates are coalesced to roughly 750 ms, with catalog snapshots read off the main thread. Browsing, search, and adding tracks to the queue are available while the rest of the catalog loads. This does not request a server-side file scan.

SQLite retains the indexed titles, artists, albums, tags, durations, remote IDs, paths, and cover references. Startup and source switching display this cached catalog immediately; an explicit Refresh currently repeats the complete metadata traversal. Audio files are requested only for playback, through an in-memory streaming buffer. Cover images are fetched on demand and stored in the separate Artwork cache.

Cancellation or a later request failure keeps both the previous cache and newly committed albums usable. Missing-track reconciliation runs only after a successful complete retrieval and updates only availability differences. An interrupted import remains marked incomplete across restarts; Refresh traverses the catalog again. Remote cover caches survive refresh while their cover IDs remain unchanged.

The library footer starts refresh, changes to Stop Refresh while active, shows progress, and waits in Stopping while cancellation completes. Cancelling clears already queued local rescans so the same operation does not immediately restart.

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

Podcast RSS durations are provisional display hints. Decoded media duration controls seeking and resume bounds, while HTTP buffering uses a bounded fallback instead of estimating bitrate from an unverified RSS duration. Nearby seeks reuse retained bytes. Timeline gestures retain their requested timestamp until VLC acknowledges it; stale gestures cannot seek a replacement queue entry. Servers without HTTP byte-range support disable seeking and discard unsupported resume requests while playback continues normally.

The playback engine samples VLC's actual clock on a main-run-loop timer registered in common modes, keeping the timeline updated while an AppKit menu is open. It does not extrapolate elapsed time. This avoids depending on VLCKit's notification timer, which the pinned version registers only in the default mode (see [the upstream implementation](https://github.com/videolan/vlckit/blob/master/Sources/Playback/VLCMediaPlayer.m)). Polling stops on pause, stop, completion, error, media replacement, and engine destruction.

There is no crossfade or crossfade setting. Gapless playback is desirable but does not block the first release.

The repeat control cycles through **None → Playlist → Track → None**. Its copies at the top and bottom of the playlist share state. Both active modes use a selected appearance; track repeat adds a "1" indicator.

Library shuffle mixes tracks within the selected artist, album, folder including subfolders, or entire library scope, then appends that batch. It starts playback only when the queue was empty. Playlist shuffle reorders the existing queue while retaining the current entry and its playback position.

Support Mac media keys and customizable in-app and global shortcuts. Space toggles playback inside the application when the user is not editing text.

Bare Left / Right seek by five seconds per press. Holding either key continues through the operating system's repeat events, with clamping at track boundaries. Releasing the key, changing playback occurrence, or leaving the player window resets the hold. Text editing, shortcut recording, sheets, and native control navigation retain their normal arrows. Bare arrows are reserved for seeking; the default Command-Left / Command-Right shortcuts remain Previous / Next.

## Optional Last.fm scrobbling

Scrobbling is disabled until the user supplies personal Last.fm API credentials and completes browser authorization. The API key, shared secret, and session are stored in Keychain; preferences and the submission queue use SQLite. There is no bundled shared key or password-based login inside Macarok.

Local and OpenSubsonic music sources can be individually excluded. Podcasts and radio are always excluded. Eligible plays qualify after half a track's duration or four minutes, with a minimum known duration greater than 30 seconds; unknown durations use four minutes. Listening uses monotonic time, excludes pauses/buffering/seeks, and treats repeats as separate occurrences. Existing library history is never uploaded retroactively.

Now Playing is separately configurable. Qualified plays are persisted and delivered oldest first, with retry and pending/ignored/failed counts. Disconnect disables scrobbling and clears pending submissions for the account. See [Last.fm setup and privacy](SCROBBLING.md).

## Library, metadata, and artwork

Use SQLite through GRDB, with FTS5 for library search. Store source references, indexed metadata, playlists, listening history, statistics, external identifiers, and pending metadata changes. Reindexing preserves playlists and listening history.

Model files separately from tracks. A CUE sheet referencing one FLAC produces individual library and playlist tracks with their own boundaries, metadata, and statistics. Preserve the original audio file. Track-specific metadata belongs in the textual CUE sheet; shared album metadata and artwork belong in the audio file.

Use TagLib for metadata reading and writing. Build enrichment around MusicBrainz, with Chromaprint/AcoustID available for identification. Use beets and Picard as workflow references.

Preview proposed changes, preserve unknown tags, and respect personal corrections. Find artwork in embedded metadata and local folders, then through web providers such as Cover Art Archive. Allow selected artwork to be embedded in audio files and optionally saved alongside the album.

Writing tags to remote originals requires a source that provides file-write access; OpenSubsonic library edits must not imply that the server's audio file was modified.

## Development conventions

Use SwiftUI, adding AppKit where necessary. Keep playback, persistence, source access, and metadata processing separate from interface code.

All code, identifiers, comments, and project documentation are written in English.
