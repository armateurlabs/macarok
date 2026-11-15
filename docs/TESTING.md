# Testing Macarok

## Automated checks

```sh
swift test
```

The core tests cover source-isolated SQLite search, reindexing without lost history or playlists, CUE timestamps and native sample boundaries, artwork caching, explicit file and playlist imports, OpenSubsonic requests, podcast parsing, and playlist serialization.

`LibraryScopeTests` and `AllSourcesTests` cover aggregate FTS reads, normalized artists, duplicate album IDs and folder paths across origins, global rankings before limiting, persisted selection migration, held snapshots during source creation/removal, serial progressive refresh with an offline origin, cancellation, and coalesced local-origin rescans.

`LyricsTests`, `OpenSubsonicLyricsTests`, and `LyricsControllerTests` use injected providers/transports to cover resolution precedence, manual corrections, metadata fingerprints, cache misses, duration matching, throttling/Retry-After, provider serialization, late responses, sheet targets, and line highlighting after seek/pause. `LyricsFileServiceTests` exercises MP3/FLAC/Vorbis/Opus round-trips, unrelated tag preservation, FLAC audio-frame preservation, CUE slicing/export reloads, and partial-write failures. These tests do not contact LRCLIB or submit lyrics.

The suite also exercises actual VLCKit playback of synthetic MP3, FLAC, Vorbis, and Opus; CUE segment boundaries; a throttled HTTP stream that starts before download completes; validated Range seeking; and live loopback HTTPS certificate acceptance, changes, and rejection. Controller tests cover queue restoration, duplicate entries, shortcut disabling, refresh cancellation, and changes received during a scan.

`PlaybackSeekInteractionTests` covers both native slider callback orders, interrupted drags, and stale releases after a queue transition. Podcast seek checks use synthetic variable-bitrate MP3 audio over loopback HTTP and wait for playback to advance from the requested timestamp. RSS duration hints are used for initial presentation, not byte-buffer sizing or resume bounds; VLC's decoded duration replaces them when available. A server that refuses byte ranges must disable seeking, discard unsupported pending resume points, and keep normal playback and pause/resume working.

`QueuePreferenceTests`, `QueueBehaviorTests`, and `ClearPlaylistTests` cover legacy preference migration, empty-playlist double-click playback, append/after-current choices, shuffled batch append, exact duplicate entry identities, ordered Undo / Redo with updated metadata, active/paused/stopped clear behavior, persistence, and held-arrow seek targets. `SourcePickerTests` checks the real native popup control, source icons, checked selection, and unchanged queue when changing browsing scope.

`RadioAndDiscoveryTests`, `LiveRadioStreamTests`, and `RadioSnapshotTests` cover station persistence, radio/music partitioning, bounded directory requests, M3U/PLS resolution, HLS rejection, ICY framing and metadata timing, podcast directory responses, throttling, and cancellation. Network fixtures replace public directory responses. `LastFMTests` and `ScrobblingControllerTests` use injected HTTP, credentials, time, and browser handling to check signed requests, authorization, listening thresholds, source exclusions, durable ordered delivery, retries, and account changes without authorizing or submitting to a real Last.fm account.

The menu-tracking regression plays a silent WAV through real VLC while pumping only the main run loop's event-tracking mode. Sentinel timers verify that default-mode sources stay suspended and common-mode sources run. The playback position must advance before returning to the default loop, and remain stable after pause or stop. This regression fails against the former delegate-only timeline updates.

`WindowLayoutTests` verifies that all three panels fill the native hosting window when resized, including startup without sources, an empty source, an empty queue, and unmatched search results. It checks actual split-view geometry in both appearances without imposing a fixed-size SwiftUI root.

`CenterNavigationTests` covers retained Home filters and Context tabs, playback-following behavior, pinned metadata/artwork targets, late editor completion, and merging drafts without replacing newer artwork or history. `ScrobblingSettingsAlignmentTests` checks the real credential text fields in the grouped macOS Form in both appearances, using injected fake credentials without Keychain or network access.

Progressive catalog tests gate API responses and controller batches to prove that tracks are persisted, searchable, and queueable before completion. They cover cancellation, later request failures, stale refresh generations, source changes, and success-only reconciliation. Folder tests include a synthetic 30,000-track, 7,000-folder catalog and cancellation; the folder tree is built off the main thread.

`LibrarySnapshotTests` covers the prepared navigation groups, deterministic sorting, cancellation, and a synthetic 50,000-track/5,000-album/100-year catalog. `LibraryResponsivenessTests` deliberately holds background loads while exercising all navigation buttons, a MainActor heartbeat, and queue persistence; it also checks coalescing and stale source/error rejection. The comparator tests cover missing disc/track numbers and strict ordering contracts.

`LibrarySearchPresentationTests` verifies grouped results in each library view, query preservation across tabs, clearing the query, source isolation, and complete album selection from a partial search result. Buffer regressions drain multi-megabyte responses through repeated prefix compaction, then exercise seeking and closing without corrupting bytes or trapping on nonzero `Data` indices.

