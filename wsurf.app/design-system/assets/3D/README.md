# 3D

Renders of the 3D Tandem mark (SceneKit, satin PBR, soft studio light), 1200px PNGs.

- `mark-front-light.png`, `mark-front-dark.png`: front view on `#F5F5F7` / `#1C1C1E`; the silhouette matches the flat mark.
- `mark-threeq-light.png`, `mark-threeq-dark.png`: three-quarter view (−25° yaw, +10° pitch).
- `mark-hero-light.png`, `mark-hero-dark.png`: low hero angle (+28° yaw, −14° pitch, 36° lens).
- `icon-3d-light.png`, `icon-3d-dark.png`: 3D app icon studies, mark at 62% of the tile.
- `turntable-light.mp4`, `turntable-dark.mp4`: 4-second seamless ±30° sway, 1080×1080, H.264.

The repository's `branding/tandem/3d/` folder also holds 2048px transparent stills, an HEVC-with-alpha turntable (`turntable-alpha.mov`), `mark-3d.usdz` / `mark-3d-dark.usdz`, and the reusable `src/Tandem3D.swift` scene builder.
