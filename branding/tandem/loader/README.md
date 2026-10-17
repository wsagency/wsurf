<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Tandem loader

The follower orbits the lead once every 1.6 s on a tilted path: behind the lead in the upper half, in front in the lower half, where it carries the mark's gap as a ring of the ground colour cutting the lead. Frame 0 is the static mark. **Not wired into the app or website yet.**

## Motion

| | full cut (> 24 px) | small cut (≤ 24 px) |
|---|---|---|
| loop | 1.6 s, constant angular speed, clockwise, seamless | same |
| orbit ellipse (lead radii) | A 1.40, B 0.887, centre 0.22 above the lead centre | A 1.30, B 0.825 |
| follower scale | 0.69 behind, 0.86 at the crossings, 1.03 at the front | same |
| gap ring | 56 × scale, closing to 0 at the crossings so nothing pops | 100 × scale |

Reduced motion: no orbit; the static mark with the follower fading 100% → 60%.

## Files

| Path | What |
|---|---|
| `web/tandem-loader.css` | pure CSS keyframes, no script, no inline style (passes the site's CSP). Colours `--wsurf-lead`, `--wsurf-follower`, `--wsurf-ground` (the surface behind it, which paints the gap); sizes `.tandem-loader--16` … `--64`; the small cut switches on automatically at ≤ 24 px |
| `web/tandem-loader.html` | the inline markup (`role="status"` plus hidden "Loading") at five sizes; copy from here |
| `web/tandem-loader.svg` | self-contained animated SVG for `<img>`; pair it with `tandem-loader-reduced.svg` in a `<picture>` for reduced motion, because an `<img>` SVG does not see that setting |
| `app/TandemLoader.swift` | SwiftUI view (`TimelineView` + `Canvas`), real path cut so it works on any background, honours Reduce Motion, small cut under 24 pt, `#Preview` included |
| `video/tandem-loader-light.mp4`, `-dark.mp4` | 512², 60 fps, three loops, H.264 |
| `video/tandem-loader.gif` | 256², transparent, 80 frames |
| `video/tandem-loader-alpha.mov` | HEVC with alpha |
| `src/model.py` | the orbit model, the single reference for every output |
| `src/gen_web.py` | writes `web/` from the model |
| `src/harness.swift`, `src/build_media.sh` | render frames from the SwiftUI view and encode the videos (needs ffmpeg) |
| `proof.png` | filmstrips, all sizes on both grounds, frame 0 against the static mark |

## Rebuild

```sh
python3 src/gen_web.py        # web/
zsh src/build_media.sh        # video/, via build/harness
```

## Known limits

- The orbit is wide, so the lead fills about 55% of the box; at 16 px the bite is only a hint.
- At 24 px the small cut shows a roughly 1 px lens pop at the crossings.
- `--wsurf-ground` must equal the surface behind the loader, or the gap shows the wrong colour. The SwiftUI view cuts a real hole and has no such limit.
- Checked in Chrome; Safari and Firefox are untested for the container query inside an SVG image.
