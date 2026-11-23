# Button

Link-styled actions for the website: a filled primary button, an outlined secondary button and an underlined text link.

## When to use
- `ws-button--primary`: the one main action in a hero or panel, such as "See the source on GitHub".
- `ws-button--secondary`: the alternative next to it, such as "Build WSurf".
- `ws-link`: an action inside running copy or at the end of a callout, such as "Read the security boundaries".
- Group several with `ws-actions` (a wrapping row with a 12px gap).

These are standard website action controls (`radius-full`). In the native macOS app and Settings, use SwiftUI's native buttons and controls (`radius-control`) instead.

## Markup
```html
<div class="ws-actions">
  <a class="ws-button ws-button--primary label" href="https://github.com/wsagency/wsurf">See the source on GitHub <span aria-hidden="true">↗</span></a>
  <a class="ws-button ws-button--secondary label" href="/#build">Build WSurf</a>
</div>
<a class="ws-link label" href="https://github.com/wsagency/wsurf/blob/main/SECURITY.md">Read the security boundaries <span aria-hidden="true">↗</span></a>
```
Works on `<a>` and `<button>`. Always add the `.label` type class. For links that leave wsurf.app, add a trailing `<span aria-hidden="true">↗</span>`.

## Do
- Keep one primary per group; write labels as short verb phrases in sentence case.
- Keep the 44px minimum height so the target stays tappable.

## Don't
- Don't put the ↗ on links within the site, or let screen readers announce it.
- Don't recolour buttons with the `assistant` colours: they are only for the assistant's own activity.

## Tokens
`accent`, `accent-hover`, `on-accent`, `surface`, `line`, `ink`, `accent-text`, `focus`, `radius-full` (round ends, like the Tandem discs), `space-8`, `space-12`, type `.label`. Hover and colour changes use 0.12s ease-out and are off under reduced motion.
