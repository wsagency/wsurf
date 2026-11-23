# Callout

A large tinted panel that pairs an eyebrow and display headline on the left with copy and a text link on the right.

`WSurf.Callout` · Content

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<section class="ws-callout" aria-labelledby="access-title">
  <div>
    <p class="ws-eyebrow eyebrow">Know what you share</p>
    <h2 class="display" id="access-title">Browser access.<br>Not a blank check.</h2>
  </div>
  <div class="ws-callout-copy">
    <p class="body">The assistant asks before purchases, sending, or signing in.</p>
    <a class="ws-link label" href="https://github.com/wsagency/wsurf/blob/main/SECURITY.md">Read the security boundaries <span aria-hidden="true">↗</span></a>
  </div>
</section>
```

## Classes and attributes

- `.ws-callout`: two-column grid (`radius-stage`, `accent-wash`), stacks under `720px`
- `.ws-eyebrow.eyebrow`: uppercase kicker in `accent-text`
- `.display`: section headline (`clamp(32px, 4vw, 44px)`)
- `.ws-callout-copy`: prose column with `.body` paragraphs and optional `.ws-link.label`

## More

- Long-form usage: [`components/Callout/README.md`](../../components/Callout/README.md)
- Live preview: [`components/Callout/preview.html`](../../components/Callout/preview.html) (`/design-system/components/Callout/preview.html`)
