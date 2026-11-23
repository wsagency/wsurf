# Motion

The Tandem loader outside the component.

- `tandem-loader.gif`: 256px transparent loop, for places that only take images.
- `tandem-loader-light.mp4`, `tandem-loader-dark.mp4`: 512px, 60fps, three loops, on `#F5F5F7` / `#1C1C1E`.
- `tandem-loader.css` (beside this README): the web loader's stylesheet, also bundled inside `components/bundle.css`.
- `TandemLoader.swift` (beside this README): the SwiftUI view (`TimelineView` + `Canvas`, honours Reduce Motion, small cut under 24pt, real path cut so it works on any background).

For CSP-safe web pages, use the `Loader` component's inline SVG markup with `tandem-loader.css` (see `../../components/Loader/README.md` and `../../components/Loader/preview.html`). Standalone animated SVGs (`web/tandem-loader.svg`, `web/tandem-loader-reduced.svg`) and an HEVC-with-alpha `.mov` (`video/tandem-loader-alpha.mov`) also live in `branding/tandem/loader/` in the repository.
