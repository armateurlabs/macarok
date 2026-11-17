# Podcast library — design and implementation plan (v2)

Working plan for the podcast library redesign. **Read this file at the start of every session.** Do one step per session, tick its box, and write the outcome in the step's `Notes:` line. Do not rely on earlier chat history: everything you need is here or in the files each step lists.

## Rules for the implementing agent

1. Do exactly one step. Read only the files that step lists, plus anything the compiler points to.
2. Before coding, check the "Verified facts" that the step relies on. Line numbers drift, so search by symbol.
3. Keep changes surgical and in the existing style (compact SwiftUI, few comments). Do not refactor unrelated code.
4. A step is done only when `swift build` and `swift test --filter <TestClass>` (the tests the step names) pass.
5. If a step turns out wrong or too big, stop. Write the problem in its `Notes:` and split it here; do not improvise.
6. UI text is English. The user-facing documentation is written last (step E1).
7. Proposals marked **⚠ changes an answer** are the plan's default. If the user rejects one, follow its "Fallback" line.

## Status

**Phase A — Browse podcasts** (fixes the reported problems: first level, dates, working sort)

- [x] A0. Baseline check
- [x] A1. Date formatting helper
- [x] A2. Podcast list model (pure functions)
- [x] A3. Podcast sort key (newest first by default)
- [x] A4. Separate podcasts from the music views
- [x] A5. Podcasts tab hub: Shows / New / Downloaded
- [x] A6. Show detail: header, filter, episode rows

**Phase B — Listening state**

- [x] B1. Persist show info and episode notes; parse `link` and `itunes:type`
- [x] B2. Persist per-episode progress
- [x] B3. Played / unplayed actions and the "In Progress" segment
- [x] B4. Resume and "Play from Beginning"

**Phase C — Home and refresh**

- [x] C1. Show Home in the center pane
- [x] C2. All Sources Home: Continue Listening / New Episodes
- [x] C3. Quiet background refresh with conditional GET
- [x] C4. Settings → Podcasts tab

**Phase E — Wrap-up**

- [x] E1. Documentation and final verification

**Later:** L1–L7 (backlog at the end; turn an item into steps when you pick it).

---

## 1. Product decisions (from the user)

| ID | Decision |
|---|---|
| D1 | Podcasts must be **first level**, with no Artist → Album folder to expand. |
| D2 | Every episode row shows its **publication date**. |
| D3 | Sort by **publication date, newest first by default**. The chevron reverses the order. |
| D4 (Q1a) | A 7th library tab, `LibraryView.podcasts`, titled "Podcasts". |
| D5 (Q2b) | The show header shows the show title in large type plus its description. |
| D6 (Q3) | An episode row shows the date, duration, download state, and playback state. It does not show the episode number, the description, or a row button. |
| D7 | Listening progress is kept per episode. |
| D8 (Q4) | All Sources Home shows in-progress episodes and the latest unplayed episode of each show. |
| D9 (Q4) | A Settings → Podcasts tab sets the refresh interval. Default **1 hour**. |
| D10 (Q5b) | An `All | Unplayed | Downloaded` filter on a show's episodes. |
| D11 (Q6a) | Opening a show leads to that show's own Home. The mechanism changes; see P2. |
| D12 (Q7a) | The chevron works in podcast views and reverses the date order. |
| D13 (Q8a) | Search inside a show searches its episodes with the existing search. |
| D14 (Q9c) | Home podcast items use 88-point tiles, like "Recently Added". |
| D15 (Q10a) | The final spec goes in `docs/PODCASTS.md`, in a `## Library browsing` section. |

## 2. Design proposals (v2)

Each proposal says why, what changes, and what to do if the user rejects it.

### P1 — Podcasts leave the music views (new; recommended)

Today, in All Sources, podcasts pollute the music views:
- A show that publishes daily stays first in **Recently Added**: albums are sorted by `addedAt`, which is the publication date (`LibrarySnapshot.swift:215`).
- Hosts appear in **Artists**.
- "Podcast" appears in **Tags → Genre**.
- **Shuffle Library** mixes in one-hour episodes.
- Episodes appear in **Recently Played** and **Most Played**.

Change: episodes are kept in their own list, exactly like radio. `LibrarySnapshot.build` already keeps radio out of `tracks` (in `stations`) while keeping it in `tracksByID`. The music tabs, the Home music sections, and Shuffle Library then contain music only. Podcasts live in the Podcasts tab and in the podcast Home sections.

Fallback: keep the snapshot as it is, and only exclude podcast albums from `recentlyAdded`.

### P2 — Open a show inside the Podcasts tab, without changing the source scope (⚠ changes the mechanism of Q6a, keeps its goal)

