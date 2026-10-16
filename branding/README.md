<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# branding/

Flux brand system for WSurf. **Draft design and candidate art. Not wired into the app, website, README or release tooling.** Read [DESIGN.md](DESIGN.md) first.

| Path | What |
|---|---|
| `DESIGN.md` | the spec: identity, words, palettes, mono, texture, asset matrix, Dock icon contract, provenance, approvals |
| `overview.png` / `.svg` | one-glance design review (exact brand colours) |
| `specimen.png` / `.svg` | full reference sheet |
| `palettes.png` / `.svg` | hex swatches with contrast ratios |
| `assets/` | committed source art and canonical geometry: `mark`, `mark-small`, `lockup`, outlined `wordmark` |
| `exports/` | **design candidates** per palette and mono: `mark/`, `lockup/`, `favicon/`, `mono/`, `dock/`; not placed anywhere, not production exports |

The candidates were generated from `assets/` by a local script that is not tracked here, so they cannot be regenerated from this repository. A production export pipeline is not part of this draft; if wanted it belongs to the approved implementation plan and the existing `Tools/` convention.

The `.png` files were rendered with the native macOS WebKit view. Dock tiles in them are drawn approximations, not real macOS icons.
