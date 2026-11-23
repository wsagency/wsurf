# Tokens

Every token of the system, a section per group: Surfaces — 1 token; Text — 1 token; Fills and status backgrounds — 5 tokens; Palette ramps and brand — 52 tokens; Type styles, families, font files; Spacing — 13 tokens; Radius — 8 tokens; Shadow — 2 tokens; Opacity — 7 tokens.

`tokens.css` follows the system appearance on `:root` by default (`prefers-color-scheme: dark` switches `:root` to Night tokens). Set `data-theme="light"` or `data-theme="dark"` on `<html>` or any nested container to lock a region to Day or Night regardless of the OS appearance.

## Color · Surfaces

### Use

```css
/* in a page’s CSS, in the light theme (Day): link /design-system/tokens.css and keep the fallback from the table below */
color: var(--surface, #ffffff);
/* in the dark theme (Night): link /design-system/tokens.css, put data-theme="dark" on the root or wrapper element, and take each fallback from the dark column */
color: var(--surface, #2c2c2e);
/* on a slide, in a chart’s options, or anywhere else var() cannot go, and in an SVG attribute such as fill, which not every browser reads var() in: the value alone, from the column of the theme it is in */
color: #ffffff;
```

### Tokens (1)

| token | light | dark | usage |
| --- | --- | --- | --- |
| `--surface` | #ffffff | #2c2c2e | Cards, panels, inputs and secondary buttons on bg. |

## Color · Text

### Use

```css
/* in a page’s CSS, in the light theme (Day): link /design-system/tokens.css and keep the fallback from the table below */
color: var(--ink, #1d1d1f);
/* in the dark theme (Night): link /design-system/tokens.css, put data-theme="dark" on the root or wrapper element, and take each fallback from the dark column */
color: var(--ink, #f5f5f7);
/* on a slide, in a chart’s options, or anywhere else var() cannot go, and in an SVG attribute such as fill, which not every browser reads var() in: the value alone, from the column of the theme it is in */
color: #1d1d1f;
```

### Tokens (1)

| token | light | dark | usage |
| --- | --- | --- | --- |
| `--ink` | #1d1d1f | #f5f5f7 | Primary text on bg, surface and sidebar. Also the lockup wordmark ink (the Flux Mono inks). |

## Color · Fills and status backgrounds

### Use

```css
/* in a page’s CSS, in the light theme (Day): link /design-system/tokens.css and keep the fallback from the table below */
color: var(--accent-hover, #2e17a8);
/* in the dark theme (Night): link /design-system/tokens.css, put data-theme="dark" on the root or wrapper element, and take each fallback from the dark column */
color: var(--accent-hover, #5a40f0);
/* on a slide, in a chart’s options, or anywhere else var() cannot go, and in an SVG attribute such as fill, which not every browser reads var() in: the value alone, from the column of the theme it is in */
color: #2e17a8;
```

### Tokens (5)

| token | light | dark | usage |
| --- | --- | --- | --- |
| `--on-accent` | #ffffff | #ffffff | Text and icons on an accent fill (9.1:1 by day, 4.8:1 by night). |
| `--accent-text` | #3b1fd1 | #b49cff | Links, eyebrows and highlighted words on bg, surface and sidebar. |
| `--accent-wash` | rgba(59, 31, 209, 0.07) | rgba(180, 156, 255, 0.12) | Tinted panel behind accent-related content, such as the security callout. |
| `--on-assistant` | #1d1d1f | #1c1c1e | Text on an assistant fill. |

**Interaction states** (same roles, suffixed):

| token | light | dark |
| --- | --- | --- |
| `--accent-hover` | #2e17a8 | #5a40f0 |

## Color · Palette ramps and brand

### Use

```css
/* in a page’s CSS, in the light theme (Day): link /design-system/tokens.css and keep the fallback from the table below */
color: var(--bg, #f5f5f7);
/* in the dark theme (Night): link /design-system/tokens.css, put data-theme="dark" on the root or wrapper element, and take each fallback from the dark column */
color: var(--bg, #1c1c1e);
/* on a slide, in a chart’s options, or anywhere else var() cannot go, and in an SVG attribute such as fill, which not every browser reads var() in: the value alone, from the column of the theme it is in */
color: #f5f5f7;
```

