# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
"""Tandem loader orbit model: the single reference for the web CSS (gen_web.py) and the Swift port.

Coordinates: lead centre = origin, SVG y-down, master units (the 1024 master / small cut of the kit).
The follower rides a tilted-orbit ellipse (centre O, semi-axes A,B). With phi measured clockwise on screen,
sin(phi) > 0 is the near (lower) half, where the follower passes IN FRONT of the lead and carries its gap
(a ground-coloured ring cutting the lead); sin(phi) < 0 is the far (upper) half, BEHIND the lead.
The orbit passes through the rest pose of the static mark, which is where the loop starts and ends.
"""
import math

LOOP_SECONDS = 1.6          # one orbit, constant angular speed
CUTS = {                    # kit numbers: lead R, follower r, gap, follower centre minus lead centre
    "full":  dict(R=348.3,  r=167.18, gap=56.0,  rest=(279.68 - 548.2, 687.87 - 506.75),  fillet=10.0,
                  a=1.40),  # a = horizontal semi-axis in lead radii
    "small": dict(R=344.44, r=186.0,  gap=100.0, rest=(296.82 - 550.38, 665.76 - 507.32), fillet=0.0,
                  a=1.30),  # small cut: the crossing lens is < 1 px at 24 px, so the orbit can be tighter
}
TILT_OY = -0.22             # orbit centre above the lead centre (lead radii): far arc stays peeking over the rim
DEPTH_K = 0.20              # perspective: scale ~ 1 + K sin(phi), normalised to 1 at the rest pose
GAP_WINDOW = 0.35           # gap closes smoothly over sin(phi) in (0, W) before the follower goes behind
HALF_BOX = 672.0            # every cut is scaled to fill a view box of this half-size (lead centre at the origin)

COLORS = {
    "day":  dict(lead="#3B1FD1", follower="#14C79A", ground="#F5F5F7"),
    "dark": dict(lead="#6D55FF", follower="#2FE0B2", ground="#1C1C1E"),
}


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


class Orbit:
    def __init__(self, cut="full"):
        c = CUTS[cut]
        self.cut = cut
        self.R, self.r, self.gap, self.fillet = c["R"], c["r"], c["gap"], c["fillet"]
        self.rest = c["rest"]
        self.A = c["a"] * self.R
        self.O = (0.0, TILT_OY * self.R)
        u, v = self.rest[0] - self.O[0], self.rest[1] - self.O[1]
        assert abs(u) < self.A and v > 0
        self.B = v / math.sqrt(1 - (u / self.A) ** 2)
        self.phi0 = math.atan2(v / self.B, u / self.A)
        self.z0 = math.sin(self.phi0)
        # square half-extent of everything drawn over the loop (+2% margin); k scales the cut to fill HALF_BOX
        e = self.R
        for i in range(720):
            f = self.frame(i / 720)
            e = max(e, abs(f["x"]) + self.r * f["s"], abs(f["y"]) + self.r * f["s"])
        self.half = e * 1.02
        self.k = HALF_BOX / self.half

    def at_phi(self, phi):
        z = math.sin(phi)
        return dict(x=self.O[0] + self.A * math.cos(phi), y=self.O[1] + self.B * z, z=z,
                    s=(1 + DEPTH_K * z) / (1 + DEPTH_K * self.z0),
                    front=z > 0, g=smoothstep(z / GAP_WINDOW))

    def frame(self, p):
        return self.at_phi(self.phi0 + 2 * math.pi * p)

    def p_of_phi(self, phi):
        return ((phi - self.phi0) / (2 * math.pi)) % 1.0


def frame_svg(o, p, size, scheme="day", half=None):
    """static frame as plain SVG (ground-ring method, as in the web version) - used by self-checks"""
    col = COLORS[scheme]
    half = half or o.half
    f = o.frame(p)
    r, s = o.r, f["s"]
    ring = (f'<circle cx="{f["x"]:.2f}" cy="{f["y"]:.2f}" r="{(r + o.gap * f["g"]) * s:.2f}" fill="{col["ground"]}"/>' if f["front"] else "")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="{-half} {-half} {2*half} {2*half}">'
            f'<rect x="{-half}" y="{-half}" width="{2*half}" height="{2*half}" fill="{col["ground"]}"/>'
            f'<circle cx="{f["x"]:.2f}" cy="{f["y"]:.2f}" r="{r*s:.2f}" fill="{col["follower"]}"/>'
            f'<clipPath id="c"><circle r="{o.R}"/></clipPath><circle r="{o.R}" fill="{col["lead"]}"/>'
            f'<g clip-path="url(#c)">{ring}</g>'
            + (f'<circle cx="{f["x"]:.2f}" cy="{f["y"]:.2f}" r="{r*s:.2f}" fill="{col["follower"]}"/>' if f["front"] else "")
            + '</svg>')


if __name__ == "__main__":
    for cut in CUTS:
        o = Orbit(cut)
        f0 = o.frame(0)
        assert abs(f0["x"] - o.rest[0]) < 1e-6 and abs(f0["y"] - o.rest[1]) < 1e-6 and abs(f0["s"] - 1) < 1e-9 and f0["g"] == 1
        f1 = o.frame(1.0)
        assert abs(f1["x"] - f0["x"]) < 1e-6
        ext = [0, 0, 0, 0]
        for i in range(720):
            f = o.frame(i / 720); rr = o.r * f["s"]
            ext = [min(ext[0], f["x"] - rr), min(ext[1], f["y"] - rr), max(ext[2], f["x"] + rr), max(ext[3], f["y"] + rr)]
        print(cut, f"half={o.half:.2f} k={o.k:.4f} (lead radius = {o.R * o.k / HALF_BOX:.1%} of the half box)")
        cross = [o.at_phi(0), o.at_phi(math.pi)]
        lens = [o.R + o.r * c["s"] - math.hypot(c["x"], c["y"]) for c in cross]
        print(cut, f"B/R={o.B/o.R:.3f} phi0={math.degrees(o.phi0):.1f}deg scale back/cross/front="
              f"{o.at_phi(1.5*math.pi)['s']:.3f}/{o.at_phi(0)['s']:.3f}/{o.at_phi(.5*math.pi)['s']:.3f}",
              "ext/R", [round(v / o.R, 2) for v in ext], "lens px at crossings", [round(v, 1) for v in lens],
              "fits box:", max(abs(v) for v in ext) < o.half)
