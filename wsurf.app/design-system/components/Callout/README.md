# Callout

A large tinted panel that pairs an eyebrow and display headline on the left with copy and a text link on the right.

## When to use
For one statement the reader must not miss, such as the security and access boundaries ("Browser access. Not a blank check."). Use at most one per page. Under 720px the two columns stack; under 480px the padding drops to 24px.

## Markup
```html
<section class="ws-callout" aria-labelledby="access-title">
  <div>
    <p class="ws-eyebrow eyebrow">Know what you share</p>
    <h2 class="display" id="access-title">Browser access.<br>Not a blank check.</h2>
  </div>
  <div class="ws-callout-copy">
    <p class="body">The assistant asks before purchases, sending, or signing in. …</p>
    <a class="ws-link label" href="https://github.com/wsagency/wsurf/blob/main/SECURITY.md">Read the security boundaries <span aria-hidden="true">↗</span></a>
  </div>
</section>
```
The consumer provides the eyebrow (written in sentence case; CSS uppercases it), the headline, one or two `.body` paragraphs and an optional `ws-link`.

## Do
- Keep the headline to two short lines and the copy factual.
- Point the link at the source of truth (here, SECURITY.md).

## Don't
- Don't put buttons or a second callout inside it.
- Don't use it for assistant status; the `assistant` colours belong to the assistant badge.

## Tokens
`accent-wash`, `line`, `ink`, `accent-text`, `radius-stage`, `space-16`, `space-24`, `space-32`, `space-48`, `space-64`, type `.eyebrow`, `.display` (scaled with clamp(32px, 4vw, 44px)), `.body`, `.label`.
