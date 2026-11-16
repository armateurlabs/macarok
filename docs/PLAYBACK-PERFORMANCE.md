# Playback during library work

Playback, indexing, and presentation use separate work paths. The app retains macOS 14 as its deployment target.

## HTTP audio

`SourceTransport` has separate playback, download, and catalog sessions with the same source-specific certificate and redirect policy. Playback receives data chunks on a dedicated high-priority delegate queue. A bounded retained-chunk buffer provides backpressure through reader/producer wakeups, without per-byte Swift concurrency, repeated polling, or moving the remaining audio under a lock. Small seeks reuse retained bytes. Old ranges and callbacks are rejected after replacement or cancellation. ICY parsing copies audio spans and keeps metadata out of decoder input.

Each prepared remote item owns an isolated playback transport, including its own serial callback queue. The next stream may prime its bounded buffer without occupying the current stream's callback queue. Replacing, removing, or cancelling a prepared item closes its stream and invalidates that transport. Catalog clients remain cached independently.

Retained byte ranges describe reusable RAM, not a cumulative download. Evicted bytes are no longer shown as buffered. CBR/VBR files use the same decoder; timeline coverage derived from byte offsets is approximate for variable bitrate. Unknown total lengths do not invent a percentage.

## VLC and the UI

A shared `VLCLibrary` avoids constructing a libVLC context for every track. Each item retains its own lightweight player/delegate identity, so callbacks cannot complete a replacement item. Local files and mounted shares receive file caching as well as network caching for streams.

`PlaybackTimeline` owns position, duration, seekability, and buffering publications. Equality guards suppress duplicate values. Only the compact seek control and a small synchronized-lyrics observer sample this clock. The lyric stack updates when the active line changes; its timer-driven observer does not rebuild the stack on every position sample. The buffer sampler retains its publisher in SwiftUI state. Playlist and radio panels observe playback state. Queue-entry lookup and source-kind lookup use indexes, while each metadata batch assigns the queue once and retains its UUIDs and selection.

Bookmark resolution, security access, and filesystem probes run through `PlaybackPreparationWorker`. The next local item, downloaded podcast, or remote URL/stream is prepared ahead of a transition. Failed prefetches are advisory: foreground playback retries after a share or server returns. Security access stays alive until source removal or application shutdown.

One upcoming item has a prepared `VLCMedia` and lightweight `VLCMediaPlayer`. A lock-protected native completion bridge starts that player before scheduling application publication on MainActor. Adoption updates the queue occurrence, playback context, controls, and listening session once. Queue edits and controls first reconcile a handoff that already happened; Stop instead invalidates both players without adopting or restarting them. Repeat uses entry identity plus a fresh playback occurrence, and CUE start/end boundaries stay segment-relative. Radio EOF retains explicit Reconnect behavior.

The pinned VLCKit exposes neither public native player/media handles nor an Objective-C next-media operation. The implementation uses public player APIs without KVC or private handle access. It reduces preparation and MainActor scheduling delays but does not promise gapless or sample-accurate transitions. Only one successor is staged, so an indefinitely blocked application cannot schedule an unlimited queue.

Native handoff/request and first-playing timestamps remain separate from delayed UI adoption. Last.fm finishes the outgoing occurrence at its native boundary and preserves the successor's native start date when available. Unobserved successor time is not backfilled into listening qualification or incorrectly credited to the previous track.

Resume checkpoints update a small record without rewriting the full queue JSON every five seconds. Content revisions and checkpoint revisions are ordered independently, so a checkpoint delivered before its preceding queue edit cannot discard that edit. macOS Now Playing receives immediate state/seek changes and periodic clock reconciliation.

## Library and images

Local scans cache each audio file's mtime, size, and parsed metadata in an additive SQLite table. Unchanged files skip TagLib and embedded-art hashing; CUE sheets and sidecar images remain independently discoverable. Narrow scans read and decode only cache rows under their covered folders. Cache persistence compares fingerprints before encoding metadata, and reused values retain their original metadata/blob for a safe no-encoding fast path. Equal fingerprints never hide a changed artwork reference or edited metadata value. Raw artwork bytes stay out of SQLite's metadata cache.

