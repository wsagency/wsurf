<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Tandem relief

The Tandem pair as a planet (the lead, violet) and its moon (the follower, mint, 0.48 of the planet's radius). In the hero pose the moon sits lower left, in front, with a gap ring, like the mark. Everything is procedural; the only exception is the Real look, which uses NASA imagery (see `real/textures/CREDITS.md`). **Not wired into the app or website yet.**

## Looks

- **Earth & Moon:** violet oceans, lilac continents with relief, a faint cloud shell and a violet atmosphere rim; a mint-grey moon with craters.
- **Clay:** matte unglazed ceramic; continents as raised terraces, deeper craters.
- **Topographic:** glowing contour lines of the height maps on `#1C1C1E`.
- **Real:** NASA Blue Marble Earth and the LROC Moon at the true 0.2727 radius ratio, a satellite cloud shell and a blue atmosphere. Real-world colours — use it where the brand look would be wrong (documentation, science contexts, walls of the agency). Not a brand surface: never as the logo.

Use them for heroes, launch films and backgrounds behind headlines. Never next to the flat mark at the same size, and never as the logo.

## Motion

8.000 s seamless loops at 30 fps: the planet spins once per loop, the moon orbits once, tidally locked, on a 6° inclined orbit, passing in front of and behind the planet. Frame 0 is the hero pose. The Real loop runs 16 s (`LOOPSEC=16`) so the satellite texture reads at a calmer pace; the cloud shell drifts one extra revolution per loop.

## Files

| Path | What |
|---|---|
| `textures/planet_{color,normal,height,clouds,roughness}.png`, `moon_{color,normal,height}.png` | equirectangular 2048×1024 maps: colour sRGB, tangent-space normals (OpenGL, G up), 8-bit height (planet 0.5 = sea level), cloud alpha = density, row 0 = north pole, u 0…1 = longitude −180…180°. For three.js `map`, `normalMap`, `displacementMap` and a transparent cloud shell, or SceneKit |
| `textures/recipe.json` | the generation recipe: seed 20261017, improved Perlin noise on the sphere, octaves, sea level, crater cells |
| `video/{earth-moon,clay,topographic}-540.mp4` | the three loops at 540², H.264 (the 1080² and 1920×1080 masters are 3–7 MB each and stay out of the repository; rebuild them below) |
| `stills/{earth-moon,clay,topographic}-hero.jpg` | 1200 px hero stills |
| `stills/earth-moon-wide-dark.png`, `clay-wide-light.png`, `topographic-wide-dark.png` | 1920×1080 with the pair on the right and room for a headline on the left |
| `real/textures/{earth_color,earth_clouds,moon_color}.*`, `real/textures/CREDITS.md` | Real look: NASA surface maps and the cloud shell, with upstream credits |
| `video/real-540.mp4` | the Real loop at 540², 16 s |
| `stills/real_hero_2048_{clear,light,dark}.png`, `real_wide_1920x1080_{light,dark}.png` | Real look stills |
| `src/TandemPlanets.swift` | reusable SceneKit scene builder: `TandemVariant` and `TandemParams` (spin and orbit per loop, inclination, axial tilt, light/dark, gap) |
| `src/TexGen.swift` | texture generator (deterministic: a rerun gives identical files) |
| `src/Render.swift`, `src/Outputs.swift` | stills, loops (AVAssetWriter), GIF |
| `proof.jpg` | review sheet: stills, filmstrips and texture maps |

## Rebuild

From this folder:

```sh
swiftc -O -swift-version 5 src/TexGen.swift -o build/texgen
swiftc -O -swift-version 5 -parse-as-library src/TandemPlanets.swift src/Render.swift src/Outputs.swift -o build/render
build/texgen textures         # the full set, including the clay, topo and 16-bit maps not committed here
build/render stills           # stills/
build/render loops            # loops/: 1080² and 1920×1080 MP4s and a 480 px GIF
ONLY=real build/render stills                                  # Real stills only
LOOPSEC=16 LOOPSIZES=540x540 LOOPDIR=video build/render loops real   # the committed Real loop
```

## Known limits

- Clouds turn with the surface, because an exact 8 s loop needs whole-number cloud drift.
- Shadow mapping is off (SceneKit gives a hard-edged wedge), so the moon casts no shadow.
- Earth land reads slightly greyish-lilac; on a light ground the limb is a little jagged and the atmosphere faint.
- Topographic has no light-ground version.
