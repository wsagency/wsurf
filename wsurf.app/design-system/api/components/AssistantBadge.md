# AssistantBadge

A small pill in the assistant colour that shows what the assistant is doing right now: thinking, acting on tabs, or waiting for the person.

`WSurf.AssistantBadge` · Assistant

## Use

Pure HTML and CSS (no JavaScript, CSP `style-src 'self'` safe). Link `/design-system/tokens.css` and `/design-system/components/bundle.css`:

```html
<span class="ws-assistant-badge app-control" data-state="thinking" role="status">
  <span class="ws-assistant-dot" aria-hidden="true"></span>Thinking
</span>
```

## Classes and attributes

- `.ws-assistant-badge` with type class `.app-control`
- `.ws-assistant-dot` (`aria-hidden="true"`)
- `data-state="thinking" | "acting" | "paused"` (`thinking` pulses and stops under `prefers-reduced-motion: reduce`; `paused` draws a hollow ring)
- Add `role="status"` when the badge updates live.

## More

- Long-form usage: [`components/AssistantBadge/README.md`](../../components/AssistantBadge/README.md)
- Live preview: [`components/AssistantBadge/preview.html`](../../components/AssistantBadge/preview.html) (`/design-system/components/AssistantBadge/preview.html`)
