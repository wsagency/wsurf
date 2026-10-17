// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Tandem3D.swift - the WSurf "Tandem" mark as a SceneKit solid.
//
// 2D source of truth: 1024 master, SVG y-down. Lead disc (548.2, 506.75) r 348.3 with a bite
// (circle around the follower centre, radius r + gap, bite points filleted r 10); follower disc
// (279.68, 687.87) r 167.18; both rest on one waterline y 855.05. This file ports that geometry
// 1:1 (exact arcs, no polylines) and extrudes it. Front silhouette == the flat mark.
//
// Why an own extruder instead of SCNShape: SceneKit silently drops the chamfer on any outline with a convex corner
// tighter than the chamfer (the r10 bite fillets vs a ~60 px edge radius) and needs CCW winding; the lead came out
// flat with seam notches, with or without fillets. RoundedSolid sweeps analytic offset outlines along an edge profile
// instead, so the silhouette stays exact and the normals are smooth.
//
// Units: scene unit = 512 master px, so the whole 1024 canvas is 2 x 2 and the mark's origin is the
// canvas centre (512, 512). All "px" parameters are master px.
import SceneKit
import AppKit

// MARK: - Parameters

public enum TandemFinish {
    case matte, satin, gloss
    var roughness: CGFloat { switch self { case .matte: 0.62; case .satin: 0.36; case .gloss: 0.2 } }
    var metalness: CGFloat { switch self { case .matte: 0.0; case .satin: 0.04; case .gloss: 0.06 } }
}

public enum TandemShadow { case none, floor, wall, both }

public struct TandemSpec {
    public var dark = false
    /// Lead thickness (master px).
    public var leadDepth: CGFloat = 132
    /// Follower thickness (master px). Slightly thicker than the lead.
    public var followerDepth: CGFloat = 156
    /// How far the follower's front face sits in front of the lead's front face (master px).
    public var followerLift: CGFloat = 34
    /// Rounded-edge radius as a fraction of each part's depth (0 = hard edge, 0.5 = full bull-nose).
    public var chamfer: CGFloat = 0.46
    /// Edge profile exponent: 2 = circular quarter round, >2 = squarer (flatter face, tighter turn), smoother highlights.
    public var edgeSquare: CGFloat = 2.5
    /// Extra tip-fillet radius (master px) reached on the front face; the silhouette keeps the exact r10.
    public var tipRound: CGFloat = 40
    public var finish: TandemFinish = .satin
    /// Bite-point fillet radius (master px). 10 = the flat mark.
    public var fillet: CGFloat = 10
    public var roughness: CGFloat? = nil
    public var metalness: CGFloat? = nil
    public var shadow: TandemShadow = .wall
    /// Distance of the shadow wall behind the lead's back face (scene units; 0.65 clears a +-30 degree sway).
    public var wallGap: CGFloat = 0.65
    public var shadowOpacity: CGFloat = 0.30
    /// Overall light level of the studio environment.
    public var exposure: CGFloat = 1.0
    public init() {}
}

public struct TandemCamera {
    /// Turntable yaw of the mark (degrees, + turns the right side away from the camera).
    public var yaw: CGFloat = 0
    /// Camera elevation (degrees, + looks down on the mark).
    public var pitch: CGFloat = 0
    /// nil = orthographic (exact silhouette); otherwise vertical field of view in degrees.
    public var fov: CGFloat? = nil
    /// Canvas fraction shown: 1.0 frames the 1024 master canvas exactly.
    public var framing: CGFloat = 1.0
    /// Look-at point, master px offset from canvas centre (x right, y up).
    public var target = CGPoint(x: 0, y: 0)
    public var distance: CGFloat = 8
    public init(yaw: CGFloat = 0, pitch: CGFloat = 0, fov: CGFloat? = nil, framing: CGFloat = 1.0) {
        self.yaw = yaw; self.pitch = pitch; self.fov = fov; self.framing = framing
    }
}

