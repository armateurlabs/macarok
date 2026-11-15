# Verification

Baseline verified on 14 November 2026 with Xcode 27.1, Swift 6.4, and macOS 27.2.1 on Apple Silicon. Native empty-window layout follow-up verified on 15 November 2026.

## Completed checks

- The complete suite passed: **87 tests, zero failures** — Core 50, Metadata 12, Audio 7, App 18.
- The 15 November progressive-import and UI-freeze follow-up passed the expanded complete suite: **110 tests, zero failures**. A subsequent controller run verifies incomplete-import persistence across restarts.
- The subsequent background-library refactor passed **125 tests, zero failures**. Gated background jobs verify that navigation, a MainActor heartbeat, and queue saving remain available during catalog preparation. Preparing the complete synthetic 50,000-track/5,000-album/100-year snapshot took about 0.66 seconds in the Debug test run, outside UI code.
- The streaming-crash and search-presentation follow-up passed **130 tests, zero failures** (Core 66, Metadata 12, Audio 7, App 45). Multi-megabyte buffer tests cover repeated compaction, seeking, and closing; search tests cover grouped results, tab changes, source isolation, and complete album selection from a partial result. The reported Foundation trap came from treating a byte offset as a `Data` collection index after prefix removal.
- The rebuilt Release app was reopened against the existing large catalog. Native search retained artist, album, year, folder, and tag presentations across navigation, including returning Home with the query intact. Track, album, and artist right-click menus displayed Play Now. The search was cleared and Home restored after verification; playback and queue contents were left unchanged.
- The Clear Playlist follow-up passed **18 focused controller tests, zero failures**. Silent generated audio played through real VLC while clearing preserved the exact current queue entry and uninterrupted position; additional checks covered pending playback, pause/resume, restored positions, duplicates, persistence, and clearing without a current entry. The Release bundle was rebuilt and passed deep strict signature verification.
- The menu-tracking timeline follow-up passed the complete suite: **134 tests, zero failures** (Core 66, Metadata 12, Audio 8, App 48). Its real-VLC regression first failed against the previous implementation with an unchanged position during event tracking, then passed with common-mode clock polling. Default/common timer sentinels isolate the tracking mode; paused and stopped positions stay stable. This is an in-process run-loop regression, without operating a desktop menu or interrupting the running player's audio.
- After reopening the rebuilt Release app, native Home, Artists, Albums, Years, Folders, and Tags navigation was exercised with an existing catalog exceeding 50,000 tracks. Expanding a year was checked as well; the previous blocking navigation delay was not observed.
- Real VLCKit 4 playback covered synthetic MP3, FLAC, Ogg Vorbis, and Opus, pause/resume, seeking, CUE boundaries, and completion.
- A throttled loopback HTTP stream began playing before download completed, then exercised Range seeking and segment playback.
- Live loopback HTTPS and protocol fixtures covered source/host/port trust, changed certificates, hostname/validity rejection, and the same transport for data and progressive audio.
- The loopback OpenSubsonic/podcast server exercised actual HTTP requests, password/API-key authentication, original audio, covers, lyrics, folders, and RSS.
- TagLib tests verified preservation of audio and unrelated properties. Multi-file CUE edits survived an unlocked rescan; library artwork overlays survived refresh.
- The bundled upstream fpcalc helper generated a real fingerprint. AcoustID request/response tests used fixtures.
- Fourteen offscreen native component renders cover Home, narrow loading and empty Home states, CUE albums, track tags, Settings, and metadata editing in Light and Dark appearances.
- A sample of the unresponsive app identified repeated full-catalog folder traversal on the main thread. The replacement indexes folder prefixes once in a background task; its synthetic 30,000-track/7,000-folder test measured about 0.17 seconds for index construction.
- A second live sample while opening Years identified full album reconstruction inside each year's disclosure group. Navigation now consumes cached snapshot groups, with collapsed children deferred until expansion; artwork completion no longer loads every track on the main thread.
- The Release app bundle was built, locally signed, and passed deep strict signature verification. Its native executable targets arm64; VLC, resource bundles, the helper, icon, and third-party notices are embedded.
- The versioned `0.1.0` DMG was built locally and passed image checksum verification. A read-only mounted copy passed deep strict app signature verification, version/build checks, and checks for the Applications link, MIT license, and third-party notices. Bash syntax and ShellCheck validation passed for the release packaging scripts.
- [GitHub Actions published v0.1.0](https://github.com/armateurlabs/macarok/actions/runs/43717627393) on 15 November 2026 from the unchanged tag commit `6385dafed67d18052f26aebbce6313f36ce5f8ff`. The hosted suite reported 132 passing tests, two skipped demo-server integration tests, and zero failures. The skipped tests' Python fixture did not become ready on the hosted runner; both pass in the recorded local suite. The build and publish jobs succeeded. The downloaded public DMG passed SHA-256 verification (`de1f128738fcd6d278fd181e0a377824ba59b203bdb7a85febfa03fb4545bc6d`) and disk-image verification.

Build/test logs and full-resolution renders are kept under the ignored `.build` directory. The checked-in native previews in `design/native` are component renders, not desktop screenshots.

## Remaining manual checks

The Mac was locked during the initial automated run. On 15 November, the empty-window height issue was reproduced in the running app and visually verified after rebuilding and reopening the corrected Release bundle. Four new geometry regressions cover no sources, a configured empty source, a populated library with an empty queue, and unmatched search results, in both appearances at several window sizes. The original code fails the empty-window regression. All four tests and the existing native render test pass.

File pickers, double-click timing, drag/reorder, custom shortcut recording, Mac media keys, and accepting a certificate through the native modal still need manual verification. The corresponding controller/transport paths have automated coverage.

Live MusicBrainz/AcoustID results and personal OpenSubsonic servers have not been verified. Metadata lookup protocol tests use fixtures; AcoustID requires your own application client key. Follow `TESTING.md` and `DEMO-SERVER.md` for a reproducible manual session with synthetic data.

## Current boundaries

- Local identity is based on source and path; renaming or moving files can create new identities. Scanning the same paths preserves history, ratings, queue references, and playlists.
- Metadata and artwork replacement is atomic per file. An operation across several files can partially save before a later error.
- Recording fingerprint identification supports whole local files. Individual CUE tracks and remote streams use metadata search instead.
- Servers that compress byte-range responses or cap an open-ended range before EOF fail explicitly; automatic stitching of such ranges is not implemented.
- Gapless playback is optional. Crossfade, commercial-service playback, merged source libraries, and direct cloud-storage integration are outside this iteration.
- Release DMGs currently target Apple Silicon and macOS 14 or later. The application is ad-hoc signed without Apple notarization.
