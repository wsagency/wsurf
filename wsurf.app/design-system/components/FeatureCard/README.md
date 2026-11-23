# FeatureCard

A bordered surface card with a heading and a short muted paragraph, laid out three across in `ws-feature-grid`.

## When to use
To present a small set of parallel features or facts on wsurf.app. The grid drops to one column under 640px, where card padding shrinks from 32px to 24px.

## Markup
```html
<div class="ws-feature-grid">
  <article class="ws-feature-card">
    <h3 class="heading">A place for every tab</h3>
    <p class="small">Organize tabs with folders and pins. Use split view, separate profiles, and private browsing. Unload page content without losing the link.</p>
  </article>
  <!-- two more cards -->
</div>
```
The consumer provides the heading level that fits the page outline (usually `h3`) and one or two sentences of copy.

## Do
- Keep titles short and in sentence case; keep copy to two or three lines per column.
- Use three cards, or one per row on narrow screens.

## Don't
- Don't number the cards ("01", "02", "03"): the features are not a sequence.
- Don't make the whole card a link or add hover effects; it is static content.

## Tokens
`surface`, `line`, `ink`, `muted`, `radius-popover`, `space-12`, `space-16`, `space-24`, `space-32`, type `.heading` and `.small`.