public enum TandemColors {
    public static func lead(dark: Bool) -> NSColor { dark ? hex(0x6D55FF) : hex(0x3B1FD1) }
    public static func follower(dark: Bool) -> NSColor { dark ? hex(0x2FE0B2) : hex(0x14C79A) }
    public static func surface(dark: Bool) -> NSColor { dark ? hex(0x1C1C1E) : hex(0xF5F5F7) }
    public static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

// MARK: - Exact 2D geometry (port of kit geometry.py)

typealias V2 = SIMD2<Double>
/// A closed CCW outline (constant sample count) with the outward in-plane normal at every sample.
struct Ring { var p: [V2]; var m: [V2] }

public struct TandemGeometry {
    public let lead = CGPoint(x: 548.2, y: 506.75)
    public let leadR: CGFloat = 348.3
    public let follower = CGPoint(x: 279.68, y: 687.87)
    public let followerR: CGFloat = 167.18
    public let gap: CGFloat = 56
    public var fillet: CGFloat = 10
    public let waterline: CGFloat = 855.05
    public static let unit: CGFloat = 1.0 / 512.0
    public init(fillet: CGFloat = 10) { self.fillet = fillet }

    // master px (y-down) -> scene units (y-up, canvas centre = origin)
    func s(_ x: CGFloat, _ y: CGFloat) -> V2 { V2(Double((x - 512) * Self.unit), Double((512 - y) * Self.unit)) }
    var leadC: V2 { s(lead.x, lead.y) }
    var followerC: V2 { s(follower.x, follower.y) }
    var u: Double { Double(Self.unit) }

    static func intersect(_ o1: V2, _ r1: Double, _ o2: V2, _ r2: Double) -> (V2, V2) {
        let d = o2 - o1, dd = hypot(d.x, d.y)
        let a = (r1 * r1 - r2 * r2 + dd * dd) / (2 * dd)
        let h = max(r1 * r1 - a * a, 0).squareRoot()
        let m = o1 + V2(a * d.x / dd, a * d.y / dd)
        return (V2(m.x + h * d.y / dd, m.y - h * d.x / dd), V2(m.x - h * d.y / dd, m.y + h * d.x / dd))
    }
    static func dist(_ a: V2, _ b: V2) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func unitVec(_ a: V2, _ b: V2) -> V2 { let d = dist(a, b); return V2((b.x - a.x) / d, (b.y - a.y) / d) }

    /// Start angle and signed span of the arc a -> b on circle o; of the two directions take the one whose midpoint is nearest `toward`.
    static func sweep(_ o: V2, _ rad: Double, _ a: V2, _ b: V2, toward: V2) -> (Double, Double) {
        let ta = atan2(a.y - o.y, a.x - o.x), tb = atan2(b.y - o.y, b.x - o.x)
        var best: (Double, Double)? = nil
        for pos in [true, false] {
            var sp = (tb - ta).truncatingRemainder(dividingBy: 2 * .pi); if sp < 0 { sp += 2 * .pi }
            if !pos { sp -= 2 * .pi }
            let mid = V2(o.x + rad * cos(ta + sp / 2), o.y + rad * sin(ta + sp / 2))
            let dd = dist(mid, toward)
            if best == nil || dd < best!.0 { best = (dd, sp) }
        }
        return (ta, best!.1)
    }

