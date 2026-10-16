# branding/

Flux brand system for WSurf. **Draft, not wired into the app or website.** Read [DESIGN.md](DESIGN.md) first.

| Path | What |
|---|---|
| `DESIGN.md` | spec: identity, geometry, palettes, mono, texture, asset matrix, Dock icon design, provenance, approvals |
| `specimen.svg` / `.png` | reference sheet (lockups, clear space, size ramp, 6 palettes x finish x light/dark, mono) |
| `palettes.svg` / `.png` | hex swatches with contrast ratios |
| `assets/` | source art: token-driven `mark`, `mark-small`, `lockup`, outlined `wordmark` (CSS vars `--wsurf-track-deep` etc., Flux light fallbacks) |
| `exports/` | candidate production files per palette: `mark/`, `lockup/`, `favicon/`, `mono/`, `dock/` (not placed anywhere yet) |
| `tools/` | `gen.py` regenerates everything except the two `.md` files; `render.swift` rasterises through WKWebView |

Regenerate (macOS, needs Figtree Bold from github.com/erikdkennedy/figtree, SIL OFL 1.1):

```sh
python3 -m venv /tmp/bv && /tmp/bv/bin/pip install fonttools uharfbuzz pillow
FIGTREE_BOLD=/path/to/Figtree-Bold.ttf /tmp/bv/bin/python branding/tools/gen.py
```
