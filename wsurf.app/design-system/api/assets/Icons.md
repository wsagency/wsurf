# Assets · Icons

13 files under `assets/Icons/`, published directly at `/design-system/assets/Icons/` (and committed under `wsurf.app/design-system/assets/Icons/`). Link or copy these files directly; never approximate or redraw them.

## Use

```html
<link rel="icon" href="/design-system/assets/Icons/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" href="/design-system/assets/Icons/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/design-system/assets/Icons/apple-touch-icon.png">
```

## Usage notes

Flat Tandem app icon sources and website icons. Website favicons and touch icons are live on `wsurf.app/`. The app's shipping bundle icon defaults to the metallic Anodized finish alongside Steel, Copper, and the flat Light, Dark, and Mono Dock finishes (see `../../assets/Dock/README.md` and `WSurf/Settings/DockIcon.swift`).

- `icon-light.svg`, `icon-dark.svg`, `icon-light-1024.png`, `icon-dark-1024.png`: flat app icon previews. Tile 824/1024, radius 185, flat `#FFFFFF` (Day) or `#1C1C1E` (Night), mark at 62% of the tile.
- `layer-lead.svg`, `layer-follower.svg`: Icon Composer layer sources, black fills on the 1024 canvas, mark at 62% centred. `icon.json` matches `branding/tandem/icon/Tandem.icon/icon.json` with per-appearance fills: lead `#3B1FD1` / `#6D55FF`, follower `#14C79A` / `#2FE0B2`. `Tools/make-alternate-icons.sh` renders `Tandem.icon` with `ictool` to produce the flat Light, Dark, and Mono Dock finishes.
- `favicon.svg`: small cut; switches to Night colours under `prefers-color-scheme: dark`. `favicon-mono.svg`: one ink, also switching. Serve as files rather than inlining `<style>` on CSP-strict pages.
- `favicon.ico`: 16, 32, and 48px multi-size ICO in Day colours (an ICO cannot follow `prefers-color-scheme`).
- `apple-touch-icon.png` (180px, opaque, mark 120px on `#FFFFFF`), `icon-192.png`, `icon-512.png` (web manifest, opaque).

## Files

| file | static path |
| --- | --- |
| [assets/Icons/icon-light.svg](../../assets/Icons/icon-light.svg) | `/design-system/assets/Icons/icon-light.svg` |
| [assets/Icons/icon-dark.svg](../../assets/Icons/icon-dark.svg) | `/design-system/assets/Icons/icon-dark.svg` |
| [assets/Icons/icon-light-1024.png](../../assets/Icons/icon-light-1024.png) | `/design-system/assets/Icons/icon-light-1024.png` |
| [assets/Icons/icon-dark-1024.png](../../assets/Icons/icon-dark-1024.png) | `/design-system/assets/Icons/icon-dark-1024.png` |
| [assets/Icons/favicon.svg](../../assets/Icons/favicon.svg) | `/design-system/assets/Icons/favicon.svg` |
| [assets/Icons/favicon-mono.svg](../../assets/Icons/favicon-mono.svg) | `/design-system/assets/Icons/favicon-mono.svg` |
| [assets/Icons/favicon.ico](../../assets/Icons/favicon.ico) | `/design-system/assets/Icons/favicon.ico` |
| [assets/Icons/apple-touch-icon.png](../../assets/Icons/apple-touch-icon.png) | `/design-system/assets/Icons/apple-touch-icon.png` |
| [assets/Icons/icon-192.png](../../assets/Icons/icon-192.png) | `/design-system/assets/Icons/icon-192.png` |
| [assets/Icons/icon-512.png](../../assets/Icons/icon-512.png) | `/design-system/assets/Icons/icon-512.png` |
| [assets/Icons/layer-lead.svg](../../assets/Icons/layer-lead.svg) | `/design-system/assets/Icons/layer-lead.svg` |
| [assets/Icons/layer-follower.svg](../../assets/Icons/layer-follower.svg) | `/design-system/assets/Icons/layer-follower.svg` |
| [assets/Icons/icon.json](../../assets/Icons/icon.json) | `/design-system/assets/Icons/icon.json` |