    /// Lead outline pulled in by `d` (scene units) with bite-point fillet radius `rho`: disc (R-d) minus bite (rb+d).
    /// d = 0, rho = fillet is the flat mark's outline exactly.
    func leadRing(d: Double, rho: Double) -> Ring {
        let nBig = 360, nBite = 240, nFil = 16
        let c = leadC, p = followerC
        let R = Double(leadR) * u - d, rb = Double(followerR + gap) * u + d, F = rho
        let ip = Self.intersect(c, R, p, rb), fp = Self.intersect(c, R - F, p, rb + F)
        let far = c + Self.unitVec(p, c) * R, inner = p + Self.unitVec(p, c) * rb
        var seg: [(fc: V2, cp: V2, bp: V2, i: V2)] = []
        for i in [ip.0, ip.1] {
            let fc = Self.dist(fp.0, i) < Self.dist(fp.1, i) ? fp.0 : fp.1
            seg.append((fc, c + Self.unitVec(c, fc) * R, p + Self.unitVec(p, fc) * rb, i))
        }
        var pts: [V2] = [], nrm: [V2] = []
        func arc(_ o: V2, _ rad: Double, _ a: V2, _ b: V2, _ toward: V2, _ n: Int, sign: Double) {
            let (t0, sp) = Self.sweep(o, rad, a, b, toward: toward)
            for j in 0..<n {
                let t = t0 + sp * Double(j) / Double(n)
                let dir = V2(cos(t), sin(t))
                pts.append(o + dir * rad); nrm.append(dir * sign)
            }
        }
        arc(seg[0].fc, F, seg[0].cp, seg[0].bp, seg[0].i, nFil, sign: 1)
        arc(p, rb, seg[0].bp, seg[1].bp, inner, nBite, sign: -1)
        arc(seg[1].fc, F, seg[1].bp, seg[1].cp, seg[1].i, nFil, sign: 1)
        arc(c, R, seg[1].cp, seg[0].cp, far, nBig, sign: 1)
        return Self.ccw(Ring(p: pts, m: nrm))
    }

    func followerRing(d: Double) -> Ring {
        let n = 400, p = followerC, r = Double(followerR) * u - d
        var pts: [V2] = [], nrm: [V2] = []
        for j in 0..<n {
            let t = 2 * Double.pi * Double(j) / Double(n), dir = V2(cos(t), sin(t))
            pts.append(p + dir * r); nrm.append(dir)
        }
        return Ring(p: pts, m: nrm)
    }

