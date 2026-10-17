<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Tandem in 3D

The exact 2D Tandem outline as a solid object: the lead (disc minus bite, with the r10 bite fillets) and the follower extruded with a soft superellipse edge. From the front the silhouette matches the flat mark (IoU 0.9993 at 2048 px). **Not wired into the app or website yet.**

## Use

Hero art, launch screens, social cards, the About window, AR Quick Look. Never in UI chrome, and never under 128 px; below that use the flat mark.

## Parameters

| | |
|---|---|
| depth | lead 132, follower 156 (1024-master units); the follower's front sits 34 ahead of the lead's |
| edge | rounded, 46% of depth (61 / 72), superellipse profile n = 2.5 |
| finish | satin PBR, roughness 0.36, metalness 0.04, in `#3B1FD1` / `#14C79A` (Night `#6D55FF` / `#2FE0B2`) |
| light | procedural studio cube map, spot key, grazing fill; soft drop shadow plus halo |

## Files

| Path | What |
|---|---|
| `usdz/mark-3d.usdz`, `mark-3d-dark.usdz` | the model for SceneKit, RealityKit and AR Quick Look; nodes `lead` and `follower`, 20 cm wide, waterline on y = 0, UsdPreviewSurface materials, passes `usdchecker` |
| `stills/{front,threeq,hero}-{light,dark}.png` | 2048 px, transparent, soft shadow baked in; light = Day colours, dark = Night colours |
| `icons/icon-3d-light.png`, `icon-3d-dark.png` | 1024 app-icon renders, mark at 62% of the 824 tile |
| `video/turntable-light.mp4`, `turntable-dark.mp4` | 4 s seamless ±30° sway, 1080², 30 fps, H.264, on `#F5F5F7` / `#1C1C1E` |
| `video/turntable-alpha.mov` | the same in HEVC with alpha, for compositing over anything |
| `src/Tandem3D.swift` | reusable scene builder: `TandemSpec` (depth, chamfer, finish, light/dark, shadow) and `TandemCamera` (yaw, pitch, lens, framing) |
| `src/Render.swift`, `Video.swift`, `main.swift` | offscreen renderer, AVAssetWriter/ImageIO encoders and the command-line driver |
| `proof.png` | review sheet: 3D next to the flat mark, silhouette overlays, icons, turntable frames |

## Rebuild

From this folder (macOS 26, Xcode command-line tools):

```sh
swiftc -O -swift-version 5 src/*.swift -o build/mark3d
build/mark3d stills      # stills/ (also on-ground and no-shadow variants)
build/mark3d icons       # icons/
build/mark3d usdz        # usdz/ (then usdcat/usdzip, see main.swift)
build/mark3d turntable 1080
```

The driver writes `stills/front-transparent.png` and similar names; the committed files were renamed to `front-light.png` / `front-dark.png`. `strip`, `alphacheck` and `usdzcheck` are development checks and use APIs deprecated since macOS 13–15.

Quick Look lights the USDZ with its own environment, so it looks slightly different from these renders. SceneKit's built-in chamfer drops on the lead's tight bite points, so the extrusion is a custom ring-offset mesh.
