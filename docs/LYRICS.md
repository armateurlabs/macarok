# Lyrics

The central panel always offers Context and Lyrics. Context keeps its navigation while Lyrics is shown. Lyrics follows the current queue entry, falling back to the inspected track only when there is no current entry. Browsing another source does not redirect the lyrics request. Retrieval starts only while Lyrics is visible; changing the target or hiding the panel cancels obsolete loading.

## Resolution and privacy

Resolution order is a user correction, local sidecar/embedded lyrics, a valid SQLite cache entry, OpenSubsonic structured lyrics, legacy server lookup, then LRCLIB. LRCLIB uses its stable v1 endpoints with an identifying User-Agent, serialized requests, and Retry-After cooldowns. Automatic matching requires the requested title/artist, album when supplied, and a duration within two seconds when usable. Uncertain matches require explicit selection through Find Lyrics, which offers editable search metadata and a preview. No lyrics are uploaded or submitted publicly, and server credentials are never sent to LRCLIB.

The SQLite lyrics cache stores documents by source and track, including metadata fingerprint, provenance, original LRC, normalized timings, and correction status. Automatic results invalidate when matching metadata changes. Corrections survive refresh and metadata edits. Missing results expire after fifteen minutes; Try Again bypasses automatic cache entries. Network errors and throttling remain errors rather than cached misses.

## Timing

Plain lyrics remain selectable text. Timed lyrics highlight the current line from VLC's reported track-relative position, including pause and seek. Auto-scroll starts enabled and can be switched off. Offsets are applied once during parsing; normalized LRC export bakes offsets into timestamps and omits the offset tag.

For CUE segments, a dedicated track sidecar is already track-relative. A shared album LRC is sliced at the segment's start/end boundaries and rebased to that track. Server/provider lyrics are track-relative and are never shifted by the CUE start.

## Corrections and file export

Edit / Paste accepts plain text or LRC and saves a private library override. Search/editor dialogs retain their original target if playback changes while the dialog is open.

Save to Files is a separate explicit action available for local sources:

- Ordinary tracks receive plain `LYRICS` through the verified TagLib writer. Synchronized lyrics also receive a sibling `.lrc`; existing sidecars are updated so older timings cannot override a correction.
- CUE tracks receive `<cue-or-audio-base>.track-XX.lrc` or `.txt`. Shared album tags and shared lyrics files are preserved.
- Sidecars use atomic writes and read-back verification. Audio replacement preserves unrelated metadata and uses the existing verified temporary-file workflow.
- A later file-write failure reports partial success and retains the SQLite document. Remote originals are never written.

All file operations, parsing, provider requests, and SQLite access run away from the foreground. See [the test guide](TESTING.md) for automated coverage and [LRCLIB documentation](https://lrclib.net/docs) for provider details.
