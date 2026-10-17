<!-- SPDX-FileCopyrightText: 2026 WSurf Agency -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# branding/

WSurf brand files. **The mark is Tandem: start with [tandem/README.md](tandem/README.md).** Nothing here is wired into the app, website, README or release tooling yet.

The Flux draft below was superseded by Tandem on 2026-10-16. Its files stay as the record of that review; its default colour pair carries over to Tandem, and its palettes stay available as colour pairs.

| Path | What |
|---|---|
| `tandem/` | **the chosen mark**: master and small cut, mono, Inter Display Bold wordmark, lockups, app icon draft, favicons, proofs; plus `3d/`, `loader/` and `relief/` for 3D, motion and hero art |
| `licenses/Inter-OFL.txt` | verbatim upstream SIL OFL 1.1 text for the Inter Display Bold outlines in the Tandem wordmark (provenance only; the font binary is not shipped) |
| `DESIGN.md` | superseded Flux spec: identity, words, palettes, mono, texture, asset matrix, Dock icon contract, provenance, approvals |
| `overview.png` / `.svg` | one-glance design review (exact brand colours) |
| `specimen.png` / `.svg` | full reference sheet |
| `palettes.png` / `.svg` | hex swatches with contrast ratios |
| `assets/` | committed source art and canonical geometry: `mark`, `mark-small`, `lockup`, outlined `wordmark` |
| `licenses/Figtree-OFL.txt` | verbatim upstream SIL OFL 1.1 text for the Figtree Bold outlines in the wordmark (provenance only; the font binary is not shipped; see DESIGN.md section 13) |
| `exports/` | **design candidates** per palette and mono: `mark/`, `lockup/`, `favicon/`, `mono/`, `dock/`; not placed anywhere, not production exports |

The candidates were generated from `assets/` by throwaway authoring/render scripts that were removed after verification; canonical SVG art is retained in `assets/`, and there is no production generator in this repository. A production export pipeline is not part of this draft; if wanted it belongs to the approved implementation plan and the existing `Tools/` convention.

The `.png` files were rendered with the native macOS WebKit view. Dock tiles in them are drawn approximations, not real macOS icons.
