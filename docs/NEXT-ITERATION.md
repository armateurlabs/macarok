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
