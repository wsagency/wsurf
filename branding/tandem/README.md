<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Tandem: the WSurf mark

Chosen by the owner on 2026-10-16. It replaces the shipped wave mark and supersedes the Flux draft in [`../DESIGN.md`](../DESIGN.md). **Nothing here is wired into the app, website, README or DMG yet**; those cutovers are separate changes.

## Idea

A large violet disc (you) with a small mint disc (the assistant) riding in a bite on its trailing edge, both on one waterline. You lead; the assistant follows in your wake, never in front, inside the space you leave it. It draws the site's line: "Your browser. Your assistant. Your call."

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

These are the Flux draft's default pair (track deep, knob start). The five other Flux palettes stay available as colour pairs for a possible Dock icon choice; they are not redrawn for Tandem yet.

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
| `icon/Tandem.icon/` | draft Icon Composer bundle: `layer-lead.svg` and `layer-follower.svg` with per-appearance fills in `icon.json`. **Not yet opened in Icon Composer or checked with actool.** |
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

## Next changes (not in this one)

1. App bundle icon: rebuild `WSurf/AppIcon.icon` from `icon/Tandem.icon/` and retire the wave path in `Tools/make-app-icon.swift`; verify with actool.
2. Website: lockup in the header and footer, favicons as files, colour tokens.
3. README `<picture>` and `.github/assets/`; DMG background (`Tools/make-dmg-background.swift`).
4. `NOTICE` line about the "new WSurf wave mark and icon".
5. Loader in the app (`loader/app/TandemLoader.swift`) and on the website (`loader/web/`); 3D and relief art for the site hero and the About window.
