# Testing Macarok

## Automated checks

```sh
swift test
```

The core tests cover source-isolated SQLite search, reindexing without lost history or playlists, CUE timestamps and native sample boundaries, artwork caching, explicit file and playlist imports, OpenSubsonic requests, podcast parsing, and playlist serialization.

`LibraryScopeTests` and `AllSourcesTests` cover aggregate FTS reads, normalized artists, duplicate album IDs and folder paths across origins, global rankings before limiting, persisted selection migration, held snapshots during source creation/removal, serial progressive refresh with an offline origin, cancellation, and coalesced local-origin rescans.

`LyricsTests`, `OpenSubsonicLyricsTests`, and `LyricsControllerTests` use injected providers/transports to cover resolution precedence, manual corrections, metadata fingerprints, cache misses, duration matching, throttling/Retry-After, provider serialization, late responses, sheet targets, and line highlighting after seek/pause. `LyricsFileServiceTests` exercises MP3/FLAC/Vorbis/Opus round-trips, unrelated tag preservation, FLAC audio-frame preservation, CUE slicing/export reloads, and partial-write failures. These tests do not contact LRCLIB or submit lyrics.

The suite also exercises actual VLCKit playback of synthetic MP3, FLAC, Vorbis, and Opus; CUE segment boundaries; a throttled HTTP stream that starts before download completes; validated Range seeking; and live loopback HTTPS certificate acceptance, changes, and rejection. Controller tests cover queue restoration, duplicate entries, shortcut disabling, refresh cancellation, and changes received during a scan.

The menu-tracking regression plays a silent WAV through real VLC while pumping only the main run loop's event-tracking mode. Sentinel timers verify that default-mode sources stay suspended and common-mode sources run. The playback position must advance before returning to the default loop, and remain stable after pause or stop. This regression fails against the former delegate-only timeline updates.

`WindowLayoutTests` verifies that all three panels fill the native hosting window when resized, including startup without sources, an empty source, an empty queue, and unmatched search results. It checks actual split-view geometry in both appearances without imposing a fixed-size SwiftUI root.

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

This renders Home, All Sources with duplicate names, narrow/wide layouts, artist albums, synchronized/empty Lyrics, a CUE album, track tags, Settings, and the metadata editor in both appearances using offscreen AppKit/SwiftUI views. `AlbumTileGeometryTests` measures mixed title lengths and square/portrait/landscape artwork before and after loading. These checks do not capture the screen or verify mouse, keyboard, file-picker, or media-key interaction.

## Run without using the regular library database

```sh
./scripts/build-app.sh
MACAROK_DATA_DIRECTORY="$PWD/.build/demo-data" ./dist/Macarok.app/Contents/MacOS/Macarok
```

Add `.build/demo-library` through the application's music-folder picker. The custom data directory selects an isolated SQLite database. Appearance and keyboard preferences continue to use the application's normal macOS preferences.

Verify that the track count matches `.macarok-demo.json`; the continuous album should contain three tracks, with no additional full-album audio entry. Check the Artists, Albums, Years, Folders, and Tags views, source-scoped search, and local cover images.

Double-clicking a library track should append it without interrupting playback. Double-clicking a queue entry should play that entry. Verify repeat cycles through None, Playlist, and Track; check next/previous, position seeking, media keys, and custom shortcuts. Confirm that typing spaces in a search field does not pause playback.

Clear Playlist should keep only the current queue entry and leave its playback position and playing/paused state intact. It must also keep a track that is still opening. Without a current entry, the playlist should become empty. Restarting should restore the retained track and position.

Right-click tracks, albums, and artists in the library and Home lists. Play Now should append the selection and start it immediately. Search for part of an album, switch library tabs, and confirm that each tab keeps its normal grouping and the query remains visible. Choosing Play Now for a matching album or artist should include its complete track list.

Double-click artist and album rows to append their complete selection while keeping playback intact. Choose Add After Current Track on each entity type; confirm insertion order, independent duplicate queue entries, and unchanged playback position. Without a current entry, the same action appends at the end.

Open each codec-check file and verify playback advances without an error. For CUE tracks, inspect tags and confirm that playback starts and ends at the selected segment. Export an M3U playlist and import it again to verify that segment boundaries survive.

Use a second folder or a test OpenSubsonic server to verify single-source browsing, then choose All Sources. Duplicate albums/tracks should remain distinct with source labels; artists with matching case/whitespace-normalized names should group together. Folder roots stay source-specific. Search and shuffle follow the scope. Switching scope should not interrupt playback. Restart to verify persisted selection; use Refresh All Sources to verify progressive serial imports, partial caches, and error summaries.

Open Lyrics while playing, pause and seek, and toggle Auto-scroll. Switch browsing sources and inspect another track; lyrics should keep following the current queue entry. Use Find Lyrics and Edit / Paste; change playback while an editor is open and confirm the correction applies to its original target. Save to Files only against generated fixtures, then reload ordinary and CUE sidecars. Close the main window, open Settings → Sources, and add a test source, including certificate acceptance/rejection and closing a pending connection dialog. Switch between System, Light, and Dark appearances and inspect selections, artwork, metadata sheets, and settings.

For real-server integration checks, use a dedicated OpenSubsonic account and podcast feed. Exercise HTTP, valid HTTPS, and a self-signed server: certificate acceptance is scoped to that server, and changed certificates require a new decision. Playback, artwork, and library requests should follow the same trust policy.

The [loopback demo server](DEMO-SERVER.md) provides an isolated OpenSubsonic library, podcast feed, covers, lyrics, and Range-enabled audio without an external account.