Q6a switched the global `libraryScope` to the show. That has three costs:
- the source picker jumps;
- the search is reset;
- going back to All Sources **rebuilds the whole All Sources library** every time you browse between shows.

The app already has a better pattern: Internet Archive navigates inside the pane, with house and back buttons (`ArchiveLibraryView.swift:16-30`).

Change: clicking a show pushes it inside the Podcasts tab (`model.openPodcastShowID`). The center Home then shows **that show's Home** (C1), which keeps Q6a's goal. Choosing a podcast in the source picker still works, and shows the same show detail directly.

Fallback: `openPodcastFeed` sets `libraryScope = .source(id)` and `libraryView = .home`; the "back" button returns to `.all` + `.podcasts`.

### P3 — The Podcasts tab is a small hub (extends Q5)

A segmented control at the root of the tab, in the same style as Radio (Stations / Favorites) and Archive (Browse / Saved / Recent):

| Segment | Content |
|---|---|
| **Shows** | One row per show, ordered by latest episode (D1, D3). |
| **New** | Unplayed episodes from every show in one flat list, newest first, with show name and date. This answers "the latest episodes at first level" directly. |
| **In Progress** | Added in B3. |
| **Downloaded** | Downloaded episodes. |

The last segment used is remembered for the session.

### P4 — One look for the show view, shared with LibriVox (refines Q2b)

The LibriVox book view (`ArchiveItemView`, `ArchiveLibraryView.swift:321`; screenshot `design/native/archive-librivox-light.png`) already has the right shape: a header with artwork, title, and author; the action buttons **Resume / Start Over / Add / Save**; a description with "More"; then a list with a bookmark on the chapter where the user stopped. A podcast show reuses that shape, so the app stays coherent:

- **Library pane** (navigate and act): a compact header with 56 pt artwork, title, author, and the actions *Resume "…"* / *Play Latest* / *Add Unplayed* / `⋯` (Refresh, Mark All as Played, Copy Feed URL, Open Website, Unsubscribe…). Below it, the `All | Unplayed | Downloaded` filter and the episodes.
- **Center Home** (read): large artwork, a large title, the full description (Q2b), then "Continue Listening" and "Latest Episodes" (C1).

### P5 — Episode rows that are readable at a glance (refines Q3)

- A leading 8 pt column: an accent dot for unplayed. Played episodes have a dimmed title.
- The date (A1 helper), relative for recent episodes: "Today", "Yesterday", the weekday name within the last 7 days, then "14 Nov", then "14 Nov 2025" for an earlier year.
- In-progress episodes: a thin progress bar under the title, and **"23 min left"** in place of the duration.
- At most one trailing status, by priority: playing ▸ downloading (progress) ▸ failed ▸ in the playlist ▸ downloaded.
- The episode notes appear only as a tooltip (`.help`, first 300 characters). The row itself stays as defined in Q3.

### P6 — Quiet background refresh (refines Q4/D9)

`startRefresh` cancels any running refresh and drives the visible footer and status bar. An hourly refresh of 20 shows must not:
- interrupt a refresh the user started, or
- show "Connecting…" every hour.

Change: a `PodcastRefreshController` refreshes shows on its own:
- at most 3 at a time;
- with a **conditional GET** (`ETag` / `Last-Modified` → 304, so nothing to parse or write);
- recording an error per show, shown as an icon on the show row and in Settings.

The footer's manual "Refresh Source" keeps the existing path.

### P7 — Played state the user controls (needed for "New" and the counters)

The existing `lastPlayedAt` is set after min(240 s, half the duration). It does not mean "played" for a one-hour episode. So:
- Played status comes from the saved progress (B2).
- The episode context menu offers Mark as Played / Mark as Unplayed.
- The show menu offers **Mark All as Played**, which empties "New" after subscribing to a show with 500 episodes.

Q3 excludes a button on the row, not a context-menu entry.

### P8 — Seven tabs on a balanced grid

The grid has 3 columns, so 7 tabs would leave a lone "Podcasts" on the third line.
- With 7 tabs, use 4 columns (4 + 3).
- Show the Podcasts tab only when the current scope contains at least one podcast, so music-only libraries keep the 6 tabs.

Check the narrow layout with `WindowLayoutTests`.

### Assumptions (change here if wrong)

- **A1:** One refresh interval for all shows: Off, 15 min, 1 h (default), 6 h, 24 h.
- **A2:** Episode states:
  - **in progress**: has saved progress, is not finished, and position ≥ 30 s;
  - **played**: finished (within 30 s of the end, reached the end, or marked);
  - **unplayed**: everything else.
- **A3:** On a Home tile, a click opens the show and a double click plays or resumes the episode.
- **A4:** A show row cannot be dragged or selected like a track; a click opens the show. Episode rows keep `.libraryItem(.track(id))`, so selection, drag, and double-click work as they do today.
- **A5:** "New" lists unplayed episodes published in the last 30 days, at most 200. "Mark All as Played" clears a show from it.

