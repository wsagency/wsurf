// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// TandemPlanets.swift - SceneKit builder for the WSurf Tandem mark as celestial bodies.
// Lead disc = planet (R = 1), follower disc = moon (r = 0.48 R), moon in front / lower-left in the hero pose.
//
//   var p = TandemParams(variant: .earthMoon); p.texturesDir = "textures"
//   let s = TandemScene(p)
//   s.frame(size: CGSize(width: 2048, height: 2048), planetCenter: CGPoint(x: 1024, y: 1024), planetRadius: 640)
//   s.setTime(0)            // hero pose;  s.setTime(t) for 0 <= t < loopSeconds (loops exactly)
//   renderer.scene = s.scene; renderer.pointOfView = s.cameraNode
//
// Always render on a clear background (scene.background = clear) and composite the ground afterwards:
// the gap ring around the moon is cut out of the planet with a depth-writing, colour-erasing sphere.
import Foundation
import SceneKit
import AppKit
import ImageIO
import Metal
import simd

public enum TandemVariant: String, CaseIterable {
    case earthMoon      // violet oceans, lilac continents, clouds, atmosphere; mint regolith moon
    case clay           // matte unglazed ceramic, strong sculpted relief
    case topographic    // glowing iso-lines of the height maps on a dark ground
}

public struct TandemParams {
    public var variant: TandemVariant = .earthMoon
    public var dark = true                      // light/dark ground: changes light rig and line colours
    public var loopSeconds = 8.0
    public var spinRevsPerLoop = 1.0            // planet rotation (integer -> seamless loop)
    public var orbitRevsPerLoop = 1.0           // moon orbit (integer -> seamless loop)
    public var cloudDriftRevsPerLoop = 0.0      // clouds relative to the surface (integer)
    public var inclinationDeg = 6.0             // moon orbit inclination vs the planet's orbital plane
    public var axialTiltDeg = 23.4              // planet axis tilt (pole leans right, towards camera)
    public var viewElevationDeg = 21.0          // how far the camera looks down on the orbital plane
    public var orbitRadius = 1.62               // in planet radii
    public var heroPhaseDeg = 119.0             // orbital phase at t = 0 (moon lower-left, in front)
    public var heroLongitudeDeg = 270.0           // planet rotation at t = 0
    public var moonFaceDeg = 0.0                // which moon longitude faces the camera at t = 0
    public var gap = 0.17                       // gap ring around the moon (fraction of moon radius)
    public var shadows = false                  // soft shadow-mapped key light (clay: plateaus shade the ocean, moon shades the planet)
    public var texturesDir = "textures"
    public var segments = 720                   // longitude segments of the relief meshes
    public var lineWidthPx: Float = 1.4         // topographic line width in render pixels
    public var spinPeriodSeconds: Double { loopSeconds / spinRevsPerLoop }
    public var orbitPeriodSeconds: Double { loopSeconds / orbitRevsPerLoop }
    public init(variant: TandemVariant = .earthMoon, dark: Bool = true) { self.variant = variant; self.dark = dark }
}

// MARK: texture loading -------------------------------------------------------------------
final class TexCache {
    let dir: String
    var images: [String: CGImage] = [:]
    var gray: [String: (Int, Int, [Float])] = [:]
    init(_ dir: String) { self.dir = dir }
    func image(_ name: String) -> CGImage {
        if let i = images[name] { return i }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { fatalError("missing texture \(url.path)") }
        images[name] = img; return img
    }
    /// 8- or 16-bit grayscale PNG as floats 0...1
    func grayFloats(_ name: String) -> (Int, Int, [Float]) {
        if let g = gray[name] { return g }
        let img = image(name)
        let w = img.width, h = img.height
        let data = img.dataProvider!.data! as Data
        var out = [Float](repeating: 0, count: w * h)
        let bpr = img.bytesPerRow, bpc = img.bitsPerComponent, bpp = img.bitsPerPixel / 8
        let little = img.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for j in 0..<h { for i in 0..<w {
                let o = j * bpr + i * bpp
                if bpc == 16 {
                    let a = Int(raw[o]), b = Int(raw[o + 1])
                    out[j * w + i] = Float(little ? (b << 8 | a) : (a << 8 | b)) / 65535
                } else { out[j * w + i] = Float(raw[o]) / 255 }
            } }
        }
        gray[name] = (w, h, out); return (w, h, out)
    }
    /// 16-bit height as an r16Unorm MTLTexture with mipmaps (precise iso-lines)
    func heightTexture(_ name: String, device: MTLDevice) -> MTLTexture {
        let (w, h, f) = grayFloats(name)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)!
        var u16 = f.map { UInt16(min(max($0, 0), 1) * 65535 + 0.5) }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &u16, bytesPerRow: w * 2)
        let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, be = cb.makeBlitCommandEncoder()!
        be.generateMipmaps(for: t); be.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return t
    }
}

