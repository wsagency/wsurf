<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: BUSL-1.1 -->
# Tandem: the WSurf mark

Chosen on 2026-10-16. Tandem is the current WSurf mark. The [design system](../../wsurf.app/design-system/README.md) publishes the artwork and documents its use on the website and in the app. [`../DESIGN.md`](../DESIGN.md) preserves the earlier Flux proposal.

## Idea

A large violet disc represents the person using WSurf. A smaller mint disc represents the assistant and follows the lead disc along the same waterline.

Mint is also the assistant's colour in the interface, so the mark and the product say the same thing: violet is what you did, mint is what the assistant did.

## Geometry (1024 master)

| | master (32 px and up) | small cut (24 px and below) |
|---|---|---|
| lead disc | centre (548.2, 506.75), r 348.3 | centre (550.38, 507.32), r 344.44 |
| follower disc | centre (279.68, 687.87), r 167.18 (0.48 R) | centre (296.82, 665.76), r 186 (0.54 R) |
| follower position | 34° below horizontal, 0.93 R from the lead centre | 32° |
| gap around the follower | 56 units, bite fillets 10 | 100 units, no fillets |
| shared waterline | y 855.05 | y 851.76 |

The pair is optically centred (65% bounding box, 35% centroid). Tight viewBox for layouts: `96.82 142.77 815.36 727.96`. Two flat shapes; no gradients, strokes or filters.

## Colours

| | Day | Night |
|---|---|---|
| lead | `#3B1FD1` | `#6D55FF` |
| follower | `#14C79A` | `#2FE0B2` |
| wordmark / mono ink | `#1D1D1F` | `#F5F5F7` |

These colors come from the Flux draft’s default pair. Its five other palettes are kept with the historical design studies. The shipping Dock finishes are listed in the [Dock guide](../../wsurf.app/design-system/assets/Dock/README.md).

## Wordmark and lockup

- "WSurf" in **Inter Display Bold** (Inter 4.1), tracking −0.04em with the font's own kerning, converted to outlines. The f is moved 104 font units right so the r and f no longer nearly touch (closest gap now equals the W–S gap). SF Pro was the reference look but Apple licenses it only for interface mock-ups, so it cannot be the logo.
- Lockup: mark 1.22× the cap height, gap to the W 0.25× cap height, waterline 1.6% of the mark height below the baseline (matching Inter's round overshoot). Aspect 4.55:1. All numbers are in `lockup/metrics.json` and `wordmark/metrics.json`.
- Clear space: the follower disc's diameter on every side of the mark or lockup (0.48× the lockup height). Minimum: lockup 24 px tall, master mark 32 px, small cut 16 px.

## Files

| Path | What |
|---|---|
| `mark/mark-light.svg`, `mark-dark.svg` | 1024 master, Day and Night |
| `mark/mark.svg` | master with `--wsurf-lead` / `--wsurf-follower` CSS variables (Day fallbacks) |
| `mark/mark-tight*.svg` | cropped to the shape plus 2%, for layouts and lockups |
| `mark/mark-small*.svg` | small cut for 24 px and below |
| `mono/` | one-ink versions: `currentColor`, `#1D1D1F` (black) and `#F5F5F7` (white), master, small and tight |
| `wordmark/` | outlined wordmark (`currentColor`, light, dark) and its metrics |
| `lockup/` | lockups: CSS-variable, light, dark, mono, black, white; 2× PNGs; metrics |
| `icon/icon-light.svg`, `icon-dark.svg`, `icon-*-{1024,512,256,128}.png` | app icon previews: tile 824/1024, radius 185, mark at 62% of the tile, on `#FFFFFF` / `#1C1C1E` |
| `icon/Tandem.icon/` | Icon Composer source for the flat finishes, with per-appearance fills for the lead and follower layers |
| `favicon/favicon.svg` | small cut; switches to Night colours with `prefers-color-scheme` |
| `favicon/favicon-mono.svg` | one ink, also switching |
| `favicon/favicon.ico` | 16, 32 (small cut) and 48 px (master), Day colours only |
| `favicon/apple-touch-icon.png`, `icon-192.png`, `icon-512.png` | opaque, mark on `#FFFFFF` |
| `proof/` | review sheets for the mark, wordmark and lockup |
| `3d/` | the mark as a 3D object: USDZ (Day and Night), 2048 px stills, 3D app-icon renders, turntable videos, SceneKit sources. See [3d/README.md](3d/README.md) |
| `loader/` | the Tandem loader (the follower orbits the lead, 1.6 s): CSS/SVG for the web, SwiftUI for the app, MP4/GIF/HEVC-alpha, generator. See [loader/README.md](loader/README.md) |
| `relief/` | the pair as a planet and its moon (Earth & Moon, Clay, Topographic): 2048×1024 maps, stills, 540 px loops, SceneKit sources. See [relief/README.md](relief/README.md) |

## Provenance

- Mark geometry: drawn from scratch for WSurf with exact circles, arcs and tangents by Anthropic Claude models working for wsagency (2026-10-16), chosen from six directions. Not derived from Linen's mark or any third-party artwork.
- Wordmark outlines: Inter Display Bold, Copyright (c) 2016 The Inter Project Authors (https://github.com/rsms/inter), SIL Open Font License 1.1; upstream licence text in [`../licenses/Inter-OFL.txt`](../licenses/Inter-OFL.txt). Source file `docs/font-files/InterDisplay-Bold.woff2` at tag `v4.1` (SHA-256 `23bc37619593377e128f24660fedb2869d18277b4026cb46e5637be7643faf91`). The font binary is not shipped.
- The files were generated by throwaway scripts that are not part of this repository, following the convention in [`../README.md`](../README.md); a production export pipeline, if wanted, belongs under `Tools/`.
- No trademark, design-right or clearance search has been done for the name or the mark.

## Published assets

The [maintainer workflow](../../wsurf.app/design-system/Adoption.md) connects the artwork in this directory and the app icon catalog to the design-system page. The current app bundle uses Anodized artwork. Settings also offers Steel, Copper, Light, Dark and Mono.
