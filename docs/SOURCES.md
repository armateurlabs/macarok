# Music sources and discovery

Open **File → Connect a Source…** or **Settings → Sources → Add Source…**. The source catalog offers Local Files, OpenSubsonic, Bandcamp, Internet Radio, Podcasts, Live Music Archive, and LibriVox. Settings can add a source while the main window is closed.

The library header uses the native macOS source picker, including an icon and a checkmark for the current selection. Choose one source or **All Sources**. All Sources combines cached music for browsing while retaining separate source identities, credentials, albums, playlists, and file-write destinations. Selecting it does not start a catalog refresh.

## Local files

Choose a music folder. Macarok indexes metadata in SQLite; the audio remains in that folder. MP3, FLAC, Ogg Vorbis, Opus, and other supported TagLib/VLC formats can be played. A CUE sheet exposes its individual tracks without splitting its referenced audio file.

Use the library footer's **Scan for Changes** action to refresh. During a scan, the same control becomes **Stop Refresh**, and the window status bar shows its progress. Cancellation retains committed library data. The control shows **Stopping…** while the current operation finishes cancelling.

While Macarok runs, folder watchers rescan the folders that changed. A few seconds after launch, Macarok also rescans every music folder in the background to pick up changes made while it was closed. Unchanged files are not read again, the cached library stays fully usable, and the list is updated only if something changed. A folder that cannot be reached, such as an unmounted drive, is reported in the status bar and keeps its cached tracks.

## OpenSubsonic

Enter a display name, the server's base HTTP or HTTPS URL, and a username/password or supported OpenSubsonic API key. Credentials belong in their fields rather than the URL. The initial catalog is imported progressively into SQLite: completed albums can be browsed, searched, and queued before the whole import finishes. Connecting does not request a server-side filesystem scan.

**Refresh Source** re-reads the catalog the server already knows; it does not make the server look for new files. To pick up files just added to the server's music folders, choose **Library → Scan Library on Server** (also in the refresh button's context menu and in **Settings → Sources**). Macarok asks the server to scan (`startScan`), shows its progress in the library footer, then refreshes the source automatically. **Full Scan on Server** asks Navidrome to re-read every file, which takes longer; other servers treat it as a normal scan. Most servers, including Navidrome, accept scans only from an administrator account; otherwise Macarok explains the refusal and the usual refresh remains available. **Stop Following Server Scan** stops watching the progress; the server keeps scanning.

Audio is requested for playback at original quality. Cover images are retrieved on demand. Refresh repeats the metadata traversal; the library footer can stop it. All Sources refreshes its sources serially and preserves completed or partial results when another source fails or is cancelled.

Server catalogs also stay current on their own. A few seconds after launch, then every hour, Macarok asks each server for its last scan date, track count, and newest album. The catalog is imported again in the background only when that changed since the last complete import, or when a previous import stopped early. During this import the cached library stays fully browsable and playable: it is updated once at the end, only if something changed, and an unreachable server is reported in the status bar instead of an alert. Starting a refresh or a server scan yourself takes precedence.

Self-signed certificates require an explicit decision for that server. The same source-specific trust applies to library, artwork, and audio requests. A changed certificate requires a new decision.

## Bandcamp

Select **Bandcamp** in the source catalog. It presets the server URL to `https://bandcamp.com/api/subsonic` and uses the OpenSubsonic connector.