/// box blur (wraps in x, clamps in y), used to soften displacement heights so thin slivers do not become spikes
func blurred(_ g: (Int, Int, [Float]), radius r: Int, passes: Int = 2) -> (Int, Int, [Float]) {
    let (w, h, a0) = g
    var a = a0
    for _ in 0..<passes {
        var t = a
        for j in 0..<h {
            var s: Float = 0
            for d in -r...r { s += a[j * w + ((d % w) + w) % w] }
            for i in 0..<w { t[j * w + i] = s / Float(2 * r + 1); s += a[j * w + ((i + r + 1) % w)] - a[j * w + (((i - r) % w) + w) % w] }
        }
        var o = t
        for i in 0..<w {
            var s: Float = 0
            for d in -r...r { s += t[min(max(d, 0), h - 1) * w + i] }
            for j in 0..<h { o[j * w + i] = s / Float(2 * r + 1); s += t[min(j + r + 1, h - 1) * w + i] - t[max(j - r, 0) * w + i] }
        }
        a = o
    }
    return (w, h, a)
}

// MARK: sphere mesh with optional displacement ------------------------------------------------
func sphereGeometry(radius: Float, segW: Int, segH: Int, height: (Int, Int, [Float])? = nil, amp: Float = 0, floor0: Float = 0) -> SCNGeometry {
    let nv = (segW + 1) * (segH + 1)
    var pos = [Float](repeating: 0, count: nv * 3), nor = pos, uv = [Float](repeating: 0, count: nv * 2), tan = [Float](repeating: 0, count: nv * 4)
    func sample(_ u: Float, _ v: Float) -> Float {
        guard let (w, h, d) = height else { return 0 }
        let x = u * Float(w) - 0.5, y = min(max(v * Float(h) - 0.5, 0), Float(h - 1))
        let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        func at(_ i: Int, _ j: Int) -> Float { d[min(max(j, 0), h - 1) * w + (((i % w) + w) % w)] }
        return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
    }
    for j in 0...segH {
        let v = Float(j) / Float(segH), lat = (0.5 - v) * Float.pi
        for i in 0...segW {
            let u = Float(i) / Float(segW), lon = (u - 0.5) * 2 * Float.pi
            let n = SIMD3<Float>(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
            let r = radius * (1 + amp * (max(sample(u, v), floor0) - floor0))
            let k = j * (segW + 1) + i
            pos[k * 3] = n.x * r; pos[k * 3 + 1] = n.y * r; pos[k * 3 + 2] = n.z * r
            nor[k * 3] = n.x; nor[k * 3 + 1] = n.y; nor[k * 3 + 2] = n.z
            uv[k * 2] = u; uv[k * 2 + 1] = v
            tan[k * 4] = -sin(lon); tan[k * 4 + 1] = 0; tan[k * 4 + 2] = cos(lon); tan[k * 4 + 3] = 1
        }
    }
    var idx = [UInt32](); idx.reserveCapacity(segW * segH * 6)
    for j in 0..<segH { for i in 0..<segW {
        let a = UInt32(j * (segW + 1) + i), b = a + 1, c = a + UInt32(segW + 1), d = c + 1
        idx += [a, b, c, b, d, c]
    } }
    func src(_ a: [Float], _ s: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
        SCNGeometrySource(data: a.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: s, vectorCount: a.count / comps,
                          usesFloatComponents: true, componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: comps * 4)
    }
    let el = SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
    return SCNGeometry(sources: [src(pos, .vertex, 3), src(nor, .normal, 3), src(uv, .texcoord, 2), src(tan, .tangent, 4)], elements: [el])
}

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
/// sRGB hex -> linear float3 (SceneKit shader code works in linear light and encodes on output)
func vec3(_ hex: UInt32) -> SCNVector3 {
    func lin(_ v: UInt32) -> CGFloat { let c = CGFloat(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return SCNVector3(lin((hex >> 16) & 255), lin((hex >> 8) & 255), lin(hex & 255))
}

// MARK: the scene -----------------------------------------------------------------------------
public final class TandemScene {
    public let params: TandemParams
    public let scene = SCNScene()
    public let cameraNode = SCNNode()
    let ecliptic = SCNNode(), orbitPlane = SCNNode(), moonPivot = SCNNode(), moonNode = SCNNode()
    let planetTilt = SCNNode(), planetSpin = SCNNode(), cloudSpin = SCNNode()
    let planetNode = SCNNode(), cloudNode = SCNNode(), rimNode = SCNNode(), glowNode = SCNNode(), cutter = SCNNode()
    let device = MTLCreateSystemDefaultDevice()!
    let tex: TexCache
    public static let moonRatio: Float = 0.48
    public let keyDir = SIMD3<Float>(0.72, -0.44, -0.54)     // direction the key light travels (from upper-left, front)
    var topoMaterials: [SCNMaterial] = []

    public init(_ p: TandemParams) {
        params = p
        tex = TexCache(p.texturesDir)
        scene.background.contents = NSColor.clear
        buildHierarchy()
        switch p.variant {
        case .earthMoon: buildEarth()
        case .clay: buildClay()
        case .topographic: buildTopo()
        }
        buildLights()
        setTime(0)
    }

    // ---- hierarchy -----------------------------------------------------------------------
    func buildHierarchy() {
        let p = params, R = TandemScene.moonRatio
        let cam = SCNCamera(); cam.zNear = 1; cam.zFar = 200; cam.fieldOfView = 20
        cameraNode.camera = cam; cameraNode.position = SCNVector3(0, 0, 24)
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(ecliptic)
        ecliptic.eulerAngles.x = CGFloat(p.viewElevationDeg * .pi / 180)
        ecliptic.addChildNode(planetTilt)
        planetTilt.eulerAngles.z = CGFloat(-p.axialTiltDeg * .pi / 180)
        planetTilt.addChildNode(planetSpin); planetTilt.addChildNode(cloudSpin)
        planetSpin.addChildNode(planetNode); cloudSpin.addChildNode(cloudNode)
        ecliptic.addChildNode(rimNode); ecliptic.addChildNode(glowNode)

        ecliptic.addChildNode(orbitPlane)
        orbitPlane.eulerAngles.z = CGFloat(p.inclinationDeg * .pi / 180)
        orbitPlane.addChildNode(moonPivot)
        moonNode.position = SCNVector3(CGFloat(p.orbitRadius), 0, 0)
        moonPivot.addChildNode(moonNode)

        // gap cutter: erases colour (and blocks later transparent shells) where it is in front of the planet
        cutter.position = moonNode.position
        cutter.geometry = SCNSphere(radius: CGFloat(R * Float(1 + p.gap)))
        (cutter.geometry as! SCNSphere).segmentCount = 64
        let m = SCNMaterial(); m.diffuse.contents = NSColor(white: 0, alpha: 0.5); m.lightingModel = .constant
        m.blendMode = .replace; m.cullMode = .front; m.writesToDepthBuffer = true; m.readsFromDepthBuffer = true
        m.shaderModifiers = [.fragment: "_output.color = float4(0.0);"]
        cutter.geometry!.firstMaterial = m
        cutter.castsShadow = false
        moonPivot.addChildNode(cutter)

        planetNode.categoryBitMask = 1; cloudNode.categoryBitMask = 1; moonNode.categoryBitMask = 2
        planetNode.renderingOrder = 10; cutter.renderingOrder = 20; moonNode.renderingOrder = 30
        glowNode.renderingOrder = 40; cloudNode.renderingOrder = 45; rimNode.renderingOrder = 50
    }

    /// deterministic pose for time t (seconds); loops exactly every `loopSeconds`
    public func setTime(_ t: Double) {
        let p = params, f = t / p.loopSeconds
        planetSpin.eulerAngles.y = CGFloat((p.heroLongitudeDeg + 360 * p.spinRevsPerLoop * f) * .pi / 180)
        cloudSpin.eulerAngles.y = CGFloat((p.heroLongitudeDeg + 360 * (p.spinRevsPerLoop + p.cloudDriftRevsPerLoop) * f) * .pi / 180)
        moonPivot.eulerAngles.y = CGFloat((-p.heroPhaseDeg + 360 * p.orbitRevsPerLoop * f) * .pi / 180)
        moonNode.eulerAngles.y = CGFloat(p.moonFaceDeg * .pi / 180)   // tidally locked: turns with the pivot
    }

    /// planet centre / radius in output pixels; off-axis (lens shift) projection, no perspective distortion
    public func frame(size: CGSize, planetCenter: CGPoint, planetRadius: CGFloat) {
        let d = CGFloat(24), Rw: CGFloat = 1
        let tanHalf = (size.height / 2) * tan(asin(Rw / d)) / planetRadius       // tan(fovY/2)
        let near = CGFloat(1), far = CGFloat(200)
        let aspect = size.width / size.height
        let sx = (planetCenter.x - size.width / 2) / (size.width / 2)            // NDC shift
        let sy = -(planetCenter.y - size.height / 2) / (size.height / 2)
        var m = SCNMatrix4Identity
        m.m11 = 1 / (tanHalf * aspect); m.m22 = 1 / tanHalf
        m.m33 = (far + near) / (near - far); m.m34 = -1; m.m43 = 2 * far * near / (near - far); m.m44 = 0
        m.m31 = -sx; m.m32 = -sy
        cameraNode.camera!.projectionTransform = m
    }

    // ---- lights ----------------------------------------------------------------------------
    func buildLights() {
        let p = params
        func dirLight(_ dir: SIMD3<Float>, _ intensity: CGFloat, _ c: NSColor, name: String, mask: Int = 3) {
            let n = SCNNode(); n.name = name; let l = SCNLight(); l.type = .directional; l.intensity = intensity; l.color = c; l.categoryBitMask = mask
            n.light = l; n.position = SCNVector3(CGFloat(-dir.x * 30), CGFloat(-dir.y * 30), CGFloat(-dir.z * 30))
            n.look(at: SCNVector3Zero); scene.rootNode.addChildNode(n)
            if name == "key" && p.shadows {
                l.castsShadow = true; l.shadowMode = .deferred; l.shadowRadius = 10; l.shadowSampleCount = 16
                l.shadowColor = NSColor(white: 0, alpha: 0.55); l.shadowMapSize = CGSize(width: 4096, height: 4096)
                l.automaticallyAdjustsShadowProjection = true; l.shadowBias = 0.02; l.maximumShadowDistance = 60
            }
        }
        switch p.variant {
        case .earthMoon:
            dirLight(keyDir, 1650, color(0xFFFCFA), name: "key")
            dirLight(SIMD3<Float>(-0.7, 0.3, 0.55), 1000, color(0x6D55FF), name: "fillPlanet", mask: 1)   // violet fill, planet only
            dirLight(SIMD3<Float>(-0.7, 0.3, 0.55), 320, color(0x2FE0B2), name: "fillMoon", mask: 2)     // mint fill, moon only
            if p.dark { dirLight(SIMD3<Float>(0.5, -0.1, 0.85), 380, color(0x8C7BFF), name: "rim", mask: 1) }
            scene.lightingEnvironment.contents = envImage(top: 0xF2F0FA, bottom: 0x3A3848)
            scene.lightingEnvironment.intensity = 0.22
        case .clay:
            dirLight(keyDir, p.dark ? 1800 : 1650, color(0xFFF8F4), name: "key")
            dirLight(SIMD3<Float>(-0.6, 0.5, 0.6), 520, color(0xE9E4FF), name: "fill")
            scene.lightingEnvironment.contents = envImage(top: 0xFFFFFF, bottom: p.dark ? 0x4A4560 : 0xC9C6D6)
            scene.lightingEnvironment.intensity = p.dark ? 0.85 : 1.15
        case .topographic:
            break
        }
    }
    func envImage(top: UInt32, bottom: UInt32) -> CGImage {
        let w = 512, h = 256
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top).cgColor, color(bottom).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        return ctx.makeImage()!
    }

    // ---- materials --------------------------------------------------------------------------
    func setup(_ p: SCNMaterialProperty, _ contents: Any, wrap: Bool = true) {
        p.contents = contents
        p.wrapS = .repeat; p.wrapT = .clamp
        p.mipFilter = .linear; p.minificationFilter = .linear; p.magnificationFilter = .linear
        p.maxAnisotropy = 8
    }
    func pbr(diffuse: CGImage, normal: CGImage, normalIntensity: CGFloat, roughness: Any, metalness: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        setup(m.diffuse, diffuse); setup(m.normal, normal); m.normal.intensity = normalIntensity
        setup(m.roughness, roughness); m.metalness.contents = metalness
        m.isDoubleSided = false
        return m
    }

    func buildEarth() {
        let seg = params.segments
        let ph = blurred(tex.grayFloats("planet_height.png"), radius: 3)
        let pg = sphereGeometry(radius: 1, segW: seg, segH: seg / 2, height: ph, amp: 0.042, floor0: 0.5)
        pg.firstMaterial = pbr(diffuse: tex.image("planet_color.png"), normal: tex.image("planet_normal.png"), normalIntensity: 1.6, roughness: tex.image("planet_roughness.png"))
        planetNode.geometry = pg

        let mh = tex.grayFloats("moon_height.png")
        let mg = sphereGeometry(radius: TandemScene.moonRatio, segW: seg, segH: seg / 2, height: mh, amp: 0.040, floor0: 0.5)
        mg.firstMaterial = pbr(diffuse: tex.image("moon_color.png"), normal: tex.image("moon_normal.png"), normalIntensity: 1.5, roughness: 0.93)
        mg.firstMaterial!.diffuse.intensity = 0.84
        moonNode.geometry = mg

        // clouds
        let cg = sphereGeometry(radius: 1.022, segW: 360, segH: 180)
        let cm = SCNMaterial(); cm.lightingModel = .physicallyBased
        setup(cm.diffuse, tex.image("planet_clouds.png")); cm.roughness.contents = 1.0; cm.metalness.contents = 0.0
        cm.writesToDepthBuffer = false; cm.blendMode = .alpha
        cm.colorBufferWriteMask = [.red, .green, .blue]       // blended over opaque ground: never lower the destination alpha
        cg.firstMaterial = cm; cloudNode.geometry = cg

        // atmosphere: thin fresnel rim on the shell + soft outer glow (back faces)
        let rimG = sphereGeometry(radius: 1.022, segW: 180, segH: 90)
        rimG.firstMaterial = atmosphere(noAlphaWrite: true, tint: params.dark ? 0x8472FF : 0x5B3FEA, power: 3.0, strength: params.dark ? 1.1 : 0.9, backFaces: false, limb: 0)
        rimNode.geometry = rimG
        let glowG = sphereGeometry(radius: 1.26, segW: 180, segH: 90)
        glowG.firstMaterial = atmosphere(tint: params.dark ? 0x6D55FF : 0x7C68FF, power: 4.0, strength: params.dark ? 0.26 : 0.16, backFaces: true, limb: Float(sqrt(1 - 1 / (1.26 * 1.26))))
        glowNode.geometry = glowG
    }

    func atmosphere(noAlphaWrite: Bool = false, tint: UInt32, power: Float, strength: Float, backFaces: Bool, limb: Float) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor(white: 0, alpha: 0.5)
        m.writesToDepthBuffer = false; m.blendMode = .alpha; m.isDoubleSided = false
        m.transparency = 0.999          // keeps SceneKit on its blended (non-opaque) pipeline
        m.cullMode = backFaces ? .front : .back
        if noAlphaWrite { m.colorBufferWriteMask = [.red, .green, .blue] }
        let l = viewSpaceLight()
        m.setValue(vec3(tint), forKey: "tint"); m.setValue(NSNumber(value: power), forKey: "power")
        m.setValue(NSNumber(value: strength), forKey: "strength"); m.setValue(NSNumber(value: limb), forKey: "limb")
        m.setValue(SCNVector3(CGFloat(l.x), CGFloat(l.y), CGFloat(l.z)), forKey: "lightV")
        m.shaderModifiers = [.fragment: """
        #pragma arguments
        float3 tint;
        float power;
        float strength;
        float limb;
        float3 lightV;
        #pragma body
        float3 n = normalize(_surface.normal);
        float3 v = normalize(_surface.view);
        float ndv = abs(dot(n, v));
        float f = limb > 0.0 ? pow(saturate(ndv / limb), power) : pow(1.0 - saturate(ndv), power) * smoothstep(0.0, 0.34, ndv);
        float lit = 0.30 + 0.70 * saturate(dot(n, lightV) * 0.9 + 0.35);
        float a = saturate(f * strength * lit);
        _output.color = float4(tint * a, a);
        """]
        return m
    }
    /// direction towards the light, in camera (view) space
    func viewSpaceLight() -> SIMD3<Float> {
        // camera looks down -z with no rotation: view space == world space
        let d = -keyDir; return simd_normalize(d)
    }

    func buildClay() {
        let seg = params.segments
        let ph = tex.grayFloats("planet_clay_height.png")
        let pg = sphereGeometry(radius: 1, segW: seg, segH: seg / 2, height: ph, amp: 0.085, floor0: 0.16)
        let pm = pbr(diffuse: tex.image("planet_clay_color.png"), normal: tex.image("planet_clay_normal.png"), normalIntensity: 1.1, roughness: 0.88)
        pg.firstMaterial = pm; planetNode.geometry = pg
        let mh = tex.grayFloats("moon_clay_height.png")
        let mg = sphereGeometry(radius: TandemScene.moonRatio, segW: seg, segH: seg / 2, height: mh, amp: 0.10, floor0: 0.0)
        mg.firstMaterial = pbr(diffuse: tex.image("moon_clay_color.png"), normal: tex.image("moon_clay_normal.png"), normalIntensity: 1.1, roughness: 0.9)
        moonNode.geometry = mg
        mg.firstMaterial!.diffuse.intensity = 0.86
    }

    func buildTopo() {
        let seg = 360
        let l = viewSpaceLight()
        func body(_ heightFile: String, radius: Float, line: UInt32, fill: UInt32, land: UInt32, levels: Float, every: Float, offset: Float, sea: Float) -> SCNGeometry {
            let g = sphereGeometry(radius: radius, segW: seg, segH: seg / 2)
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = ProcessInfo.processInfo.environment["H8"] != nil ? (tex.image(heightFile.replacingOccurrences(of: "16", with: "")) as Any) : (tex.heightTexture(heightFile, device: device) as Any)
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .clamp
            m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear; m.diffuse.magnificationFilter = .linear; m.diffuse.maxAnisotropy = 8
            m.isDoubleSided = false
            m.setValue(NSNumber(value: levels), forKey: "levels"); m.setValue(NSNumber(value: every), forKey: "every")
            m.setValue(NSNumber(value: offset), forKey: "offset"); m.setValue(NSNumber(value: sea), forKey: "sea")
            m.setValue(vec3(land), forKey: "landCol")
            m.setValue(NSNumber(value: params.lineWidthPx), forKey: "lineW")
            m.setValue(vec3(line), forKey: "lineCol"); m.setValue(vec3(fill), forKey: "fillCol")
            m.setValue(SCNVector3(CGFloat(l.x), CGFloat(l.y), CGFloat(l.z)), forKey: "lightV")
            m.shaderModifiers = [.surface: topoShader]
            g.firstMaterial = m; topoMaterials.append(m)
            return g
        }
        planetNode.geometry = body("planet_topo_height16.png", radius: 1, line: params.dark ? 0x8F7DFF : 0x3B1FD1, fill: params.dark ? 0x26243A : 0xEDEBFA, land: params.dark ? 0x3D3868 : 0xDCD6FA, levels: 16, every: 4, offset: 0, sea: 0.5)
        moonNode.geometry = body("moon_topo_height16.png", radius: TandemScene.moonRatio, line: params.dark ? 0x3BF0BE : 0x0E9E7B, fill: params.dark ? 0x233B36 : 0xE6F6F1, land: params.dark ? 0x233B36 : 0xE6F6F1, levels: 8, every: 5, offset: 0.5, sea: -1)
        // thin outer limb ring so the bodies read as spheres even where lines fade
    }
    /// fewer iso-lines when the bodies are small on screen (k = 1: hero size, 0.5: small loop frames)
    public func setTopoDetail(_ k: Float) {
        guard topoMaterials.count == 2 else { return }
        let pl = Float(2 * Int((8 * k).rounded())), ml = Float(max(4, Int((8 * k).rounded())))
        topoMaterials[0].setValue(NSNumber(value: pl), forKey: "levels")
        topoMaterials[0].setValue(NSNumber(value: Int(pl) / 2 % 2 == 0 ? pl / 4 : pl / 2), forKey: "every")
        topoMaterials[1].setValue(NSNumber(value: ml), forKey: "levels")
        topoMaterials[1].setValue(NSNumber(value: max(3, (ml * 5 / 8).rounded())), forKey: "every")
    }
    public func setLineWidth(_ px: Float) { for m in topoMaterials { m.setValue(NSNumber(value: px), forKey: "lineW") } }

    let topoShader = """
    #pragma arguments
    float levels;
    float every;
    float offset;
    float lineW;
    float sea;
    float3 lineCol;
    float3 fillCol;
    float3 landCol;
    float3 lightV;
    #pragma body
    float hgt = _surface.diffuse.r;
    float f = hgt * levels - offset;
    float fw = max(fwidth(f), 1e-6);
    float nearest = floor(f + 0.5);
    float d = abs(f - nearest) / fw;
    float isIdx = step(fmod(nearest + 1000.0 * every, every), 0.5);
    float w = lineW * mix(1.0, 1.7, isIdx);
    float flatFade = smoothstep(0.0015, 0.006, fw);                  // no filled blobs on plateaus
    float cov = saturate(w * 0.5 + 0.5 - d) * (1.0 - smoothstep(0.16, 0.45, fw)) * flatFade;
    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    float lit = smoothstep(-0.25, 0.85, dot(n, lightV));
    float rim = pow(1.0 - saturate(dot(n, v)), 3.5);
    float land = sea > 0.0 ? smoothstep(sea - fw * 0.0, sea + 0.004, hgt) : 0.0;
    float3 body = mix(fillCol, landCol, land) * (0.62 + 0.75 * lit);
    float isCoast = sea > 0.0 ? 1.0 - smoothstep(0.0, 0.012, abs(hgt - sea)) : 0.0;
    float3 ln = lineCol * (0.42 + 0.85 * lit) * (0.82 + 0.18 * hgt) * mix(0.90, 1.12, isIdx);
    ln = mix(ln, float3(0.80, 0.77, 1.0) * (0.45 + 0.55 * lit), isCoast * 0.85);
    float3 col = mix(body, ln, cov);
    col += lineCol * rim * (0.10 + 0.35 * lit);
    col = min(col, float3(1.0));
    _surface.diffuse = float4(col, 1.0);
    """
}