## 3. Wireframes (library pane is about 320 pt wide)

The Podcasts tab, root, with the Shows segment:

```
[ Search all sources                    ]
[Home ][Artists][Albums ][Years ]
[Folders][Tags  ][Podcasts]              ← P8: 4+3, Podcasts only if in scope
( Shows | New | In Progress | Downloaded ) ← P3 (In Progress from B3)
SHOWS                                  ⌄  ← chevron = date order (D3/D12)
[art] The Daily                     3 ●   ← unplayed count
      Updated today · 412 episodes    ›
[art] Hardcore History              ⚠    ← refresh error (P6), help = message
      Updated 12 Sep · 70 episodes    ›
──────────────────────────────────────────
6 shows · 1,204 episodes      ↻ Refresh
```

The Podcasts tab, New segment, which lists episodes from every show:

```
NEW EPISODES                           ⌄
● [art] Episode title              41:20
        The Daily · Today
● [art] Another episode          1:02:11 ⬇
        Hardcore History · Mon
```

A show detail in the library pane (P2/P4/P5):

```
⌂ ‹  The Daily
[art56] The Daily
        The New York Times
▶ Resume "Title" · 23 min left   ▷ Play Latest   ＋ Add Unplayed   ⋯
( All | Unplayed | Downloaded )
EPISODES                               ⌄
●  Episode title                   41:20
   Today
   Episode in progress       23 min left
   ▬▬▬▬▬▬▬▭▭▭  Mon
   Older episode (dimmed)          38:02
   12 Nov
```

The center Home with a show open (C1):

```
PODCAST
[art 120]  The Daily
           The New York Times · Updated today · 412 episodes
           Description, 4 lines…  More
Continue Listening   [tile][tile]
Latest Episodes      [tile][tile][tile][tile]
```

The All Sources Home additions (C2). Tiles are 88 pt: cover, episode title on 2 lines, and a caption (show · date, or "23 min left"):

```
Continue Listening   [tile][tile][tile]
New Episodes         [tile][tile][tile][tile]
```

## 4. Verified facts about the code (0.5.0)

Search by symbol if a line number has moved.

**Library views and scope**

- `LibraryView` (`AppPreferences.swift:20`): `home, artists, albums, years, folders, tags`. Not persisted. The tab grid is a 3-column `LazyVGrid` over `allCases` in `LibraryPane.swift`.
- `AppModel.libraryView` (`AppModel.swift:110`): setting `.home` also sets `contextPage = .home`. `selectLibraryView` is in `AppModel+CenterNavigation.swift:27`.
- `AppModel.libraryScope` (`AppModel.swift:96`): its `didSet` clears selection and `search`, then calls `reloadLibrary()`. Also there: `isAllSources` (`:297`), `selectedSource` (`:296`).
- `LibraryPane.body` picks a dedicated view per source kind: `isRadioSource` → `RadioLibraryView`, Internet Archive → `ArchiveLibraryView`, otherwise the music list.

**Patterns to reuse**

- Segmented pane: `RadioLibraryView.swift`.
- Drill-down with house and back buttons: `ArchiveLibraryView.swift:16-30`.
- Header, actions, "More", and resume bookmark: `ArchiveItemView` (`:321`).
- Row with download state: `ArchiveTrackRow` (`:439`).

**Snapshot**

- `LibrarySnapshot.build` (`LibrarySnapshot.swift:110`) keeps radio tracks out of `tracks` (into `stations`), but `tracksByID` includes them (`:132`). **P1 follows this pattern.**
- `orderPodcastEpisodes` (`:402`) orders episodes newest first. `recentlyAdded` sorts albums by `addedAt` (`:215`).

**Sorting**

- `LibrarySortKey`, `LibraryView.sortKey`, and `LibrarySortOrder` are in `LibrarySortOrder.swift`.
- The order is persisted as an array of *descending* keys, default `[.years]`; unknown keys are ignored.
- `librarySortIsDescending` and `toggleLibrarySort()` are at `AppModel.swift:323-330`.

**Podcast data**

- `PodcastEpisode` and `PodcastFeed` are in `Sources/MacarokCore/PodcastClient.swift`.
- `asTrackRecord` (`:25`) maps:
  - `album` ← the show title
  - `artist` ← the author
  - `albumID` = `StableID.make(sourceID, "podcast-feed", feedURL)`
  - `addedAt` = `publicationDate ?? Date()`
  - `genre = "Podcast"`
- `PodcastEpisode.description` and `PodcastFeed.description` are parsed **but never stored**. The `<link>`, `itunes:type`, and HTTP validators are not handled.
- One show = one `SourceRecord` with `kind == .podcasts` (`Models.swift:23`; no description field).
- The feed is fetched and saved in `addPodcast(address:)` (`AppModel.swift:1278`) and in `refreshSource` `case .podcasts` (`:1484`).