1. Open [Bandcamp Fan Settings](https://bandcamp.com/settings#fan).
2. Generate the Subsonic username and password for your account.
3. Enter those generated credentials in Macarok and choose **Connect**.

Use the generated Subsonic credentials for this connection. Bandcamp's [official Subsonic announcement and instructions](https://blog.bandcamp.com/2026/07/16/discover-improvements-and-subsonic-implementation/) describe its account setup and service behavior.

## Internet radio

Select **Internet Radio** to add a station name and HTTP/HTTPS stream URL, or choose **Browse Radio Stations…**. Saving a station or favorite creates the persistent Internet Radio source automatically.

Directory search is provided by [Radio Browser](https://www.radio-browser.info). Search by station name, country, language, or tags. Results offer Play, Add to Active Playlist, Add After Current Track, and Favorites actions. Directory searches are bounded; Macarok does not import the entire directory.

The Internet Radio library has **Stations** and **Favorites** views. Saved stations remain separate from music albums, artists, play counts, and rankings. In All Sources, Home shows Radio Favorites as a separate section.

Direct streams and M3U/PLS playlist wrappers are supported. HLS streams are marked unsupported and cannot be played. Live radio has no seekable timeline or fixed duration. Station-provided broadcast metadata appears in the player when available. Pausing closes the live connection; resuming reconnects to the live stream. If a station disconnects, choose **Reconnect** rather than relying on automatic retry.

Station and directory availability depend on their operators. Favorites and saved station details are kept locally; audio is streamed during playback.

## Podcasts

Paste a publisher RSS or Atom feed URL and choose **Subscribe**, or open **Search Podcasts…**. Search defaults to [Podcast Index](https://podcastindex.org); the directory selector also offers [Apple Podcasts](https://podcasts.apple.com).

Enter a title or author, choose **Search**, then **Use Feed** beside the desired show. Macarok returns to the source sheet with that feed URL. Choose **Subscribe** to retrieve its episodes. Playback and refresh use the publisher's feed and enclosures rather than the search directory.

Search only runs on submission. Requests are rate-limited and cached; a directory error or throttling message can be retried later. You can always paste a feed URL directly.

Episodes stream by default. Choose **Download Episode** to keep an explicit local copy, then **Reveal in Finder** to locate it. The timeline distinguishes playback progress from buffered/downloaded coverage. See [podcast timelines, storage, and cleanup](PODCASTS.md) for the download folder and retention policy.

Subscribed shows are browsed in the [Podcasts library tab](PODCASTS.md#library-browsing) and refresh automatically every hour by default ([automatic refresh](PODCASTS.md#automatic-refresh)).

## Internet Archive: Live Music Archive and LibriVox

Select **Live Music Archive** or **LibriVox** and choose **Add Collection**. No account is needed. Each collection is a separate source backed by the same Internet Archive connector. Adding a collection that is already present selects it.

These collections are too large to import. Macarok does not download a catalog when the source is added. Its library pane browses the collection like a website: each list loads page by page as it is opened and scrolled, so expect some network latency.

- **Live Music Archive** ([etree](https://archive.org/details/etree)): **Browse** lists artist collections. Search by name and sort by Popular or A–Z. Open an artist to list years with recording counts, then a year to list its recordings by date, venue, recording source, and rating. Several recordings of one show stay distinct.
- **LibriVox** ([librivoxaudio](https://archive.org/details/librivoxaudio)): **Browse** lists books. Search titles or authors, filter by language, and sort by Popular, Recently Added, or A–Z.

Opening an item shows its details, description, and tracks or chapters. **Play**, **Add**, a double-click, or a track's context menu adds the item to the active playlist. **Save** keeps it in the library. Saved items appear in the **Saved** tab and as normal albums in Home, Albums, and All Sources. **Recent** lists items you opened for playback. **Open on archive.org** shows the item's page.

An item's tracks enter the library only when you play, queue, or save it. Refresh re-reads the metadata of those items. It never imports the collection. Refresh also hides unsaved items from library views unless the active playlist or a saved playlist still uses them. Their history and ratings are kept if you open them again.

Browsing responses are cached in SQLite: listings for 24 hours and item details for 7 days. Cached entries older than 30 days are removed on launch. If the Internet Archive cannot be reached, an earlier cached result is shown with a notice.

**Settings → Playback → Internet Archive quality** defaults to **High**. High streams FLAC (including 24-bit) when a recording makes it public, otherwise the best MP3, and LibriVox 128 kbps MP3. **Standard** uses VBR or 64 kbps MP3. Stream-only or private files fall back to the best public derivative. Changing quality refreshes Internet Archive sources. Track identities do not change, so playlists, history, and ratings are kept.

LibriVox specifics:

- Macarok remembers the chapter and position where you stopped in each book. **Resume** continues there; **Start Over** plays from the first chapter.
- **Download Book**, or **Download Chapter** in a chapter's context menu, keeps local copies in the same folder and with the same retention policy as [podcast downloads](PODCASTS.md). Later plays use the local file.
- Audiobooks are not scrobbled to Last.fm. Live Music Archive recordings are scrobbled like other music.

Availability, recording rights, and descriptions are provided by the Internet Archive and the contributing tapers and volunteers.

## Service availability

| Service | Macarok support |
| --- | --- |
| Local files | Indexed library and playback |
| OpenSubsonic / Navidrome | Cached library, original-quality playback, source-specific authentication and certificate trust |
| Bandcamp | OpenSubsonic preset with generated account credentials |
| Internet Radio / Radio Browser | Saved stations, favorites, directory search, direct streams and M3U/PLS wrappers; HLS unsupported |
| Podcasts / Podcast Index / Apple Podcasts | Feed subscription, streaming and explicit episode downloads; directories provide discovery |
| Internet Archive: Live Music Archive / LibriVox | On-demand browsing with a local cache, saved items, FLAC or MP3 streaming, audiobook resume and chapter downloads |
| Last.fm | Optional scrobbling; see [setup and privacy](SCROBBLING.md) |
| [Qobuz](https://www.qobuz.com) | No playback connector; approved partner integration is required |
| [Deezer](https://www.deezer.com) | No confirmed public full-playback integration route |
| [Spotify](https://www.spotify.com) | No playback connector; developer policy restricts multi-service players |

Add Source lists only working connectors. Qobuz, Deezer, and Spotify are not included in that dialog.