    static func ccw(_ r: Ring) -> Ring {
        var area = 0.0
        for i in 0..<r.p.count { let a = r.p[i], b = r.p[(i + 1) % r.p.count]; area += a.x * b.y - b.x * a.y }
        return area >= 0 ? r : Ring(p: r.p.reversed(), m: r.m.reversed())
    }
}

// MARK: - Rounded solid (own extruder: analytic rings + superellipse edge profile)

enum RoundedSolid {
    /// `ring(d)` = the outline pulled in `d` from the silhouette. Front/back faces are swept along the edge profile
    /// (d, z) = (c(1 - cos^e a), H - c + c sin^e a), e = 2/n, so every vertex normal is analytic. Caps by ear clipping.
    static func geometry(depth: Double, chamfer c: Double, square n: Double, steps K: Int, ring: (Double) -> Ring) -> SCNGeometry {
        let H = depth / 2, e = 2 / n
        var pos: [SCNVector3] = [], nor: [SCNVector3] = [], idx: [UInt32] = []
        var base: [Int] = [], N = 0, cap: [V2] = []
        for s in [1.0, -1.0] {
            base.append(pos.count)
            for k in 0...K {
                let a = Double(k) / Double(K) * .pi / 2, ca = cos(a), sa = sin(a)
                var nm = 1.0, nz = 0.0
                if k == K { nm = 0; nz = 1 } else if k > 0 {
                    let dpd = e * pow(ca, e - 1) * sa, dpz = e * pow(sa, e - 1) * ca, l = hypot(dpd, dpz)
                    nm = dpz / l; nz = dpd / l
                }
                let r = ring(c * (1 - pow(ca, e)))
                N = r.p.count
                if k == K && s > 0 { cap = r.p }
                let z = s * ((H - c) + c * pow(sa, e))
                for i in 0..<N {
                    pos.append(SCNVector3(r.p[i].x, r.p[i].y, z))
                    nor.append(SCNVector3(r.m[i].x * nm, r.m[i].y * nm, s * nz))
                }
            }
        }
        func at(_ f: Int, _ k: Int, _ i: Int) -> Int { base[f] + k * N + (i % N) }
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            let pa = pos[a], pb = pos[b], pc = pos[c]
            let u = SCNVector3(pb.x - pa.x, pb.y - pa.y, pb.z - pa.z), v = SCNVector3(pc.x - pa.x, pc.y - pa.y, pc.z - pa.z)
            let g = SCNVector3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
            let d = g.x * (nor[a].x + nor[b].x + nor[c].x) + g.y * (nor[a].y + nor[b].y + nor[c].y) + g.z * (nor[a].z + nor[b].z + nor[c].z)
            if d < 0 { idx += [UInt32(a), UInt32(c), UInt32(b)] } else { idx += [UInt32(a), UInt32(b), UInt32(c)] }
        }
        for f in 0..<2 { for k in 0..<K { for i in 0..<N {
            tri(at(f, k, i), at(f, k, i + 1), at(f, k + 1, i + 1)); tri(at(f, k, i), at(f, k + 1, i + 1), at(f, k + 1, i))
        } } }
        if H - c > 1e-6 { for i in 0..<N { // straight wall between the two equators
            tri(at(0, 0, i), at(0, 0, i + 1), at(1, 0, i + 1)); tri(at(0, 0, i), at(1, 0, i + 1), at(1, 0, i))
        } }
        for (a, b, c) in earClip(cap) { tri(at(0, K, a), at(0, K, b), at(0, K, c)); tri(at(1, K, a), at(1, K, b), at(1, K, c)) }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// Ear clipping of a simple CCW polygon (the flat cap). O(n^2)-ish; n is a few hundred.
    static func earClip(_ P: [V2]) -> [(Int, Int, Int)] {
        func cr(_ a: V2, _ b: V2, _ c: V2) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        func inside(_ q: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool { cr(a, b, q) > 1e-12 && cr(b, c, q) > 1e-12 && cr(c, a, q) > 1e-12 }
        var ids = Array(0..<P.count), out: [(Int, Int, Int)] = []
        while ids.count > 3 {
            var cut = -1, bestConvex = -1.0, bestJ = 0
            for j in 0..<ids.count {
                let i0 = ids[(j + ids.count - 1) % ids.count], i1 = ids[j], i2 = ids[(j + 1) % ids.count]
                let c = cr(P[i0], P[i1], P[i2])
                if c > bestConvex { bestConvex = c; bestJ = j }
                if c <= 1e-14 { continue }
                if !ids.contains(where: { $0 != i0 && $0 != i1 && $0 != i2 && inside(P[$0], P[i0], P[i1], P[i2]) }) { cut = j; break }
            }
            if cut < 0 { cut = bestJ }   // numerical fallback: clip the sharpest convex corner
            out.append((ids[(cut + ids.count - 1) % ids.count], ids[cut], ids[(cut + 1) % ids.count]))
            ids.remove(at: cut)
        }
        out.append((ids[0], ids[1], ids[2]))
        return out
    }
}

// MARK: - Mark (the two solids)

public enum TandemMark {
    public static func material(_ color: NSColor, spec: TandemSpec) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = spec.roughness ?? spec.finish.roughness
        m.metalness.contents = spec.metalness ?? spec.finish.metalness
        m.isDoubleSided = false
        return m
    }

    static func solid(lead: Bool, spec: TandemSpec, color: NSColor) -> SCNNode {
        let geo = TandemGeometry(fillet: spec.fillet), u = TandemGeometry.unit
        let depth = lead ? spec.leadDepth : spec.followerDepth
        let c = min(depth * spec.chamfer, depth * 0.5)
        let F = Double(spec.fillet * u), tip = Double(spec.tipRound * u), cc = Double(c * u)
        let g = RoundedSolid.geometry(depth: Double(depth * u), chamfer: cc, square: Double(spec.edgeSquare), steps: 28) { d in
            lead ? geo.leadRing(d: d, rho: F + tip * (d / cc) * (d / cc)) : geo.followerRing(d: d)
        }
        g.materials = [material(color, spec: spec)]
        let n = SCNNode(geometry: g)
        n.name = lead ? "lead" : "follower"
        return n
    }

