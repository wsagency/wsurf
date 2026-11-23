# Button

Standard website action controls: a filled primary button, an outlined secondary button, and an underlined text link. (In the native macOS app, use SwiftUI controls instead.)

`WSurf.Button` · Actions

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<div class="ws-actions">
  <a class="ws-button ws-button--primary label" href="https://github.com/wsagency/wsurf">See the source on GitHub <span aria-hidden="true">↗</span></a>
  <a class="ws-button ws-button--secondary label" href="/#build">Build WSurf</a>
</div>
<a class="ws-link label" href="https://github.com/wsagency/wsurf/blob/main/SECURITY.md">Read the security boundaries <span aria-hidden="true">↗</span></a>
```

## Classes and attributes

- `.ws-actions`: wrapping action row (`gap: var(--space-12)`)
- `.ws-button.ws-button--primary.label` / `.ws-button.ws-button--secondary.label`: works on `<a>` and `<button>` (`min-height: 44px`, `radius-full`)
- `.ws-link.label`: underlined text link (`min-height: 44px`)
- Append `<span aria-hidden="true">↗</span>` on links that leave `wsurf.app`.

## More

- Long-form usage: [`components/Button/README.md`](../../components/Button/README.md)
- Live preview: [`components/Button/preview.html`](../../components/Button/preview.html) (`/design-system/components/Button/preview.html`)
