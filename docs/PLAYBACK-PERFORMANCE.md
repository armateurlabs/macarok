# Playback during library work

Playback, indexing, and presentation use separate work paths. The app retains macOS 14 as its deployment target.

## HTTP audio

`SourceTransport` has separate playback, download, and catalog sessions with the same source-specific certificate and redirect policy. Playback receives data chunks on a dedicated high-priority delegate queue. A bounded retained-chunk buffer provides backpressure through reader/producer wakeups, without per-byte Swift concurrency, repeated polling, or moving the remaining audio under a lock. Small seeks reuse retained bytes. Old ranges and callbacks are rejected after replacement or cancellation. ICY parsing copies audio spans and keeps metadata out of decoder input.

Retained byte ranges describe reusable RAM, not a cumulative download. Evicted bytes are no longer shown as buffered. CBR/VBR files use the same decoder; timeline coverage derived from byte offsets is approximate for variable bitrate. Unknown total lengths do not invent a percentage.

## VLC and the UI

A shared `VLCLibrary` avoids constructing a libVLC context for every track. Each item retains its own lightweight player/delegate identity, so callbacks cannot complete a replacement item. Local files and mounted shares receive file caching as well as network caching for streams.

`PlaybackTimeline` owns position, duration, seekability, and buffering publications. Equality guards suppress duplicate values. Only the compact seek control and synchronized lyric lines observe this clock. Playlist and radio panels observe playback state. Queue-entry lookup and source-kind lookup use indexes, while each metadata batch assigns the queue once and retains its UUIDs and selection.

Bookmark resolution, security access, and filesystem probes run through `PlaybackPreparationWorker`. The next local item is prepared ahead of a transition. Failed prefetches are advisory: foreground playback retries after a share or file returns. Security access stays alive until source removal or application shutdown.

Resume checkpoints update a small record without rewriting the full queue JSON every five seconds. Content revisions and checkpoint revisions are ordered independently, so a checkpoint delivered before its preceding queue edit cannot discard that edit. macOS Now Playing receives immediate state/seek changes and periodic clock reconciliation.

## Library and images

Local scans cache each audio file's mtime, size, and parsed metadata in an additive SQLite table. Unchanged files skip TagLib and embedded-art hashing; CUE sheets and sidecar images remain independently discoverable. Interrupted scans keep prior cache entries and do not reconcile absent tracks. Progress is coalesced to approximately ten updates per second. SQLite updates only changed columns and availability, avoiding unnecessary FTS work.

History, rating, artwork, and radio presentation patches run off the foreground without rereading and re-sorting the whole catalog. Snapshot and search publication overlays newer committed patches. Rankings still aggregate the complete selected scope before selecting eight entries. Structural metadata edits rebuild grouping when needed.

Remote artwork requests are bounded and share cached source clients. Thumbnails use ImageIO on a utility queue, with coalesced decoding, a maximum of three concurrent decodes, and a bounded memory cache. Drawing does not decode original full-resolution images on the main thread.

FSEvents batches retain their paths and rescan flags. Recent app writes are suppressed only when exact post-write file fingerprints still match. Directory-only, dropped, root-change, and mixed external events remain eligible for a scan. Verified file writers replace audio atomically; a playback regression checks that tag changes preserve PCM and do not stop a currently open file.

## Measurements and validation

Use Instruments' Points of Interest to inspect `Install`, `TrackTransition`, `PublishSnapshot`, and `StreamBufferWait` intervals. Stream snapshots expose underrun count, wait duration, retained ranges, and buffer capacity. Player diagnostics report installation and transition durations without publishing them to views.

The automated stress fixtures play finite HTTP audio and ICY radio during SQLite imports and catalog preparation, exercise a MainActor heartbeat, and bound transition gaps. They use synthetic audio and loopback HTTP/TLS. These checks do not replace testing the throughput and latency of a particular NAS or remote server.

See [Testing Macarok](TESTING.md) for the full suite and native rendering commands.