`LocalScanCoverage` carries either the complete source or recursive source-relative folders through scanning, cache access, and track reconciliation. File identities remain relative to the original selected source root, independent of the folder being scanned. Watcher batches coalesce folder coverage, ignore unrelated files, and preserve directory flags so a deleted or renamed directory still reconciles its old descendants. A missing covered folder is a complete empty result for that folder; unreadable directories or failed/racing metadata reads produce an incomplete result. Incomplete scans retain previous tracks and cache rows. A completed narrow scan marks missing only the records inside its coverage, preserving unrelated source tracks, user corrections, history, and playlists.

External CUE cache entries retain parsed sheet text and indexed audio references, including references to files that are currently missing. Changes to either side expand coverage to the sheet and audio folders before loading the bounded cache. Existing indexed CUE tracks supply dependencies for older caches. A newly discovered sheet referencing existing audio outside the prepared coverage escalates to a full source scan. Explicit audio/CUE/playlist sources, relocated bookmark roots, dropped event history, and root changes also use complete coverage. These fallbacks prevent narrow reconciliation from leaving duplicate physical/virtual tracks or dropping unrelated CUE segments.

Progress is coalesced to approximately ten updates per second. SQLite updates only changed columns and availability, avoiding unnecessary FTS work. Upsert and replacement operations report whether stored index values actually changed after preserving statistics and locked corrections. An unchanged refresh does not prepare or publish a replacement library snapshot. Folder artwork is resolved again without reopening unchanged audio; replacing image bytes at the same path separately invalidates the artwork presentation cache.

History, rating, artwork, and radio presentation patches run off the foreground without rereading and re-sorting the whole catalog. Only affected genre/format arrays and ancestor-folder arrays are replaced; unrelated folder descendants retain their arrays. The flat track array and global rankings still require linear work, and publishing a snapshot still updates the catalog value. Snapshot and search publication overlays newer committed patches. Rankings still aggregate the complete selected scope before selecting eight entries. Structural metadata edits rebuild grouping when needed.

Committed index changes carry revisioned dirty markers until a matching snapshot actually publishes. A later cache-write error or cancellation cannot leave the presentation stale after a successful track commit. Stop Refresh invalidates old watcher callbacks, cancels pending coverage, preserves committed data, and reinstalls watchers for future genuine changes.

Remote artwork requests are bounded and share cached source clients. Thumbnails use ImageIO on a utility queue, with coalesced decoding, a maximum of three concurrent decodes, and a bounded memory cache. Drawing does not decode original full-resolution images on the main thread.

FSEvents batches retain their paths and rescan flags. Recent app writes are suppressed only when exact post-write file fingerprints still match. Directory-only, dropped, root-change, and mixed external events remain eligible for a scan. Verified file writers replace audio atomically; a playback regression checks that tag changes preserve PCM and do not stop a currently open file.

## Measurements and validation

Use Instruments' Points of Interest to inspect `Install`, `TrackTransition`, `PublishSnapshot`, and `StreamBufferWait` intervals. Stream snapshots expose underrun count, wait duration, retained ranges, and buffer capacity. Player diagnostics report installation and transition durations without publishing them to views.

**Help → Playback Diagnostics…** shows native audio/decode/read counters, buffer occupancy, waits, installation/transition durations, and a bounded session event log. Copy and JSON export are explicit. The log has a closed vocabulary and numeric metrics, excluding titles, source names, URLs, credentials, paths, and arbitrary error text. Events also use `os.Logger`; nothing is uploaded automatically.

The pure `PlaybackWatchdog` checks monotonic progress rather than audio amplitude. It covers opening/buffering deadlines and stalled position or native played-buffer counters, with seek grace, large custom buffers, pause/sleep exclusions, and long-scheduler-gap reset. A backend without a trustworthy live clock reports monitoring unavailable. Each occurrence reports at most one incident. Recovery stops the failed transport while retaining the queue entry for Play/Retry or radio Reconnect; it does not silently skip or retry forever.

The upcoming regression deliberately blocks MainActor for four seconds and verifies that the successor's native played-audio-buffer counter continues increasing before the application adopts it. VLCKit's `time` getter is cached, so reading that clock while its update queue is blocked would not establish audible progress. Native transition timing uses the callback timestamps and excludes delayed UI publication.

The automated stress fixtures play finite HTTP audio and ICY radio during SQLite imports and catalog preparation, exercise a MainActor heartbeat, and bound transition gaps. They use synthetic audio and loopback HTTP/TLS. These checks do not replace testing the throughput and latency of a particular NAS or remote server.

See [Testing Macarok](TESTING.md) for the full suite and native rendering commands.
