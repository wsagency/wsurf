# Assets · Relief

15 files under `assets/Relief/`, published directly at `/design-system/assets/Relief/` (and committed under `wsurf.app/design-system/assets/Relief/`). Link or copy these files directly; honour `prefers-reduced-motion` by showing posters when reduced motion is enabled.

## Use

```html
<video controls preload="none" playsinline poster="/design-system/assets/Relief/relief-earth-moon-poster.jpg">
  <source src="/design-system/assets/Relief/relief-earth-moon.mp4" type="video/mp4">
</video>
```

## Usage notes

The Tandem pair as a planet and its moon. Procedural only (improved Perlin noise on the sphere, seed 20261017; recipe in `texture-recipe.json`).

- `relief-earth-moon.mp4`, `relief-clay.mp4`, `relief-topographic.mp4`: 8-second seamless loops, 1080×1080, 30fps. Earth & Moon and Topographic on `#1C1C1E`, Clay on `#F5F5F7`. Each has a `-poster.jpg`.
- `relief-earth-moon-480.gif`: 480px GIF of the Earth & Moon loop.
- `planet_color.png`, `planet_normal.png`, `planet_height.png`, `planet_clouds.png`, `moon_color.png`, `moon_normal.png`, `moon_height.png`: equirectangular 2048×1024 maps for three.js (`map`, `normalMap`, `displacementMap`, a transparent cloud shell) or SceneKit.

The repository's `branding/tandem/relief/` folder also holds 1920×1080 wide stills (pair on the right, room for a headline), 540px loops, the `Real` look, `src/TexGen.swift`, and the `src/TandemPlanets.swift` SceneKit builder for regenerating 1080px / 1920×1080 loops and 16-bit / clay / topographic height maps.

## Files

| file | static path |
| --- | --- |
| [assets/Relief/relief-earth-moon.mp4](../../assets/Relief/relief-earth-moon.mp4) | `/design-system/assets/Relief/relief-earth-moon.mp4` |
| [assets/Relief/relief-earth-moon-poster.jpg](../../assets/Relief/relief-earth-moon-poster.jpg) | `/design-system/assets/Relief/relief-earth-moon-poster.jpg` |
| [assets/Relief/relief-clay.mp4](../../assets/Relief/relief-clay.mp4) | `/design-system/assets/Relief/relief-clay.mp4` |
| [assets/Relief/relief-clay-poster.jpg](../../assets/Relief/relief-clay-poster.jpg) | `/design-system/assets/Relief/relief-clay-poster.jpg` |
| [assets/Relief/relief-topographic.mp4](../../assets/Relief/relief-topographic.mp4) | `/design-system/assets/Relief/relief-topographic.mp4` |
| [assets/Relief/relief-topographic-poster.jpg](../../assets/Relief/relief-topographic-poster.jpg) | `/design-system/assets/Relief/relief-topographic-poster.jpg` |
| [assets/Relief/relief-earth-moon-480.gif](../../assets/Relief/relief-earth-moon-480.gif) | `/design-system/assets/Relief/relief-earth-moon-480.gif` |
| [assets/Relief/planet_color.png](../../assets/Relief/planet_color.png) | `/design-system/assets/Relief/planet_color.png` |
| [assets/Relief/planet_normal.png](../../assets/Relief/planet_normal.png) | `/design-system/assets/Relief/planet_normal.png` |
| [assets/Relief/planet_height.png](../../assets/Relief/planet_height.png) | `/design-system/assets/Relief/planet_height.png` |
| [assets/Relief/planet_clouds.png](../../assets/Relief/planet_clouds.png) | `/design-system/assets/Relief/planet_clouds.png` |
| [assets/Relief/moon_color.png](../../assets/Relief/moon_color.png) | `/design-system/assets/Relief/moon_color.png` |
| [assets/Relief/moon_normal.png](../../assets/Relief/moon_normal.png) | `/design-system/assets/Relief/moon_normal.png` |
| [assets/Relief/moon_height.png](../../assets/Relief/moon_height.png) | `/design-system/assets/Relief/moon_height.png` |
| [assets/Relief/texture-recipe.json](../../assets/Relief/texture-recipe.json) | `/design-system/assets/Relief/texture-recipe.json` |