    /// Node "tandem" with children "lead" and "follower". Origin = canvas centre, +z toward the viewer.
    public static func node(spec: TandemSpec) -> SCNNode {
        let u = TandemGeometry.unit
        let root = SCNNode(); root.name = "tandem"
        let lead = solid(lead: true, spec: spec, color: TandemColors.lead(dark: spec.dark))
        let fol = solid(lead: false, spec: spec, color: TandemColors.follower(dark: spec.dark))
        // lead centred on z = 0; follower front sits `followerLift` ahead of the lead's front face
        fol.position.z = (spec.leadDepth / 2 + spec.followerLift - spec.followerDepth / 2) * u
        root.addChildNode(lead); root.addChildNode(fol)
        return root
    }
}

extension TandemMark {
    /// Scene for export: just the solids (no lights/camera), scaled to `width` metres across the 1024 canvas
    /// (default 0.2 m) and lifted so the shared waterline sits on y = 0, i.e. the mark stands on the floor in AR.
    public static func exportScene(spec: TandemSpec, width: CGFloat = 0.2) -> SCNScene {
        let scene = SCNScene()
        let m = node(spec: spec)
        let k = width / 2                                   // canvas is 2 scene units wide
        m.scale = SCNVector3(k, k, k)
        m.position.y = (TandemGeometry().waterline - 512) * TandemGeometry.unit * k
        scene.rootNode.addChildNode(m)
        return scene
    }

    @discardableResult
    public static func exportUSDZ(spec: TandemSpec, to url: URL, width: CGFloat = 0.2) -> Bool {
        exportScene(spec: spec, width: width).write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }
}

// MARK: - Studio scene

public struct TandemRig {
    public struct Layer { public let scene: SCNScene; public let mark: SCNNode; public let camera: SCNNode }
    /// Colour pass: mark, lights, procedural IBL. Transparent background, no planes.
    public let beauty: Layer
    /// Shadow pass: invisible mark casting onto lit white catcher planes (see Renderer.renderWithShadow).
    public let shadow: Layer?
    public let shadowLights: [SCNNode]
    public var spec: TandemSpec
    public var cam: TandemCamera

    /// Move the camera / mark to a view (cheap; the same rig renders every frame).
    public mutating func setView(_ c: TandemCamera) {
        cam = c
        for l in [beauty] + (shadow.map { [$0] } ?? []) { TandemRig.apply(c, to: l) }
    }

    static func apply(_ c: TandemCamera, to l: Layer) {
        l.mark.eulerAngles = SCNVector3(0, c.yaw * .pi / 180, 0)
        let u = TandemGeometry.unit
        let t = SCNVector3(c.target.x * u, c.target.y * u, 0)
        let p = c.pitch * .pi / 180
        var d = c.distance
        let cm = l.camera.camera!
        if let f = c.fov {
            cm.usesOrthographicProjection = false
            cm.projectionDirection = .vertical
            cm.fieldOfView = f
            d = 1.0 / c.framing / tan(f * .pi / 360)   // framed height == canvas height at the look-at depth
        } else {
            cm.usesOrthographicProjection = true
            cm.orthographicScale = 1.0 / Double(c.framing)
        }
        l.camera.position = SCNVector3(t.x, t.y + d * sin(p), d * cos(p))
        l.camera.eulerAngles = SCNVector3(-p, 0, 0)
        cm.zNear = 0.05; cm.zFar = 200
    }
}

public enum TandemStudio {
    static func light(_ type: SCNLight.LightType, _ intensity: CGFloat, at pos: SCNVector3, temperature: CGFloat = 6500) -> SCNNode {
        let n = SCNNode(); let l = SCNLight()
        l.type = type; l.intensity = intensity; l.temperature = temperature
        n.light = l; n.position = pos
        n.look(at: SCNVector3(0, 0, 0))
        return n
    }

