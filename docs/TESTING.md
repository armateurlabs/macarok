# Testing Macarok

## Automated checks

```sh
swift test
```

The core tests cover source-isolated SQLite search, reindexing without lost history or playlists, CUE timestamps and native sample boundaries, artwork caching, explicit file and playlist imports, OpenSubsonic requests, podcast parsing, and playlist serialization.

`LibraryScopeTests` and `AllSourcesTests` cover aggregate FTS reads, normalized artists, duplicate album IDs and folder paths across origins, global rankings before limiting, persisted selection migration, held snapshots during source creation/removal, serial progressive refresh with an offline origin, cancellation, and coalesced local-origin rescans.

`LyricsTests`, `OpenSubsonicLyricsTests`, and `LyricsControllerTests` use injected providers/transports to cover resolution precedence, manual corrections, metadata fingerprints, cache misses, duration matching, throttling/Retry-After, provider serialization, late responses, sheet targets, and line highlighting after seek/pause. `LyricsFileServiceTests` exercises MP3/FLAC/Vorbis/Opus round-trips, unrelated tag preservation, FLAC audio-frame preservation, CUE slicing/export reloads, and partial-write failures. These tests do not contact LRCLIB or submit lyrics.

The suite also exercises actual VLCKit playback of synthetic MP3, FLAC, Vorbis, and Opus; CUE segment boundaries; a throttled HTTP stream that starts before download completes; validated Range seeking; and live loopback HTTPS certificate acceptance, changes, and rejection. Controller tests cover queue restoration, duplicate entries, shortcut disabling, refresh cancellation, and changes received during a scan.

`PlaybackEventQueueTests` checks installation of the retained asynchronous VLCKit event policy before media creation. A synthetic WAV exercises repeated playback, prepared-player replacement, stream-backed segments, pause discontinuities, and immediate stop/release. Notification observers verify that state and non-main time events use the configured queue, require actual queued time events, and confirm retired players are released. Framework main-thread timer notifications remain allowed. This regression targets notification autorelease reentry into libVLC's native timer lock; it does not replace the separate handoff and MainActor responsiveness checks.

`PlaybackSeekInteractionTests` covers both native slider callback orders, interrupted drags, and stale releases after a queue transition. Podcast seek checks use synthetic variable-bitrate MP3 audio over loopback HTTP and wait for playback to advance from the requested timestamp. RSS duration hints are used for initial presentation, not byte-buffer sizing or resume bounds; VLC's decoded duration replaces them when available. A server that refuses byte ranges must disable seeking, discard unsupported pending resume points, and keep normal playback and pause/resume working.

`PlaybackWatchdogTests` uses injected monotonic samples to check advancing and frozen clocks, native output counters, opening/buffering deadlines, large configured prebuffers, phase flapping, preparation, pause, sleep/sample gaps, explicit and missed seeks, radio without a timeline, and one recovery incident per playback occurrence. Incoming transport bytes must not mask a frozen decoder. `PlaybackEventLogTests` checks circular retention, overwrite counts, sequence identity, finite numeric sanitization, versioned JSON, and the closed diagnostic field vocabulary. `PlaybackDiagnosticsTests` checks publication of actual stream counters, event coalescing, seek integration, recovery protection after clearing the log, unavailable clock reporting, bounded explicit exports, and native Light/Dark rendering. Set `MACAROK_SNAPSHOT_DIRECTORY` to retain `playback-diagnostics-light.png` and `playback-diagnostics-dark.png`.

For manual diagnostics checks, open **Help → Playback Diagnostics…** while playing local music, a podcast, and radio. Confirm counters change, pausing stops playback progress, reader waits reflect a throttled stream, and a seek does not raise a watchdog incident. Test sleep/wake and reconnect after an intentional stream interruption. A stalled occurrence should stop with a retry/reconnect message while retaining its queue entry, without repeated automatic recovery. Copy or export the report, inspect its bounded numeric/state content, and confirm that it contains no track titles, source names, addresses, paths, or credentials. Clearing the event list must leave playback and its recovery protection intact.

`OpenSubsonicScanTests` uses an injected HTTP fixture to check `startScan` with and without the full-scan parameter, progress polling until the server reports completion, and recognition of a non-administrator refusal. `PodcastChaptersTests` checks chapter normalization, Podcasting 2.0 JSON (hidden entries and unsafe links), Podlove times, the notes heuristic and its rejections, and feed chapter storage with source deletion. `PlaybackTimelineBufferTests` also checks pixel gaps at chapter starts in the played and buffered layers in both appearances. `PodcastLibraryTests` covers chapter source priority, previous/next chapter targets, the Option-arrow key rule, relative episode dates, show and episode ordering in both directions, the All / Unplayed / Downloaded filters, New and Continue Listening selection, listening-state rules, due shows for automatic refresh, the podcast sort default for existing preferences, and resume positions. `PodcastStoreTests` checks show website and serial parsing, conditional GET with 304, and show, notes, and progress persistence with source deletion. `PodcastLibraryOrderTests` checks that All Sources keeps podcasts out of music lists and rankings while episodes stay addressable.

