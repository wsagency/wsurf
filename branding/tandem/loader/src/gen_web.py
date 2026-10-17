# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
"""Generates web/tandem-loader.{css,svg,html} from model.py (pure CSS animation, no script, no inline style)."""
import math, os
from model import *

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web")
N = 36  # orbit samples per loop; linear interpolation between them (sagitta < 0.4% of the orbit radius)


def n(v, d=2):
    s = f"{v:.{d}f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def pct(p):
    return n(p * 100, 3) + "%"


def keyframes(cut):
    o = Orbit(cut)
    orb = []
    for i in range(N + 1):
        f = o.frame(i / N)
        orb.append(f"{pct(i / N)}{{transform:translate({n(f['x'])}px,{n(f['y'])}px) scale({n(f['s'], 4)})}}")
    # ring width: closes over sin(phi) in (0,W) before the follower goes behind, re-opens after it comes round
    w = math.asin(GAP_WINDOW)
    ph = [0.0 + i * w / 8 for i in range(9)] + [math.pi - w + i * w / 8 for i in range(9)]
    pts = sorted({round(o.p_of_phi(x), 5) for x in ph} | {0.0})
    gap = []
    for p in sorted(set(pts) | {1.0}):
        f = o.frame(p % 1.0 if p < 1.0 else 0.0)
        gap.append(f"{pct(p)}{{transform:scale({n((o.r + o.gap * f['g']) / (o.r + o.gap), 4)})}}")
    # in front for phi in (0, pi): p in [p(0), 1) and [0, p(pi))
    p_pi, p_0 = o.p_of_phi(math.pi), o.p_of_phi(0.0)
    front = (f"0%,{pct(p_pi)}{{opacity:1}}{n(p_pi * 100 + 0.001, 3)}%,{pct(p_0)}{{opacity:0}}"
             f"{n(p_0 * 100 + 0.001, 3)}%,100%{{opacity:1}}")
    rest = o.rest
    return dict(o=o, orbit="@keyframes tl-orbit-%s{%s}" % (cut, "".join(orb)),
                gap="@keyframes tl-gap-%s{%s}" % (cut, "".join(gap)),
                front="@keyframes tl-front-%s{%s}" % (cut, front), rest=rest)


def geometry(cut, k):
    o = k["o"]
    return (f'<g class="tl-{cut}" transform="scale({n(o.k, 4)})">'
            f'<g class="tl-orbit tl-back"><circle class="tl-follower" r="{n(o.r)}"/></g>'
            f'<circle class="tl-lead" r="{n(o.R)}"/>'
            f'<g class="tl-front"><g clip-path="url(#tl-clip-{cut})"><g class="tl-orbit"><circle class="tl-ring" r="{n(o.r + o.gap)}"/></g></g>'
            f'<g class="tl-orbit"><circle class="tl-follower tl-disc" r="{n(o.r)}"/></g></g></g>')


def svg_body(ks):
    defs = "<defs>" + "".join(f'<clipPath id="tl-clip-{c}"><circle r="{n(k["o"].R)}"/></clipPath>' for c, k in ks.items()) + "</defs>"
    return defs + "".join(geometry(c, k) for c, k in ks.items())


def motion_css(ks, scope, small_rule):
    """rest pose + animation rules; scope = '.tandem-loader ' (inline) or '' (standalone svg)"""
    s = scope
    css = []
    for c, k in ks.items():
        css += [k["orbit"], k["gap"], k["front"]]
    for c, k in ks.items():
        rx, ry = k["rest"]
        css.append(f"{s}.tl-{c} .tl-orbit{{transform:translate({n(rx)}px,{n(ry)}px)}}")   # rest pose = the static mark
    css.append(f"{s}.tl-small{{display:none}}")
    css.append(small_rule)
    run = "var(--_dur) linear infinite var(--_delay) var(--_play)"
    anim = "".join(f"{s}.tl-{c} .tl-orbit{{animation:tl-orbit-{c} {run}}}{s}.tl-{c} .tl-ring{{animation:tl-gap-{c} {run}}}"
                   f"{s}.tl-{c} .tl-front{{animation:tl-front-{c} {run}}}" for c in ks)
    css.append("@media (prefers-reduced-motion:no-preference){" + anim + "}")
    css.append("@keyframes tl-pulse{to{opacity:.6}}")
    css.append(f"@media (prefers-reduced-motion:reduce){{{s}.tl-back{{display:none}}{s}.tl-disc{{animation:tl-pulse 1.4s ease-in-out infinite alternate}}}}")
    return "\n".join(css)


