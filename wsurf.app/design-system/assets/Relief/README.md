# Relief

The Tandem pair as a planet and its moon. Procedural only (improved Perlin noise on the sphere, seed 20261017; recipe in `texture-recipe.json` beside this README).

- `relief-earth-moon.mp4`, `relief-clay.mp4`, `relief-topographic.mp4`: 8-second seamless loops, 1080×1080, 30fps. Earth & Moon and Topographic on `#1C1C1E`, Clay on `#F5F5F7`. Each has a `-poster.jpg`.
- `relief-earth-moon-480.gif`: 480px GIF of the Earth & Moon loop.
- `planet_color.png`, `planet_normal.png`, `planet_height.png`, `planet_clouds.png`, `moon_color.png`, `moon_normal.png`, `moon_height.png`: equirectangular 2048×1024 maps for three.js (`map`, `normalMap`, `displacementMap`, a transparent cloud shell) or SceneKit.

The repository's `branding/tandem/relief/` folder also holds 1920×1080 wide stills (pair on the right, room for a headline), 540px loops, the `Real` look, `src/TexGen.swift`, and the `src/TandemPlanets.swift` SceneKit builder for regenerating 1080px / 1920×1080 loops and 16-bit / clay / topographic height maps.
