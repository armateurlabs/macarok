# Podcasts: streaming, downloads, and storage

Subscribe to a publisher RSS/Atom feed or find a show through Podcast Index or Apple Podcasts. See [source setup](SOURCES.md#podcasts) for discovery and subscription.

Episodes are listed by publication date, newest first by default, including cached feeds and search results. Undated episodes follow dated episodes in both directions. Existing playlist entries keep their saved order.

## Library browsing

Podcasts have their own **Podcasts** library tab, shown when the current scope contains at least one show. In All Sources, podcasts no longer appear in Artists, Albums, Years, Folders, Tags, Shuffle Library, or the music sections of Home, so a show that publishes often cannot fill Recently Added.

The tab has four views:

- **Shows** lists every show with its artwork, episode count, latest publication date, and unplayed count. Click a show to open it in place; the back button returns to the list.
- **New** lists unplayed episodes from the last 30 days across every show.
- **In Progress** lists episodes you started and have not finished, most recent first.
- **Downloaded** lists downloaded episodes.

An open show, or a podcast chosen in the source picker, shows its artwork, author, and actions: **Resume** (the most recently heard unfinished episode), **Play Latest**, **Add Unplayed** (oldest first), and a menu with Mark All as Played, Refresh Show, Copy Feed URL, Open Website, and Unsubscribe…. Its episodes can be filtered by **All**, **Unplayed**, or **Downloaded**. The central Home shows the show's description, Continue Listening, and Latest Episodes; the Home filters (Recently added, Recently played, Most played) apply to music only and are hidden there.

Each episode row shows an unplayed dot, the title, its publication date (Today, Yesterday, the weekday within a week, then the date), and the remaining time with a progress bar once started. A trailing symbol shows, in order of priority, playback, download progress, a failed download, presence in the active playlist, or a completed download. Hover a row for the start of its notes. Rows support the usual selection, Return or double-click, dragging into the playlist, and a context menu with Mark as Played / Unplayed, Play from Beginning, Go to Show, and download actions.

The arrow beside a podcast list heading reverses the date order, and the Shows list by latest episode. Searching filters shows and episodes with the library search.

In **Playing**, an episode always shows its context: its notes from the feed, its show (click to open it), and download actions. Notes keep the publisher's paragraphs and lists; long notes collapse behind **More**. Web addresses open in the browser, and chapter times such as `03:12` or `1:02:03` are links that jump to that moment, starting the episode if needed. Lyrics, Wikipedia, and the metadata editors do not apply to episodes, so their menu is hidden; your chosen view returns with the next music track.

All Sources Home adds **Continue Listening** and **New Episodes** (the latest unplayed episode of each show). Click a tile to open its show; double-click to play it.

## Chapters

Episodes with chapters show them on the playback timeline as small gaps in the bar. Hover the bar to see the time and chapter under the pointer; while dragging, the same label shows where playback will jump. The title row shows the chapter being heard, such as “3/12 · Interview” (hover it for the author), and two small buttons beside the times move to the previous or next chapter. **Option-Left** and **Option-Right**, or **Playback → Previous Chapter / Next Chapter**, do the same. Like Previous Track, Previous Chapter first returns to the start of the current chapter when more than three seconds into it. Text fields keep Option-arrows for moving by word. The menu bar mini player shows the same current chapter below the author, with chapter buttons on each side of the track buttons.

In **Playing → Context**, the episode's chapters are listed with the current one highlighted; click one to jump there, or to start the episode at that chapter.

Macarok uses, in order: the publisher's Podcasting 2.0 chapters file (`podcast:chapters`), Podlove Simple Chapters in the feed (`psc:chapters`), then a chapter list written in the episode notes (at least three lines starting with increasing times, the first within five minutes). A chapters file is downloaded only when an episode is played or shown in Context, then kept with the library and removed with its show. Chapters embedded in the audio file are not read yet. When a stream cannot seek, chapter navigation is unavailable like the timeline.

## Listening progress

Macarok saves where you stop in each episode. Starting an unfinished episode again continues two seconds before that point; **Play from Beginning** starts over. An episode counts as played when you reach its last 30 seconds, it plays to the end, or you choose **Mark as Played**. Positions under 30 seconds are treated as a preview. Episodes heard before this version count as played until marked unplayed. Progress is removed with its show.

## Automatic refresh

**Settings → Podcasts → Check for new episodes** refreshes shows every hour by default; choose every 15 minutes, 6 hours, a day, or Off. Refresh happens quietly while Macarok is open and does not interrupt a refresh you started. Macarok sends the feed's cache validators, so an unchanged feed is not downloaded or parsed again. A failed refresh keeps the existing episodes and shows a warning on the show and in Settings. **Refresh All Now** checks every show immediately; the library footer's Refresh still refreshes the selected scope.

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