`PodcastDownloadTests` uses injected HTTP fixtures to verify explicit-only downloads, persisted files and manifests, source-specific identities, failures/cancellation, owned staging cleanup, retention, invalid paths/symlinks, external deletion, and duplicate-transfer protection. `PlaybackTimelineBufferTests` checks range gaps/clamps/unknown lengths and actual native gray/white/blue pixels in both appearances, including complete local-file coverage through the download controller. Its optional snapshots use `MACAROK_SNAPSHOT_DIRECTORY`.

`WikipediaPaneTests` checks metadata query encoding, artist/album targets, safe navigation, visibility cancellation, stale responses, and pinned-editor context. These tests use an offline navigation state and do not request Wikipedia pages.

`QueuePreferenceTests`, `QueueBehaviorTests`, and `ClearPlaylistTests` cover legacy preference migration, empty-playlist double-click playback, append/after-current choices, shuffled batch append, exact duplicate entry identities, ordered Undo / Redo with updated metadata, active/paused/stopped clear behavior, persistence, and held-arrow seek targets. `SourcePickerTests` checks the real native popup control, source icons, checked selection, and unchanged queue when changing browsing scope.

`RadioAndDiscoveryTests`, `LiveRadioStreamTests`, and `RadioSnapshotTests` cover station persistence, radio/music partitioning, bounded directory requests, M3U/PLS resolution, HLS rejection, ICY framing and metadata timing, podcast directory responses, throttling, and cancellation. Network fixtures replace public directory responses. `LastFMTests` and `ScrobblingControllerTests` use injected HTTP, credentials, time, and browser handling to check signed requests, authorization, listening thresholds, source exclusions, durable ordered delivery, retries, and account changes without authorizing or submitting to a real Last.fm account.

The menu-tracking regression plays a silent WAV through real VLC while pumping only the main run loop's event-tracking mode. Sentinel timers verify that default-mode sources stay suspended and common-mode sources run. The playback position must advance before returning to the default loop, and remain stable after pause or stop. This regression fails against the former delegate-only timeline updates.

`WindowLayoutTests` verifies that all three panels fill the native hosting window when resized, including startup without sources, an empty source, an empty queue, and unmatched search results. It checks actual split-view geometry in both appearances without imposing a fixed-size SwiftUI root.

`PanelFooterGeometryTests` checks matching 42-point library/playlist rows, compact-width thresholds, refresh/reconnect/stop transitions, and equal footer contrast distinct from the global status bar in Light/Dark.

`PlaybackTimelineSmoothingTests` uses injected sample times to verify bounded cell-only interpolation, immediate seek/pause/input updates, occurrence guards, and unchanged native/accessibility values; timeline pixel tests check the 16-point filled thumb, 32-point input height, and aligned blue endpoint. `PlaybackTimelineTrackingTests` also holds a drag open across stale clock/view writes and verifies exact final endpoints, cancellation, and authoritative values after an external seek. `PlaybackTimelineRoutingTests` hosts the complete TransportBar with decoded local and stream-backed media. It resolves the actual event receiver through NSHostingView hit testing, including points 15 points above/below the bar, then exercises the real interaction and engine callbacks for clicks and both drag directions in Light/Dark while paused/playing. A separate case preserves the disabled gate for genuinely unseekable media. The hidden test window suppresses NSWindow.sendEvent; events enter the receiver resolved by the real host, rather than selecting TimelineSlider directly.

`CenterNavigationTests` covers retained Home filters and Context tabs, playback-following behavior, visible editor and artwork pins, retained inactive drafts, direct song/album editor target inheritance, manual inspection across ordinary mode changes, late editor completion, and merging drafts without replacing newer artwork or history. `ScrobblingSettingsAlignmentTests` checks the real credential text fields in the grouped macOS Form in both appearances, using injected fake credentials without Keychain or network access.

