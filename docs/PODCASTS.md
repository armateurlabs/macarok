# Podcasts: streaming, downloads, and storage

Subscribe to a publisher RSS/Atom feed or find a show through Podcast Index or Apple Podcasts. See [source setup](SOURCES.md#podcasts) for discovery and subscription.

Each show's library episodes appear newest first by publication date, including cached feeds and search results. Undated episodes follow dated episodes. Existing playlist entries keep their saved order.

## Read the timeline

The podcast timeline has three layers:

- **Gray:** audio that is not currently buffered or downloaded.
- **White:** retained streaming data or the received portion of an explicit download. A completed download covers the whole bar.
- **Blue:** playback progress up to the cursor.

Streaming coverage is estimated from byte offsets and the total file length. Its time alignment is approximate for variable-bitrate audio. An unknown total length does not produce a fabricated percentage. Seeking can retrieve a separate byte range; white coverage does not imply that every preceding byte was downloaded. Retained streaming data may disappear from the indicator when it is evicted.

## Download an episode

Choose **Download Episode** from an episode's context menu or its context panel. **Cancel Download** stops an active transfer; retrying starts a fresh transfer. Downloads begin only after this explicit action. Ordinary playback and feed subscription do not save complete episode files automatically.

Later plays prefer the completed local file. **Reveal in Finder** selects that file. **Settings → Playback → Podcast Downloads** lists completed downloads, their sizes, Reveal/Remove actions, and **Open Downloads Folder…**.

## Where files live

The default folder is:

```text
~/Library/Application Support/Macarok/PodcastDownloads/
```

When `MACAROK_DATA_DIRECTORY` is set, `PodcastDownloads` is placed inside that directory alongside `library.sqlite`. Audio files use stable filenames derived from the source and episode identities, so copies from different sources stay separate. `downloads.json` records their titles and file references. Audio is stored in separate files, not inside SQLite.

Ordinary streaming uses a bounded memory buffer. Macarok does not create a playable episode file for that buffer, so there is no streaming file to reveal in Finder. Consumed chunks are evicted as space is needed; closing or replacing the stream releases its retained data. Pausing may retain the bounded buffer. See [playback internals](PLAYBACK-PERFORMANCE.md#http-audio).

## Cleanup and removal

Completed explicit downloads have no automatic expiry or size-based eviction. Refreshing or removing a source does not delete its completed downloads. Choose **Remove Download**, or Remove in Settings, to move a completed audio file to Trash. Removal is disabled while that episode is active, including paused playback.

Failed or cancelled transfers do not publish a completed file. Macarok removes its unfinished staging files after failure/cancellation and cleans up owned staging files left by an interrupted app session on the next startup. Unrelated files and completed audio are retained. URLSession uses a system temporary location during the transfer before Macarok publishes the completed file.

If a completed file is deleted in Finder, Macarok prunes its stale download entry when it reloads the download list. The episode can then be downloaded again.
