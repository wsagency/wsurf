<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# WSurf brand system: Flux

Status: **DRAFT for written-spec review. Design and candidate art only: nothing here is wired into the app, website, README, DMG or release tooling, and no app code was written.**
Branch `feature/flux-brand-system-20261016`, base `origin/main` 7b99516.
Labels: **EXISTING** = read in the repo or in a rendered file this session; **DESIGN** = proposed; **UNVERIFIED** = not run or not provable from static sources.

Start with [overview.png](overview.png) (one-glance, exact brand colours), then [specimen.png](specimen.png) (full reference) and [palettes.png](palettes.png) (hex + contrast).

## 0. Finished, candidate, not done

| Part | State |
|---|---|
| Identity design: mark, wordmark, lockup, palettes, mono, texture, words, Dock icon contract | DESIGN, specified here |
| `overview`, `specimen`, `palettes` (`.svg` + `.png`) | EXISTING design illustrations. PNGs rendered with the native macOS WebKit view and viewed back. Tiles are drawn approximations, not real macOS icons |
| `assets/`: `mark.svg`, `mark-small.svg`, `lockup.svg`, `wordmark.svg` | EXISTING committed source art. **Canonical source of the geometry** |
| `exports/`: 12 mark, 12 lockup, 7 favicon SVG (6 colour + mono), `favicon.ico`, `mono.ico`, 2 apple-touch PNG, 3 mono SVG, 26 Dock PNG | EXISTING **design candidates**, not placed anywhere, not production exports |
| Production export matrix, app bundle icon, website/README/DMG cutover | **NOT DONE** (section 11) |
| In-app Dock icon picker, settings keys, localisation, tests | **NOT DONE**; section 9 is design only |
| Runtime behaviour of any custom Dock image | **UNVERIFIED** (section 9.4) |

How the candidates were made: a throwaway local script (kept untracked, outside `branding/`) reads the committed `assets/` geometry, outlines "WSurf" from Figtree Bold, writes the SVGs and renders the PNGs. It is **not** a reproducible production pipeline and is not in the repo; the production pipeline belongs to the approved implementation plan and the existing `Tools/` convention.

## 1. Intent

WSurf is a native macOS browser (macOS 26+, Apple silicon): WebKit by default and embedded Chromium per website (README, Website Settings > Browser Engine), a built-in assistant, your own model provider or a local model. **Flux** is the identity idea of *a browser that adapts to you*: a switch whose knob flows into a second shape. One mark, six selectable colour palettes plus a mono option, light and dark sets, smooth or textured finish.

## 2. Words (DESIGN; every claim below is grounded in README.md or wsurf.app/index.html as read in this branch)

- **Primary tagline:** "A browser that adapts to you."
  Alternates: "Your browser, shaped your way." / "One browser. Every way you work." / "Browse your way. Build your way."
  The site's current headline is "Your browser. Your assistant. Your call."; replacing it is an approval item.