def main():
    ks = {c: keyframes(c) for c in CUTS}
    day, dark = COLORS["day"], COLORS["dark"]
    # ---- external CSS (inline SVG in HTML) ---------------------------------------------------------
    small_rule = ("@container tandem-loader (max-width:24px){.tandem-loader .tl-full{display:none}.tandem-loader .tl-small{display:inline}}\n"
                  ".tandem-loader--small .tl-full{display:none}.tandem-loader--small .tl-small{display:inline}"
                  ".tandem-loader--full .tl-small{display:none}.tandem-loader--full .tl-full{display:inline}")
    head = f"""/* WSurf Tandem loader. Pure CSS, no script, no inline style needed (CSP-safe).
   Colours: --wsurf-lead, --wsurf-follower, --wsurf-ground (the surface behind the loader: it fills the gap ring).
   Size: .tandem-loader--16|24|32|48|64, or set --tandem-loader-size. <=24px uses the small cut automatically
   (container query; force with .tandem-loader--small / --full). Speed: --tandem-loader-duration (default 1.6s).
   prefers-reduced-motion: no orbit; the follower fades 100% -> 60% on the static mark. */
.tandem-loader{{--_lead:var(--wsurf-lead,{day['lead']});--_follower:var(--wsurf-follower,{day['follower']});--_ground:var(--wsurf-ground,{day['ground']});
--_dur:var(--tandem-loader-duration,{LOOP_SECONDS}s);--_delay:var(--tandem-loader-delay,0s);--_play:var(--tandem-loader-play,running);
display:inline-block;position:relative;width:var(--tandem-loader-size,1.5em);height:var(--tandem-loader-size,1.5em);
line-height:0;vertical-align:middle;container:tandem-loader/inline-size}}
@media (prefers-color-scheme:dark){{.tandem-loader{{--_lead:var(--wsurf-lead,{dark['lead']});--_follower:var(--wsurf-follower,{dark['follower']});--_ground:var(--wsurf-ground,{dark['ground']})}}}}
.tandem-loader--16{{--tandem-loader-size:16px}}.tandem-loader--24{{--tandem-loader-size:24px}}.tandem-loader--32{{--tandem-loader-size:32px}}
.tandem-loader--48{{--tandem-loader-size:48px}}.tandem-loader--64{{--tandem-loader-size:64px}}
.tandem-loader svg{{display:block;width:100%;height:100%;overflow:visible}}
.tandem-loader__label{{position:absolute;width:1px;height:1px;margin:-1px;padding:0;border:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}}
.tandem-loader .tl-lead{{fill:var(--_lead)}}.tandem-loader .tl-follower{{fill:var(--_follower)}}.tandem-loader .tl-ring{{fill:var(--_ground)}}
"""
    css = head + motion_css(ks, ".tandem-loader ", small_rule) + "\n"
    open(os.path.join(OUT, "tandem-loader.css"), "w").write(css)

    # ---- standalone SVG (works as <img>) -----------------------------------------------------------
    vb = f"{-HALF_BOX:g} {-HALF_BOX:g} {2 * HALF_BOX:g} {2 * HALF_BOX:g}"
    sa_small = "@media (max-width:24px){.tl-full{display:none}.tl-small{display:inline}}"
    sa = f"""svg{{--_dur:{LOOP_SECONDS}s;--_delay:0s;--_play:running}}
.tl-lead{{fill:{day['lead']}}}.tl-follower{{fill:{day['follower']}}}.tl-ring{{fill:{day['ground']}}}
@media (prefers-color-scheme:dark){{.tl-lead{{fill:{dark['lead']}}}.tl-follower{{fill:{dark['follower']}}}.tl-ring{{fill:{dark['ground']}}}}}
""" + motion_css(ks, "", sa_small)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="Loading"><title>Loading</title>'
           f"<style>{sa}</style>{svg_body(ks)}</svg>\n")
    open(os.path.join(OUT, "tandem-loader.svg"), "w").write(svg)

    # ---- reduced-motion still for <img>/<picture> (an SVG image may not receive the OS reduced-motion setting) ---------
    def still(cut, k):
        o = k["o"]
        x, y = o.rest
        return (f'<g class="tl-{cut}" transform="scale({n(o.k, 4)})"><circle class="tl-lead" r="{n(o.R)}"/>'
                f'<g clip-path="url(#tl-clip-{cut})"><circle class="tl-ring" cx="{n(x)}" cy="{n(y)}" r="{n(o.r + o.gap)}"/></g>'
                f'<circle class="tl-follower tl-disc" cx="{n(x)}" cy="{n(y)}" r="{n(o.r)}"/></g>')
    still_css = (f".tl-lead{{fill:{day['lead']}}}.tl-follower{{fill:{day['follower']}}}.tl-ring{{fill:{day['ground']}}}\n"
                 f"@media (prefers-color-scheme:dark){{.tl-lead{{fill:{dark['lead']}}}.tl-follower{{fill:{dark['follower']}}}.tl-ring{{fill:{dark['ground']}}}}}\n"
                 ".tl-small{display:none}" + sa_small + "\n@keyframes tl-pulse{to{opacity:.6}}.tl-disc{animation:tl-pulse 1.4s ease-in-out infinite alternate}")
    defs = "<defs>" + "".join(f'<clipPath id="tl-clip-{c}"><circle r="{n(k["o"].R)}"/></clipPath>' for c, k in ks.items()) + "</defs>"
    open(os.path.join(OUT, "tandem-loader-reduced.svg"), "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="Loading"><title>Loading</title><style>{still_css}</style>'
        f'{defs}{"".join(still(c, k) for c, k in ks.items())}</svg>\n')

    # ---- HTML snippet / demo -----------------------------------------------------------------------
    inner = svg_body(ks)

    def one(size):
        return (f'<span class="tandem-loader tandem-loader--{size}" role="status"><svg viewBox="{vb}" aria-hidden="true" focusable="false">'
                f'{inner}</svg><span class="tandem-loader__label">Loading</span></span>')
    html = f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WSurf Tandem loader</title>
<!-- Needs only: <link rel="stylesheet" href="tandem-loader.css"> and the markup below. Same-origin CSS, no script, no style attribute.
     Prefer the inline markup: it honours prefers-reduced-motion everywhere. As an image, use <picture> so every browser gets the still:
     <picture><source media="(prefers-reduced-motion: reduce)" srcset="tandem-loader-reduced.svg"><img src="tandem-loader.svg" width="24" height="24" alt="Loading"></picture> -->
<link rel="stylesheet" href="tandem-loader.css">
<style>/* demo page only */body{{margin:0;padding:32px;font:14px system-ui;background:#F5F5F7;color:#1D1D1F;display:flex;gap:28px;align-items:center;flex-wrap:wrap}}
@media (prefers-color-scheme:dark){{body{{background:#1C1C1E;color:#F5F5F7}}}}</style>
{chr(10).join(one(s) for s in (16, 24, 32, 48, 64))}
"""
    open(os.path.join(OUT, "tandem-loader.html"), "w").write(html)
    print({f: os.path.getsize(os.path.join(OUT, f)) for f in sorted(os.listdir(OUT))})


if __name__ == "__main__":
    main()
