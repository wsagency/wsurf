# AssistantBadge

A small pill in the assistant colour that shows what the assistant is doing right now: thinking, acting on tabs, or waiting for the person.

## When to use
Only for the assistant's own activity, in the app chrome or in website illustrations of the app. Three states, set with `data-state`:
- `thinking`: the dot pulses (static under reduced motion).
- `acting`: a solid dot, with a label that names the work, such as "Reading 2 tabs".
- `paused`: a hollow dot, with "Waiting for you" when the assistant needs the person.

## Markup
```html
<span class="ws-assistant-badge app-control" data-state="thinking" role="status">
  <span class="ws-assistant-dot" aria-hidden="true"></span>Thinking
</span>
```
The consumer provides the state and a short label. Add `role="status"` when the badge updates live, so screen readers announce the change.

## Do
- Keep labels to two or three words in sentence case; the text, not the colour, carries the state.
- Show one badge per assistant session.

## Don't
- Don't use the `assistant` colours for anything else: not for links, selection, brand accents or warnings.
- Don't make the badge a button; put actions such as Stop next to it.

## Tokens
`assistant-wash`, `assistant-text` (label and the paused ring), `assistant` (dot), `radius-full`, `space-4`, `space-6`, `space-10`, type `.app-control`.
