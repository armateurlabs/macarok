# Private beta verification

Baseline verified on 14 November 2026 with Xcode 27.1, Swift 6.4, and macOS 27.2.1 on Apple Silicon. Native empty-window layout follow-up verified on 15 November 2026.

## Completed checks

- The complete suite passed: **87 tests, zero failures** — Core 50, Metadata 12, Audio 7, App 18.
- The 15 November progressive-import and UI-freeze follow-up passed the expanded complete suite: **110 tests, zero failures**. A subsequent controller run verifies incomplete-import persistence across restarts.
- Real VLCKit 4 playback covered synthetic MP3, FLAC, Ogg Vorbis, and Opus, pause/resume, seeking, CUE boundaries, and completion.
- A throttled loopback HTTP stream began playing before download completed, then exercised Range seeking and segment playback.
- Live loopback HTTPS and protocol fixtures covered source/host/port trust, changed certificates, hostname/validity rejection, and the same transport for data and progressive audio.
- The loopback OpenSubsonic/podcast server exercised actual HTTP requests, password/API-key authentication, original audio, covers, lyrics, folders, and RSS.
- TagLib tests verified preservation of audio and unrelated properties. Multi-file CUE edits survived an unlocked rescan; library artwork overlays survived refresh.
- The bundled upstream fpcalc helper generated a real fingerprint. AcoustID request/response tests used fixtures.
- Fourteen offscreen native component renders cover Home, narrow loading and empty Home states, CUE albums, track tags, Settings, and metadata editing in Light and Dark appearances.
- A sample of the unresponsive app identified repeated full-catalog folder traversal on the main thread. The replacement indexes folder prefixes once in a background task; its synthetic 30,000-track/7,000-folder test measured about 0.17 seconds for index construction.
- The Release app bundle was built, locally signed, and passed deep strict signature verification. Its native executable targets arm64; VLC, resource bundles, the helper, icon, and third-party notices are embedded.

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
- This is a locally signed private beta, without notarization or a public release package.
