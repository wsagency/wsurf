# Icons

Flat Tandem app icon sources and website icons. Website favicons and touch icons are live on `wsurf.app/`. The app's shipping bundle icon defaults to the metallic Anodized finish alongside Steel, Copper, and the flat Light, Dark, and Mono Dock finishes (see `../Dock/README.md` and `WSurf/Settings/DockIcon.swift`).

- `icon-light.svg`, `icon-dark.svg`, `icon-light-1024.png`, `icon-dark-1024.png`: flat app icon previews. Tile 824/1024, radius 185, flat `#FFFFFF` (Day) or `#1C1C1E` (Night), mark at 62% of the tile.
- `layer-lead.svg`, `layer-follower.svg`: Icon Composer layer sources, black fills on the 1024 canvas, mark at 62% centred. `icon.json` (beside this README) matches `branding/tandem/icon/Tandem.icon/icon.json` with per-appearance fills: lead `#3B1FD1` / `#6D55FF`, follower `#14C79A` / `#2FE0B2`. `Tools/make-alternate-icons.sh` renders `Tandem.icon` with `ictool` to produce the flat Light, Dark, and Mono Dock finishes.
- `favicon.svg`: small cut; switches to Night colours under `prefers-color-scheme: dark`. `favicon-mono.svg`: one ink, also switching. Serve as files rather than inlining `<style>` on CSP-strict pages.
- `favicon.ico`: 16, 32, and 48px multi-size ICO in Day colours (an ICO cannot follow `prefers-color-scheme`).
- `apple-touch-icon.png` (180px, opaque, mark 120px on `#FFFFFF`), `icon-192.png`, `icon-512.png` (web manifest, opaque).
