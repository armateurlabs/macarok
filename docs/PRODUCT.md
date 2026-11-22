# Product and architecture decisions

Macarok is a native macOS music player inspired by Amarok 1.4. The first release targets personal use and a private beta.

**Current implementation:** a native SwiftUI application with libVLC 4 playback, SQLite persistence, source integrations, and TagLib file operations. Interactive design mockups remain available as a reference. See `docs/TESTING.md` for checks and review procedures.

## Interface and navigation

Preserve a dense, resizable three-panel layout:

- **Library:** source selection, search, and collection browsing.
- **Context:** selected or playing track, album information, lyrics, metadata, and listening statistics.
- **Active Playlist:** the playback queue and its controls.

Provide System, Light, and Dark appearances with readable selections, secondary text, artwork, and dialogs.

Library views include Artists, Albums, Years, Folders, and Tags, plus Podcasts when the scope contains a show (see [podcast library browsing](PODCASTS.md#library-browsing)). In All Sources, podcasts appear only in the Podcasts tab and the podcast sections of Home. Clicking an artist, album, track, or folder selects it natively (blue highlight) and inspects it; double-click or Return adds it as before. Any of these rows can be dragged onto the active playlist and dropped between entries, inserting the complete artist, album, or folder at that position. Playlist rows carry no click gestures, so an entry can be grabbed anywhere on its row to reorder it; double-click and the context menu are provided by the list. Folder browsing follows the source's directory hierarchy; tag browsing uses musical metadata. The arrow on each library section heading reverses that list between ascending and descending natural alphanumeric order (Years: oldest or newest first; Unknown Year stays last). Home shares the artist direction. Each direction persists, applies to search results, and never changes the playlist or playback. Album track order, Home rankings, and source roots keep their own order; podcast lists have their own date direction, newest first by default. The heading's context menu still shuffles the library or selected folder.

Home contains Recently Added, Recently Played, and Most Played. Most Played has separate horizontal Tracks, Artists, and Albums rows, each showing up to eight entries. Recently Played displays a fixed Last Played date in English and the local time zone. Every library view, search, homepage section, and library shuffle follows the selected library scope. All Sources adds a separate Radio Favorites section; stations do not enter music rankings.

The three panels share a 42-point bar header and a full-width bottom divider. Library search/navigation sits below its native macOS source picker, which shows source icons and the checked selection. The search field has a clear button (Escape also clears it); the library views form one grouped control, and a divider then opens the list with its heading, item count, and sort direction on the list's own background. The title bar omits the redundant left app title and refresh button. Album artwork is square; captions reserve two title lines and one artist line. Sources can be added directly from Settings while the main window is closed; the presenting window owns connection and certificate dialogs.

The central panel has two centered segmented menu rows with stable heights. Home / Playing selects the main view. Home offers All, Recently added, Recently played, and Most played, filtering the displayed sections. Playing offers Context, Lyrics, Wikipedia, YouTube, Edit song metadata, and Edit album metadata; Context retains its Overview / Tags detail choice. Automatic track changes update the central playback context without changing these menu selections or the library's browsing scope. Home keeps its selected filter while playback advances.

Settings → General → Center Panel contains **Show Playing automatically**, a native picker with three choices and no explanatory subtext:

- **Every manually started track** is the default. Play Now, playlist double-click, Play from stopped, and manual Next/Previous that starts another track show Playing, overriding earlier Home navigation.
- **First playback after app launch** allows one initial switch per application launch, unless the user navigated in the central panel before that start.
- **First playback after Stop or playlist end** allows one initial switch per playback session. An application-level stop or queue completion rearms it; central navigation after that boundary can suppress the first switch.

Navigation occurs when a valid explicit playback request is accepted. An active metadata or artwork editor prevents this navigation and retains its original target and draft. A protected request, or one that later fails or is cancelled, consumes its one-shot opportunity without a delayed switch. Pause/resume, buffering, automatic advance/repeat, queue restoration, and Undo preserve the selected view; radio pause/resume is a continuation even though its stream reconnects. Internal decoder stops do not rearm session navigation. Switching to Playing retains its submenu, Overview/Tags choice, Home filter, and browsing scope. The preference persists across launches; changing it affects future starts without immediate navigation or rearming a consumed opportunity.

An active metadata or artwork editor pins its original track and draft while playback continues. Switching to Home does not discard an unfinished metadata session. Returning to Playing restores that editor. Choosing Context, Lyrics, Wikipedia, or YouTube releases an inactive metadata draft's pin and resumes following playback; returning to its editor restores the original draft. Switching directly between fresh song and album editors keeps the visible editing target, while an existing draft keeps its own target. Artwork and modal metadata sheets stay pinned until closed. Saving a metadata draft changes only its edited fields, retaining newer artwork, listening history, and unrelated concurrent tag corrections. A save completing after the editor is left preserves any later manual inspection.

Library and playlist lists use the same native alternating row style. The unused viewport below the last actual row stays plain, including after adding/removing entries, resizing, scrolling, or expanding folders. A transparent view covers only that unused canvas; native row selection, keyboard navigation, drag operations, context menus, and scrollbars remain owned by AppKit. Every list shows its selection as a soft accent tint instead of the strong system band, so labels keep their colors: adjacent selected rows merge into one rounded block, and the tint turns neutral while the window is inactive. In the playlist, a fully selected album reads as a stronger header band above a lighter body. Buttons, controls, and menus, including the source picker, keep the system accent.

The playback bar keeps Previous, Play/Pause, and Next at the leading edge and the volume at the trailing edge. Between them, one boxed unit uses the available width: the artwork, the title with “Artist — Album” (or the current podcast chapter, or the radio station) below it, then the timeline with the elapsed time and duration, level with the volume. Click the title to show the track in the library; click the artwork to see it enlarged at full resolution; its context menu offers **Choose Artwork…** for music and **Show Current Track**.

Settings → General → Menu Bar offers **Show Macarok in the menu bar**, disabled by default and remembered across launches. Clicking the system menu bar item opens a compact native player with album artwork, the current title and artist, Play/Pause or radio Reconnect, Previous, Next, Show Macarok, and Quit Macarok. Playback controls remain available while the main window is closed. Disabling the option removes the item without changing playback or keyboard preferences.

A single click inspects an item. Double-clicking a library track, album, or artist starts its first available track when the active playlist is empty. With an existing playlist, individual tracks follow the Track double-click preference: Add to Playlist, Add After Current Track, or Play Now. Double-clicking a playlist entry plays that existing entry.

Double-clicking an artist or album always appends its complete selection, including when search shows only some matching tracks. The configurable double-click preference applies to individual tracks. Artist, album, and track context menus offer Add After Current Track, which inserts the selection in order immediately after the current queue entry without interrupting it. Without a current entry, the selection appends to the queue. Repeated copies receive independent queue identities.

Right-click a track, album, or artist to choose Play Now. It appends the selection to the active playlist and immediately starts its first track. Album and artist actions resolve the complete selection even when search shows only some matching tracks.

Clear Playlist preserves the exact current entry and position while playing, opening, or buffering. When paused, stopped, failed, or without a current entry, it empties the playlist. Shuffle, repeat, clear, and the save/export menu appear at both the top and bottom of the playlist panel. **Show Album Groups** is on by default; it is one persisted preference in both More (`…`) menus and in Settings › General. It places an Amarok-style header (artwork, album, album artist, year, track count, and duration) above adjacent entries from the same source-specific album. A lone album entry shows its artwork inline instead. Headers are display-only: they cannot be selected, moved, or deleted. Queue order, duplicate entries, separate source copies, selection, playback, and drag/delete offsets are unchanged. Radio entries stay flat. Disabling the option restores the compact list. When browsing All Sources, a grouped album names its source once in its header, beside the artist and year; its entries gain no extra line. Lone and ungrouped entries keep their inline source badge. **Show Sources**, also in both More menus and Settings, hides every playlist source badge; it is available only while browsing All Sources.

Playlist content edits support native Undo / Redo in their normal order: adding, inserting, removing, moving, shuffling, clearing, and loading a saved playlist. Undo preserves entry identities and updated metadata; it does not autoplay or seek. An existing live entry continues if it survives the restored queue, and stops if the undo removes it. Text fields and editors retain their own native undo behavior. Queue undo history is cleared when sources are removed.

Search retains the selected library presentation: artist/album hierarchy, albums, years, folders, or tags. The query persists across tabs; clearing it restores the complete source catalog. Home listening history remains scoped to the complete selected source.

## Sources and connections

The application supports local files, OpenSubsonic servers, Bandcamp through OpenSubsonic, podcasts, Internet radio, and the Internet Archive's Live Music Archive and LibriVox collections. Existing single-source selection remains the default. The optional All Sources scope combines cached indexes without starting network scans. Artists group by case/whitespace-normalized name. Albums and tracks remain distinct copies with source labels, and Folders has one root per source. Playlist entries, credentials, history, artwork, file writes, and lyrics retain their actual source references.

Scope selection persists across launches and migrates the former selected-source preference. Adding/removing sources preserves All Sources. Show in Library keeps All Sources when it includes the selected track. Snapshot and search publication checks both scope and source-list revision. All Sources refresh runs source jobs serially, publishes partial progress, preserves committed caches, continues after individual failures, and summarizes errors. Each included local source has its own watcher and coalesced rescan request.

The source catalog includes a Bandcamp preset for `https://bandcamp.com/api/subsonic`, generated Subsonic username/password fields, and official setup links. Qobuz, Deezer, and Spotify have no playback or account connection in Macarok and do not appear in Add Source. Direct cloud-storage access remains a separate feasibility study. See [source setup and availability](SOURCES.md).

Podcast discovery offers Podcast Index by default and an Apple Podcasts selector. Search returns publisher feeds; Use Feed fills the subscription sheet, and Subscribe retrieves the chosen RSS/Atom feed. Search has cancellation, caching, rate limits, and explicit errors. Direct feed entry remains available.

Podcast streaming retains a bounded RAM buffer; durable episode files require Download Episode. Completed downloads stay until explicitly removed, and Reveal in Finder locates the source-specific file. The timeline layers gray unavailable data, white buffered/downloaded ranges, and blue playback progress. Byte-to-time coverage is approximate for variable bitrate, and unknown lengths have no percentage. See [podcast storage and cleanup](PODCASTS.md).

Podcast episodes within a feed use publication dates in descending order throughout the library and search, with undated episodes last. The timeline uses a 16-point filled circle, light gray in Dark and dark gray in Light, centered on the played-progress endpoint. Its full-width 32-point-high native interaction area accepts direct clicks and dragging, including above and below the thin bar. Only the seek cell smooths movement toward confirmed playback samples, for at most 200 milliseconds; controls, lyrics, history, and scrobbling retain the measured audio time. The native volume control retains its existing visible border.

Wikipedia context uses artist or album metadata for an English Wikipedia page or search result, with editable search and Open in Browser. Loading is limited to the visible pane, follows the central pinned/current target, and rejects obsolete navigation. The unmodified page retains its own attribution and licenses. See [Wikipedia context](WIKIPEDIA.md).

The YouTube tab plays the song's video in YouTube's embedded player and pauses the music when the video starts. Share sends the song with its Wikipedia and YouTube links through the native macOS share menu. See [YouTube and sharing](YOUTUBE.md).

Internet Archive collections (Live Music Archive and LibriVox) are browsed on demand rather than imported. The library pane has Browse, Saved, and Recent tabs with drill-down navigation, paged results, and a SQLite response cache with offline fallback. Items become library tracks only when played, queued, or saved. A quality preference chooses lossless or MP3 files. LibriVox books remember their resume point, support chapter downloads, and are not scrobbled. See [source setup](SOURCES.md#internet-archive-live-music-archive-and-librivox).

Internet Radio is a persistent source with Stations and Favorites views, URL entry, and Radio Browser directory filters for name, country, language, and tags. Stations remain separate from music albums, artists, and statistics. Direct streams and bounded M3U/PLS resolution are supported; HLS is explicitly unsupported. ICY broadcast metadata is stripped from audio and displayed as live information. Live playback has no seek timeline or saved resume offset. Pause closes the live connection; resume reconnects. Disconnections expose an explicit Reconnect action, without an automatic retry loop.

Support HTTP and HTTPS. Self-signed certificates require explicit acceptance, remembered for the relevant server. Certificate changes require a new decision. Apply a consistent source-specific trust policy to metadata requests, artwork, and audio delivery.

### Current OpenSubsonic catalog loading

Connecting a server retrieves its album list in pages of 500. Each page's albums are imported before requesting the next page. Each completed album is committed immediately to SQLite, and the first album is published before the next request. Later UI updates are coalesced to roughly 750 ms, with catalog snapshots read off the main thread. Browsing, search, and adding tracks to the queue are available while the rest of the catalog loads. This does not request a server-side file scan. Refreshing a server whose catalog is already cached keeps that catalog unchanged while it reads, then publishes it once at the end, only if something changed; an active library search is updated at the same time.

SQLite retains the indexed titles, artists, albums, tags, durations, remote IDs, paths, and cover references. Startup and source switching display this cached catalog immediately; an explicit Refresh currently repeats the complete metadata traversal. After launch, a quiet background pass rescans local folders from their file cache and re-imports a server catalog only when the server reports a change ([Sources](SOURCES.md)). OpenSubsonic audio is requested for playback through an in-memory streaming buffer. Cover images are fetched on demand and stored in the separate Artwork cache.

Cancellation or a later request failure keeps both the previous cache and newly committed albums usable. Missing-track reconciliation runs only after a successful complete retrieval and updates only availability differences. An interrupted import remains marked incomplete across restarts; Refresh traverses the catalog again. Remote cover caches survive refresh while their cover IDs remain unchanged.

Library and playlist footers share a fixed single-row height, an opaque native control background, and a top divider, distinct from the full-width status bar. Library totals and refresh controls share that row; compact widths keep the full counts and action available through accessible labels and tooltips.

The library footer starts refresh, changes to Stop Refresh while active with its progress in the window status bar, and waits in Stopping while cancellation completes. Cancelling clears already queued local rescans so the same operation does not immediately restart.

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

Podcast RSS durations are provisional display hints. Decoded media duration controls seeking and resume bounds, while HTTP buffering uses a bounded fallback instead of estimating bitrate from an unverified RSS duration. Nearby seeks reuse retained bytes. Timeline gestures retain their requested timestamp until VLC acknowledges it; stale gestures cannot seek a replacement queue entry. Servers without HTTP byte-range support disable seeking and discard unsupported resume requests while playback continues normally. A stopped, restored, finished, or still-preparing entry behaves like Apple Music: the timeline and Left / Right move only its start point, and Play begins there. A disabled timeline uses a lighter thumb and explains why seeking is unavailable.

The playback engine samples VLC's actual clock on a main-run-loop timer registered in common modes, keeping the timeline updated while an AppKit menu is open. It does not extrapolate elapsed time. This avoids depending on VLCKit's notification timer, which the pinned version registers only in the default mode (see [the upstream implementation](https://github.com/videolan/vlckit/blob/master/Sources/Playback/VLCMediaPlayer.m)). Polling stops on pause, stop, completion, error, media replacement, and engine destruction.

A progress watchdog checks the decoded position and available native audio-output counters against a monotonic clock. Preparation, pause, sleep, seeks, and large sampling gaps reset or suspend observation. Startup and buffering have longer deadlines, extended for a configured prebuffer; live streams use a longer progress deadline. Incoming network bytes do not conceal a frozen decoder. Media without an observable playback clock or output counter is reported as unmonitored rather than assumed silent. Each playback occurrence can raise one incident; recovery keeps the current queue entry and offers retry or radio reconnect instead of silently advancing.

**Help → Playback Diagnostics…** opens a native panel with current playback state, native output/decode/read counters when available, stream buffer size, reader waits, and player-installation/transition timings. Its circular event log retains the latest 200 events in session memory. Copy and Export are explicit actions; clearing the log does not reset watchdog recovery protection. Diagnostic exports contain typed states, counters, timestamps, and random playback-occurrence identifiers. They exclude track titles, source names, network addresses, file paths, credentials, and arbitrary error descriptions, and are never uploaded automatically.

There is no crossfade or crossfade setting. Gapless playback is desirable but does not block the first release.

The repeat control cycles through **None → Playlist → Track → None**. Its copies at the top and bottom of the playlist share state. Both active modes use a selected appearance; track repeat adds a "1" indicator.

Library shuffle mixes tracks within the selected artist, album, folder including subfolders, or entire library scope, then appends that batch. It starts playback only when the queue was empty. Playlist shuffle reorders the existing queue while retaining the current entry and its playback position.

Support Mac media keys and customizable in-app and global shortcuts. Space toggles playback inside the application when the user is not editing text.

Bare Left / Right seek by five seconds per press. Holding either key continues through the operating system's repeat events, with clamping at track boundaries. Releasing the key, changing playback occurrence, or leaving the player window resets the hold. The keys also seek while the timeline or the active playlist has focus. Text editing, shortcut recording, sheets, library outlines, and other native controls retain their normal arrows. Bare arrows are reserved for seeking; the default Command-Left / Command-Right shortcuts remain Previous / Next.

## Optional Last.fm scrobbling

Scrobbling is disabled until the user supplies personal Last.fm API credentials and completes browser authorization. The API key, shared secret, and session are stored in Keychain; preferences and the submission queue use SQLite. There is no bundled shared key or password-based login inside Macarok.

Local and OpenSubsonic music sources can be individually excluded. Podcasts and radio are always excluded. Eligible plays qualify after half a track's duration or four minutes, with a minimum known duration greater than 30 seconds; unknown durations use four minutes. Listening uses monotonic time, excludes pauses/buffering/seeks, and treats repeats as separate occurrences. Existing library history is never uploaded retroactively.

Now Playing is separately configurable. Qualified plays are persisted and delivered oldest first, with retry and pending/ignored/failed counts. Disconnect removes the saved session and stops submission while retaining that account's pending plays. Reconnecting the same account resumes them; another account cannot submit them. See [Last.fm setup and privacy](SCROBBLING.md).

## Similar playlists and mixes

Library, Playing, and playlist menus can replace the active playlist with a fixed similar playlist, unlimited by default, or a dynamic mix that announces only the next track. Skip Suggestion and Next exclude a recording for the rest of the mix; suggestions can follow the seed, the last played track, or both. Similarity comes from Last.fm (with a personal API key) and ListenBrainz similar artists, matched to tracks in every local and OpenSubsonic source. See [similar playlists and mixes](RECOMMENDATIONS.md).

## Library, metadata, and artwork

Use SQLite through GRDB, with FTS5 for library search. Store source references, indexed metadata, playlists, listening history, statistics, external identifiers, and pending metadata changes. Reindexing preserves playlists and listening history.

Model files separately from tracks. A CUE sheet referencing one FLAC produces individual library and playlist tracks with their own boundaries, metadata, and statistics. Preserve the original audio file. Track-specific metadata belongs in the textual CUE sheet; shared album metadata and artwork belong in the audio file.

Use TagLib for metadata reading and writing. Build enrichment around MusicBrainz, with Chromaprint/AcoustID available for identification. Use beets and Picard as workflow references.

Preview proposed changes, preserve unknown tags, and respect personal corrections. Find artwork in embedded metadata and local folders, then through web providers such as Cover Art Archive. Allow selected artwork to be embedded in audio files and optionally saved alongside the album.

Writing tags to remote originals requires a source that provides file-write access; OpenSubsonic library edits must not imply that the server's audio file was modified.

### Album metadata editing

**Edit song metadata** and **Edit album metadata** have separate drafts. The album editor exposes only Album, Album artist, Artist (all tracks), Year, and Genre. It resolves every available track in the original source and album, even when a search displays only a subset. An identically named album in another source is a separate target. The visible editor keeps its source/album target when playback advances or Home is shown. Other Playing views follow playback while preserving that draft for a later return.

Only shared fields changed in the draft are applied. Unchanged per-track artists, titles, track/disc numbers, CUE timestamps, artwork, listening history, ratings, and unrelated concurrent corrections are preserved. The protection checkbox controls whether local corrections survive future scans; remote corrections remain library overlays.

**Save to Files** explicitly confirms local writes. Each physical audio file is written once through the verified TagLib writer; external CUE sheets are updated once, and textual embedded CUE changes are committed together with shared audio tags. Album-artist changes preserve inherited per-track performers unless Artist (all tracks) is explicitly changed. Unknown tags, CUE directives, audio frames, and segment boundaries remain intact. A multi-file save can partially succeed; an error reports completed destinations and retains the draft. **Save to Library** changes only Macarok's index for remote sources. Artwork uses the separate Change Artwork action.

## Development conventions

Use SwiftUI, adding AppKit where necessary. Keep playback, persistence, source access, and metadata processing separate from interface code.

All code, identifiers, comments, and project documentation are written in English.
