# YouTube and sharing

## YouTube tab

Open **Playing → YouTube** to watch the video of the inspected or playing song. Like Wikipedia, the tab follows the same track as the central context.

Macarok looks for the song's video in this order:

1. A YouTube link attached to the song's recording on [MusicBrainz](https://musicbrainz.org). No account or key is needed.
2. The [YouTube Data API](https://developers.google.com/youtube/v3), when you add your own API key in **Settings → Services**. The best match is shown; **Other Videos** lists the other results.
3. YouTube's own search page, shown in the tab for the song's artist and title. Choosing a video there links it to the song.

A found or chosen video is remembered for the song (its artist and title, whatever source it comes from). A video you choose always wins over an automatic match. **Other Videos → Choose on YouTube…** picks another one. A song without a video is searched again after a week, or as soon as an API key is added.

The video plays in YouTube's embedded player. Starting it pauses your music; playing music again pauses the video. Some music videos refuse playback outside YouTube: the tab then keeps the video's details and offers **Watch on YouTube**. Radio stations and podcast episodes have no song video.

### Personal YouTube API key

The key is optional. Create one in [Google Cloud Console](https://console.cloud.google.com/apis/library/youtube.googleapis.com) by enabling the YouTube Data API v3 for a project, then open **Settings → Services**, choose **Configure…** beside YouTube, paste the key, and choose **Save Key**. Each search uses 100 units of the free daily quota of 10,000, so about 100 songs a day; results are cached. When the quota is used up, the tab falls back to YouTube's search page until it resets at midnight Pacific Time. Clear the field and choose **Remove Key** to delete it.

The key is stored in macOS Keychain and read only when the YouTube tab or a share needs it.

## Share

**Share** opens the native macOS share menu (Messages, Mail, AirDrop, Notes, Copy, and other extensions). It is available:

- at the end of the playback bar's timeline;
- in the context menu of songs and episodes, in the library and the playlist (**Share…**);
- in the menu bar mini player, beside **More**;
- in the YouTube tab, for the video itself.

The shared text names what is playing, then the links Macarok knows, one per line. It never adds a line about Macarok.

| Item | Shared text |
| --- | --- |
| Song | `Title — Artist`, then its English Wikipedia article (the song's if it exists, otherwise the artist's) and its YouTube video |
| Radio station | `Station — current title`, then the station's website |
| Podcast episode | `Show — Episode`, then the episode's page, the show's website, or the episode's address |

A missing song link is looked up for at most four seconds when you share, then left out.

## Settings → Services

**Services** lists the online services Macarok uses, like **Sources** lists sources. **Accounts and Keys** shows Last.fm and YouTube with their state; **Configure…** opens each one's settings. **Without an Account** lists Wikipedia, MusicBrainz and Cover Art Archive, LRCLIB, and ListenBrainz, which need no setup.

## Requests and privacy

The song's artist and title are sent to MusicBrainz, Wikipedia, and YouTube only while the YouTube tab is shown, or when you share a song. Macarok sends no source credentials, file paths, or listening history. Results are cached in the library database.

Videos and YouTube's search page come from YouTube, which applies its own [terms](https://www.youtube.com/t/terms) and [privacy policy](https://policies.google.com/privacy). YouTube's cookies, such as your consent choice or an optional sign-in, are kept in a website data store used only by Macarok's YouTube tab, separate from Safari. The embedded player identifies Macarok as the embedding site, as YouTube requires.