**Refresh**

- `refresh()`, `refresh(sourceID:)`, and the private `startRefresh` are at `AppModel.swift:1353-1364`. `startRefresh` cancels any refresh in progress.
- There is no periodic timer. A `didBecomeActive` subscriber exists (`AppModel.swift:~461`).

**Playback history and progress**

- `recordPlay` is called from the tick (`AppModel.swift:~1929`). The same tick calls `archive?.recordProgress` (`:~1937`); copy that throttled pattern from `InternetArchiveController.recordProgress`.
- `MPNowPlayingInfoPropertyPlaybackRate` is hard-coded to 1.0 (`AppModel.swift:~1996`), and there is no playback speed API yet.

**Downloads**

- `model.podcastDownloads` provides `key(track)`, `localURL(for:)`, `isDownloading`, `progress[key].fraction`, `errors[key]`, `downloads[key]`, `download`, `cancel`, `reveal`, `remove`, and `canRemove`.

**Storage, footer, Home, Settings, preferences**

- Migrations: `LibraryStore.swift:44` registers `library-v1` and `library-v2-remote-paths`, then calls each `XxxStorage.registerMigration(&migrator)` (`:132-137`). The reference feature table, with `ON DELETE CASCADE` on `sources(id)`, is `InternetArchiveStorage`.
- `LibraryFooterSummary` (`PanelFooter.swift:24`) has `.music`, `.radio`, `.archive`, each with compact SF Symbols.
- Center Home: `ContextPane.swift` around line 120 (Recently Added grid of `AlbumTile`, Recently Played, Most Played, `RadioFavoritesSection` for All Sources). The episode context: `PodcastEpisodeActions` (`TrackFileActions.swift:28`).
- `SettingsTab` (`SettingsView.swift:6`): `general, playback, shortcuts, sources, scrobbling`.
- `AppPreferences`: a new field must be added to `CodingKeys`, `init(from:)` (`decodeIfPresent ?? default`), and `encode(to:)`.
- `PodcastDiscoverySheet` (`DiscoverySheets.swift:4`) is a reusable podcast search. `AddSourceSheet` uses it, then calls `model.addPodcast(address:)`.

**Existing tests touched by P1**

- `PodcastLibraryOrderTests`:
  - `testAllSourcesPreservesMusicSlots…` asserts that podcasts are mixed into `snapshot.tracks`;
  - `testCachedFeedSearch…` asserts `model.displayedTracks`.
- Also check: `AllSourcesTests`, `LibrarySnapshotPatchTests`, `AppModelPresentationPerformanceTests`.

---

## 5. Steps

### Phase A — Browse podcasts

#### A0. Baseline check

- Run `swift build`, then `swift test --filter PodcastLibraryOrderTests`.
- Record any failure that already exists. Do not fix unrelated failures.
- Notes: Baseline 0.5.0: build OK; 279 app tests, 0 failures (3 skipped).

#### A1. Date formatting helper

- New file `Sources/MacarokApp/PodcastLibrary.swift`.
- Add `enum PodcastDate { static func short(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String }`. Formats (P5):
  - "Today"
  - "Yesterday"
  - the weekday name within the last 7 days
  - "14 Nov" within the same year
  - "14 Nov 2025" otherwise
- Add `static func remaining(_ seconds: Double) -> String`, for example "23 min left" or "1 h 5 min left".
- Test: new `PodcastLibraryTests` with a fixed `now`, a fixed calendar, and `en_US_POSIX`. Cover each format and the boundaries.
- Notes: Done in `PodcastLibrary.swift` (`PodcastDate`). Formats follow the locale (en_US: "Nov 7", "Dec 22, 2025"). `PodcastDate.publication` returns nil for undated episodes (`year == nil`).

#### A2. Podcast list model (pure functions)

- In `PodcastLibrary.swift`:
  - `enum PodcastEpisodeState: Equatable { case unplayed, inProgress(position: Double, remaining: Double), played }`
  - `enum PodcastEpisodeFilter { all, unplayed, downloaded }`
  - `struct PodcastShowSummary: Identifiable` with `id` (the sourceID), `title`, `latestEpisode`, `episodeCount`, `unplayedCount`, `latestDate`.
  - `enum PodcastLibrary`, static functions only. They take `episodes: [TrackRecord]`, `sources`, and closures `state: (TrackRecord) -> PodcastEpisodeState` and `isDownloaded: (TrackRecord) -> Bool`:
    - `shows(…, newestFirst:)`: one summary per `.podcasts` source, ordered by `latestDate`; shows with no date go last; ties by title.
    - `episodes(ofShow:…, filter:, newestFirst:)`: ordered by `addedAt`, ties by title, then id.
    - `newEpisodes(…, now:, maxAge: 30 days, limit: 200)`: unplayed, newest first (A5).
    - `inProgress(…, limit:)`: most recently updated first. Take the update time from the closure, or pass the progress dictionary.
    - `latestUnplayedPerShow(…, limit:)`