### Tokens (52)

| token | light | dark | usage |
| --- | --- | --- | --- |
| `--bg` | #f5f5f7 | #1c1c1e | Page and window background. #F5F5F7 and #1C1C1E are the surfaces the Flux palettes were tuned for. |
| `--sidebar` | #e8e8ed | #111113 | Sidebars and recessed areas such as code blocks. |
| `--line` | #d2d2d7 | #3a3a3c | Hairline borders and dividers. Decorative only. |
| `--line-strong` | #86868b | #7c7c80 | Borders that identify a control (inputs, toggles). At least 3:1 on bg and surface. |
| `--muted` | #636366 | #98989d | Secondary text on bg, surface and sidebar. |
| `--accent` | #3b1fd1 | #6d55ff | The one action colour: primary button fill, selection, active nav. The colour of the Tandem lead disc. By night the fill is 3.6:1 on bg but 2.9:1 on surface (Flux value kept); there the white label carries the button. |
| `--focus` | #3b1fd1 | #b49cff | Solid 2px focus ring with a 2px offset. At least 6:1 on every surface. |
| `--assistant` | #14c79a | #2fe0b2 | The colour of the Tandem follower disc, used for the assistant's own activity: thinking, reading or acting on a tab, speaking. Fills and dots only; by day it is 2:1 on bg, so pair it with a label. |
| `--assistant-text` | #08745a | #2fe0b2 | Assistant labels and status text on bg, surface and sidebar. |
| `--assistant-wash` | rgba(20, 199, 154, 0.14) | rgba(47, 224, 178, 0.14) | Background of an assistant activity row or badge. |
| `--mark-lead` | #3b1fd1 | #6d55ff | The Tandem mark's lead disc (you): #3B1FD1 by day, #6D55FF by night. Only for the mark and the app icon. |
| `--mark-follower` | #14c79a | #2fe0b2 | The Tandem mark's follower disc (the assistant): #14C79A by day, #2FE0B2 by night. The same mint as `assistant`. |
| `--success` | #1e7b34 | #30d158 | Success text and icons on bg and surface. Always with a word or icon, because it sits near the assistant mint. |
| `--warning` | #b5540d | #e6a363 | Warning text and icons on bg and surface (4.1:1 on sidebar by day). |
| `--danger` | #d70015 | #ff6961 | Destructive actions and errors on bg and surface. Always with a word or icon. |
| `--flux-track-deep` | #3b1fd1 | #6d55ff | Flux palette (the brand pair carried into Tandem: lead = track deep, follower = knob start), track gradient start; the silhouette, at least 3:1 on its surface. The only colour palette for the website, README and favicons. |
| `--flux-track-bright` | #8a63ff | #b49cff | Flux palette: Track gradient end. |
| `--flux-knob-start` | #14c79a | #2fe0b2 | Flux palette: Knob gradient start; defines the knob edge against the ring. |
| `--flux-knob-end` | #d9fff0 | #effff9 | Flux palette: Knob gradient end; sits near the surface on purpose. |
| `--ember-track-deep` | #a3153a | #e0476a | Ember palette, track gradient start; the silhouette, at least 3:1 on its surface. Momentum. From the superseded Flux palette draft (reference only; current Dock icon finishes are Default/Anodized, Steel, Copper, Light, Dark, and Mono). |
| `--ember-track-bright` | #f0502f | #ff8a5b | Ember palette: Track gradient end. |
| `--ember-knob-start` | #ffb02e | #ffc24d | Ember palette: Knob gradient start; defines the knob edge against the ring. |
| `--ember-knob-end` | #fff1cc | #fff6dc | Ember palette: Knob gradient end; sits near the surface on purpose. |
| `--tide-track-deep` | #0b3a8c | #4c8dff | Tide palette, track gradient start; the silhouette, at least 3:1 on its surface. Calm, ocean heritage. From the superseded Flux palette draft (reference only; current Dock icon finishes are Default/Anodized, Steel, Copper, Light, Dark, and Mono). |
| `--tide-track-bright` | #3c8cff | #8dbfff | Tide palette: Track gradient end. |
| `--tide-knob-start` | #00b8e6 | #4fd8ff | Tide palette: Knob gradient start; defines the knob edge against the ring. |
| `--tide-knob-end` | #eafbff | #f2fdff | Tide palette: Knob gradient end; sits near the surface on purpose. |
| `--grove-track-deep` | #0e4d3a | #2fae80 | Grove palette, track gradient start; the silhouette, at least 3:1 on its surface. Growth. From the superseded Flux palette draft (reference only; current Dock icon finishes are Default/Anodized, Steel, Copper, Light, Dark, and Mono). |
| `--grove-track-bright` | #2e9e6b | #6fd6a4 | Grove palette: Track gradient end. |
| `--grove-knob-start` | #8fcb1f | #b6e64a | Grove palette: Knob gradient start; defines the knob edge against the ring. |
| `--grove-knob-end` | #f7ffd9 | #fbffe6 | Grove palette: Knob gradient end; sits near the surface on purpose. |
| `--bloom-track-deep` | #8f1480 | #d43fc0 | Bloom palette, track gradient start; the silhouette, at least 3:1 on its surface. Playful, punchy. From the superseded Flux palette draft (reference only; current Dock icon finishes are Default/Anodized, Steel, Copper, Light, Dark, and Mono). |
| `--bloom-track-bright` | #f5309f | #ff7fc8 | Bloom palette: Track gradient end. |
| `--bloom-knob-start` | #00c2e0 | #2fd6f0 | Bloom palette: Knob gradient start; defines the knob edge against the ring. |
| `--bloom-knob-end` | #e6fcff | #eefdff | Bloom palette: Knob gradient end; sits near the surface on purpose. |
| `--graphite-track-deep` | #1d1f24 | #7f8797 | Graphite palette, track gradient start; the silhouette, at least 3:1 on its surface. Focus, neutral. A two-stop colour gradient, not monochrome. From the superseded Flux palette draft (reference only; current Dock icon finishes are Default/Anodized, Steel, Copper, Light, Dark, and Mono). |
| `--graphite-track-bright` | #5a6170 | #c3c9d4 | Graphite palette: Track gradient end. |
| `--graphite-knob-start` | #9aa3b2 | #d5dae3 | Graphite palette: Knob gradient start; defines the knob edge against the ring. |
| `--graphite-knob-end` | #ffffff | #ffffff | Graphite palette: Knob gradient end; sits near the surface on purpose. |