`PlayingAutoSwitchTests` and `PlayingAutoSwitchPreferenceTests` exercise all three modes, additive preference decoding and round-trips, explicit versus automatic starts, prepared-player handoffs, genuine stop/session boundaries, and central navigation before the first start. Include failed/cancelled requests, a slow preparation completed after the user returns Home, mode changes during playback, and song/album/artwork editor protection. Verify that submenus, Overview/Tags, Home filters, and library scope survive; queue restoration and Undo must not trigger a switch. General rendering checks inspect the native picker in Light/Dark at 650 × 555 points with readable options and no helper text. Set `MACAROK_SNAPSHOT_DIRECTORY` to retain `playing-auto-switch-settings-light.png` and `playing-auto-switch-settings-dark.png`.

`AlbumMetadataEditorTests` checks complete source-specific album selection under search, duplicate albums in other sources, preserved queue identities and concurrent track corrections, ordinary FLAC tag/audio preservation, external CUE rescans, embedded CUE batching, and partial file-write errors. `AlbumMetadataRenderingTests` renders the real central album editor at 370 and 590 points in Light/Dark, verifying its five shared fields, pinned draft after a queue change, and centered native mode selectors with readable compact labels and full tooltips.

`NativeListBackgroundTests` compares pixels from a real SwiftUI List in both appearances: actual rows must alternate while the complete empty viewport remains uniform after 2 → 4 → 1 → 0 entries and resizing. It also checks pass-through hit testing, native selection/delegate preservation, and mask geometry during native outline expansion/collapse. `MenuBarControllerTests` uses an injected status-item host to check opt-in preference migration, enable/disable lifecycle, current action state, callbacks, and model updates without changing the user's system menu bar. `MenuBarMiniPlayerTests` renders the real popover content in both appearances, checks loaded cover pixels and same-path artwork replacement, and covers empty/radio presentations and disabled actions. The retained presentation must not keep its controller or application model alive.

Progressive catalog tests gate API responses and controller batches to prove that tracks are persisted, searchable, and queueable before completion. They cover cancellation, later request failures, stale refresh generations, source changes, and success-only reconciliation. Folder tests include a synthetic 30,000-track, 7,000-folder catalog and cancellation; the folder tree is built off the main thread.

`LibrarySnapshotTests` covers the prepared navigation groups, deterministic sorting, cancellation, and a synthetic 50,000-track/5,000-album/100-year catalog. `LibraryResponsivenessTests` deliberately holds background loads while exercising all navigation buttons, a MainActor heartbeat, and queue persistence; it also checks coalescing and stale source/error rejection. The comparator tests cover missing disc/track numbers and strict ordering contracts.

`LibrarySearchPresentationTests` verifies grouped results in each library view, query preservation across tabs, clearing the query, source isolation, and complete album selection from a partial search result. Buffer regressions drain multi-megabyte responses through bounded retained-chunk eviction, then exercise seeking and closing without corrupting bytes or trapping on nonzero `Data` indices. Transport tests also exercise playback/catalog isolation, reader wakeups, TLS trust parity, and download progress/cancellation.

To exercise the optional real fingerprint helper as well:

```sh
./scripts/fetch-fingerprint-helper.sh
MACAROK_FPCALC_PATH="$PWD/.build/tools/chromaprint/fpcalc" swift test
```

Standard AcoustID and MusicBrainz protocol tests use fixtures; no service key or personal music is needed. `AudioIdentificationTests` exercises fingerprint validation, helper failures, form POST requests, structured service errors, and empty versus populated recording metadata. With `MACAROK_FPCALC_PATH` set, helper integration additionally fingerprints synthetic WAV, MP3, FLAC, and Ogg audio, then checks a truncated synthetic FLAC that produces usable JSON with fpcalc exit status 3. That case retains its fingerprint and shows the fixed partial-decoding warning separately; unusable output and other process failures remain errors.

`RecordingIdentificationPreparationTests` covers moved directory bookmarks, moved or renamed explicitly selected files, off-main resolution/readability probes, removed or replaced sources during a blocked resolution, delayed bookmark renewal after persisted source deletion/replacement, task cancellation, missing/unreadable files, and CUE/remote rejection before local resolution. The fixtures use temporary synthetic files and fake bookmark environments without network or Keychain access.

The gated `AudioIdentificationTests.testLiveAcoustIDReferenceWhenClientKeyIsProvided` checks the official public-reference fingerprint against the live service only when `MACAROK_ACOUSTID_CLIENT_KEY` is supplied. Leave it unset for fixture-only runs. Supply an application client key through a no-echo terminal prompt and only the test process environment; keep it out of command literals, shell history, files, fixtures, and logs. The check establishes public-reference lookup; recognizing a specific recording requires a separate explicit manual check.

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