- Until B2 exists, `AppModel` provides `state` as: `.played` if `lastPlayedAt != nil`, otherwise `.unplayed`.
- Tests (`PodcastLibraryTests`; reuse the fixture style of `PodcastLibraryOrderTests`): cover show order and the toggle, each filter, the age limit of new episodes, one episode per show, and that non-podcast tracks are ignored.
- Notes: Done. List functions expect podcast episodes only (`shows` filters by source kind). Tests: `PodcastLibraryTests`.

#### A3. Podcast sort key

- `LibrarySortOrder.swift`: add `LibrarySortKey.podcasts`.
- Settings saved by 0.5.0 have no `podcasts` key, so membership means **reversed from the default**: `isDescending(.podcasts) == !descending.contains(.podcasts)`. Add a one-line comment.
- `AppModel`: add a `currentSortKey` computed property. It is `.podcasts` when `libraryView == .podcasts` or when the selected source is a podcast; otherwise `libraryView.sortKey`. Use it in `librarySortIsDescending` and `toggleLibrarySort`. Toggling `.podcasts` does not need to rebuild the snapshot, because podcast lists are sorted at display time.
- `LibraryPane.sortHelp`: "newest first" / "oldest first" for podcasts.
- Tests:
  - decoding `["years"]` gives podcasts newest first;
  - toggling then doing an encode/decode round-trip gives oldest first.
- Notes: Done. `AppModel.currentSortKey`; inverted membership for `.podcasts`.

#### A4. Separate podcasts from the music views (P1)

- `LibrarySnapshot.build`: partition episodes from podcast sources into a new `podcastEpisodes: [TrackRecord]`, the same way as `stations`:
  - keep them in `tracksByID`;
  - keep `orderPodcastEpisodes` on that list;
  - remove them from `tracks` and from everything derived from it (artists, albums, years, tags, folders, recentlyAdded, mostPlayed*, recentlyPlayed).
- Update every place that builds or copies a snapshot: the `replacing` method and the `updating` patch path (`:244`) and `updatingStations` (`:354`). Then grep for `stations:` and mirror it.
- `AppModel`: add `var podcastEpisodes: [TrackRecord] { displayedCatalog.podcastEpisodes }`. Search uses the same snapshot builder, so search results are partitioned too (D13).
- `LibraryPane` checks: the empty state must not say "no results" when only podcasts match. The tab grid (P8): use `count: tabs.count > 6 ? 4 : 3`, where `tabs` hides `.podcasts` unless a podcast source is in scope. Add `case podcasts` to `LibraryView` in this step (symbol `"waveform"`), so the switch compiles. Its pane content comes in A5; show a placeholder until then.
- Update the tests listed in "Existing tests touched by P1":
  - the slot-preservation test becomes: music order is unchanged, and episodes are in `podcastEpisodes`, newest first per show;
  - `displayedTracks` assertions become `podcastEpisodes`.
- New test: in All Sources, `recentlyAdded`, `artists`, and `genreGroups` contain no podcast albums or tracks.
- Run `swift test --filter "PodcastLibraryOrderTests|AllSourcesTests|LibrarySnapshotPatchTests|AppModelPresentationPerformanceTests"`.
- Notes: Done for **All Sources only**: a single podcast scope keeps its previous snapshot shape (its pane is the dedicated show view), so `testEveryPreparedFeedGroup…` stays valid. Podcast albums stay in `albumsByID`; a podcast update in All Sources rebuilds the snapshot (structural). The music list explains where podcasts went when only they match.

#### A5. Podcasts tab hub (P3)

