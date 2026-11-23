# Loader

The Tandem loader: the follower circles the lead once every 1.6 seconds and settles into the mark at rest.

`WSurf.Loader` · Feedback

## Use

Pure HTML and CSS (no JavaScript, no inline styles, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css` (which bundles `assets/Motion/tandem-loader.css`):

```html
<span class="tandem-loader tandem-loader--32" role="status">
  <svg viewBox="-672 -672 1344 1344" aria-hidden="true" focusable="false"><!-- copied from components/Loader/preview.html --></svg>
  <span class="tandem-loader__label">Loading</span>
</span>
```

## Classes and custom properties

- `.tandem-loader` with size modifier `.tandem-loader--16 | --24 | --32 | --48 | --64` (or `--tandem-loader-size`)
- Automatic small cut at `<= 24px` via CSS container query (force with `.tandem-loader--small` / `.tandem-loader--full`)
- `--wsurf-lead`, `--wsurf-follower`, `--wsurf-ground`: mapped automatically from `--mark-lead`, `--mark-follower`, `--bg`; override `--wsurf-ground: var(--surface)` on cards
- `--tandem-loader-duration` (default `1.6s`, never faster than `1.2s`); honours `prefers-reduced-motion: reduce`
- Use unique `<clipPath>` IDs when rendering multiple loaders on one page.

## More

- Long-form usage: [`components/Loader/README.md`](../../components/Loader/README.md)
- Live preview: [`components/Loader/preview.html`](../../components/Loader/preview.html) (`/design-system/components/Loader/preview.html`)
- SwiftUI and video assets: [`assets/Motion/README.md`](../../assets/Motion/README.md)