| ramp | step and value (light, dark) |
| --- | --- |
| `--neutral-*` | 0 #ffffff, 50 #f5f5f7, 100 #e8e8ed, 200 #d2d2d7, 300 #aeaeb2, 400 #86868b, 450 #7c7c80, 500 #636366, 600 #48484a, 700 #3a3a3c, 800 #2c2c2e, 900 #1c1c1e, 950 #111113 |

## Type

Set text in one of the styles below: write its values from the Styles and Families tables, or, on a page that links `/design-system/tokens.css`, prefer its variable, where the Styles table’s CSS column gives one.

### Use

```css
/* any surface: a style’s values from the Styles and Families tables */
font: 700 72px/1.02 -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, "Segoe UI", sans-serif; letter-spacing: -0.04em;
/* a page that links /design-system/tokens.css: prefer the variables, so that a change to tokens.css reaches the page */
font: var(--text-display-xl); letter-spacing: -0.04em;
font-family: var(--font-display);   /* the family alone */
```

### Styles

| style | CSS | size / line, italic, letter spacing | weight | family | usage |
| --- | --- | --- | --- | --- | --- |
| `display-xl` | `.display-xl`, `--text-display-xl` | 72px / 1.02, letter-spacing -0.04em | 700 | `display` | Hero headline on the website, one per page. Scale down with clamp(44px, 6.4vw, 72px). |
| `display` | `.display`, `--text-display` | 44px / 1.1, letter-spacing -0.03em | 700 | `display` | Section headlines (h2). clamp(32px, 4vw, 44px). |
| `heading` | `.heading`, `--text-heading` | 20px / 1.3, letter-spacing -0.015em | 650 | `sans` | Card and sub-section titles (h3). |
| `lede` | `.lede`, `--text-lede` | 19px / 1.6 | 400 | `sans` | Intro paragraph under a hero or section headline, in muted. |
| `body` | `.body`, `--text-body` | 16px / 1.65 | 400 | `sans` | Running text on the website. |
| `small` | `.small`, `--text-small` | 14px / 1.55 | 400 | `sans` | Card copy and secondary paragraphs. |
| `label` | `.label`, `--text-label` | 14px / 1.2 | 600 | `sans` | Buttons, navigation and text links. |
| `eyebrow` | `.eyebrow`, `--text-eyebrow` | 12px / 1.2, letter-spacing 0.12em | 700 | `sans` | Uppercase kicker above a headline, in accent-text. |
| `caption` | `.caption`, `--text-caption` | 12px / 1.5 | 400 | `sans` | Release notes, footers, fine print, in muted. |
| `code` | `.code`, `--text-code` | 14px / 1.9 | 400 | `mono` | Code blocks and commands. |
| `app-title` | `.app-title`, `--text-app-title` | 13px / 1.4 | 500 | `sans` | Theme.Font.title: window and panel titles. |
| `app-row-title` | `.app-row-title`, `--text-app-row-title` | 12.5px / 1.4 | 500 | `sans` | Theme.Font.rowTitle: sidebar section and row titles. |
| `app-row` | `.app-row`, `--text-app-row` | 12.5px / 1.4 | 400 | `sans` | Theme.Font.row: tab and list rows. |
| `app-control` | `.app-control`, `--text-app-control` | 12px / 1.4 | 500 | `sans` | Theme.Font.control: buttons and segmented controls. |
| `app-body` | `.app-body`, `--text-app-body` | 12px / 1.4 | 400 | `sans` | Theme.Font.body: panel text. |
| `app-secondary` | `.app-secondary`, `--text-app-secondary` | 11.5px / 1.4 | 400 | `sans` | Theme.Font.secondary: secondary text, in muted. |
| `app-label` | `.app-label`, `--text-app-label` | 11px / 1.4 | 400 | `sans` | Theme.Font.label: field labels. |
| `app-caption` | `.app-caption`, `--text-app-caption` | 10.5px / 1.4 | 400 | `sans` | Theme.Font.caption: timestamps and hints. |
| `app-mono` | `.app-mono`, `--text-app-mono` | 11.5px / 1.4 | 400 | `mono` | Theme.Font.mono: model ids, URLs, code. |
| `app-mono-caption` | `.app-mono-caption`, `--text-app-mono-caption` | 10.5px / 1.4 | 400 | `mono` | Theme.Font.monoCaption: shortcuts. |
| `app-badge` | `.app-badge`, `--text-app-badge` | 10px / 1.4 | 600 | `sans` | Theme.Font.badge: counters and badges. |
| `app-micro` | `.app-micro`, `--text-app-micro` | 10px / 1.4 | 400 | `sans` | Theme.Font.micro: the smallest UI text. |
| `app-heading` | `.app-heading`, `--text-app-heading` | 15px / 1.4 | 600 | `sans` | Proposed token for the 15pt literals in the app (no token today). |
| `app-title2` | `.app-title2`, `--text-app-title2` | 17px / 1.4 | 600 | `sans` | Proposed token for the 17pt literals (onboarding, settings headers). |
| `app-display` | `.app-display`, `--text-app-display` | 22px / 1.4 | 700 | `sans` | Proposed token for the 21 and 22pt literals (onboarding). |

