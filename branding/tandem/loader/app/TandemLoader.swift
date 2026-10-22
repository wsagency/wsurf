// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
import SwiftUI

// WSurf "Tandem" loader.
//
// The small mint follower disc orbits the big lead disc on a tilted orbit (pseudo-3D): it shrinks a little and passes
// BEHIND the lead at the top, grows and passes IN FRONT at the bottom. Whenever it is in front it carries the brand's
// gap with it, so the lead gets exactly the logo's bite. At progress 0 the frame is the static Tandem mark.
//
// Orbit numbers mirror src/model.py (the reference used for the web CSS loader): loop 1.6 s, constant angular speed.
// Drawing is a real cut (path subtraction with the logo's bite fillets), so the view works on any background.

public struct TandemLoader: View {
    public var size: CGFloat
    public var lead: Color?
    public var follower: Color?
    /// 1 = one orbit per 1.6 s.
    public var speed: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - size: side of the square view in points. Sizes up to 24 pt use the kit's small cut.
    ///   - lead/follower: default to the WSurf palette for the current colour scheme.
    public init(size: CGFloat = 24, lead: Color? = nil, follower: Color? = nil, speed: Double = 1) {
        self.size = size
        self.lead = lead
        self.follower = follower
        self.speed = speed
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            if reduceMotion {
                // No orbit: the static mark, the follower gently fading 100% -> 60% -> 100% (2.8 s).
                TandemLoaderMark(size: size, lead: lead, follower: follower, followerOpacity: 0.8 + 0.2 * cos(2 * .pi * t / 2.8))
            } else {
                TandemLoaderMark(size: size, lead: lead, follower: follower, progress: t * max(speed, 0) / TandemOrbit.loopSeconds)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One frame of the loader. `progress` 0...1 is one orbit (0 = rest pose = the static mark); values wrap.
public struct TandemLoaderMark: View {
    public var size: CGFloat
    public var lead: Color?
    public var follower: Color?
    public var progress: Double
    public var followerOpacity: Double

    @Environment(\.colorScheme) private var scheme

    public init(size: CGFloat = 24, lead: Color? = nil, follower: Color? = nil, progress: Double = 0, followerOpacity: Double = 1) {
        self.size = size
        self.lead = lead
        self.follower = follower
        self.progress = progress
        self.followerOpacity = followerOpacity
    }

    public var body: some View {
        let dark = scheme == .dark
        let leadColor = lead ?? (dark ? Color(hex: 0x6D55FF) : Color(hex: 0x3B1FD1))
        let followerColor = follower ?? (dark ? Color(hex: 0x2FE0B2) : Color(hex: 0x14C79A))
        Canvas { context, canvas in
            let orbit = canvas.width <= 24 ? TandemOrbit.small : TandemOrbit.full
            let unit = Double(min(canvas.width, canvas.height)) / (2 * orbit.half)
            context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            context.scaleBy(x: unit, y: unit)
            let f = orbit.frame(progress)
            // The follower is always drawn first: when it is behind, the lead hides it; when it is in front, the
            // bite cut into the lead reveals it.
            let rf = orbit.r * f.s
            context.fill(Path(ellipseIn: CGRect(x: f.x - rf, y: f.y - rf, width: 2 * rf, height: 2 * rf)),
                         with: .color(followerColor.opacity(followerOpacity)))
            let rb = (orbit.r + orbit.gap * f.g) * f.s
            let path = f.front ? orbit.leadPath(bite: CGPoint(x: f.x, y: f.y), biteRadius: rb, fillet: orbit.fillet * f.s * f.g) : orbit.disc
            context.fill(path, with: .color(leadColor))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Orbit model (mirror of src/model.py)

struct TandemOrbit {
    static let loopSeconds = 1.6
    private static let tiltOy = -0.22  // orbit centre above the lead centre, in lead radii
    private static let depthK = 0.20   // perspective: scale ~ 1 + K sin(phi), normalised to 1 at the rest pose
    private static let gapWindow = 0.35 // gap closes over sin(phi) in (0, W) before the follower goes behind

    /// Kit master: lead (548.2, 506.75) R 348.3, follower (279.68, 687.87) r 167.18, gap 56, bite fillet 10.
    static let full = TandemOrbit(R: 348.3, r: 167.18, gap: 56, rest: CGPoint(x: 279.68 - 548.2, y: 687.87 - 506.75), fillet: 10, a: 1.40)
    /// Kit small cut (<= 24 px): lead (550.38, 507.32) R 344.44, follower (296.82, 665.76) r 186, gap 100, no fillet.
    static let small = TandemOrbit(R: 344.44, r: 186, gap: 100, rest: CGPoint(x: 296.82 - 550.38, y: 665.76 - 507.32), fillet: 0, a: 1.30)

    let R, r, gap, fillet: Double
    /// Half-size (master units) of the square, centred on the lead, that holds the whole loop plus ~2% margin.
    let half: Double
    private let semiA, semiB, centreY, phi0, z0: Double

    init(R: Double, r: Double, gap: Double, rest: CGPoint, fillet: Double, a: Double) {
        self.R = R; self.r = r; self.gap = gap; self.fillet = fillet
        semiA = a * R
        centreY = Self.tiltOy * R
        let u = Double(rest.x), v = Double(rest.y) - centreY
        semiB = v / (1 - (u / semiA) * (u / semiA)).squareRoot()
        phi0 = atan2(v / semiB, u / semiA)
        z0 = sin(phi0)
        var e = R
        for i in 0..<720 {
            let phi = 2 * .pi * Double(i) / 720, z = sin(phi)
            let rs = r * (1 + Self.depthK * z) / (1 + Self.depthK * z0)
            e = max(e, abs(semiA * cos(phi)) + rs, abs(centreY + semiB * z) + rs)
        }
        half = e * 1.02
    }

    struct Frame { var x, y, s, g: Double; var front: Bool }

    /// progress 0 = rest pose; clockwise on screen. sin(phi) > 0 is the near half, in front of the lead.
    func frame(_ progress: Double) -> Frame {
        let p = progress - progress.rounded(.down)
        let phi = phi0 + 2 * .pi * p
        let z = sin(phi)
        let t = min(max(z / Self.gapWindow, 0), 1)
        return Frame(x: semiA * cos(phi), y: centreY + semiB * z,
                     s: (1 + Self.depthK * z) / (1 + Self.depthK * z0), g: t * t * (3 - 2 * t), front: z > 0)
    }

    var disc: Path { Path(ellipseIn: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)) }

    /// The lead disc with the follower's bite (the logo's construction: bite circle + filleted bite points).
    func leadPath(bite p: CGPoint, biteRadius rb: Double, fillet F: Double) -> Path {
        let c = CGPoint.zero
        let toLead = Self.unit(p, c)
        let inner = CGPoint(x: p.x + rb * toLead.x, y: p.y + rb * toLead.y)   // bite rim, toward the lead centre
        let far = CGPoint(x: c.x + R * toLead.x, y: c.y + R * toLead.y)       // lead rim, away from the bite
        guard let i = Self.intersections(c, R, p, rb) else {
            // no crossing: the bite is entirely outside the lead (or entirely inside it)
            return hypot(p.x, p.y) >= R ? disc : disc.subtracting(Path(ellipseIn: CGRect(x: p.x - rb, y: p.y - rb, width: 2 * rb, height: 2 * rb)))
        }
        guard F >= 0.75, let fc = Self.intersections(c, R - F, p, rb + F) else {
            var path = Path()
            path.move(to: i.0)
            Self.arc(&path, p, rb, i.0, i.1, near: inner)
            Self.arc(&path, c, R, i.1, i.0, near: far)
            path.closeSubpath()
            return path
        }
        func nearest(_ q: CGPoint) -> CGPoint { hypot(fc.0.x - q.x, fc.0.y - q.y) <= hypot(fc.1.x - q.x, fc.1.y - q.y) ? fc.0 : fc.1 }
        func tangency(_ q: CGPoint) -> (centre: CGPoint, onLead: CGPoint, onBite: CGPoint) {
            let f = nearest(q)
            let uc = Self.unit(c, f), ub = Self.unit(p, f)
            return (f, CGPoint(x: c.x + R * uc.x, y: c.y + R * uc.y), CGPoint(x: p.x + rb * ub.x, y: p.y + rb * ub.y))
        }
        let a = tangency(i.0), b = tangency(i.1)
        var path = Path()
        path.move(to: a.onLead)
        Self.arc(&path, a.centre, F, a.onLead, a.onBite, near: i.0)
        Self.arc(&path, p, rb, a.onBite, b.onBite, near: inner)
        Self.arc(&path, b.centre, F, b.onBite, b.onLead, near: i.1)
        Self.arc(&path, c, R, b.onLead, a.onLead, near: far)
        path.closeSubpath()
        return path
    }

    // MARK: circle helpers

    private static func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let d = hypot(b.x - a.x, b.y - a.y)
        return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
    }

    private static func intersections(_ o1: CGPoint, _ r1: Double, _ o2: CGPoint, _ r2: Double) -> (CGPoint, CGPoint)? {
        let dx = o2.x - o1.x, dy = o2.y - o1.y
        let d = hypot(dx, dy)
        guard d > 1e-9, d < r1 + r2, d > abs(r1 - r2) else { return nil }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(0, r1 * r1 - a * a).squareRoot()
        let mx = o1.x + a * dx / d, my = o1.y + a * dy / d
        return (CGPoint(x: mx + h * dy / d, y: my - h * dx / d), CGPoint(x: mx - h * dy / d, y: my + h * dx / d))
    }

    /// Appends the arc a -> b of circle (o, rad), taking the direction whose midpoint is nearer `near`.
    private static func arc(_ path: inout Path, _ o: CGPoint, _ rad: Double, _ a: CGPoint, _ b: CGPoint, near: CGPoint) {
        let ta = atan2(a.y - o.y, a.x - o.x), tb = atan2(b.y - o.y, b.x - o.x)
        func wrap(_ v: Double) -> Double { let m = v.truncatingRemainder(dividingBy: 2 * .pi); return m < 0 ? m + 2 * .pi : m }
        let spans = [wrap(tb - ta), -wrap(ta - tb)]
        let span = spans.min { s1, s2 in
            let m1 = CGPoint(x: o.x + rad * cos(ta + s1 / 2), y: o.y + rad * sin(ta + s1 / 2))
            let m2 = CGPoint(x: o.x + rad * cos(ta + s2 / 2), y: o.y + rad * sin(ta + s2 / 2))
            return hypot(m1.x - near.x, m1.y - near.y) < hypot(m2.x - near.x, m2.y - near.y)
        }!
        // ponytail: polyline at 0.5 deg steps (sagitta < 1e-5 of the radius); swap for Bezier arcs only if path size matters
        let steps = max(2, Int((abs(span) / (.pi / 360)).rounded(.up)))
        for k in 1...steps {
            let t = ta + span * Double(k) / Double(steps)
            path.addLine(to: CGPoint(x: o.x + rad * cos(t), y: o.y + rad * sin(t)))
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

#Preview("Tandem loader") {
    HStack(spacing: 0) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            VStack(spacing: 22) {
                HStack(alignment: .center, spacing: 22) {
                    ForEach([16, 24, 32, 48, 64], id: \.self) { TandemLoader(size: CGFloat($0)) }
                }
                TandemLoader(size: 160)
                TandemLoader(size: 96, speed: 0.5)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF5F5F7))
            .environment(\.colorScheme, scheme)
        }
    }
    .frame(width: 640, height: 420)
}