To exercise the optional real fingerprint helper as well:

```sh
./scripts/fetch-fingerprint-helper.sh
MACAROK_FPCALC_PATH="$PWD/.build/tools/chromaprint/fpcalc" swift test
```

AcoustID and MusicBrainz protocol tests use fixtures; no service key or personal music is needed. Try a known recording manually with your own AcoustID application client key to check live identification results.

## Generate an isolated music collection

```sh
python3 scripts/create-demo-library.py .build/demo-library
```

This creates a **Macarok Demo** collection using synthetic music metadata. Its playable audio contains silence by default, so automated playback checks remain quiet. Pass `--audible` to generate quiet test tones for manual listening.

The collection contains:

- Two artists with three WAV tracks each, album tags, years, genres, and local `cover.png` artwork.
- One continuous audio file with a CUE sheet defining three individual tracks, including an INDEX 00 pregap marker.
- An M3U playlist containing ordinary files and CUE segment boundaries, plus a PLS playlist containing whole files.
- MP3, FLAC, Ogg Vorbis, and Ogg Opus codec checks when the corresponding ffmpeg encoders are installed.

The script uses Python's standard library. ffmpeg is optional; `--no-codecs` disables it. A hidden `.macarok-demo.json` manifest records generated files and the expected track count. With `--force`, the script replaces only files recorded by a previous generated demo.

Native component renders can be generated after creating the demo library:

```sh
MACAROK_SNAPSHOT_DIRECTORY="$PWD/.build/native-snapshots" swift test --filter NativeRenderingTests
```

This renders Home and its three focused filters, All Sources with duplicate names, narrow/wide layouts, artist albums, synchronized/empty Lyrics, a CUE album, track tags, Settings, the metadata editor, source catalog, podcast discovery, Internet Radio library, and minimum-width playlist controls in all repeat states. Inline metadata renders cover 370- and 590-point panels and a queue change while a draft remains pinned. Header geometry checks exercise the real native segmented controls in both appearances, with both navigation rows centered at a stable height. `AlbumTileGeometryTests` measures mixed title lengths and square/portrait/landscape artwork before and after loading. These checks do not capture the screen or verify physical keyboard, file-picker, or media-key interaction.

## Run without using the regular library database

```sh
./scripts/build-app.sh
MACAROK_DATA_DIRECTORY="$PWD/.build/demo-data" ./dist/Macarok.app/Contents/MacOS/Macarok
```

Add `.build/demo-library` through the application's music-folder picker. The custom data directory selects an isolated SQLite database. Appearance and keyboard preferences continue to use the application's normal macOS preferences.

Verify that the track count matches `.macarok-demo.json`; the continuous album should contain three tracks, with no additional full-album audio entry. Check the Artists, Albums, Years, Folders, and Tags views, source-scoped search, and local cover images.

With an empty playlist, double-click a track, album, and artist in separate runs; each should start playback. With an existing playlist, test the three Track double-click choices: Add to Playlist, Add After Current Track, and Play Now. Album and artist double-clicks always append their complete track lists. Double-clicking a playlist entry should play that existing entry. Check these actions from Home as well as library groups and partial search results.

The top and bottom playlist controls should both shuffle, cycle None → Playlist → Track → None, clear, save, and export. Both repeat indicators must update together. Check that they remain visible at the minimum window width. The former double-click footer hint and title-bar refresh control should be absent.

Choose All Sources and compare playlist rows with single-source browsing. Each entry should remain two lines high: title, then artist with its source label inline. Long artist/source names should truncate without adding a third line, and duration or LIVE should remain visible.

Use the centered Home / Playing selector and its second header row in both appearances and at narrow/wide widths. Both rows must retain the same vertical positions through populated, empty, loading, lyrics, and editing states. Home → All shows every section; Recently added, Recently played, and Most played hide the other sections. Switching to Playing and back should retain the chosen Home filter.

In Playing → Context, choose Tags and advance to another queue entry. Its tags should update while Context and Tags remain selected. Repeat while Lyrics is selected. Open Edit metadata, type a draft, and advance the queue: the editor must retain its original title, source, and draft while the playback indicator shows the new entry. Return Home and back to Playing; the draft should still be present. Save or Cancel should return to Context and follow the current queue entry without resetting Overview / Tags. Use generated files when saving.

Open Change Artwork while editing, then advance playback through media controls or automatic completion. The artwork chooser and underlying editor should retain their original target. Closing the artwork chooser must preserve any metadata draft; leaving the metadata editor should resume following playback. Check that the Last.fm API key field aligns its text to the left in Settings.

Clear Playlist should keep only the exact current entry while playing, opening, or buffering, with uninterrupted position. Pause, clear, and confirm the entire queue becomes empty. Repeat for a stopped or restored playlist. Command-Z should undo Clear without autoplay or seeking; Shift-Command-Z should redo it. Add after Clear and confirm Undo removes the new addition before undoing Clear. Repeat with removal, move, shuffle, duplicate tracks, and updated metadata. Editing text must retain its own undo history.