    public static func rig(spec: TandemSpec, camera cam: TandemCamera = TandemCamera()) -> TandemRig {
        // ---- beauty pass
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let mark = TandemMark.node(spec: spec)
        scene.rootNode.addChildNode(mark)
        scene.lightingEnvironment.contents = environment(exposure: spec.exposure)
        scene.lightingEnvironment.intensity = 0.6
        let k = spec.exposure
        let key = light(.spot, 50 * k, at: SCNVector3(-1.6, 2.2, 3.4), temperature: 6200)
        key.light!.spotInnerAngle = 30; key.light!.spotOuterAngle = 95
        key.light!.attenuationFalloffExponent = 0
        let fill = light(.directional, 260 * k, at: SCNVector3(3, -0.5, 0.1), temperature: 7600)   // near-grazing: its specular glare only appears beyond the sway
        scene.rootNode.addChildNode(key); scene.rootNode.addChildNode(fill)
        let camNode = SCNNode(); camNode.name = "camera"; camNode.camera = SCNCamera()
        scene.rootNode.addChildNode(camNode)
        let beauty = TandemRig.Layer(scene: scene, mark: mark, camera: camNode)

        // ---- shadow pass (only when something receives shadows)
        var shadowLayer: TandemRig.Layer? = nil
        var lights: [SCNNode] = []
        if spec.shadow != .none {
            let sc = SCNScene(); sc.background.contents = NSColor.clear
            let m = TandemMark.node(spec: spec)
            m.enumerateChildNodes { n, _ in
                // black and opaque: SceneKit only casts shadows from visible geometry (renderWithShadow masks it out again)
                let mat = SCNMaterial(); mat.lightingModel = .constant; mat.diffuse.contents = NSColor.black
                n.geometry?.materials = [mat]
            }
            sc.rootNode.addChildNode(m)
            let u = TandemGeometry.unit
            func catcher(_ n: SCNNode) {
                let mat = SCNMaterial(); mat.lightingModel = .lambert; mat.diffuse.contents = NSColor.white
                mat.ambient.contents = NSColor.black
                n.geometry!.materials = [mat]; sc.rootNode.addChildNode(n)
            }
            if spec.shadow == .floor || spec.shadow == .both {
                let f = SCNNode(geometry: SCNPlane(width: 16, height: 16)); f.eulerAngles.x = -.pi / 2
                f.position.y = Double((512 - TandemGeometry().waterline) * u)
                catcher(f)
            }
            if spec.shadow == .wall || spec.shadow == .both {
                let w = SCNNode(geometry: SCNPlane(width: 16, height: 16))
                w.position.z = Double(-(spec.leadDepth / 2) * u - spec.wallGap)
                catcher(w)
            }
            // (position, blur radius): a soft offset drop shadow and a wide, near-frontal halo
            for (pos, radius) in [(SCNVector3(-0.12, 0.26, 1.0), 44.0), (SCNVector3(0, 0.04, 1.0), 34.0)] {
                let n = light(.directional, 1000, at: SCNVector3(pos.x * 6, pos.y * 6, pos.z * 6))
                let l = n.light!
                l.castsShadow = true; l.shadowMode = .deferred
                l.shadowColor = NSColor.black
                l.shadowRadius = radius; l.shadowSampleCount = 64
                l.shadowMapSize = CGSize(width: 4096, height: 4096)
                // auto projection collapses on the large catcher planes (no shadow at all): fix the light's frustum instead
                l.automaticallyAdjustsShadowProjection = false
                l.orthographicScale = 3; l.zNear = 1; l.zFar = 30
                n.isHidden = true
                sc.rootNode.addChildNode(n); lights.append(n)
            }
            let cn = SCNNode(); cn.camera = SCNCamera(); sc.rootNode.addChildNode(cn)
            shadowLayer = TandemRig.Layer(scene: sc, mark: m, camera: cn)
        }
        var rig = TandemRig(beauty: beauty, shadow: shadowLayer, shadowLights: lights, spec: spec, cam: cam)
        rig.setView(cam)
        return rig
    }

