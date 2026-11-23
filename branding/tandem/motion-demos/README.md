<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: BUSL-1.1 -->
# Tandem motion demos — Illustrated walkthroughs

These short silent walkthroughs for `wsurf.app/media/demos/` are **illustrated walkthroughs** rendered deterministically from native SwiftUI views (`ImageRenderer`) and encoded with `ffmpeg`. They are not screen recordings of live user sessions, private browsing data, or network sync sign-ins, and they do not represent or benchmark real iCloud sync latency.

## Deliverables (`wsurf.app/media/demos/`)

| Files | Feature | Duration | Dimensions / Aspect | Spec |
|---|---|---|---|---|
| `spaces.mp4`, `spaces.jpg` | Shared project Space across two Macs (`Studio MacBook` → `Desk Mac`), opening a tab on Mac A and delivering it to Mac B while each Mac keeps its own selection | 8.0 s (60 fps) | 1280×800 (16:10) | H.264 High (`avc1`), `yuv420p`, BT.709, muted (`-an`), `+faststart` |
| `micro.mp4`, `micro.jpg` | Moving a page out of a normal WSurf window into a compact Micro Window (`Move to Micro Window`), auto-hiding and revealing the Micro bar, and returning it (`Move Back to Main Window`) | 8.5 s (60 fps) | 1280×800 (16:10) | H.264 High (`avc1`), `yuv420p`, BT.709, muted (`-an`), `+faststart` |

## Fidelity and brand rules

- **Tandem Day identity:** ground `#F5F5F7`, surface `#FFFFFF`, sidebar `#EAEAEE`, ink `#1D1D1F`, muted `#636366`, lead accent `#3B1FD1`.
- **Mint reserved for assistant:** Tandem mint (`#14C79A`) is intentionally omitted from all chrome, highlights, indicators, and synthetic sample pages.
- **Accurate WSurf UI & labels (checked against source):**
  - `SidebarSpaceSwitcher.swift`: bottom space dots with `icloud.fill` badge and `"Shared Space — …"` naming.
  - `SidebarReveal.swift` & `SidebarRowInk.swift`: inverse dark fill on active rows, unseen-tab accent dot (`SidebarNewMark`), and two-swell accent reveal pulse (`SidebarRevealPulse`).
  - `MicroWindowBadge.swift`, `MicroBar.swift`, `MicroShell.swift`, `MainMenu.swift`: address bar `arrow.up.forward.square` (`"Move to Micro Window"`, `⇧⌥⌘N`), sidebar placeholder row mark (`arrow.up.forward.square`), compact single-page window with sliding top `MicroBar`, `Float on Top` (`square.3.layers.3d.top.filled`), and return control `arrow.down.backward.square` (`"Move Back to Main Window"`).
- **Synthetic neutral examples:** local-only placeholder domains (`*.fieldguide.example`, `*.meadow.example`) and vector layouts with no external assets.

## Rebuild

All build intermediates stay inside `<repo>/build/motion-demos/` (gitignored):

```sh
zsh branding/tandem/motion-demos/src/build_demos.sh
```
