# Last.fm setup and privacy

Last.fm scrobbling is optional and remains disabled until an account is authorized. Macarok uses your personal API credentials; no shared application key is bundled.

## Connect an account

1. Open **Settings → Services** and choose **Configure…** beside Last.fm.
2. Follow **Create an API account…** to [Last.fm's API account form](https://www.last.fm/api/account/create).
3. Enter your API key and shared secret, then choose **Save API Keys**.
4. Choose **Connect Last.fm…**. Macarok opens Last.fm authorization in your browser.
5. Approve the connection on Last.fm, return to Macarok, and choose **Complete Connection**.

Your Last.fm password stays in the browser. The API key, shared secret, and authorized session are stored in macOS Keychain. Library preferences and pending submissions are stored in the local SQLite database.

Completing authorization enables scrobbling. Use **Scrobble music to Last.fm** to pause submissions and listening collection. **Share Now Playing** separately controls the live track announcement while scrobbling is enabled. **Disconnect** disables scrobbling and removes the saved account session from Keychain. Pending submissions remain in SQLite and resume after reconnecting the same Last.fm account with its original API credentials. The saved personal application credentials can be reused for a later connection.

## Eligible listening

Local files and OpenSubsonic music can be scrobbled. Podcasts and radio are excluded. Disable individual music sources in Settings if a server already submits the same listening to Last.fm.

Tracks with a known duration longer than 30 seconds qualify after half their duration or four minutes of listening, whichever comes first. Eligible tracks with an unknown duration qualify after four minutes. Artist and track title must be available. Each playback occurrence is counted separately, including repeated tracks and individual CUE segments.

Pauses, buffering, and time skipped by seeking do not count as listening. Changing queue order or clearing other entries does not restart an ongoing listening occurrence. Macarok does not upload its previously recorded library listening history when you enable scrobbling.

## Submission queue

Qualified plays are stored locally before delivery and survive restarts. They are sent oldest first. Settings shows pending, ignored, and failed counts, and offers **Retry Pending**. Temporary network failures remain queued for retry; authentication or provider errors appear in the settings view.

Changing API credentials disconnects the current session and retains its pending plays. Submission queues belong to their original API account and Last.fm username. Connecting a different account never sends another account's pending plays, and accepted occurrence records prevent duplicate submissions after reconnecting.

An authorized account receives the eligible track's artist, title, available album/album-artist and track-number information, duration, and listening start time. Now Playing shares the current eligible track when enabled. See [Last.fm](https://www.last.fm) for your account's submitted listening and service privacy controls.

API and authorization documentation: [Last.fm desktop authentication](https://www.last.fm/api/desktopauth), [track.scrobble](https://www.last.fm/api/show/track.scrobble), and [track.updateNowPlaying](https://www.last.fm/api/show/track.updateNowPlaying).
