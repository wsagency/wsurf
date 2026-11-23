# CodeBlock

A recessed monospace block for shell commands, with an optional muted caption underneath.

## When to use
For commands the reader copies, such as cloning and opening the project. Long lines scroll horizontally inside the block instead of wrapping or widening the page.

## Markup
```html
<figure class="ws-codeblock">
  <pre class="code" tabindex="0" aria-label="Clone the repository and open the Xcode project"><code>git clone https://github.com/wsagency/wsurf.git
cd wsurf
open WSurf.xcodeproj</code></pre>
  <figcaption class="caption">Select the WSurf target and set your team in Signing &amp; Capabilities.</figcaption>
</figure>
```
The consumer provides the commands (escaped HTML), an `aria-label` describing them, and an optional `figcaption`. Keep `tabindex="0"` so keyboard users can scroll the block.

## Do
- Put one command per line, exactly as it should be typed.
- Use the caption for the next step or a caveat.

## Don't
- Don't include prompts (`$`), secrets, tokens or personal paths.
- Don't syntax-colour it with brand or assistant colours.

## Tokens
`sidebar`, `line`, `ink`, `muted`, `focus`, `radius-card`, `space-12`, `space-16`, `space-24`, type `.code` and `.caption`.
