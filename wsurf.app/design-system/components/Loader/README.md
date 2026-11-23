# Loader

The Tandem loader: the follower circles the lead once every 1.6 seconds and settles into the mark at rest.

## When to use
Wherever WSurf waits: page and panel loads, the assistant starting a task, a model connecting. Use 24px inline with text, 32–48px in empty panels, 64px for a full-window wait. It means "working", so pair it with a short label when the wait is the assistant's ("Reading 2 tabs"); for the assistant's ongoing state use `AssistantBadge` instead.

## Markup
```html
<link rel="stylesheet" href="/design-system/tokens.css">
<link rel="stylesheet" href="/design-system/components/bundle.css">
<span class="tandem-loader tandem-loader--32" role="status">
  <svg viewBox="-672 -672 1344 1344" aria-hidden="true" focusable="false"><!-- copied from preview.html or branding/tandem/loader/web/tandem-loader.html --></svg>
  <span class="tandem-loader__label">Loading</span>
</span>
```
Copy the SVG markup from [`preview.html`](preview.html) (or `branding/tandem/loader/web/tandem-loader.html`) and link `components/bundle.css` (or `assets/Motion/tandem-loader.css` standalone). Give each `<clipPath>` a unique `id` when placing more than one loader on the same page. No script and no inline style are needed, so it passes the website's strict CSP. As an image, use `<picture>` with `branding/tandem/loader/web/tandem-loader-reduced.svg` for `prefers-reduced-motion`, because an SVG in an `<img>` does not see that setting.

## How it works
- The follower rides an ellipse centred 0.22 lead radii above the lead (A 1.40 R, B 0.887 R), shrinking to 0.69 at the back and growing to 1.03 at the front, at constant speed.
- Behind (upper half) the lead hides it. In front (lower half) it carries the mark's gap: a ring in the ground colour cuts the lead, so frame 0 is the static mark. The ring closes to zero at the two crossings, so nothing pops.
- At 24px and below it switches to the small cut automatically.

## Colours
`--wsurf-lead` and `--wsurf-follower` come from `mark-lead` and `mark-follower`. `--wsurf-ground` must equal the surface behind the loader, because it paints the gap: `bg` by default; on a card set `--wsurf-ground: var(--surface)`.

## Do
- Keep one loader per view.
- Set the ground colour on cards and coloured panels.

## Don't
- Don't recolour it, speed it up past 1.2 s per loop, or put it on a photo or gradient (the gap ring needs a flat ground).
- Don't use it for progress you can measure; show a determinate bar instead.

## Other platforms
SwiftUI `TandemLoader` (`assets/Motion/TandemLoader.swift`: `TimelineView` + `Canvas`, honours Reduce Motion, small cut under 24 pt), MP4 and GIF renders in `assets/Motion/`, and HEVC-with-alpha video (`tandem-loader-alpha.mov`) in `branding/tandem/loader/`.

## Tokens
`mark-lead`, `mark-follower`, `bg`, `surface`, `muted`, `space-8`, `space-16`, `space-24`, `radius-popover`, type `.caption`.
