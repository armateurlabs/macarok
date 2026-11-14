# Private beta verification

Verified on 14 November 2026 with Xcode 27.1, Swift 6.4, and macOS 27.2.1 on Apple Silicon.

## Completed checks

- The complete suite passed: **87 tests, zero failures** — Core 50, Metadata 12, Audio 7, App 18.
- Real VLCKit 4 playback covered synthetic MP3, FLAC, Ogg Vorbis, and Opus, pause/resume, seeking, CUE boundaries, and completion.
- A throttled loopback HTTP stream began playing before download completed, then exercised Range seeking and segment playback.
- Live loopback HTTPS and protocol fixtures covered source/host/port trust, changed certificates, hostname/validity rejection, and the same transport for data and progressive audio.
- The loopback OpenSubsonic/podcast server exercised actual HTTP requests, password/API-key authentication, original audio, covers, lyrics, folders, and RSS.
- TagLib tests verified preservation of audio and unrelated properties. Multi-file CUE edits survived an unlocked rescan; library artwork overlays survived refresh.
- The bundled upstream fpcalc helper generated a real fingerprint. AcoustID request/response tests used fixtures.
- Ten offscreen native component renders covered Home, CUE albums, track tags, Settings, and metadata editing in Light and Dark appearances.
- The Release app bundle was built, locally signed, and passed deep strict signature verification. Its native executable targets arm64; VLC, resource bundles, the helper, icon, and third-party notices are embedded.

Build/test logs and full-resolution renders are kept under the ignored `.build` directory. The checked-in native previews in `design/native` are component renders, not desktop screenshots.

## Remaining manual checks

The Mac was locked during the automated run. Full desktop interaction has therefore not been verified: file pickers, double-click timing, drag/reorder, custom shortcut recording, Mac media keys, resize behavior, and accepting a certificate through the native modal still need a session with the Mac unlocked. The corresponding controller/transport paths have automated coverage.

Live MusicBrainz/AcoustID results and personal OpenSubsonic servers have not been verified. Metadata lookup protocol tests use fixtures; AcoustID requires your own application client key. Follow `TESTING.md` and `DEMO-SERVER.md` for a reproducible manual session with synthetic data.

## Current boundaries

- Local identity is based on source and path; renaming or moving files can create new identities. Scanning the same paths preserves history, ratings, queue references, and playlists.
- Metadata and artwork replacement is atomic per file. An operation across several files can partially save before a later error.
- Recording fingerprint identification supports whole local files. Individual CUE tracks and remote streams use metadata search instead.
- Servers that compress byte-range responses or cap an open-ended range before EOF fail explicitly; automatic stitching of such ranges is not implemented.
- Gapless playback is optional. Crossfade, commercial-service playback, merged source libraries, and direct cloud-storage integration are outside this iteration.
- This is a locally signed private beta, without notarization or a public release package.
