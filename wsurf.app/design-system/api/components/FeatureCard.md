# FeatureCard

A bordered surface card with a heading and a short muted paragraph, laid out three across in `ws-feature-grid`.

`WSurf.FeatureCard` · Content

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<div class="ws-feature-grid">
  <article class="ws-feature-card">
    <h3 class="heading">A place for every tab</h3>
    <p class="small">Organize tabs with folders and pins. Use split view, separate profiles, and private browsing. Unload page content without losing the link.</p>
  </article>
</div>
```

## Classes and attributes

- `.ws-feature-grid`: three-column grid on wide viewports, one column under `640px`
- `.ws-feature-card`: static bordered card (`surface`, `line`, `radius-popover`)
- `.heading` on the card heading (`h3`) and `.small` on muted body paragraphs

## More

- Long-form usage: [`components/FeatureCard/README.md`](../../components/FeatureCard/README.md)
- Live preview: [`components/FeatureCard/preview.html`](../../components/FeatureCard/preview.html) (`/design-system/components/FeatureCard/preview.html`)