The same command renders `archive-live-` and `archive-librivox-` views of the Internet Archive sources. A separate isolated index holds saved items with the demo covers, and the browse and item responses are written to the archive response cache beforehand, so no request reaches archive.org.

Generate the additional album-editor previews independently:

```sh
MACAROK_SNAPSHOT_DIRECTORY="$PWD/.build/native-snapshots" swift test --filter AlbumMetadataRenderingTests
```

The output contains `album-metadata-light.png`, `album-metadata-dark.png`, and corresponding `album-metadata-narrow-` variants. The render uses an isolated two-track index, advances the current queue entry after editing the draft, and starts neither playback nor a source connection. The native-list pixel checks run with `swift test --filter NativeListBackgroundTests`; they do not need the demo collection. Setting the same snapshot variable additionally writes the initial two-row views as `list-rows-light.png` and `list-rows-dark.png` before the add/remove/resize checks.

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

In Settings → General → Center Panel, check that Show Playing automatically defaults to Every manually started track and contains exactly the three navigation choices, without explanatory subtext. Verify readable labels at the existing Settings window size in Light/Dark, persistence after restarting, and no immediate central navigation when changing the preference.

With the default mode, choose Home → Most played and manually start a track: the center should switch to Playing. Return Home, then let playback advance or repeat automatically; Home and its filter must remain selected. Pause/resume, including radio reconnection after pause, must also preserve Home. Start another entry explicitly through Play Now, playlist double-click, or manual Next/Previous and confirm Playing returns; Previous that only seeks to zero must preserve the current view. Restore a queue or use Undo without triggering a switch.

Choose First playback after app launch and restart the app. An untouched central panel should switch on the first accepted start only. In a separate launch, navigate centrally before the first start and confirm that view remains selected. Choose First playback after Stop or playlist end, stop fully, and restart playback without further central navigation: it should switch again. Repeat with central navigation after stopping and confirm that selection wins. Ordinary track transitions and internal decoder stops must not rearm it. For either one-shot mode, delay or fail playback preparation, navigate Home, then complete or retry the request; the consumed opportunity must not cause another switch. Open song/album metadata or artwork editing before an eligible start and confirm the original editor and draft remain protected, with no postponed switch after closing it.

In Playing → Context, choose Tags and advance to another queue entry. Its tags should update while Context and Tags remain selected. Repeat while Lyrics is selected. Open Edit song metadata, type a draft, and advance the queue: the editor must retain its original title, source, and draft while the playback indicator shows the new entry. Return Home and back to Playing; the draft should still be present. Save or Cancel should return to Context and follow the current queue entry without resetting Overview / Tags. Use generated files when saving.

Leave an unfinished song or album editor by selecting Context, Lyrics, or Wikipedia. Playing should catch up immediately and continue following subsequent tracks while keeping that mode and Overview/Tags selection. Return to the editor and confirm its original target and draft are restored. Switch directly from a song editor to a fresh album editor, and the reverse: both should use the visible editing target even when another track is playing. An already retained draft should restore its own target. Ordinary Context/Wikipedia switching must preserve a manually inspected selection until playback advances.

Start a song or album save, leave the editor, and inspect another track or album before saving completes. Completion should release the saved draft while retaining the later inspection and selected Playing mode. Completing the currently active editor should still return to Context and catch up with the current queue entry.

Open Change Artwork while editing, then advance playback through media controls or automatic completion. The artwork chooser and underlying editor should retain their original target. Closing the artwork chooser must preserve any metadata draft; leaving the metadata editor should resume following playback. Check that the Last.fm API key field aligns its text to the left in Settings.

Using generated local files, open Edit song metadata → Identify Recording. Check current-bookmark resolution after moving the source directory or renaming an explicitly selected audio file. Enter an AcoustID application client key, leave Remember in Keychain off for a temporary lookup, and verify optional save/removal separately. Identify should progress through fingerprint creation and lookup, then explicitly report matches or no recording metadata. A usable partially decoded file should retain its separate fixed warning through lookup completion; helper and service errors must remain distinct from an empty result. Cancel or leave the editor during preparation/lookup, change its target, or remove its source: obsolete work must not present a late sheet or update another draft. Selecting a match previews recording title/artist changes; Find Metadata still chooses an album edition, and saving remains explicit.

Open Edit album metadata from Playing or an album's context menu while search matches only one of its tracks. Confirm that all available tracks from that source's album are included, and that Album, Album artist, Artist (all tracks), Year, and Genre are the only editable fields. Change Album and Year, advance playback, and switch Home/Playing; the original album and draft must remain pinned. Save against generated ordinary files and CUE albums, rescan with protection disabled, and verify unchanged titles, per-track artists, numbering, audio, and CUE segment boundaries. An identically named album in another source must remain unchanged. Use the separate artwork action to verify that closing its chooser preserves the album draft.