    // Procedural cube-map studio. Directions use the Metal cube convention (+X,-X,+Y,-Y,+Z,-Z).
    static func radiance(_ d: SIMD3<Double>, exposure: Double) -> SIMD3<Double> {
        let y = d.y
        // soft dome, deliberately dark toward the camera (+Z) so brand colours stay saturated and the edges pick up the softboxes
        let front = max(d.z, 0)
        var c = SIMD3<Double>(repeating: (0.20 + 0.22 * max(y, 0) - 0.12 * max(-y, 0)) * (1 - 0.85 * front * front))
        func box(_ centre: SIMD3<Double>, _ tangent: SIMD3<Double>, _ hw: Double, _ hh: Double, _ soft: Double, _ power: Double) -> Double {
            let n = centre / (centre.x * centre.x + centre.y * centre.y + centre.z * centre.z).squareRoot()
            let t = tangent - n * (tangent.x * n.x + tangent.y * n.y + tangent.z * n.z)
            let tl = (t.x * t.x + t.y * t.y + t.z * t.z).squareRoot(); let tt = t / tl
            let bt = SIMD3<Double>(n.y * tt.z - n.z * tt.y, n.z * tt.x - n.x * tt.z, n.x * tt.y - n.y * tt.x)
            let dn = d.x * n.x + d.y * n.y + d.z * n.z
            if dn <= 0 { return 0 }
            let px = (d.x * tt.x + d.y * tt.y + d.z * tt.z) / dn
            let py = (d.x * bt.x + d.y * bt.y + d.z * bt.z) / dn
            func sstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double { let t = min(max((x - e0) / (e1 - e0), 0), 1); return t * t * (3 - 2 * t) }
            let ax = 1 - sstep(hw - soft, hw + soft, abs(px)), ay = 1 - sstep(hh - soft, hh + soft, abs(py))
            return ax * ay * power
        }
        let key = box(SIMD3(-0.9, 0.8, 0.6), SIMD3(0, 1, 0), 0.7, 0.45, 0.3, 3.0)           // big upper-left softbox
        let fill = box(SIMD3(1.0, 0.1, 0.3), SIMD3(0, 1, 0), 0.2, 0.7, 0.25, 0.14)          // tall right fill
        let rim = box(SIMD3(0.9, 0.3, -0.9), SIMD3(0, 1, 0), 0.12, 0.9, 0.12, 2.4)          // thin back-right strip
        let rim2 = box(SIMD3(-1.0, 0.2, -0.8), SIMD3(0, 1, 0), 0.10, 0.9, 0.12, 1.6)        // thin back-left strip
        let top = box(SIMD3(0, 1, 0.1), SIMD3(1, 0, 0), 0.9, 0.5, 0.4, 0.8)                 // overhead
        let warm = SIMD3<Double>(1.0, 0.985, 0.96), cool = SIMD3<Double>(0.96, 0.98, 1.0)
        c += warm * key + cool * fill + cool * rim + warm * rim2 + SIMD3(repeating: top)
        return c * exposure
    }

    static func environment(exposure: CGFloat) -> [NSImage] {
        let n = 256
        let faces: [(Double, Double) -> SIMD3<Double>] = [
            { u, v in SIMD3(1, -v, -u) }, { u, v in SIMD3(-1, -v, u) },
            { u, v in SIMD3(u, 1, v) }, { u, v in SIMD3(u, -1, -v) },
            { u, v in SIMD3(u, -v, 1) }, { u, v in SIMD3(-u, -v, -1) },
        ]
        return faces.map { f in
            var px = [UInt8](repeating: 255, count: n * n * 4)
            for j in 0..<n { for i in 0..<n {
                let u = (Double(i) + 0.5) / Double(n) * 2 - 1, v = (Double(j) + 0.5) / Double(n) * 2 - 1
                var d = f(u, v); let l = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot(); d /= l
                let c = radiance(d, exposure: Double(exposure))
                func enc(_ x: Double) -> UInt8 {
                    let x = min(max(x, 0), 1)
                    let s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
                    return UInt8((s * 255).rounded())
                }
                let o = (j * n + i) * 4
                px[o] = enc(c.x); px[o + 1] = enc(c.y); px[o + 2] = enc(c.z)
            } }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: n, height: n))
        }
    }
}