- **Descriptor:** "WSurf is an open-source macOS browser with a built-in assistant."
- **Website hero:** headline = primary tagline. Subhead: "An open-source macOS browser with an assistant built in. Choose your look, choose your model, and take over whenever you want." Meta line (unchanged, EXISTING): "For macOS 26+ · Apple silicon".
- **Everyday paragraph:** "Browse the way you already do: tabs with folders and pins, split view, and separate profiles. When you want help, the assistant can search, read websites, and use the tabs you share. Click the page and it stops, so you can carry on yourself."
- **Developer paragraph:** "WSurf is open source under Apache 2.0. Build the current source on macOS 26 or later with Apple silicon and Xcode 26.5 or later. Use your own provider credentials or a local model with Ollama or LM Studio, and switch providers in Settings. Pick WebKit or embedded Chromium for each website."
- **Call to action, today:** primary "See the source on GitHub" (https://github.com/wsagency/wsurf); secondary "Build WSurf" (EXISTING link). Status line (EXISTING, must be re-checked against the live site before reuse): "In development. No verified public signed release yet."
- **Download wording is conditional, not banned.** A "Download WSurf" button (target: the repository's latest-release page) is allowed only after a public signed release is **verified live** (release page reachable anonymously, asset signed and notarised). The existence of a build on the owner's own Macs or in CI is private use, not public distribution, and never justifies a download claim. A release listing query returned no rows when checked here; not authoritative, re-verify before launch.
- **Do not claim** (not evidenced): magic, unlimited, private, secure, fastest, uses less RAM, "no tracking", any benchmark.
- **Voice:** plain, concrete, second person, short sentences, no hype words.
- **Settings copy** (section 9.1): row "Dock icon"; helper "Changes the icon in the Dock while WSurf is running."; reset "Reset Dock icon".

## 3. Mark (geometry EXISTING in `assets/mark.svg`, `assets/mark-small.svg`)

- Master viewBox 1024, drawn bbox x 40-984, y 202-822 (944 x 620, 1.523:1). Two shapes: **track** (evenodd stadium with a pill-with-bridge cut-out) and **knob** (gourd). The gap is *transparent*: the surface shows through as the ring. Never fill it.
- Gradients: track deep to bright along (40,202)->(984,822); knob start to end along (260,512)->(860,512).
- **Small geometry** (`assets/mark-small.svg`, bbox 32-992 x 182-842): heavier ring, wider gap, **flat two-colour** (track deep + knob start), no gradient. Use for every render narrower than 64 px, colour or mono.
- Optical centre: measured alpha centroid of the master render is x 498.8, y 511.5 against bbox centre 512, 512 (1.4% of the width to the left). Centre by bounding box; revisit during the Dock review.
- Clear space **x = 1/4 of the mark width** on all sides, and around the lockup (x taken from the mark width). Minimum: mark 16 px (small geometry), lockup 96 px wide.
- Not allowed: colours outside the palettes, outline strokes, gradients on small geometry, texture below 128 px, stretching, baked drop shadows, filling the ring.

## 4. Wordmark and lockup

- "WSurf" in **Figtree Bold**, converted to outlines (`assets/wordmark.svg`); kerning from the font's GPOS (HarfBuzz), tracking +10/1000 em; ink `currentColor`.
- Lockup (`assets/lockup.svg`): mark scale 0.2 (188.8 x 124), wordmark cap height 0.62 x mark height, gap 0.22 x mark width, caps centred on the mark, viewBox 556.75 x 124. Ink `#1D1D1F` on light, `#F5F5F7` on dark; mono = one ink.
- UI text is the system font (SF); Figtree appears only inside the outlined logo, so no web font is shipped. The tagline in `overview` is specimen text in the system font.

## 5. Palettes (DESIGN)

Each palette = `[track deep, track bright, knob start, knob end]`, a light set (for `#F5F5F7`) and a dark set (for `#1C1C1E`). WCAG 2.x contrast against that surface (also in `palettes.png`).

| Palette (meaning) | Set | track deep | track bright | knob start | knob end |
|---|---|---|---|---|---|
| **Flux** (adaptability, default) | light | `#3B1FD1` 8.38 | `#8A63FF` 3.63 | `#14C79A` 2.00 | `#D9FFF0` 1.01 |
| | dark | `#6D55FF` 3.56 | `#B49CFF` 7.41 | `#2FE0B2` 10.07 | `#EFFFF9` 16.48 |
| **Ember** (momentum) | light | `#A3153A` 7.08 | `#F0502F` 3.27 | `#FFB02E` 1.68 | `#FFF1CC` 1.03 |
| | dark | `#E0476A` 4.28 | `#FF8A5B` 7.32 | `#FFC24D` 10.59 | `#FFF6DC` 15.77 |
| **Tide** (calm, ocean heritage) | light | `#0B3A8C` 9.65 | `#3C8CFF` 3.02 | `#00B8E6` 2.14 | `#EAFBFF` 1.02 |
| | dark | `#4C8DFF` 5.32 | `#8DBFFF` 8.94 | `#4FD8FF` 10.21 | `#F2FDFF` 16.42 |
| **Grove** (growth) | light | `#0E4D3A` 9.01 | `#2E9E6B` 3.10 | `#8FCB1F` 1.80 | `#F7FFD9` 1.05 |
| | dark | `#2FAE80` 6.07 | `#6FD6A4` 9.59 | `#B6E64A` 11.67 | `#FBFFE6` 16.65 |
| **Bloom** (playful, punchy) | light | `#8F1480` 7.48 | `#F5309F` 3.32 | `#00C2E0` 1.97 | `#E6FCFF` 1.02 |
| | dark | `#D43FC0` 4.27 | `#FF7FC8` 7.39 | `#2FD6F0` 9.72 | `#EEFDFF` 16.31 |
| **Graphite** (focus, neutral) | light | `#1D1F24` 15.14 | `#5A6170` 5.71 | `#9AA3B2` 2.34 | `#FFFFFF` 1.09 |
| | dark | `#7F8797` 4.71 | `#C3C9D4` 10.23 | `#D5DAE3` 12.13 | `#FFFFFF` 17.01 |
| **Mono** (one flat ink) | light | ink `#1D1D1F` 15.46 | | | |
| | dark | ink `#F5F5F7` 15.63 | | | |

- The track carries the silhouette: >= 3:1 on its surface. The knob's light end sits near the surface on purpose; the ring and the knob's start colour define its edge. Tide knob start vs track bright is only 1.41:1 (the ring separates them).
- Light-set `track bright` is close to the 3:1 floor: Tide 3.02, Grove 3.10, Ember 3.27, Bloom 3.32, Flux 3.63. Bloom was moved from `#FF3FA8` (2.95) to `#F5309F` (3.32) to clear 3:1: **approval item**.
- **Graphite is a neutral two-stop gradient: colour art, not monochrome.** The monochrome option is **Mono** (one flat ink, no gradient), section 6.
- sRGB only (no Display P3). Palettes are independent of the UI `ThemePreset` (section 9.1).

## 6. Mono (DESIGN, candidates in `exports/`)

One flat ink, ring transparent. Positive = `#1D1D1F` on light, reverse = `#F5F5F7` on dark. Source of truth: `assets/mark.svg` outline, no new shapes.

| Target | Files |
|---|---|
| Web / README | `exports/mono/mark-mono.svg`, `lockup-mono.svg` (`currentColor`), `mark-mono-small.svg` (small geometry) |
| Favicon | `exports/favicon/mono.svg` (small geometry, ink follows `prefers-color-scheme`: `#1D1D1F` / `#F5F5F7`); `mono.ico` 16/32/48 in a single ink `#6E6E73` that holds 4.66:1 on `#F5F5F7` and 3.36:1 on `#1C1C1E` (an ICO cannot follow the tab theme); `apple-touch-icon-mono.png` 180, opaque, dark ink on the light tile |
| macOS app bundle icon | Icon Composer mono source = `mark-mono.svg` as one layer (system derives its tinted/clear forms). **Not produced** |
| macOS Dock (picker choice **Mono**) | `exports/dock/mono-smooth-light.png` (positive: dark ink on light tile), `mono-smooth-dark.png` (reverse: light ink on dark tile); the Dock image follows the system appearance (section 9.2) |

Mono is smooth only: the Textured finish is not offered for it (section 7, 9.1).

## 7. Texture (DESIGN, colour art only)

Optional **Textured** finish for colour raster art >= 128 px: Dock tile, social/OG art, large web art. Not on favicons, tabs, UI, any render below 128 px, or mono. Graphite is colour art and may be textured.
Filter (deterministic, specimen only): `feTurbulence fractalNoise baseFrequency 0.85, 2 octaves, seed 7`; light-grain alpha = `3.2R - 1.85`, dark-grain alpha = `-3.2R + 1.35`, each clipped to the mark's alpha, x0.22, merged over the mark. Bake to PNG at export so output is identical everywhere; the live filter never ships in the app. Pixel determinism across machines is UNVERIFIED.

## 8. Asset matrix (colour and mono for every target)

| Target | Colour | Mono | State |
|---|---|---|---|
| Favicon | `exports/favicon/{flux,ember,tide,grove,bloom,graphite}.svg` (small geometry, flat, `prefers-color-scheme`); `favicon.ico` 16/32/48 (Flux light); `apple-touch-icon.png` 180 opaque (Flux) | `favicon/mono.svg`, `mono.ico`, `apple-touch-icon-mono.png` | candidates |
| Website, README | `exports/mark/{palette}-{light,dark}.svg`, `exports/lockup/{palette}-{light,dark}.svg` | `exports/mono/*` | candidates |
| App bundle icon (Finder, Launchpad, Applications, DMG) | `.icon`: track and knob as separate SVG layers, Flux light/dark fills | one-layer mono source | **not produced** |
| Dock choices | 24 PNG `exports/dock/{palette}-{smooth,textured}-{light,dark}.png` (512 px, pre-masked tile) | 2 PNG `mono-smooth-{light,dark}.png` | candidates, runtime-unverified |
| Social / `og:image` | lockup on surface, textured allowed | mono lockup | not produced (the site has none) |

- Fixed brand vs personalisation: **website, README and favicons use Flux only, always**. The six palettes and Mono are downloadable brand assets and an in-app Dock-icon feature; the website never follows a user's in-app choice.
- Apple-touch candidates use a vertical `#FFFFFF`->`#E4E7EE` tile (white top edge is intentional, light-theme only).
- `flux-smooth-{light,dark}.png` exist only as candidate previews. The default Flux/Smooth choice does **not** use them (it uses the native bundle icon, 9.1): do not wire them as the default.
- Dock PNGs: 512x512, transparent outside a plain rounded rectangle (rx 185 of 1024; tile 824/1024 = 80.5%), mark 520/824 of the tile, no baked shadow. This is **not** Apple's continuous-corner shape; whether macOS adds its own mask, inset or shadow to a runtime image is UNVERIFIED (9.4).

## 9. In-app Dock icon (DESIGN; no code written)

### 9.1 Product contract
- Settings > Appearance row **"Dock icon"** beside the Theme card. Choice = palette (**Flux** default, Ember, Tide, Grove, Bloom, Graphite, **Mono**) x finish (**Smooth**, **Textured**). 13 selectable states: 6 palettes x 2 finishes + Mono (smooth only). While Mono is selected, Textured is dimmed with the reason "Mono is one flat ink, so Textured is not available."; returning to a palette restores the previous finish.
- **Default Flux/Smooth sets `NSApp.applicationIconImage = nil`**, showing the native bundle icon (system light/dark/clear/tinted rendering). Every other state sets a pre-rendered image from the 26 Dock PNGs. The picker's default is Flux **only after the new `AppIcon.icon` has replaced the current blue wave icon**: that cutover (section 11 item 1) is a **hard prerequisite** of the picker, in the same change set or earlier. Without it the default would show the old wave while every other state shows Flux.
- Keys (follow `BrowserSettings` `Key`/`globalValue`/`setGlobal`; app-global, not in `sessionKeys`): `appearance.appIconPalette`, `appearance.appIconFinish`. Decode with the existing `rawValue ?? default` pattern so an unknown stored value falls back to Flux/Smooth. Add them to `resetToDefaults()`. Apply once in `BrowserApplication.bootstrap` after `applyAppearance()`, and on change. Do not also hook the per-window `AppCoordinator+Bootstrap` path.
- Strings: title "Dock icon"; helper "Changes the icon in the Dock while WSurf is running." (a Finder/Launchpad sentence only if 9.4 confirms it); palette menu "Palette"; finish menu "Finish" (Smooth, Textured); reset "Reset Dock icon" (restores Flux, Smooth). Accessibility: palette control label "Dock icon palette"; each option announced "Ember, momentum" (name + meaning); selected state spoken as selected; finish control label "Dock icon finish"; the preview tile is one image labelled "Dock icon preview, Ember palette, smooth finish"; the disabled Textured option exposes the reason as its help text. Search keywords: dock icon, icon, palette, colour, color, mono, texture.
- Independent of the unmerged integration branch's `ThemePreset` (`a98f51f`, touches the same Settings files): separate row/file, rebase after that merge.

### 9.2 Appearance basis (decided)
- WSurf overrides `NSApp.appearance` with its own theme (`BrowserSettings.applyAppearance`, `AppearanceMode.nsAppearance`), so `NSApp.effectiveAppearance` is the **WSurf theme**, not the OS appearance. The native icon follows the **system**.
- **Decision:** the light/dark Dock image follows the **system** appearance, independent of the WSurf theme, so custom and default icons agree. Live updates on an OS change are wanted.
- The public API that reads the OS appearance while `NSApp.appearance` is overridden, and that fires on a live OS change, is **not chosen here and not invented**: it is a probe item (9.4.2) and a plan decision. Do not use `NSApp.effectiveAppearance`.
- The native default follows the OS icon style (default/dark/clear/tinted). Custom images: Clear/Tinted behaviour is **not promised**; UNVERIFIED until 9.4.
- About box and onboarding show the **default WSurf bundle icon**, never the chosen Dock image (identity stays constant). They currently read `NSApp.applicationIconImage` (`SettingsView.swift:305`, `OnboardingIntro.swift:51`, `OnboardingScreens.swift:376`), which returns the override, so the plan must load the bundle icon explicitly; verified in 9.4.

### 9.3 Platform limits (stated up front)
- **EXISTING (Apple docs):** `NSApplication.applicationIconImage` is the documented AppKit hook: it changes the Dock tile temporarily, `nil` restores. The documented alternate-icon API (`setAlternateIconName`) is listed for UIKit/Catalyst. No AppKit equivalent was found in the pages read; **absence of a page is not proof** none exists, so 9.4.1 also searches the Xcode 27 SDK headers.
- Dock tile of a not-running or pinned app, Finder, Launchpad: expected to stay the bundle icon, **UNVERIFIED**. Helper copy and any Finder/Launchpad sentence must match the probe.
- Cmd-Tab, Mission Control, notifications, About/alert boxes, Sparkle: **UNKNOWN** whether they follow `applicationIconImage` or the bundle icon.
- Guarantees: no bundle writes, no `NSWorkspace.setIcon` on the installed app, no hand-edited `Info.plist` icon keys, no new entitlement/capability/provisioning change for the runtime property. Newly bundled image files are a normal rebuild, re-sign and notarise.

### 9.4 Runtime probe (planned; **not run**; starts only after the written spec and the implementation plan are both approved)
Per `AGENTS.md`: sync sources to an isolated worktree or owned snapshot on Pro (ssh alias `pro`), build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Xcode 27.0, EXISTING), copy the **stage** app to the Air for UI checks with `WSURF_STAGE=1` and an owned `WSURF_STAGE_HOME` per `CONTRIBUTING.md`. Never launch or replace the installed app, never use production data, do not install Xcode 26.5. Report component probes separately from whole-app UI checks.
1. API search in the Xcode 27 SDK for any AppKit alternate-icon API; if none, `applicationIconImage` remains the only route.
2. Find and prove a public way to read the **system** appearance independent of `NSApp.appearance`, including a live OS change.
3. Set a candidate PNG live: masking, size, shadow (double padding?), default/dark/clear/tinted icon styles, `nil` restore, Flux-default equals the new bundle icon.
4. Quit/relaunch: flash of the default icon, pinned tile when not running, minimised-window tiles.
5. Cmd-Tab, Mission Control, notification, About, alerts, Sparkle; Finder/Launchpad unchanged.
6. Stage isolation: keys saved in the stage defaults suite only; `check-built-identity.py` still passes.
**If a probe shows a limit** (wrong masking, no tint support, no live following, anything else) the result is a report of the missing prerequisite and an **explicit decision request to the user**. No silent scope cut, no substitute feature.

## 10. Website, README, DMG cutover (DESIGN; to be done in the approved plan)

- `wsurf.app/style.css` hard-codes a blue brand: `--blue:#075bce` (line 8), text `#162942`, bg `#f6f9fd` (lines 4-5), hero-art gradient and orbits (`.hero-art` 40, `.orbit` 42-44, `.art-caption` 45), `.access` `#eaf2fd` (55); `index.html` has `theme-color #f6f9fd` and `color-scheme: light` (lines 8-9). The cutover **explicitly migrates these brand tokens, the hero art and `theme-color` to Flux** (accent from the Flux light set); a Flux mark on an all-blue page is not acceptable. No layout redesign. Exact token mapping (including whether navy text/background stay) is a plan decision: approval item.
- The site stays **light-only**; dark mark/lockup variants are not used by the page. Only the favicon SVG reacts to `prefers-color-scheme` (browser UI). Add no dark mode implicitly.
- CSP is `img-src 'self'; style-src 'self'`: serve the favicon files from the site root; never inline the favicon SVG (its `<style>` would be blocked).
- Replace `<link rel="icon" href="/mark.svg">` with `favicon.ico` (32), `favicon.svg`, `apple-touch-icon.png`; swap `mark.svg` uses (index.html lines 11, 19, 44, 104); README `<picture>` and `.github/assets/{mark-black,mark-white,logo}.svg`; `Tools/make-dmg-background.swift` carries its own hand-copied mark path (third copy); no manifest or `og:image` exists today.

## 11. Not done (nothing below is started)

1. `WSurf/AppIcon.icon` + `Tools/make-app-icon.swift` (EXISTING: generated blue ribbon, one mono layer): redo as track and knob SVG layers with Flux light/dark fills and a mono source; verify with actool on Pro. **Hard prerequisite of the picker.**
2. Website, README and DMG cutover (section 10).
3. Picker, keys, strings, search entry, tests (section 9).
4. Probe (9.4), only after both approvals.
5. `NOTICE` line 13 says the repo uses "a new WSurf wave mark and icon": owner review at cutover.
6. A production brand export pipeline, if wanted, placed per the existing `Tools/` convention in the plan.

## 12. Acceptance criteria (testable, for the later implementation)

- Contrast: every palette's track deep and track bright >= 3:1 on the intended surface (table in 5); knob start >= 1.6:1 on light, >= 9:1 on dark; Mono ink >= 15:1.
- Small geometry reads at 16/32/48 px on both surfaces in colour and mono (`specimen.png` sections 3 and 6).
- `exports/` SVGs have no live `feTurbulence` and no CSS variables except `favicon/*.svg` (media query only); grain exists only in baked PNGs and in the specimen.
- Every wired surface uses files derived from `assets/`; no hand-copied path data remains (DMG script migrated).
- Default Flux/Smooth restores the native bundle icon and that icon is the new Flux `.icon`; each other state shows its PNG; the choice persists across relaunch; the image follows the system appearance and updates on a live OS change; About/onboarding show the bundle icon; helper copy matches the probe.

## 13. Provenance and legal

- **Mark geometry:** concept C, `assets/mark.svg` and `assets/mark-small.svg` (committed canonical source; the earlier untracked concept folder is not needed and was not duplicated). It is original WSurf work and **not derived from the Linen mark**. Authorship statement, recorded by the WSurf design coordinator from session metadata and not checkable from the repo alone: concept C was authored from scratch by an Anthropic Claude Opus model working for wsagency. No private logs are copied here.
- **Wordmark:** outlines of Figtree Bold, kerned and tracked by us. Source used (verified this session): `https://github.com/erikdkennedy/figtree`, file `fonts/ttf/Figtree-Bold.ttf`, fetched 2026-10-16 from `master`; git blob `588d2bd7f176cc6c44af3e6227629310974a72bf` (equals the GitHub blob for that path at `master` 032dfa7fe219ef3a02890d6d3add84eacc9aebfe); SHA-256 `71a35e2bd92a05427e2dc9897bab41f8a865800e148238007735b5934508198a`; last commit touching the file `48ad76bba9fa1d25241f5ef53382bf8143055ff5` (2025-04-02, "build fonts"); font name table: "Version 2.001; ttfautohint (v1.8.4.7-5d5b)". Upstream `OFL.txt` (SHA-256 `140d37233e7f3ce7313798befa9600893bcceaf41a55fa0fa5ad52f7f657a268`, last commit `f54cce0f0a84f6b19ba3a951531d58a4d1688b4b`) begins: "Copyright 2022 The Figtree Project Authors (https://github.com/erikdkennedy/figtree). This Font Software is licensed under the SIL Open Font License, Version 1.1." The file declares no Reserved Font Name beyond the generic licence wording. The credit travels in the header of every file containing wordmark outlines. No font file is redistributed; whether outlined-logo use needs more than this credit is an INFERENCE from the OFL, **no legal review done**.
- **File headers:** new brand files follow the repo's convention for original files, `SPDX-FileCopyrightText: 2026 WSurf Agency` and `SPDX-License-Identifier: Apache-2.0` (the repository `LICENSE` applies; no new licence for the mark). They intentionally do **not** carry the "Modified for WSurf ... based on Linen by Kavoye" line, which marks files modified from Linen sources. `NOTICE`, `LICENSE` and upstream acknowledgements are untouched.
- **Current WSurf wave mark** (`wsurf.app/mark.svg`, `.github/assets/*`): created in commit `c4c4055`; unchanged here.
- **No trademark, design-right or clearance search has been done** for "WSurf" or this mark. WSurf is not endorsed by Kavoye or Apple (`NOTICE`); Apple's icon shapes and Liquid Glass belong to Apple.

## 14. Approvals and gates

Already decided, not re-asked: concept C is the mark; a textured finish is part of the scope.
Approve or change:
1. Palette names, meanings and values, including Bloom `#F5309F` and the Mono inks.
2. Figtree Bold wordmark and the lockup proportions (cap height 0.62, gap 0.22).
3. Usage rules: clear space, minimum sizes, small geometry below 64 px, texture only on colour art >= 128 px, ICO ink `#6E6E73`.
4. Platform details: Dock-only contract and wording, system-appearance basis, About/onboarding show the bundle icon, Textured disabled for Mono, 13-state picker.
5. Words (section 2): headline replacing the current one, subhead, paragraphs, today's CTA.
6. Website token migration to Flux (section 10), including whether navy text/background stay.
7. `NOTICE` review and a trademark search before launch.
Gates: (1) written-spec review, this document; (2) implementation-plan review, which will schedule the section 9.4 probe; only then (3) implementation. Spec approval alone does not start the probe or any code.
