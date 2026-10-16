"""Regenerates every file under branding/ except DESIGN.md/README.md.

  python3 -m venv /tmp/bv && /tmp/bv/bin/pip install fonttools uharfbuzz pillow
  FIGTREE_BOLD=/path/Figtree-Bold.ttf /tmp/bv/bin/python branding/tools/gen.py

Figtree (SIL OFL 1.1): https://github.com/erikdkennedy/figtree (fonts/ttf/Figtree-Bold.ttf). Only outlines are
embedded, so no font file or OFL text ships in the repo. Rendering uses WKWebView via tools/render.swift (macOS).
"""
import json, os, subprocess, sys, tempfile
from PIL import Image
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, "..")

TRACK = ("M350 202H674A310 310 0 0 1 674 822H350A310 310 0 0 1 350 202ZM442.2 400.4A16 16 0 0 0 466.3 395.8"
         "A238 238 0 1 1 466.3 628.2A16 16 0 0 0 442.2 623.6A144 144 0 1 1 442.2 400.4Z")
KNOB = ("M411.9 437.6A64 64 0 0 0 508.2 419.2A190 190 0 1 1 508.2 604.8A64 64 0 0 0 411.9 586.4"
        "A96 96 0 1 1 411.9 437.6Z")
TRACK_S = ("M362 182H662A330 330 0 0 1 662 842H362A330 330 0 0 1 362 182ZM457.7 366.5A20 20 0 0 0 484.3 362.9"
           "A232 232 0 1 1 484.3 661.1A20 20 0 0 0 457.7 657.5A176 176 0 1 1 457.7 366.5Z")
KNOB_S = ("M410.4 436A104 104 0 0 0 548.6 416.9A148 148 0 1 1 548.6 607.1A104 104 0 0 0 410.4 588"
          "A92 92 0 1 1 410.4 436Z")
# gradient axes (userSpaceOnUse)
GT, GK = (40, 202, 984, 822), (260, 512, 860, 512)
GT_S, GK_S = (32, 182, 992, 842), (266, 512, 840, 512)
BB = (40, 202, 984, 822)      # mark bbox, master
BB_S = (32, 182, 992, 842)    # small

# palettes: name -> (L set, D set) ; [track deep, track bright, knob start, knob end]
PAL = {
    "Flux":     (["#3B1FD1", "#8A63FF", "#14C79A", "#D9FFF0"], ["#6D55FF", "#B49CFF", "#2FE0B2", "#EFFFF9"]),
    "Ember":    (["#A3153A", "#F0502F", "#FFB02E", "#FFF1CC"], ["#E0476A", "#FF8A5B", "#FFC24D", "#FFF6DC"]),
    "Tide":     (["#0B3A8C", "#3C8CFF", "#00B8E6", "#EAFBFF"], ["#4C8DFF", "#8DBFFF", "#4FD8FF", "#F2FDFF"]),
    "Grove":    (["#0E4D3A", "#2E9E6B", "#8FCB1F", "#F7FFD9"], ["#2FAE80", "#6FD6A4", "#B6E64A", "#FBFFE6"]),
    "Bloom":    (["#8F1480", "#F5309F", "#00C2E0", "#E6FCFF"], ["#D43FC0", "#FF7FC8", "#2FD6F0", "#EEFDFF"]),
    "Graphite": (["#1D1F24", "#5A6170", "#9AA3B2", "#FFFFFF"], ["#7F8797", "#C3C9D4", "#D5DAE3", "#FFFFFF"]),
}
MEANING = {"Flux": "adaptability (default)", "Ember": "momentum", "Tide": "calm, ocean heritage",
           "Grove": "growth", "Bloom": "playful, punchy", "Graphite": "focus, neutral"}
LS, DS = "#F5F5F7", "#1C1C1E"


