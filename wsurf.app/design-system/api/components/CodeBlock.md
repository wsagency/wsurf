# CodeBlock

A recessed monospace block for shell commands, with an optional muted caption underneath.

`WSurf.CodeBlock` · Content

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<figure class="ws-codeblock">
  <pre class="code" tabindex="0" aria-label="Clone the repository and open the Xcode project"><code>git clone https://github.com/wsagency/wsurf.git
cd wsurf
open WSurf.xcodeproj</code></pre>
  <figcaption class="caption">Select the WSurf target and set your team in Signing &amp; Capabilities.</figcaption>
</figure>
```

## Classes and attributes

- `.ws-codeblock`: `<figure>` wrapper
- `pre.code` with `tabindex="0"` and descriptive `aria-label` for keyboard scrolling and visible focus ring
- `figcaption.caption`: optional muted note underneath

## More

- Long-form usage: [`components/CodeBlock/README.md`](../../components/CodeBlock/README.md)
- Live preview: [`components/CodeBlock/preview.html`](../../components/CodeBlock/preview.html) (`/design-system/components/CodeBlock/preview.html`)
