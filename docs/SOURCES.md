# Music sources and discovery

Open **File → Connect a Source…** or **Settings → Sources → Add Source…**. The source catalog offers Local Files, OpenSubsonic, Bandcamp, Internet Radio, and Podcasts. Settings can add a source while the main window is closed.

The library header uses the native macOS source picker, including an icon and a checkmark for the current selection. Choose one source or **All Sources**. All Sources combines cached music for browsing while retaining separate source identities, credentials, albums, playlists, and file-write destinations. Selecting it does not start a catalog refresh.

## Local files

Choose a music folder. Macarok indexes metadata in SQLite; the audio remains in that folder. MP3, FLAC, Ogg Vorbis, Opus, and other supported TagLib/VLC formats can be played. A CUE sheet exposes its individual tracks without splitting its referenced audio file.

Use the library footer's **Scan for Changes** action to refresh. During a scan, the same control becomes **Stop Refresh** and displays progress. Cancellation retains committed library data. The control shows **Stopping…** while the current operation finishes cancelling.

## OpenSubsonic

Enter a display name, the server's base HTTP or HTTPS URL, and a username/password or supported OpenSubsonic API key. Credentials belong in their fields rather than the URL. The initial catalog is imported progressively into SQLite: completed albums can be browsed, searched, and queued before the whole import finishes. Connecting does not request a server-side filesystem scan.

Audio is requested for playback at original quality. Cover images are retrieved on demand. Refresh repeats the metadata traversal; the library footer can stop it. All Sources refreshes its sources serially and preserves completed or partial results when another source fails or is cancelled.

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

## Service availability

| Service | Macarok support |
| --- | --- |
| Local files | Indexed library and playback |
| OpenSubsonic / Navidrome | Cached library, original-quality playback, source-specific authentication and certificate trust |
| Bandcamp | OpenSubsonic preset with generated account credentials |
| Internet Radio / Radio Browser | Saved stations, favorites, directory search, direct streams and M3U/PLS wrappers; HLS unsupported |
| Podcasts / Podcast Index / Apple Podcasts | Feed subscription, streaming and explicit episode downloads; directories provide discovery |
| Last.fm | Optional scrobbling; see [setup and privacy](SCROBBLING.md) |
| [Qobuz](https://www.qobuz.com) | No playback connector; approved partner integration is required |
| [Deezer](https://www.deezer.com) | No confirmed public full-playback integration route |
| [Spotify](https://www.spotify.com) | No playback connector; developer policy restricts multi-service players |

Add Source lists only working connectors. Qobuz, Deezer, and Spotify are not included in that dialog.