- New file `Sources/MacarokApp/PodcastLibraryView.swift`, containing `PodcastLibraryView(model:)`. `LibraryPane` uses it when `libraryView == .podcasts`, the same way it branches to `RadioLibraryView`, but keeping the shared search field and tab grid above it.
- `@State segment: PodcastHubSegment` (`shows, new, downloaded`; `inProgress` is added in B3).
- Shows: a `List` of `PodcastShowRow`, laid out as in the wireframe. A click calls `model.openPodcastShow(id)` (P2; implemented in A6). Context menu: Play Latest, Mark All as Played (from B3), Refresh, Unsubscribe… (confirm, then `model.removeSource`).
- New and Downloaded: a `List(selection:)` bound like the music list (`model.librarySelection`, `selectLibraryItem`, `primaryAction` → `activateLibraryItem`), with `PodcastEpisodeRow(track:, showsShowName: true).libraryItem(.track(id))`.
- Chevron (A3): sorts Shows by latest episode and the episode lists by date.
- Empty state, when there are no podcast sources: `ContentUnavailableView("No Podcasts", …)` with **Search Podcasts…** (opens `PodcastDiscoverySheet`, then `model.addPodcast`) and **Add Feed URL…** (`presentAddSource`).
- Footer: `LibraryFooterSummary.podcasts(shows:episodes:)`, with compact symbols `"waveform"` and `"list.bullet"`.
- `PodcastEpisodeRow` (P5, without progress until B2):
  - unplayed dot
  - title
  - date line, with "Show ·" when `showsShowName`
  - one trailing status
  - duration
  - `.help` showing the notes (from B1)
  - context menu `LibraryPlaybackActions { [track] }` + `TrackFileActions`
- Tests: model-level checks for each segment's content. Rows are covered by `PodcastLibraryTests`.
- Notes: Done in `PodcastLibraryView.swift`. In Progress was added at the same time as B2.

#### A6. Show detail (P2, P4)

- `AppModel`: `var openPodcastShowID: String?`. `openPodcastShow(_:)` sets it and `selectLibraryView(.podcasts)`. `closePodcastShow()` clears it. Also clear it when `libraryScope` changes, or when the show's source is removed.
- `PodcastLibraryView`: when `openPodcastShowID` is set, show the house and back bar (copy from `ArchiveLibraryView.swift:16-30`) and a `PodcastShowView(source:)`.
- When the **selected source** is a podcast, `LibraryPane` shows `PodcastShowView` directly, without the hub or the back button. Add the branch next to the radio and archive branches.
- `PodcastShowView`, modeled on `ArchiveItemView`:
  - Header: 56 pt `ArtworkView(track: latest)`, title, author. Buttons: *Play Latest*, *Add Unplayed* (adds the unplayed episodes, oldest first, to the playlist). A `⋯` menu: Refresh, Mark All as Played (B3), Copy Feed URL, Open Website (B1), Unsubscribe…
  - The `All | Unplayed | Downloaded` filter (D10), the "EPISODES" header with the chevron, then the list of `PodcastEpisodeRow`, bound to the library selection.
  - Search (D13): when `model.search` is not empty, filter the rows by `podcastEpisodes` from the search snapshot.
- Tests:
  - open and close; a scope change clears the show;
  - removing the source clears the show;
  - a podcast source in the picker gives this show's episodes, filtered and sorted.
- Notes: Done. Navigation state lives in `PodcastController.openShowID`; helpers in `AppModel+Podcasts.swift`. "Refresh Show" uses the visible manual refresh.

### Phase B — Listening state

#### B1. Persist show info and episode notes

- `PodcastClient.swift`:
  - Parse the channel `<link>` into `PodcastFeed.link: URL?`.
  - Parse `itunes:type` into `isSerial: Bool`.
  - Parse the episode `<link>` into `PodcastEpisode.link: URL?`.
  - Add `fetchFeed(url:validators:) -> PodcastFetchResult` (`.notModified`, or `.feed(PodcastFeed, validators)`). It sends `If-None-Match` / `If-Modified-Since` and reads `ETag` / `Last-Modified`.
  - Keep `fetchFeed(url:)` as a wrapper.
- New file `Sources/MacarokCore/PodcastStore.swift`, copying the `InternetArchiveStorage` pattern. Migration `"podcast-v1"`:
  ```sql
  CREATE TABLE podcastShows (
      sourceID TEXT PRIMARY KEY NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      title TEXT NOT NULL, author TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
      artworkURL TEXT, link TEXT, isSerial BOOLEAN NOT NULL DEFAULT 0,
      etag TEXT, lastModified TEXT, refreshedAt DATETIME, lastError TEXT
  );
  CREATE TABLE podcastEpisodeNotes (
      trackID TEXT PRIMARY KEY NOT NULL,
      sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      notes TEXT NOT NULL DEFAULT '', link TEXT
  );
  ```
- Add `LibraryStore` methods to save and read show info (upsert), and to save and read episode notes for a source (replace all rows for that source). Register the migration in `LibraryStore.swift`.
- `AppModel`:
  - Add `podcastShows: [String: PodcastShowInfo]`, loaded at startup.
  - Write it in `addPodcast` and in `refreshSource case .podcasts`.
  - Read notes on demand: `podcastNotes(for:) async`.
- Strip HTML at display time (`NSAttributedString(html:)`, or a small tag stripper); store the raw notes.
- Tests:
  - `PodcastStoreTests` (core): round-trip, upsert, cascade on source deletion.
  - Parser: `link`, `itunes:type`, `ETag` → validators, 304 → `.notModified`. Use the existing parser test fixtures and the injected transport.