Compare library and playlist alternation in Light/Dark with only a few entries, then add/remove entries, resize, scroll, and expand artists, albums, and folders. Actual rows should alternate; the area after the last real row must have no placeholder stripes. Selection, context menus, drag/reorder, and native keyboard navigation must continue working.

In Settings → General, verify that Show Macarok in the menu bar starts disabled. Enable it and click its icon to open the mini player. Check its artwork, English title/artist, and playback controls in Light/Dark, then close the main window and use Show Macarok to reopen it. Advance the queue while the popover is open; artwork and metadata should update and actions should control the current entry. Check radio Pause/Reconnect, disable the option during playback, and restart to confirm the preference is retained. Automated host tests cover state and callbacks; this manual check verifies actual macOS status-item presentation.

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

Use [source setup](SOURCES.md) to inspect each catalog choice. The Bandcamp preset should fill its endpoint and link to official account/setup pages; a live account check uses generated Subsonic credentials. Add Source should contain the five working connector choices, without the former Qobuz, Deezer, and Spotify information cards.

Search podcasts with Podcast Index, then Apple Podcasts. Select Use Feed and confirm subscription still requires Subscribe in the source sheet. Cancel or change provider during a request and confirm old results cannot replace the new state. Direct feed entry should work independently of either directory. Re-subscribing to a known feed should select its existing source.

For podcast playback, compare gray unavailable data, white buffered/downloaded coverage, and blue cursor progress in Light/Dark. Seek beyond the retained range and confirm the white bar does not invent a downloaded prefix. Unknown lengths should have no percentage; variable-bitrate time coverage is approximate. Choose Download Episode, cancel a transfer, then retry. Confirm a completed episode plays locally after disconnecting the network, Reveal in Finder selects the file, and Settings → Playback lists its size and folder. Restart and refresh without losing completed downloads. Use Remove Download on an inactive episode and verify that its file moves to Trash. See [storage and retention](PODCASTS.md).

Open Playing → Wikipedia with a known artist, switch Artist/Album, edit a query, and follow an article link. Change tracks while loading and leave the pane; obsolete navigation must not replace the current target or continue loading in the hidden pane. Keep an artwork sheet open while advancing playback and confirm Wikipedia retains that sheet's target until it closes. An inactive song/album draft must remain available without pinning Wikipedia. Check centered loading/error/empty states and Try Again while offline, and Open in Browser for the current page. Typing in native or embedded search fields must preserve text editing, arrows, Space, and Undo. Automated Wikipedia tests remain offline; these page checks use the public website.

`SimilarityTests` checks Last.fm and ListenBrainz parsing with injected HTTP replies, MusicBrainz artist resolution, SQLite cache lifetimes, lenient library matching, edition deduplication, exclusions, partial service failures, and artist diversity. `SimilarMixTests` covers playlist replacement, one announced track, Skip Suggestion, Next as a skip, Repeat during a mix, waiting for the next track, Restore Skipped Tracks, follow modes, fixed playlists, and ending a mix; set `MACAROK_SNAPSHOT_DIRECTORY` to retain `similar-mix-*` and `similar-sheet-*` renders. With a Last.fm API key, start a mix from a well-known track and confirm suggestions come from your library and skipped tracks never return. See [similar playlists and mixes](RECOMMENDATIONS.md).

Add an isolated radio stream URL or browse Radio Browser. Save a station to Favorites, restart, and verify Stations/Favorites and the separate All Sources Home section. Confirm radio never appears as a music album, artist ranking, or counted play. Check direct, M3U, and PLS streams; HLS must report unsupported. With an ICY fixture, verify changing broadcast titles and uninterrupted audio. Live playback must have no seek timeline or saved resume offset; pause closes the connection and resume reconnects. Disconnect the fixture and verify Reconnect is offered without an automatic retry loop.

Follow [Last.fm setup](SCROBBLING.md) only for an explicit live-account check. Confirm browser authorization, Complete Connection, source exclusions, and separate Now Playing control. Use a dedicated listening session to check the threshold, buffering/pause/seek exclusion, repeated tracks, and offline queue delivery after restart. Podcasts and radio must not submit. Disconnect removes the saved account session and stops submission while retaining account-specific pending events. Reconnecting the same account with its original API credentials resumes those events without uploading old local listening history; another account must not submit them. Automated tests use fixtures and cannot verify the public account authorization page or a real listening profile.
