# Next iteration

These interface changes are planned after the current release.

## Library sorting

- Replace the shuffle button on the library section heading (Your Library, Artists, Albums, Years, Folders, or Tags) with a single sort-direction arrow.
- Toggle natural alphanumeric ascending/descending order; the arrow changes direction with the selection. Years use numeric order.
- Keep library/group shuffle available from the existing context menu.
- Sorting changes library presentation without changing the active playlist or playback.

## Rich playlist album groups

- Offer an Amarok-inspired presentation with an album header, artwork, album name, and artist above its tracks.
- Keep the option available in Settings and in both playlist More (`…`) menus, at the top and bottom. All three controls use the same persisted preference and stay synchronized.
- Disabling the option restores the compact playlist presentation.
- Preserve queue order, duplicate entry identities, current playback, selection, and queue actions. Group adjacent entries from the same source-specific album; headers must not merge or reorder separate copies.

## Implementation constraints

- Prepare browsing order off the foreground path. Keep canonical album track order, Home date/play-count rankings, newest-first podcast episodes, and source-qualified folder identities intact.
- `LibrarySnapshot` supplies full and searched presentations; carry sorting through structural rebuilds and incremental patches. Existing natural comparators use `localizedStandardCompare`.
- `QueuePane` and both instances of `PlaylistControls` live in `MainWindow.swift`. Display-only album headers require translating visual move/delete offsets back to real queue offsets; row selection and playback continue to use existing queue UUIDs.
- Refresh group presentation when metadata or artwork changes, even when `queueRevision` does not change. Reuse `ArtworkView` for actual-source, asynchronous cover loading.
- Keep radio entries flat: stations share an internal album ID and must not become an artificial album group.
