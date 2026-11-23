# Assets · Motion

5 files under `assets/Motion/`, published directly at `/design-system/assets/Motion/` (and committed under `wsurf.app/design-system/assets/Motion/`). Link or copy these files directly; never approximate or redraw the loader.

## Use

```html
<img src="/design-system/assets/Motion/tandem-loader.gif" alt="Loading">
```

## Usage notes

The Tandem loader outside the component.

- `tandem-loader.gif`: 256px transparent loop, for places that only take images.
- `tandem-loader-light.mp4`, `tandem-loader-dark.mp4`: 512px, 60fps, three loops, on `#F5F5F7` / `#1C1C1E`.
- `tandem-loader.css`: the web loader's stylesheet, also bundled inside `components/bundle.css`.
- `TandemLoader.swift`: the SwiftUI view (`TimelineView` + `Canvas`, honours Reduce Motion, small cut under 24pt, real path cut so it works on any background).

For CSP-safe web pages, use the `Loader` component's inline SVG markup with `tandem-loader.css` (see [`components/Loader/README.md`](../../components/Loader/README.md) and [`components/Loader/preview.html`](../../components/Loader/preview.html)). Standalone animated SVGs (`web/tandem-loader.svg`, `web/tandem-loader-reduced.svg`) and an HEVC-with-alpha `.mov` (`video/tandem-loader-alpha.mov`) also live in `branding/tandem/loader/` in the repository.

## Files

| file | static path |
| --- | --- |
| [assets/Motion/tandem-loader.gif](../../assets/Motion/tandem-loader.gif) | `/design-system/assets/Motion/tandem-loader.gif` |
| [assets/Motion/tandem-loader-light.mp4](../../assets/Motion/tandem-loader-light.mp4) | `/design-system/assets/Motion/tandem-loader-light.mp4` |
| [assets/Motion/tandem-loader-dark.mp4](../../assets/Motion/tandem-loader-dark.mp4) | `/design-system/assets/Motion/tandem-loader-dark.mp4` |
| [assets/Motion/tandem-loader.css](../../assets/Motion/tandem-loader.css) | `/design-system/assets/Motion/tandem-loader.css` |
| [assets/Motion/TandemLoader.swift](../../assets/Motion/TandemLoader.swift) | `/design-system/assets/Motion/TandemLoader.swift` |