Press Left / Right to seek by five seconds, then hold them to continue through OS repeat. Check both boundaries, pause, CUE tracks, and a track transition while a key remains held. Release and press again on the new track. Command-Left / Command-Right remain Previous / Next by default. Text fields, lyrics editing, source popup navigation, and shortcut recording should keep their native arrows. Confirm typing spaces in search does not pause playback and bare arrows cannot silently override a custom shortcut assignment.

Right-click tracks, albums, and artists in the library and Home lists. Play Now should append the selection and start it immediately. Search for part of an album, switch library tabs, and confirm that each tab keeps its normal grouping and the query remains visible. Choosing Play Now for a matching album or artist should include its complete track list.

Double-click artist and album rows to append their complete selection while keeping playback intact. Choose Add After Current Track on each entity type; confirm insertion order, independent duplicate queue entries, and unchanged playback position. Without a current entry, the same action appends at the end.

Choose library, album, artist, and folder shuffle with an existing playing or paused queue. The shuffled selection should append while retaining the existing entries and current position. An empty queue should start the first shuffled track. Playlist shuffle should rearrange only existing entries. Recently Played dates should stay fixed as time passes and use English labels with local dates/times.

Open each codec-check file and verify playback advances without an error. For CUE tracks, inspect tags and confirm that playback starts and ends at the selected segment. Export an M3U playlist and import it again to verify that segment boundaries survive.

Use a second folder or a test OpenSubsonic server to verify single-source browsing, then choose All Sources. Duplicate albums/tracks should remain distinct with source labels; artists with matching case/whitespace-normalized names should group together. Folder roots stay source-specific. Search and shuffle follow the scope. Switching scope should not interrupt playback. Restart to verify persisted selection; use Refresh All Sources to verify progressive serial imports, partial caches, and error summaries.

Use the native source picker with the keyboard and mouse; verify its selected icon/checkmark in both appearances. Start a refresh from the library footer, stop it after partial results appear, and verify the Stopping state completes, partial data remains usable, and already queued watcher scans do not immediately restart it. A new explicit refresh should work afterward.

Open Lyrics while playing, pause and seek, and toggle Auto-scroll. Switch browsing sources and inspect another track; lyrics should keep following the current queue entry. Use Find Lyrics and Edit / Paste; change playback while an editor is open and confirm the correction applies to its original target. Save to Files only against generated fixtures, then reload ordinary and CUE sidecars. Close the main window, open Settings → Sources, and add a test source, including certificate acceptance/rejection and closing a pending connection dialog. Switch between System, Light, and Dark appearances and inspect selections, artwork, metadata sheets, and settings.

For real-server integration checks, use a dedicated OpenSubsonic account and podcast feed. Exercise HTTP, valid HTTPS, and a self-signed server: certificate acceptance is scoped to that server, and changed certificates require a new decision. Playback, artwork, and library requests should follow the same trust policy.

The [loopback demo server](DEMO-SERVER.md) provides an isolated OpenSubsonic library, podcast feed, covers, lyrics, and Range-enabled audio without an external account.

## Source discovery and optional services

Use [source setup](SOURCES.md) to inspect each catalog choice. The Bandcamp preset should fill its endpoint and link to official account/setup pages; a live account check uses generated Subsonic credentials. Qobuz, Deezer, and Spotify cards should open official information pages without presenting a fake connection.

Search podcasts with Podcast Index, then Apple Podcasts. Select Use Feed and confirm subscription still requires Subscribe in the source sheet. Cancel or change provider during a request and confirm old results cannot replace the new state. Direct feed entry should work independently of either directory. Re-subscribing to a known feed should select its existing source.

Add an isolated radio stream URL or browse Radio Browser. Save a station to Favorites, restart, and verify Stations/Favorites and the separate All Sources Home section. Confirm radio never appears as a music album, artist ranking, or counted play. Check direct, M3U, and PLS streams; HLS must report unsupported. With an ICY fixture, verify changing broadcast titles and uninterrupted audio. Live playback must have no seek timeline or saved resume offset; pause closes the connection and resume reconnects. Disconnect the fixture and verify Reconnect is offered without an automatic retry loop.

Follow [Last.fm setup](SCROBBLING.md) only for an explicit live-account check. Confirm browser authorization, Complete Connection, source exclusions, and separate Now Playing control. Use a dedicated listening session to check the threshold, buffering/pause/seek exclusion, repeated tracks, and offline queue delivery after restart. Podcasts and radio must not submit. Disconnect removes the saved account session and stops submission while retaining account-specific pending events. Reconnecting the same account with its original API credentials resumes those events without uploading old local listening history; another account must not submit them. Automated tests use fixtures and cannot verify the public account authorization page or a real listening profile.