### Families

| family | CSS variable | stack |
| --- | --- | --- |
| `sans` | `--font-sans` | `-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", sans-serif` |
| `display` | `--font-display` | `-apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, "Segoe UI", sans-serif` |
| `mono` | `--font-mono` | `ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace` |

## Spacing

One 2px-based scale for app and web. The app uses 6, 10 and 14 often, so they stay as half steps. Snap the app's 9px literals to 8 or 10.

### Use

```css
/* any surface: a token’s value from the table below */
padding: 2px;
/* a page that links /design-system/tokens.css: prefer the token’s name, so that a change to tokens.css reaches the page */
padding: var(--space-2);
```

### Tokens (13)

| token | value | usage |
| --- | --- | --- |
| `--space-2` | 2px | Hairline gaps, icon nudges. |
| `--space-4` | 4px | Icon-to-label gap in chips, tight stacks. |
| `--space-6` | 6px | Gap between a mark and the wordmark; compact row padding. |
| `--space-8` | 8px | Gap between nav links and buttons in a row. |
| `--space-10` | 10px | Inner padding of compact controls. |
| `--space-12` | 12px | Default padding in app panels and between grouped controls. |
| `--space-14` | 14px | Row height padding in the sidebar. |
| `--space-16` | 16px | Card gap in grids; minimum page gutter on phones. |
| `--space-24` | 24px | Card padding on phones; gap between a headline and its copy. |
| `--space-32` | 32px | Card and panel padding on desktop. |
| `--space-48` | 48px | Gap between hero columns; large panel padding. |
| `--space-64` | 64px | Section padding on phones. |
| `--space-96` | 96px | Section padding on desktop. |

