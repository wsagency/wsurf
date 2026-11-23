# SiteHeader

The website header: the Tandem lockup (mark plus "WSurf" wordmark) on the left and the main navigation on the right.

## When to use
At the top of every wsurf.app page, with the lockup 32px tall (about 146px wide). In the footer use `ws-lockup ws-lockup--footer` (24px tall, about 109px wide). At 480px and below the navigation wraps under the lockup and spreads across the width.

## Markup
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
Paste `assets/Lockup/lockup.svg` verbatim, keeping its `BUSL-1.1` SPDX notice and Inter Display Bold OFL credit comment (see `assets/Lockup/Inter-OFL.txt` and `NOTICE`). It has no width, height or ids, so several copies can share a page; CSS sizes it by height.

`ws-lockup` sets the SVG's two variables from the tokens: `--wsurf-lead` from `mark-lead` and `--wsurf-follower` from `mark-follower`. The wordmark is filled with `currentColor`, which the wrapper sets to `ink` (`#1D1D1F` by day, `#F5F5F7` by night).

## Lockup rules
- Clear space: the follower disc's diameter on every side (about 15px around the 32px header lockup, 12px around the 24px footer lockup). Keep nav links outside it.
- Minimum size: 24px tall. Size by height only so the 4.55:1 proportion holds.

## Do
- Use the lockup as delivered, in its two flat colours, with the wordmark in `ink`.
- Keep nav labels to one or two words.

## Don't
- Don't redraw, stretch, recolour, outline or re-space the lockup, or set the wordmark in live text.
- Don't add more than four nav links.

## Tokens
`ink`, `mark-lead`, `mark-follower`, `accent-text`, `focus`, `radius-tight`, `space-4`, `space-8`, `space-12`, `space-14`, `space-16`, `space-24`, type `.label`.
