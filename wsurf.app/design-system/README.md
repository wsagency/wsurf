# WSurf design system

The public reference for WSurf’s identity, macOS interface and website. Browse [the gallery](index.html), read the [AI guide](AI.md), or resolve artwork and examples through the [manifest](manifest.json). The [maintainer workflow](Adoption.md) lists the canonical source for each part.

## Identity

Tandem is a large violet disc for the person and a smaller mint disc for the assistant, riding in a cutout on the same waterline. The master is drawn on a 1024-unit square. The lead disc has radius 348.3. The follower radius is 0.48 of the lead’s, with its center 34° below horizontal and 0.93 lead radii from the lead’s center. The gap is 56 units. Use the supplied vector to preserve the joins and optical centering.

- Use the master at 32 px and above and the small cut at 24 px and below. Leave the follower’s diameter of clear space around the mark or lockup. Platform icons use their own safe areas. [Mark artwork](assets/Mark/README.md)
- Use the outlined Inter Display Bold wordmark and lockup. The mark is 1.22 times the wordmark’s cap height. The complete lockup is 4.55:1 and has a minimum height of 24 px. [Lockup artwork](assets/Lockup/README.md) · [Wordmark license](assets/Lockup/Inter-OFL.txt)
- Use the single-ink version on one-color surfaces. Flux and the legacy waves are earlier design studies. [Mono](assets/Mono/README.md) · [Flux](assets/Flux/README.md) · [Legacy](assets/Legacy/README.md)
- Anodized is the bundle artwork. Settings → Appearance → Dock icon offers Default, Anodized, Steel, Copper, Light, Dark and Mono. Default follows the Mac’s icon style. The six fixed finishes use their catalog rendition while WSurf runs. [Dock finishes](assets/Dock/README.md) · [Website icons](assets/Icons/README.md)

## Color, type and layout

| Role | Day | Night |
| --- | --- | --- |
| Lead disc | `#3B1FD1` | `#6D55FF` |
| Follower disc | `#14C79A` | `#2FE0B2` |
| Page | `#F5F5F7` | `#1C1C1E` |
| Primary text | `#1D1D1F` | `#F5F5F7` |

Use `--accent` for a primary action and `--accent-text` for a link. Mint fills, labels and washes identify assistant activity. Pair status colors with text or a symbol. Native app accents follow the chosen theme and the Mac’s settings.

Use the system display and text fonts for headings and prose and the system monospace font for commands. Keep headlines tightly set and running text near 65 characters per line. The exported type scale includes web and app styles. The native theme owns actual macOS sizes. Use the space and radius tokens for spacing, cards and popovers. Reserve shadows for floating surfaces. A nested radius follows the outer radius minus the inset. [JSON values](tokens.json) · [CSS tokens](tokens.css) · [Complete token reference](api/tokens.md)

## Components and accessibility

The web components are HTML and CSS. Link `tokens.css`, then `components/bundle.css`. Each preview is a standalone document you can inspect or copy. The machine-readable list includes button, assistant badge, callout, code block, feature card, loader, site header and cover. Use the existing theme and Settings primitives for native macOS work. [Previews](index.html#components) · [Source and native guidance](AI.md)

Give every actionable control a visible keyboard focus indicator. Status should make sense without color. Let a visitor start and pause a film, keep posters readable before playback and honor reduced motion. Static brand artwork is appropriate while idle. The 1.6-second Tandem loader signifies work in progress. The illustrated Shared Space and Micro walkthroughs have local MP4 and poster paths under `walkthroughs` in the manifest. [Motion](assets/Motion/README.md) · [Satin renders](assets/3D/README.md) · [Relief studies](assets/Relief/README.md)

## Product voice

The homepage uses “Fully private. Fully yours.” Describe the choice that gives it meaning. A person can use a local model, grant an external assistant access to a page, or choose which WSurf data to sync through iCloud. A chosen external AI receives the request and included content. Name the real control, describe one action at a time and follow the current app’s capitalization.

Use stage data for product screenshots. Label illustrated walkthroughs, show which Mac or window changes, and describe sync as delivery through iCloud. Memory features can be demonstrated by unloading and reopening a tab. Publish speed comparisons only with reproducible measurements. Public download links require a verified, publicly accessible distribution. [Current product behavior](https://github.com/wsagency/wsurf/blob/main/CHANGELOG.md) · [MCP access model](https://github.com/wsagency/wsurf/blob/main/MCP.md)

WSurf is source-available. The [repository license](https://github.com/wsagency/wsurf/blob/main/LICENSE), [attributions](https://github.com/wsagency/wsurf/blob/main/NOTICE) and [Inter license](assets/Lockup/Inter-OFL.txt) apply to their respective sources.