## Radius

Values from Theme.Radius in the app. In the app, panel, card, control and chip are capped by the window corner radius.

### Use

```css
/* any surface: a token’s value from the table below (--radius-tight: 4px) */
/* a page that links /design-system/tokens.css: prefer var(--radius-tight), so that a change to tokens.css reaches the page */
```

### Tokens (8)

| token | value | usage |
| --- | --- | --- |
| `--radius-tight` | 4px | Theme.Radius.tight: focus outlines, tiny swatches, inline code. |
| `--radius-chip` | 8px | Theme.Radius.chip: chips, badges, tab favicons. |
| `--radius-control` | 10px | Theme.Radius.control: app buttons, inputs, hover backgrounds; website inputs. |
| `--radius-card` | 12px | Theme.Radius.card: cards in the app; code blocks on the website. |
| `--radius-panel` | 14px | Theme.Radius.panel: sidebars and floating panels. |
| `--radius-popover` | 16px | Theme.Radius.popover: popovers and menus; feature cards on the website. |
| `--radius-stage` | 24px | Website only: large callout panels and hero artwork. |
| `--radius-full` | 999px | Stadium shapes that echo the Flux track: website buttons, the assistant badge, status pills. |

## Shadow

The app's most common shadow and the command palette shadow, softened for Day.

### Use

```css
/* any surface: a token’s value from the table below (--shadow-raised: 0 4px 12px rgba(23, 23, 28, 0.10) in the light theme; the table gives its value in the others) */
/* a page that links /design-system/tokens.css: prefer var(--shadow-raised), so that a change to tokens.css, or a change of theme, reaches the page */
```

### Tokens (2)

| token | value | usage |
| --- | --- | --- |
| `--shadow-raised` | 0 4px 12px rgba(23, 23, 28, 0.10) · dark: 0 5px 11px rgba(0, 0, 0, 0.30) | Popovers, menus and hovered cards. |
| `--shadow-overlay` | 0 18px 44px rgba(23, 23, 28, 0.18) · dark: 0 18px 44px rgba(0, 0, 0, 0.40) | Command palette and modal sheets. |

## Opacity

Theme.Wash: the primary text colour at these opacities, used for chrome states.

### Use

```css
/* any surface: a token’s value from the table below (--wash-faint: 0.04) */
/* a page that links /design-system/tokens.css: prefer var(--wash-faint), so that a change to tokens.css reaches the page */
```

### Tokens (7)

| token | value | usage |
| --- | --- | --- |
| `--wash-faint` | 0.04 | Faint fills behind grouped rows. |
| `--wash-hairline` | 0.06 | Hairline separators drawn with ink. |
| `--wash-hover` | 0.08 | Hover background of rows and buttons. |
| `--wash-selection` | 0.12 | Selected row background. |
| `--wash-strong` | 0.16 | Pressed state; strong fills. |
| `--wash-emphasis` | 0.30 | Disabled ink; emphasised strokes. |
| `--wash-scrim` | 0.55 | Scrim behind sheets. |