- Notes: Done. One migration `podcast-v1` creates `podcastShows`, `podcastEpisodeNotes`, and `podcastProgress` (B2). Notes are the parser's plain text. Tests: `PodcastStoreTests`.

#### B2. Persist per-episode progress

- In `PodcastStore.swift`, add migration `"podcast-progress-v1"`:
  ```sql
  CREATE TABLE podcastProgress (
      trackID TEXT PRIMARY KEY NOT NULL,
      sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      position DOUBLE NOT NULL, duration DOUBLE NOT NULL,
      isFinished BOOLEAN NOT NULL DEFAULT 0, updatedAt DATETIME NOT NULL
  );
  ```
  There is no foreign key on `tracks`, because a feed refresh may rewrite track rows.
- New file `Sources/MacarokApp/PodcastProgressController.swift`, `@MainActor @Observable`. It holds `progress` and provides:
  - `record(track:position:duration:)`: only for podcast sources; skips changes under 4 s; marks finished at `duration - 30`.
  - `setFinished(_:for:)`
  - `state(for:)` (A2)
- Call `record` next to `archive?.recordProgress` in the tick. Call finished when an episode plays to its end; find where the queue advances at the end of a track.
- Replace the A2 placeholder `state` with the controller.
- Tests: `PodcastProgressTests`, with injected values: unplayed, in progress (remaining time), finished near the end, the 4 s throttle, and that music is ignored.
- Notes: Done in `PodcastController` (no separate progress controller). Positions under 30 s are ignored; completion is recorded on end of track and gapless handoff.

#### B3. Played actions and the In Progress segment

- Episode context menu: Mark as Played / Mark as Unplayed, through `setFinished`.
- Show menu (A5 and A6): **Mark All as Played**, one batch write.
- Hub: add the `inProgress` segment. `PodcastEpisodeRow` gets its thin progress bar and "N min left".
- Unplayed counts on show rows now use the real state.
- Tests: Mark All as Played empties "New" for that show; Mark as Unplayed brings an episode back.
- Notes: Done.

#### B4. Resume and "Play from Beginning"

- Find where a queue item starts from position 0 (`playQueueItem` / `restorePosition`, `AppModel.swift:~771-800`). For an in-progress podcast episode, start at the saved position, using the same mechanism as `playTracks(_:position:)`. Never do this for music or radio, or after an explicit seek.
- Show header: **Resume "Title" · 23 min left** plays the most recently updated in-progress episode. **Play from Beginning** in the episode menu clears the progress, then plays.
- Tests: an injected in-progress episode starts at its saved position; music starts at 0; "Play from Beginning" starts at 0.
- Notes: Done via `AppModel.playbackStartPosition(for:)` (tested without network playback). The gapless prepared next item starts at 0.

### Phase C — Home and refresh

#### C1. Show Home in the center pane

- `ContextPane` Home: when `openPodcastShowID` is set, or the selected source is a podcast, render `PodcastShowHome` instead of the music sections (wireframe):
  - large header with the description and More/Less (Q2b)
  - "Continue Listening" for this show
  - "Latest Episodes", 8 tiles
- `PodcastEpisodeTile` (D14): 88 pt cover, title on 2 lines, caption. A click selects the episode (`inspect`); a double click plays or resumes it.
- Tests: model-level check that the show Home data is limited to that show. Optionally, a rendering smoke test like `AlbumMetadataRenderingTests`.
- Notes: Done (`PodcastShowHome`).

#### C2. All Sources Home podcast sections

- When `isAllSources && homeFilter == .all`, add `PodcastHomeSection` next to `RadioFavoritesSection`:
  - "Continue Listening": `inProgress(limit: 8)`
  - "New Episodes": `latestUnplayedPerShow(limit: 8)`
- Use the same tiles. A click opens the show (A3); a double click plays.
- Hide a section when it is empty.
- Tests: the sections draw from every show and contain no music.
- Notes: Done (`PodcastHomeSection`). Home counts read "N shows · M episodes" without music.

#### C3. Quiet background refresh (P6)

- Extract the body of `refreshSource case .podcasts` into an internal `refreshPodcast(_ source:, store:, generation:)`. Both the manual path and the new controller use it. It uses the B1 validators: on 304, only update `refreshedAt`.
- New `PodcastRefreshController` (`@MainActor @Observable`):
  - `static func due(shows:sources:interval:now:) -> [String]`, pure: a show with no info is due; an interval of 0 gives `[]`.
  - A loop every 5 minutes, plus on `didBecomeActive`. It refreshes the due shows, at most 3 at a time, without touching `isRefreshing`, `refreshProgress`, or `status`.
  - On failure, store `lastError`; on success, clear it.
  - Skip a show that the manual refresh is currently refreshing.