def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def cr(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


# ---------- wordmark (outlined Figtree Bold, kerned via HarfBuzz) ----------
FONT = os.environ["FIGTREE_BOLD"]
tt = TTFont(FONT)
gs = tt.getGlyphSet()
order = tt.getGlyphOrder()
blob = hb.Blob.from_file_path(FONT)
face = hb.Face(blob)
font = hb.Font(face)
buf = hb.Buffer()
buf.add_str("WSurf")
buf.guess_segment_properties()
hb.shape(font, buf, {"kern": True, "liga": False})
TRACKING = 10  # font units added between glyphs
x = 0
wm_paths = []
for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
    name = order[info.codepoint]
    pen = SVGPathPen(gs, ntos=lambda v: ("%.1f" % v).rstrip("0").rstrip("."))
    gs[name].draw(TransformPen(pen, (1, 0, 0, -1, x + pos.x_offset, 0)))  # flip y; baseline y=0
    wm_paths.append(pen.getCommands())
    x += pos.x_advance + TRACKING
WM_W = x - TRACKING
WM_D = "".join(wm_paths)
CAP = 700


# ---------- gradient/mark helpers ----------
def grad(id_, g, c0, c1):
    return (f'<linearGradient id="{id_}" x1="{g[0]}" y1="{g[1]}" x2="{g[2]}" y2="{g[3]}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{c0}"/><stop offset="1" stop-color="{c1}"/></linearGradient>')


def var_grad(id_, g, v0, v1):
    return (f'<linearGradient id="{id_}" x1="{g[0]}" y1="{g[1]}" x2="{g[2]}" y2="{g[3]}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" style="stop-color:{v0}"/><stop offset="1" style="stop-color:{v1}"/></linearGradient>')


FLUX_L = PAL["Flux"][0]
V = [f"var(--wsurf-{n},{FLUX_L[i]})" for i, n in enumerate(("track-deep", "track-bright", "knob-start", "knob-end"))]


def write(rel, s):
    os.makedirs(os.path.dirname(os.path.join(OUT, rel)), exist_ok=True)
    with open(os.path.join(OUT, rel), "w") as f:
        f.write(s)


HDR = "<!-- WSurf brand artwork, wsagency 2026. Original WSurf artwork (concept C), not derived from the Linen mark. Licence: repository LICENSE. Provenance: branding/DESIGN.md#provenance -->\n"
HDRW = HDR.replace("(concept C), not derived from the Linen mark.", "(concept C), not derived from the Linen mark; wordmark outlines typeset from Figtree Bold, SIL OFL 1.1, Copyright 2022 The Figtree Project Authors.")

# assets/mark.svg
write("assets/mark.svg", HDR +
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="WSurf">'
      '<defs>' + var_grad("wsurf-track", GT, V[0], V[1]) + var_grad("wsurf-knob", GK, V[2], V[3]) + '</defs>'
      f'<path fill="url(#wsurf-track)" fill-rule="evenodd" d="{TRACK}"/><path fill="url(#wsurf-knob)" d="{KNOB}"/></svg>\n')
# assets/mark-small.svg: flat two-colour, <=48 px
write("assets/mark-small.svg", HDR +
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="WSurf">'
      f'<path style="fill:{V[0]}" fill-rule="evenodd" d="{TRACK_S}"/><path style="fill:{V[2]}" d="{KNOB_S}"/></svg>\n')

# lockup: mark left, outlined wordmark right, tight viewBox
S = 0.2                      # mark scale
mw, mh = (BB[2] - BB[0]) * S, (BB[3] - BB[1]) * S
FS = 0.125 * 1000 / 1000      # font size in px: cap = 700u * k ; want cap = 0.62 * mh
k = 0.62 * mh / CAP
gap = 0.22 * mw
wm_w = WM_W * k
LW, LH = mw + gap + wm_w, mh
base = mh / 2 + CAP * k / 2   # baseline so caps are centred on the mark
lock_inner = (f'<g transform="translate({-BB[0]*S:.3f} {-BB[1]*S:.3f}) scale({S})">'
              '<path fill="url(#wsurf-track)" fill-rule="evenodd" d="%s"/><path fill="url(#wsurf-knob)" d="%s"/></g>'
              '<path fill="currentColor" transform="translate(%.3f %.3f) scale(%.5f)" d="%s"/>'
              % (TRACK, KNOB, mw + gap, base, k, WM_D))
write("assets/lockup.svg", HDRW +
      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {LW:.2f} {LH:.2f}" width="{LW:.0f}" height="{LH:.0f}" role="img" aria-label="WSurf">'
      '<defs>' + var_grad("wsurf-track", GT, V[0], V[1]) + var_grad("wsurf-knob", GK, V[2], V[3]) + '</defs>'
      + lock_inner + '</svg>\n')
write("assets/wordmark.svg", HDRW +
      f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {-CAP-10} {WM_W:.0f} {CAP+20+210}" role="img" aria-label="WSurf">'
      f'<path fill="currentColor" d="{WM_D}"/></svg>\n')


# ---------- specimen / palettes building blocks ----------
GID = [0]


def mark(pal_set, tx, ty, w, finish="smooth", small=False, mono=None):
    """Return <g> placing mark with bbox width w at (tx,ty)=top-left. pal_set=[4 hex]. mono=hex for one-ink."""
    GID[0] += 1
    i = GID[0]
    bb = BB_S if small else BB
    s = w / (bb[2] - bb[0])
    t, kn = (TRACK_S, KNOB_S) if small else (TRACK, KNOB)
    gt, gk = (GT_S, GK_S) if small else (GT, GK)
    tr = f'translate({tx:.2f} {ty:.2f}) scale({s:.5f}) translate({-bb[0]} {-bb[1]})'
    if mono:
        body = f'<path fill="{mono}" fill-rule="evenodd" d="{t}"/><path fill="{mono}" d="{kn}"/>'
        return f'<g transform="{tr}">{body}</g>'
    if small:
        body = f'<path fill="{pal_set[0]}" fill-rule="evenodd" d="{t}"/><path fill="{pal_set[2]}" d="{kn}"/>'
        return f'<g transform="{tr}">{body}</g>'
    defs = grad(f"gt{i}", gt, pal_set[0], pal_set[1]) + grad(f"gk{i}", gk, pal_set[2], pal_set[3])
    body = f'<path fill="url(#gt{i})" fill-rule="evenodd" d="{t}"/><path fill="url(#gk{i})" d="{kn}"/>'
    flt = ""
    if finish == "grain":
        body = f'<g filter="url(#grain)">{body}</g>'
    return f'<g transform="{tr}"><defs>{defs}</defs>{body}</g>'


GRAIN = ('<filter id="grain" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">'
         '<feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="7" result="n"/>'
         '<feColorMatrix in="n" type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  3.2 0 0 0 -1.85" result="lt"/>'
         '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  -3.2 0 0 0 1.35" result="dk"/>'
         '<feComposite in="lt" in2="SourceAlpha" operator="in" result="lt2"/>'
         '<feComposite in="dk" in2="SourceAlpha" operator="in" result="dk2"/>'
         '<feComponentTransfer in="lt2" result="lt3"><feFuncA type="linear" slope="0.22"/></feComponentTransfer>'
         '<feComponentTransfer in="dk2" result="dk3"><feFuncA type="linear" slope="0.22"/></feComponentTransfer>'
         '<feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="lt3"/><feMergeNode in="dk3"/></feMerge></filter>')


def lockup_for(pal_set, tx, ty, h, ink):
    s = h / mh
    GID[0] += 1
    i = GID[0]
    defs = grad(f"gt{i}", GT, pal_set[0], pal_set[1]) + grad(f"gk{i}", GK, pal_set[2], pal_set[3])
    inner = (f'<g transform="translate({-BB[0]*S:.3f} {-BB[1]*S:.3f}) scale({S})">'
             f'<path fill="url(#gt{i})" fill-rule="evenodd" d="{TRACK}"/><path fill="url(#gk{i})" d="{KNOB}"/></g>'
             f'<path fill="{ink}" transform="translate({mw+gap:.3f} {base:.3f}) scale({k:.5f})" d="{WM_D}"/>')
    return f'<g transform="translate({tx} {ty}) scale({s:.4f})"><defs>{defs}</defs>{inner}</g>', LW * s


def T(x, y, s, size=13, fill="#555", weight=400, anchor="start"):
    s = s.replace("&", "&amp;").replace("<", "&lt;")
    return (f'<text x="{x}" y="{y}" font-family="-apple-system, system-ui, sans-serif" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{s}</text>')


def tile(pal_set, x, y, dark, finish="smooth", size=232):
    """Dock tile preview: 824/1024 squircle approx on neutral tile. size=outer box."""
    sc = size / 1024
    GID[0] += 1
    i = GID[0]
    a, b = ("#2C2C30", "#121214") if dark else ("#FFFFFF", "#E4E7EE")
    side = 824
    off = (1024 - side) / 2
    g = f'<g transform="translate({x} {y}) scale({sc:.4f})">'
    g += (f'<defs><linearGradient id="tl{i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/>'
          f'<stop offset="1" stop-color="{b}"/></linearGradient></defs>')
    g += f'<rect x="{off}" y="{off}" width="{side}" height="{side}" rx="185" fill="url(#tl{i})"/>'
    g += f'<rect x="{off+1}" y="{off+1}" width="{side-2}" height="{side-2}" rx="184" fill="none" stroke="{"#ffffff" if dark else "#000000"}" stroke-opacity="0.12" stroke-width="2"/>'
    mwid = 520
    g += mark(pal_set, 512 - mwid / 2, 512 - mwid * (620 / 944) / 2, mwid, finish)
    g += "</g>"
    return g


# ---------- specimen.svg ----------
W, H = 1600, 2700
P = []
P.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">')
P.append('<defs>' + GRAIN + '</defs>')
P.append(f'<rect width="{W}" height="{H}" fill="{LS}"/>')
P.append(T(60, 70, "WSurf identity specimen - Flux (DRAFT, needs approval)", 26, "#1d1d1f", 700))
P.append(T(60, 98, "Generated from branding/assets; fonts: Figtree Bold (OFL) outlined. Labels below are specimen text only, not the logo.", 14, "#6e6e73"))

# 1 lockups
P.append(T(60, 150, "1  Lockup", 18, "#1d1d1f", 700))
P.append(f'<rect x="60" y="165" width="700" height="260" rx="20" fill="{LS}" stroke="#d2d2d7"/>')
l, lw_ = lockup_for(PAL["Flux"][0], 0, 0, 110, "#1d1d1f")
P.append(f'<g transform="translate({60+(700-lw_)/2:.1f} {165+75})">{lockup_for(PAL["Flux"][0],0,0,110,"#1d1d1f")[0]}</g>')
P.append(f'<rect x="800" y="165" width="740" height="260" rx="20" fill="{DS}"/>')
P.append(f'<g transform="translate({800+(740-lw_)/2:.1f} 240)">{lockup_for(PAL["Flux"][1],0,0,110,"#f5f5f7")[0]}</g>')
P.append(T(60, 450, "Light surface #F5F5F7, ink #1D1D1F, light palette set", 13))
P.append(T(800, 450, "Dark surface #1C1C1E, ink #F5F5F7, dark palette set", 13))

# 2 clear space + construction
P.append(T(60, 510, "2  Clear space = 1/4 of mark width (x) on all sides; Dock/app fit separately", 18, "#1d1d1f", 700))
mx, my, mwid = 170, 680, 440
xq = mwid / 4
mhh = mwid * 620 / 944
P.append(f'<rect x="{mx-xq}" y="{my-xq}" width="{mwid+2*xq}" height="{mhh+2*xq}" fill="none" stroke="#e5484d" stroke-dasharray="6 5"/>')
P.append(f'<rect x="{mx}" y="{my}" width="{mwid}" height="{mhh}" fill="none" stroke="#999" stroke-dasharray="2 4"/>')
P.append(mark(PAL["Flux"][0], mx, my, mwid))
P.append(T(mx - xq, my - xq - 10, "x = 1/4 mark width", 12, "#e5484d"))
# lockup with clear space
lx, ly, lh = 880, 700, 130
l1, lw1 = lockup_for(PAL["Flux"][0], lx, ly, lh, "#1d1d1f")
xq2 = lw1 * 0 + (mw * (lh / mh)) / 4
P.append(f'<rect x="{lx-xq2}" y="{ly-xq2}" width="{lw1+2*xq2}" height="{lh+2*xq2}" fill="none" stroke="#e5484d" stroke-dasharray="6 5"/>')
P.append(l1)
P.append(T(lx - xq2, ly + lh + xq2 + 24, "Lockup: same x (1/4 of the mark width) around the whole lockup", 12, "#6e6e73"))
# min size note
P.append(T(840, ly + lh + xq2 + 60, "Minimum: lockup 96 px wide; mark 16 px (small geometry <=48 px, flat)", 12, "#6e6e73"))

# 3 size ramp
y0 = 1220
P.append(T(60, y0 - 25, "3  Size ramp - small geometry (flat, 2 colour) up to 48 px, master above", 18, "#1d1d1f", 700))
P.append(f'<rect x="60" y="{y0}" width="740" height="150" rx="16" fill="{LS}" stroke="#d2d2d7"/>')
P.append(f'<rect x="800" y="{y0}" width="740" height="150" rx="16" fill="{DS}"/>')
xx = 90
for w_, small in ((16, 1), (24, 1), (32, 1), (48, 1), (64, 0), (96, 0), (128, 0)):
    P.append(mark(PAL["Flux"][0], xx, y0 + 75 - w_ * 0.328, w_, small=bool(small)))
    P.append(T(xx, y0 + 140, f"{w_}", 11))
    xx += w_ + 42
xx = 830
for w_, small in ((16, 1), (24, 1), (32, 1), (48, 1), (64, 0), (96, 0), (128, 0)):
    P.append(mark(PAL["Flux"][1], xx, y0 + 75 - w_ * 0.328, w_, small=bool(small)))
    P.append(T(xx, y0 + 140, f"{w_}", 11, "#aaa"))
    xx += w_ + 42

# 4 palettes smooth + textured
y1 = 1470
P.append(T(60, y1 - 25, "4  Six palettes: Dock-tile previews (illustrative, not final masks) - smooth row, textured row; light then dark", 18, "#1d1d1f", 700))
names = list(PAL)
cw = 250
for r, (dark, fin) in enumerate(((0, "smooth"), (1, "smooth"), (0, "grain"), (1, "grain"))):
    for c, n in enumerate(names):
        pal = PAL[n][dark]
        P.append(tile(pal, 60 + c * 255, y1 + r * 235, bool(dark), fin, 240))
    P.append(T(60, y1 + r * 235 + 232, f"{'dark' if dark else 'light'} / {fin}", 11, "#999"))
for c, n in enumerate(names):
    P.append(T(60 + c * 255 + 120, y1 + 4 * 235 + 18, f"{n} - {MEANING[n]}", 12, "#1d1d1f", 600, "middle"))

# 5 mono
y2 = y1 + 4 * 235 + 70
P.append(T(60, y2, "5  One-ink mono: positive, reverse, and on brand-ink surfaces", 18, "#1d1d1f", 700))
for j, (bg, ink, lab) in enumerate((("#FFFFFF", "#1D1D1F", "positive"), ("#1D1D1F", "#FFFFFF", "reverse"),
                                    ("#3B1FD1", "#FFFFFF", "on Flux deep"), ("#14C79A", "#0B2B22", "on Flux knob"))):
    bx = 60 + j * 385
    P.append(f'<rect x="{bx}" y="{y2+20}" width="360" height="160" rx="14" fill="{bg}" stroke="#d2d2d7"/>')
    P.append(mark(None, bx + 90, y2 + 20 + 28, 180, mono=ink))
    P.append(T(bx, y2 + 200, lab, 12))
P.append("</svg>")
write("specimen.svg", HDRW + "\n".join(P) + "\n")

# ---------- palettes.svg ----------
rows = []
table = []
PW, PH = 1400, 140 + len(PAL) * 150
rows.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {PW} {PH}" width="{PW}" height="{PH}"><rect width="{PW}" height="{PH}" fill="#fff"/>')
rows.append(T(40, 50, "WSurf palettes: [track deep, track bright, knob start, knob end]; contrast vs #F5F5F7 (light) / #1C1C1E (dark), WCAG 2.x ratio", 18, "#1d1d1f", 700))
labels = ("track deep", "track bright", "knob start", "knob end")
for r, n in enumerate(names):
    y = 90 + r * 150
    rows.append(T(40, y + 24, n, 18, "#1d1d1f", 700))
    rows.append(T(40, y + 46, MEANING[n], 12, "#6e6e73"))
    for si, (setname, surf) in enumerate((("light", LS), ("dark", DS))):
        bx = 260 + si * 560
        rows.append(f'<rect x="{bx-10}" y="{y-8}" width="540" height="130" rx="10" fill="{surf}" stroke="#d2d2d7"/>')
        fg = "#555" if si == 0 else "#aaa"
        for k_, hx in enumerate(PAL[n][si]):
            sx = bx + k_ * 130
            rows.append(f'<rect x="{sx}" y="{y}" width="110" height="60" rx="8" fill="{hx}"/>')
            rows.append(T(sx, y + 80, hx, 12, fg, 600))
            rows.append(T(sx, y + 98, f"{labels[k_]} {cr(hx, surf):.2f}:1", 11, fg))
            table.append((n, setname, labels[k_], hx, round(cr(hx, surf), 2)))
rows.append("</svg>")
write("palettes.svg", HDR + "\n".join(rows) + "\n")



# ---------- production exports ----------
TMP = tempfile.mkdtemp()
RENDER = os.path.join(TMP, "render")
subprocess.run(["swiftc", "-O", os.path.join(ROOT, "render.swift"), "-o", RENDER], check=True)


def render(svg_path, png_path, w, h, transparent=True):
    subprocess.run([RENDER, svg_path, png_path, str(w), str(h)] + (["t"] if transparent else []), check=True)


def out(*p):
    path = os.path.join(OUT, *p)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


XML = '<svg xmlns="http://www.w3.org/2000/svg" '
INK = {"light": "#1D1D1F", "dark": "#F5F5F7"}


def mark_svg(pal):
    return (HDR + XML + 'viewBox="40 202 944 620" width="944" height="620" role="img" aria-label="WSurf"><defs>'
            + grad("t", GT, pal[0], pal[1]) + grad("k", GK, pal[2], pal[3]) + "</defs>"
            f'<path fill="url(#t)" fill-rule="evenodd" d="{TRACK}"/><path fill="url(#k)" d="{KNOB}"/></svg>\n')


def lockup_svg(pal, ink):
    return (HDRW + XML + f'viewBox="0 0 {LW:.2f} {LH:.2f}" width="{LW:.0f}" height="{LH:.0f}" role="img" aria-label="WSurf"><defs>'
            + grad("t", GT, pal[0], pal[1]) + grad("k", GK, pal[2], pal[3]) + "</defs>"
            f'<g transform="translate({-BB[0]*S:.3f} {-BB[1]*S:.3f}) scale({S})"><path fill="url(#t)" fill-rule="evenodd" d="{TRACK}"/>'
            f'<path fill="url(#k)" d="{KNOB}"/></g><path fill="{ink}" transform="translate({mw+gap:.3f} {base:.3f}) scale({k:.5f})" d="{WM_D}"/></svg>\n')


def favicon_svg(pal):
    L, D = pal
    return (HDR + XML + 'viewBox="32 32 960 960" role="img" aria-label="WSurf"><style>'
            f':root{{--a:{L[0]};--b:{L[2]}}}@media (prefers-color-scheme:dark){{:root{{--a:{D[0]};--b:{D[2]}}}}}</style>'
            f'<path style="fill:var(--a)" fill-rule="evenodd" d="{TRACK_S}"/><path style="fill:var(--b)" d="{KNOB_S}"/></svg>\n')


for n, (L, D) in PAL.items():
    ln = n.lower()
    for mode, st in (("light", L), ("dark", D)):
        write(f"exports/mark/{ln}-{mode}.svg", mark_svg(st))
        write(f"exports/lockup/{ln}-{mode}.svg", lockup_svg(st, INK[mode]))
    write(f"exports/favicon/{ln}.svg", favicon_svg((L, D)))

# mono: one ink via currentColor; the ring gap stays transparent
write("exports/mono/mark-mono.svg", HDR + XML +
      f'viewBox="40 202 944 620" role="img" aria-label="WSurf" fill="currentColor"><path fill-rule="evenodd" d="{TRACK}"/><path d="{KNOB}"/></svg>\n')
write("exports/mono/lockup-mono.svg", HDRW + XML +
      f'viewBox="0 0 {LW:.2f} {LH:.2f}" role="img" aria-label="WSurf" fill="currentColor"><g transform="translate({-BB[0]*S:.3f} {-BB[1]*S:.3f}) scale({S})">'
      f'<path fill-rule="evenodd" d="{TRACK}"/><path d="{KNOB}"/></g><path transform="translate({mw+gap:.3f} {base:.3f}) scale({k:.5f})" d="{WM_D}"/></svg>\n')

# favicon.ico (Flux light, flat, 16/32/48) + apple-touch-icon (opaque 180 tile)
fl = PAL["Flux"][0]
ico = []
for px in (16, 32, 48):
    p = os.path.join(TMP, f"f{px}.svg")
    open(p, "w").write(XML + f'viewBox="32 32 960 960" width="{px}" height="{px}"><path fill="{fl[0]}" fill-rule="evenodd" d="{TRACK_S}"/><path fill="{fl[2]}" d="{KNOB_S}"/></svg>')
    render(p, os.path.join(TMP, f"f{px}.png"), px, px)
    ico.append(Image.open(os.path.join(TMP, f"f{px}.png")).convert("RGBA"))
ico[2].save(out("exports", "favicon", "favicon.ico"), format="ICO", sizes=[(16, 16), (32, 32), (48, 48)], append_images=ico[:2])
GID[0] += 1
ap = os.path.join(TMP, "apple.svg")
open(ap, "w").write(XML + 'viewBox="0 0 180 180" width="180" height="180"><defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
                    '<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E4E7EE"/></linearGradient></defs>'
                    '<rect width="180" height="180" fill="url(#bg)"/>' + mark(fl, 30, 90 - 98 * 0.328, 120) + '</svg>')
render(ap, out("exports", "favicon", "apple-touch-icon.png"), 180, 180, transparent=False)

# Dock tile candidates: palette x finish x appearance, 512 px, transparent outside the 824/1024 squircle
for n, (L, D) in PAL.items():
    for finish, fname in (("smooth", "smooth"), ("grain", "textured")):
        for mode, st in (("light", L), ("dark", D)):
            p = os.path.join(TMP, "d.svg")
            open(p, "w").write(XML + 'viewBox="0 0 1024 1024" width="512" height="512"><defs>' + GRAIN + "</defs>"
                               + tile(st, 0, 0, mode == "dark", finish, 1024) + "</svg>")
            render(p, out("exports", "dock", f"{n.lower()}-{fname}-{mode}.png"), 512, 512)

# specimen / palettes PNGs
render(os.path.join(OUT, "specimen.svg"), os.path.join(OUT, "specimen.png"), W, H, transparent=False)
render(os.path.join(OUT, "palettes.svg"), os.path.join(OUT, "palettes.png"), PW, PH, transparent=False)
json.dump(table, open(os.path.join(TMP, "contrast.json"), "w"))
print("ok", TMP, "lockup", round(LW, 1), round(LH, 1))
