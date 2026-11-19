# Similar playlists and mixes

Macarok builds playlists from listening similarity rather than tags. Every suggestion is a track already in your library; nothing is streamed from a recommendation service.

## Starting

Library, Playing, and playlist menus offer **Start Similar Mix** and **Create Similar Playlist…** for a track, album, artist, or other selection. The sheet chooses between a fixed playlist and a dynamic mix. Both replace the active playlist as one edit; Undo restores the previous playlist.

- **Fixed playlist**: generated once. A single seed track opens it; album, artist, and multi-track seeds are excluded from the result. Length is unlimited by default and can be limited in the sheet. Consecutive tracks avoid the same artist when possible, and each artist appears at most four times.
- **Dynamic mix**: only the next track is announced, with a dashed outline and a sparkle after the current entry. A banner under the playlist header shows the seed, the number of skipped tracks, the Follow choice, and Stop Mix.

## Dynamic mix behavior

- Right-click the announced track and choose **Skip Suggestion** to replace it. Removing it from the playlist also skips it.
- **Next** skips the track that was playing. Skipped recordings, including other copies and remasters of the same recording, are not suggested again during the session. **Restore Skipped Tracks** clears the list.
- **Follow** chooses what the next suggestion is based on: the seed, the last played track, or both (the seed plus the three latest unskipped tracks with decreasing weight). The choice is remembered.
- Repeat and Shuffle are unavailable during a mix. When the playlist reaches the end before the next track is found, playback starts as soon as it is found.
- The mix ends with Stop Mix, Clear Playlist, a new similar playlist or mix, or when the playlist no longer contains any of its entries, for example after Undo.

## Services and matching

- **Last.fm** `track.getSimilar` and `artist.getSimilar` are used when a personal API key is configured in Settings › Services. Only the API key is needed; no scrobbling session is required.
- **ListenBrainz** similar artists are always available without an account. The artist name is first resolved to a MusicBrainz identifier, at most one request per second.
- Track-level similarity ranks first, then tracks by similar artists, then other tracks by the seed artist. A little weight goes to frequently played tracks. The dynamic mix picks among the best few candidates with a weighted random choice, avoiding the artist just played.
- Provider answers are matched to library tracks by artist and title. Version suffixes, track numbers, and featured artists are tolerated; live, acoustic, demo, and remix editions are distinct recordings. All local and OpenSubsonic sources are searched; radio and podcasts are excluded.
- Answers are cached in SQLite for a week, and empty answers for a day. Network errors are not cached. One unavailable service does not prevent results from the other.

## Privacy

Only artist names and track titles of the seeds are sent to Last.fm, ListenBrainz, and MusicBrainz, with an identifying User-Agent. No library contents, listening history, or account information is sent.