- Changes are published the same way as the manual path (`unpublishedSourceChanges` + `reloadLibrary`), batched once per pass.
- Tests: the `due` cases; a pass with an injected transport answering 304 writes nothing except `refreshedAt`; a failure sets `lastError` without changing `status`.
- Notes: Done in `PodcastController.refresh(sourceIDs:)` + `AppModel.refreshPodcast`. Started only when system controls are registered (the app, not tests). A failed show is retried after one interval (`attempts`).

#### C4. Settings → Podcasts tab

- `AppPreferences`: `podcastRefreshInterval: TimeInterval = 3600`, where 0 means Off, in the three coding places.
- `SettingsTab.podcasts`, with `Label("Podcasts", systemImage: "waveform")`, containing a `Form`:
  - a "Refresh shows" `Picker`: Off / 15 min / 1 h / 6 h / 24 h;
  - **Refresh All Now**;
  - a list of shows with "Updated …", the error if any, and Unsubscribe…
- Move the **Podcast Downloads** block from Playback to this tab, so podcast settings live in one place. Update the doc reference in E1.
- Tests: a preferences round-trip with the key missing gives 3600.
- Notes: Done (`PodcastSettingsView.swift`). **Deviation:** Podcast Downloads stay in Settings → Playback because the list also holds LibriVox chapters.

### Phase E — Wrap-up

#### E1. Documentation and final verification

- `docs/PODCASTS.md`:
  - new `## Library browsing` section: hub, show view, filter, row states, sort, both Homes, played state;
  - new `## Automatic refresh` section;
  - update the intro paragraph;
  - update the path to Podcast Downloads in Settings.
- `docs/PRODUCT.md`:
  - library views: add Podcasts, and say that podcasts are no longer in the music views;
  - update the paragraph about newest-first podcast episodes.
- `docs/SOURCES.md` `## Podcasts`: add links. `docs/TESTING.md`: one line for each new test class.
- Run `swift build`, then `swift test`. Fix only regressions caused by this work.
- Manual check:
  - subscribe to 2 shows;
  - Podcasts → Shows → open a show: flat list, dates, newest first, chevron reverses the order, filter works;
  - New lists both shows;
  - play for 1 minute, quit, relaunch: the episode is in "Continue Listening" and resumes;
  - All Sources → Recently Added contains no podcasts.
- Notes: Done: PODCASTS, PRODUCT, SOURCES, TESTING updated. Offscreen renders added (`NativeRenderingTests.testRenderPodcastLibraryInLightAndDarkAppearance`, references in `design/native/podcasts-*.png`). Manual check with real feeds still to do by the user.

---

## 6. Later (backlog — specs only; turn one into steps when picked)

| ID | Feature | Sketch | Watch out |
|---|---|---|---|
| L1 | **Show notes in Playing → Context** — *done: paragraphs kept, links and chapter times clickable* | For a podcast episode, a "Show Notes" section from B1. Links are clickable. Timestamps like `12:34` or `1:02:03` become links that seek when the episode is current. | Sanitize the HTML; render text plus links only. |
| L2 | **Playback speed per show** + skip −15 s / +30 s | A speed menu (1×, 1.25×, 1.5×, 2×) in the transport bar for podcasts, remembered per show. For podcasts, the Previous/Next keys could skip −15/+30 (optional). | First check that the VLCKit player exposes the rate. Update `MPNowPlayingInfoPropertyPlaybackRate`. Scrobbling is not affected (podcasts are excluded). |
| L3 | **Serial shows** | When `isSerial` (B1) is set, the show defaults to oldest first. When an episode ends, offer to continue with the next one (like LibriVox chapters). | The chevron then needs a per-show direction. |
| L4 | **OPML import/export** | Settings → Podcasts → Import OPML… subscribes to each feed through `addPodcast`, in a cancellable sequence with progress. Export OPML… writes all subscriptions. | Deduplicate with `samePodcastFeed`. |
| L5 | **Automatic downloads** | Per show: Off / latest 1 / latest 3. After a refresh, download new episodes. Optionally remove a download N days after it is marked played. | This contradicts the current "downloads only on explicit action" rule in `PODCASTS.md`, so the doc changes and the option is off by default. |
| L6 | **New episode notifications** | An optional macOS notification after a background refresh finds new episodes (one notification per pass). | Ask for notification permission only when the user enables it. |
| L8 | **Chapters** — *done: timeline gaps, hover label, current chapter, ⌥←/⌥→, Context list; sources: Podcasting 2.0 JSON, Podlove, notes. ID3 CHAP later.* | | |
| L7 | **Episodes in the active playlist** | A playlist row for an episode shows "Show · date" and the time left, instead of an album group. | Look at `PlaylistAlbumGroups` first. |
