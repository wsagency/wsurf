# SiteHeader

The website header: the Tandem lockup (mark plus "WSurf" wordmark) on the left and the main navigation on the right.

`WSurf.SiteHeader` · Navigation

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<header class="ws-site-header">
  <a class="ws-lockup" href="/" aria-label="WSurf home"><!-- assets/Lockup/lockup.svg, verbatim --></a>
  <nav class="ws-nav" aria-label="Main navigation">
    <a class="label" href="/#features">Features</a>
    <a class="label" href="/changelog/">Changelog</a>
    <a class="label" href="/#build">Build</a>
    <a class="label" href="https://github.com/wsagency/wsurf">GitHub <span aria-hidden="true">↗</span></a>
  </nav>
</header>
```

## Classes and attributes

- `.ws-site-header`: responsive header bar; wraps nav under lockup at `<= 480px`
- `.ws-lockup`: maps `--wsurf-lead` / `--wsurf-follower` / `color: var(--ink)` and sizes the inline SVG to `32px` tall (`min-height: 44px`)
- `.ws-lockup--footer`: `24px` tall footer variant
- `.ws-nav` with `.label` links (`min-height: 44px`; keep at most four links)

## More

- Long-form usage: [`components/SiteHeader/README.md`](../../components/SiteHeader/README.md)
- Live preview: [`components/SiteHeader/preview.html`](../../components/SiteHeader/preview.html) (`/design-system/components/SiteHeader/preview.html`)
- Lockup artwork and licence: [`assets/Lockup/README.md`](../../assets/Lockup/README.md)
