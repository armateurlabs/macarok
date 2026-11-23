# Application icon

The selected design is **Native (B)**: a blue wolf holding a red apple on a silver macOS tile.

- `AppIconArtwork.png` retains the generated source artwork.
- `AppIcon.png` is the exported 1024 × 1024 PNG.
- `AppIcon.icns` is the application resource referenced by `CFBundleIconFile` in `Info.plist`.

## Regeneration

From the repository root, run:

```sh
swift scripts/make-icon.swift
```

The AppKit generator validates the square source, applies a consistent rounded-square export mask, and downsamples with high-quality interpolation. The mask excludes generated exterior fringe while retaining the wolf, apple, colors, and internal tile. It writes the standard 16, 32, 128, 256, and 512 point representations at 1× and 2× into `.build/Macarok.iconset`, exports the largest PNG, then calls `iconutil` to produce the ICNS. The app build script regenerates these resources on every build.

## Menu bar icon

`Support/MenuBarIcon.png` is the menu bar silhouette: the app icon's wolf, cropped below the head so the head, eye, and apple fill the item. It was traced from `AppIconArtwork.png` by keeping its blue body and its apple, leaf, and stem, separating the apple from the muzzle with a thin gap, and filling the apple's highlight. The eye and open mouth stay in negative space. `Sources/MacarokApp/MenuBarIcon.swift` embeds it as 18, 36, and 54-pixel PNG representations of an 18-point template image, so macOS draws it in the menu bar's color and highlight. After changing the source, regenerate those representations by downsampling it with high-quality interpolation and replacing the base64 strings.

## Verification

The selected icon was packaged on 16 November 2026. All ten decoded ICNS representations retain their expected dimensions and alpha channels; the largest representation matches the 1024-pixel PNG exactly. The 32- and 64-pixel exports were visually inspected. The local Release bundle passed deep strict signature verification and retains macOS 14.0 as its minimum. Its icon-only resource update preserves the existing executable apart from its code signature; no application source compilation was needed. The previous bundle is retained under the ignored `.build/icon-b-update` directory.

## Artwork provenance and prompts

The source was generated with the built-in `image_gen` tool from the user-provided Amarok wolf reference, then the user selected concept B. The cleanup pass uses the selected B mockup as its edit target. No image API credentials are required by the build; generation is separate from resource export.

### Selected concept prompt

Use case: logo-brand. Create ONE polished Macarok macOS app icon mockup, variation B: Native. The attached Amarok image is a visual reference: retain the blue wolf's upward-facing profile and distinctive white eye, but redesign the silhouette with elegant broad curves and very few internal facets. A clearly recognizable whole small red apple, short stem and small green leaf, is held gently between the wolf's open jaws. The apple must be physically in the mouth, not floating above it or replacing the head. Put this blue wolf on a softly shaded pale silver rounded-square macOS app tile with generous internal margins. Modern native macOS craft, restrained relief, deep blue enamel, a soft precise shadow, no busy detail. The composition must read immediately at 32 and 64px. No Apple corporate logo, bitten apple, text, letters, notes, headphones, watermark or labels. One large centered icon on a square canvas, transparent outside the rounded-square tile. No comparison board.

### Production cleanup prompt

Use case: background-extraction. Edit target: the attached selected Macarok icon B. Production cleanup ONLY. Preserve the blue wolf silhouette, white eye, red whole apple with green leaf, the silver rounded-square tile, internal soft shading, colors, composition and proportions exactly. Remove every stray white/blue speck, fuzzy fragment, white haze and disconnected pixel OUTSIDE the rounded-square tile. The outer rounded-square edge must have a clean, continuous, smooth antialiased alpha boundary with fully transparent empty space beyond it, including all four corners. Keep the entire tile comfortably inside the square canvas with even clear margins, approximately the existing layout. Do not add any exterior glow or shadow, new objects, text, outlines or labels. Do not redesign or reinterpret the wolf, apple or tile. Return a single production-ready square app-icon master PNG with genuine transparency outside the tile, ideally 1024 by 1024 pixels.

