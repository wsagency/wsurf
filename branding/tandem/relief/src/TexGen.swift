// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// TexGen.swift - procedural equirectangular textures for the WSurf Tandem planets.
// Fixed seed, 3D gradient noise sampled on the unit sphere (no seam, no pole pinching).
//
//   swiftc -O -swift-version 5 src/TexGen.swift -o build/texgen
//   build/texgen <outDir> [width=2048]          (height = width / 2)
//
// Output convention (all PNG, untagged, row 0 = north pole, u = 0..1 = longitude -180..+180):
//   *_height.png      8-bit gray   (planet: 0.5 = sea level)
//   *_height16.png    16-bit gray  (for contour shaders)
//   *_color.png       RGB          sRGB albedo
//   *_normal.png      RGB          tangent-space, OpenGL convention (R east, G north, B out)
//   planet_roughness.png, planet_clouds.png (RGBA, alpha = density)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

typealias V3 = SIMD3<Float>
let SEED: UInt64 = 20261017            // fixed: every run reproduces the same bytes

// MARK: RNG + noise ---------------------------------------------------------
struct SplitMix {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
@inline(__always) func mix64(_ a: UInt64) -> UInt64 {
    var z = a &+ 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}
@inline(__always) func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t)
}
@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

final class Perlin {
    var perm = [Int32](repeating: 0, count: 512)
    init(seed: UInt64) {
        var r = SplitMix(s: seed)
        var p = Array(0..<256).map { Int32($0) }
        for i in stride(from: 255, to: 0, by: -1) { p.swapAt(i, Int(r.next() % UInt64(i + 1))) }
        for i in 0..<512 { perm[i] = p[i & 255] }
    }
    @inline(__always) func grad(_ h: Int32, _ x: Float, _ y: Float, _ z: Float) -> Float {
        let hh = h & 15
        let u = hh < 8 ? x : y
        let v = hh < 4 ? y : (hh == 12 || hh == 14 ? x : z)
        return ((hh & 1) == 0 ? u : -u) + ((hh & 2) == 0 ? v : -v)
    }
    @inline(__always) func noise(_ p: V3) -> Float {
        let fl = p.rounded(.down)
        let xi = Int(fl.x) & 255, yi = Int(fl.y) & 255, zi = Int(fl.z) & 255
        let x = p.x - fl.x, y = p.y - fl.y, z = p.z - fl.z
        let u = x * x * x * (x * (x * 6 - 15) + 10)
        let v = y * y * y * (y * (y * 6 - 15) + 10)
        let w = z * z * z * (z * (z * 6 - 15) + 10)
        let A = Int(perm[xi]) + yi, AA = Int(perm[A]) + zi, AB = Int(perm[A + 1]) + zi
        let B = Int(perm[xi + 1]) + yi, BA = Int(perm[B]) + zi, BB = Int(perm[B + 1]) + zi
        let l0 = lerp(grad(perm[AA], x, y, z), grad(perm[BA], x - 1, y, z), u)
        let l1 = lerp(grad(perm[AB], x, y - 1, z), grad(perm[BB], x - 1, y - 1, z), u)
        let l2 = lerp(grad(perm[AA + 1], x, y, z - 1), grad(perm[BA + 1], x - 1, y, z - 1), u)
        let l3 = lerp(grad(perm[AB + 1], x, y - 1, z - 1), grad(perm[BB + 1], x - 1, y - 1, z - 1), u)
        return lerp(lerp(l0, l1, v), lerp(l2, l3, v), w)
    }
    /// fractional Brownian motion, normalised to roughly [-1, 1]
    @inline(__always) func fbm(_ p0: V3, _ oct: Int, lac: Float = 2.0, gain: Float = 0.5) -> Float {
        var p = p0, a: Float = 1, sum: Float = 0, norm: Float = 0
        for _ in 0..<oct { sum += a * noise(p); norm += a; a *= gain; p = p * lac + V3(17.3, 9.1, 5.7) }
        return sum / norm
    }
    /// ridged multifractal in [0, 1]
    @inline(__always) func ridged(_ p0: V3, _ oct: Int) -> Float {
        var p = p0, a: Float = 0.5, sum: Float = 0, w: Float = 1
        for _ in 0..<oct {
            var s = 1 - abs(noise(p)); s *= s; s *= w
            w = clamp01(s * 2); sum += s * a; a *= 0.5; p = p * 2.03 + V3(3.1, 7.7, 1.9)
        }
        return min(sum * 1.45, 1)
    }
}

// MARK: colour ---------------------------------------------------------------
func hex(_ h: UInt32) -> V3 { V3(Float((h >> 16) & 255), Float((h >> 8) & 255), Float(h & 255)) / 255 }
func mixc(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func ramp(_ stops: [(Float, V3)], _ t: Float) -> V3 {
    if t <= stops[0].0 { return stops[0].1 }
    for i in 1..<stops.count where t <= stops[i].0 {
        let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
        return mixc(c0, c1, (t - t0) / (t1 - t0))
    }
    return stops.last!.1
}

// MARK: PNG writers -----------------------------------------------------------
func writePNG(_ path: String, w: Int, h: Int, comps: Int, bits: Int, bytes: [UInt8]) {
    let cs = comps == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
    if comps == 4 { info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) }
    if bits == 16 { info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue) }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let img = CGImage(width: w, height: h, bitsPerComponent: bits, bitsPerPixel: bits * comps,
                      bytesPerRow: w * comps * bits / 8, space: cs, bitmapInfo: info, provider: provider,
                      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    precondition(CGImageDestinationFinalize(dst), "PNG write failed: \(path)")
}
@inline(__always) func q8(_ x: Float) -> UInt8 { UInt8(clamp01(x) * 255 + 0.5) }

// MARK: sphere sampling ------------------------------------------------------------
struct Frame { let p: V3, e: V3, n: V3 }
@inline(__always) func frame(u: Float, v: Float) -> Frame {
    let lon = (u - 0.5) * 2 * Float.pi, lat = (0.5 - v) * Float.pi
    let cl = cos(lat), sl = sin(lat), co = cos(lon), so = sin(lon)
    return Frame(p: V3(cl * co, sl, cl * so), e: V3(-so, 0, co), n: V3(-sl * co, cl, -sl * so))
}

struct Baked { var h: [Float]; var gx: [Float]; var gy: [Float] }   // gx/gy: d(height)/d(arc length, radius = 1)

func bake(w: Int, h: Int, fn: @escaping (V3) -> Float) -> Baked {
    let delta = 2 * Float.pi / Float(w)
    var H = [Float](repeating: 0, count: w * h), GX = H, GY = H
    H.withUnsafeMutableBufferPointer { hp in GX.withUnsafeMutableBufferPointer { gxp in GY.withUnsafeMutableBufferPointer { gyp in
        let hb = hp.baseAddress!, xb = gxp.baseAddress!, yb = gyp.baseAddress!
        DispatchQueue.concurrentPerform(iterations: h) { j in
            let v = (Float(j) + 0.5) / Float(h)
            for i in 0..<w {
                let f = frame(u: (Float(i) + 0.5) / Float(w), v: v)
                let c = fn(f.p)
                let pe = simd_normalize(f.p + f.e * delta), me = simd_normalize(f.p - f.e * delta)
                let pn = simd_normalize(f.p + f.n * delta), mn = simd_normalize(f.p - f.n * delta)
                hb[j * w + i] = c
                xb[j * w + i] = (fn(pe) - fn(me)) / (2 * delta)
                yb[j * w + i] = (fn(pn) - fn(mn)) / (2 * delta)
            }
        }
    }}}
    return Baked(h: H, gx: GX, gy: GY)
}


func normalMap(_ b: Baked, k: Float, grain: Float = 0, seed: UInt64 = 0, w: Int, h: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 3)
    let g = Perlin(seed: seed &+ 99)
    for j in 0..<h {
        let v = (Float(j) + 0.5) / Float(h)
        for i in 0..<w {
            let idx = j * w + i
            var gx = -k * b.gx[idx], gy = -k * b.gy[idx]
            if grain > 0 {   // fine ceramic grain: tiny isotropic bumps, scaled to texel size
                let f = frame(u: (Float(i) + 0.5) / Float(w), v: v)
                let q = f.p * Float(w) * 0.19
                gx += grain * g.noise(q); gy += grain * g.noise(q + V3(31.4, 15.9, 26.5))
            }
            let n = simd_normalize(V3(gx, gy, 1))
            out[idx * 3] = q8(n.x * 0.5 + 0.5); out[idx * 3 + 1] = q8(n.y * 0.5 + 0.5); out[idx * 3 + 2] = q8(n.z * 0.5 + 0.5)
        }
    }
    return out
}

func boxBlur(_ a: [Float], w: Int, h: Int, r: Int) -> [Float] {   // wraps in x, clamps in y
    var t = a, o = a
    for j in 0..<h {
        var s: Float = 0
        for d in -r...r { s += a[j * w + ((d % w) + w) % w] }
        for i in 0..<w {
            t[j * w + i] = s / Float(2 * r + 1)
            s += a[j * w + (((i + r + 1) % w) + w) % w] - a[j * w + (((i - r) % w) + w) % w]
        }
    }
    for i in 0..<w {
        var s: Float = 0
        for d in -r...r { s += t[min(max(d, 0), h - 1) * w + i] }
        for j in 0..<h {
            o[j * w + i] = s / Float(2 * r + 1)
            s += t[min(j + r + 1, h - 1) * w + i] - t[max(j - r, 0) * w + i]
        }
    }
    return o
}

// MARK: planet fields ---------------------------------------------------------------
let nC = Perlin(seed: SEED &+ 1), nW1 = Perlin(seed: SEED &+ 2), nW2 = Perlin(seed: SEED &+ 3), nW3 = Perlin(seed: SEED &+ 4)
let nM = Perlin(seed: SEED &+ 5), nV = Perlin(seed: SEED &+ 6), nK = Perlin(seed: SEED &+ 7), nCl = Perlin(seed: SEED &+ 8)

/// raw continental field c(p)  (domain-warped fBm, 8 octaves)
func planetC(_ p: V3) -> Float {
    let w = V3(nW1.fbm(p * 1.5, 4), nW2.fbm(p * 1.5 + V3(5.2, 1.3, 8.8), 4), nW3.fbm(p * 1.5 + V3(9.1, 3.3, 2.7), 4)) * 0.17
    return nC.fbm((p + w) * 1.18, 6)
}
func planetMountains(_ p: V3) -> Float { nM.ridged(p * 2.6 + V3(4, 2, 7), 5) }

struct PlanetShape { var cmin: Float, sea: Float, cmax: Float }
func planetShape() -> PlanetShape {
    var vals = [Float](); vals.reserveCapacity(512 * 256)
    for j in 0..<256 { for i in 0..<512 { vals.append(planetC(frame(u: (Float(i) + 0.5) / 512, v: (Float(j) + 0.5) / 256).p)) } }
    vals.sort()
    return PlanetShape(cmin: vals[Int(Float(vals.count) * 0.002)], sea: vals[Int(Float(vals.count) * 0.63)], cmax: vals[Int(Float(vals.count) * 0.998)])
}

func earthHeight(_ s: PlanetShape) -> (V3) -> Float {
    return { p in
        let c = planetC(p)
        if c < s.sea {
            let t = clamp01((c - s.cmin) / (s.sea - s.cmin))
            return 0.5 * powf(t, 1.5)
        }
        let a = (c - s.sea) / (s.cmax - s.sea)
        let m = planetMountains(p) * smoothstep(0.02, 0.30, a)
        let aa = a / (1 + 0.55 * a)          // soft saturation: no flat clipped plateaus
        return min(0.5 + 0.5 * (0.62 * aa * 1.55 * 0.62 + 0.46 * m), 1)
    }
}
/// Clay planet: oceans flat, two sculpted terraces, craggy detail only on the upper one
func clayPlanetHeight(_ s: PlanetShape) -> (V3) -> Float {
    return { p in
        let c = planetC(p) - s.sea
        let t1 = smoothstep(-0.020, 0.028, c)
        let t2 = smoothstep(0.20, 0.255, c)
        let m = planetMountains(p)
        let rip = nV.fbm(p * 6, 3) * 0.012
        return 0.16 + rip * (1 - t1) + 0.36 * t1 + 0.30 * t2 + 0.07 * m * t2 + 0.012 * nV.fbm(p * 9 + V3(1, 2, 3), 3) * t1
    }
}

// MARK: moon fields -----------------------------------------------------------------
let craterCells: [Float] = [0.78, 0.40, 0.21, 0.115, 0.062, 0.034]   // cell size per octave (unit-sphere radius 1)

/// returns (height, brightness): sum of procedural bowl+rim+ejecta craters on hashed 3D cells
@inline(__always) func craters(_ p: V3, depth: Float, mare: Float) -> (Float, Float) {
    var h: Float = 0, bright: Float = 0
    for (si, cell) in craterCells.enumerated() {
        let q = p / cell, base = q.rounded(.down)
        let bx = Int64(base.x), by = Int64(base.y), bz = Int64(base.z)
        let scaleMul: Float = si <= 1 ? (1 - 0.85 * mare) : (1 - 0.45 * mare)   // old basins are flooded
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            let key = mix64(UInt64(bitPattern: (bx + Int64(dx)) &* 73856093 ^ (by + Int64(dy)) &* 19349663 ^ (bz + Int64(dz)) &* 83492791) &+ UInt64(si) &* 0x1234567 &+ SEED)
            let r0 = Float(key & 0xFFFF) / 65535, r1 = Float((key >> 16) & 0xFFFF) / 65535
            let r2 = Float((key >> 32) & 0xFFFF) / 65535, r3 = Float((key >> 48) & 0xFFFF) / 65535
            if r3 > 0.80 { continue }
            let ctr = (V3(Float(bx + Int64(dx)), Float(by + Int64(dy)), Float(bz + Int64(dz))) + V3(r0, r1, r2) * 0.86 + 0.07) * cell
            let rad = cell * (0.13 + 0.23 * r3 / 0.80 * (r3 / 0.80)) * 1.15
            let rel = (p - ctr) / rad
            let wob = 1 + 0.16 * nK.noise(rel * 1.6 + V3(r0, r1, r2) * 40) + 0.07 * nK.noise(rel * 4.1 + V3(r2, r0, r1) * 40)
            let d = simd_length(rel) / wob
            if d > 2.2 { continue }
            let age = 0.30 + 0.70 * powf(r1, 0.8)                           // old craters are softened
            let amp = rad * depth * scaleMul * age
            var bowl: Float = 0
            if d < 1 {
                bowl = -(1 - d * d) * 0.95                        // parabolic floor
                bowl += 0.30 * expf(-d * d * 22)                    // central peak
                bowl *= 1 - 0.35 * (1 - clamp01(r0 * 3))           // some craters are shallower
            }
            let rim = (0.50 + 0.25 * age) * expf(-powf((d - 1.04) / (0.14 + 0.10 * (1 - age)), 2))      // raised rim
            let eject = d >= 1 ? 0.10 * expf(-(d - 1) * 2.6) : 0   // ejecta blanket
            h += (bowl + rim + eject) * amp
            if d >= 0.9 { bright += (rim * 0.28 + eject * 1.4) * scaleMul * (si >= 3 ? 1 : 0.6) * age }
            else { bright -= 0.30 * (1 - d) * scaleMul * (0.5 + 0.5 * age) }
        } } }
    }
    return (h, bright)
}
func mareMask(_ p: V3) -> Float { smoothstep(0.10, 0.34, nK.fbm(p * 0.85 + V3(2, 4, 1), 4)) }
func moonRaw(depth: Float) -> (V3) -> Float {
    return { p in
        let m = mareMask(p)
        let (c, _) = craters(p, depth: depth, mare: m)
        return c + 0.030 * nK.fbm(p * 2.1, 6) + 0.012 * nK.ridged(p * 5.3, 4) * (1 - m) - 0.020 * m
    }
}

// MARK: main ---------------------------------------------------------------------------
let argv = CommandLine.arguments
let outDir = argv.count > 1 ? argv[1] : "textures"
let W = argv.count > 2 ? Int(argv[2])! : 2048
let Hh = W / 2
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func P(_ n: String) -> String { "\(outDir)/\(n)" }
func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
let PART = ProcessInfo.processInfo.environment["PART"] ?? "all"     // all | planet | moon
let t0 = Date()
func lap(_ s: String) { log(String(format: "[%.1fs] %@", Date().timeIntervalSince(t0), s)) }

func writeHeight(_ name: String, _ h: [Float]) {
    writePNG(P("\(name)_height.png"), w: W, h: Hh, comps: 1, bits: 8, bytes: h.map { q8($0) })
    var b16 = [UInt8](repeating: 0, count: W * Hh * 2)
    for i in 0..<(W * Hh) { let v = UInt16(clamp01(h[i]) * 65535 + 0.5); b16[i * 2] = UInt8(v >> 8); b16[i * 2 + 1] = UInt8(v & 255) }
    writePNG(P("\(name)_height16.png"), w: W, h: Hh, comps: 1, bits: 16, bytes: b16)
}

// ---- planet (Earth variant) ----
if PART != "moon" {
let shape = planetShape()
lap("planet shape: cmin \(shape.cmin) sea \(shape.sea) cmax \(shape.cmax)")
let earth = bake(w: W, h: Hh, fn: earthHeight(shape))
lap("earth height baked")
writeHeight("planet", earth.h)
writeHeight("planet_topo", boxBlur(boxBlur(earth.h, w: W, h: Hh, r: max(2, W / 680)), w: W, h: Hh, r: max(2, W / 680)))   // smoothed for iso-lines
do {   // calm oceans: relief lives on the continents
    var e = earth
    for i in 0..<(W * Hh) { let k = lerp(0.16, 1, smoothstep(0.46, 0.53, earth.h[i])); e.gx[i] *= k; e.gy[i] *= k }
    writePNG(P("planet_normal.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: normalMap(e, k: 0.055, w: W, h: Hh))
}

let oceanStops: [(Float, V3)] = [(0, hex(0x1D0A86)), (0.35, hex(0x2C12B0)), (0.65, hex(0x3B1FD1)), (0.88, hex(0x5238E8)), (1.0, hex(0x6E58FF))]
let landStops: [(Float, V3)] = [(0, hex(0xA580FF)), (0.18, hex(0x8F66F6)), (0.50, hex(0xA682FF)), (0.80, hex(0xC0A2FF)), (1.0, hex(0xE0CCFF))]
var colorBytes = [UInt8](repeating: 0, count: W * Hh * 3)
var roughBytes = [UInt8](repeating: 0, count: W * Hh)
for j in 0..<Hh {
    let v = (Float(j) + 0.5) / Float(Hh)
    for i in 0..<W {
        let idx = j * W + i
        let f = frame(u: (Float(i) + 0.5) / Float(W), v: v)
        let h = earth.h[idx]
        var c: V3
        let patch = nV.fbm(f.p * 2.6, 4)                      // biome-like tint patches (stay in the violet family)
        if h < 0.5 {
            c = ramp(oceanStops, h / 0.5)
            c *= 1 + 0.05 * patch
        } else {
            let s = (h - 0.5) / 0.5
            c = ramp(landStops, s)
            c = mixc(c, hex(0xD0A8FF), clamp01(0.5 + patch * 1.1) * 0.20 * (1 - s))   // warm lilac-pink patches
            c = mixc(c, hex(0x7F94FF), clamp01(0.5 - patch * 1.1) * 0.26 * (1 - s))   // cool periwinkle patches
        }
        let lat = abs(asin(f.p.y)) * 180 / Float.pi
        let ice = smoothstep(70, 78, lat + 6 * nV.fbm(f.p * 5 + V3(3, 3, 3), 4))
        c = mixc(c, hex(0xCFC8FF), ice * 0.85)
        colorBytes[idx * 3] = q8(c.x); colorBytes[idx * 3 + 1] = q8(c.y); colorBytes[idx * 3 + 2] = q8(c.z)
        roughBytes[idx] = q8(h < 0.5 ? 0.72 : 0.90 - 0.18 * ice)
    }
}
writePNG(P("planet_color.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: colorBytes)
writePNG(P("planet_roughness.png"), w: W, h: Hh, comps: 1, bits: 8, bytes: roughBytes)
lap("earth colour/normal/roughness")

// clouds: separate RGBA map (alpha = density), warped fBm, latitude belts
var cloud = [UInt8](repeating: 0, count: W * Hh * 4)
let cloudBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: W * Hh * 4)
DispatchQueue.concurrentPerform(iterations: Hh) { j in
    let v = (Float(j) + 0.5) / Float(Hh)
    for i in 0..<W {
        let f = frame(u: (Float(i) + 0.5) / Float(W), v: v)
        let w1 = V3(nCl.fbm(f.p * 1.4, 3), nCl.fbm(f.p * 1.4 + V3(4, 5, 6), 3), nCl.fbm(f.p * 1.4 + V3(8, 1, 2), 3)) * 0.55
        let n = nCl.fbm((f.p + w1) * 2.3 + V3(1, 1, 1), 7)
        let belt = 0.10 * sin(asin(f.p.y) * 9)
        let d = smoothstep(0.16, 0.40, n + belt + 0.02)
        let a = d * 0.88
        let idx = (j * W + i) * 4
        cloudBuf[idx] = 246; cloudBuf[idx + 1] = 243; cloudBuf[idx + 2] = 255; cloudBuf[idx + 3] = q8(a)
    }
}
cloud = Array(UnsafeBufferPointer(start: cloudBuf, count: W * Hh * 4)); cloudBuf.deallocate()
writePNG(P("planet_clouds.png"), w: W, h: Hh, comps: 4, bits: 8, bytes: cloud)
lap("clouds")

// ---- planet (Clay variant) ----
let clayP = bake(w: W, h: Hh, fn: clayPlanetHeight(shape))
writeHeight("planet_clay", clayP.h)
writePNG(P("planet_clay_normal.png"), w: W, h: Hh, comps: 3, bits: 8,
         bytes: normalMap(clayP, k: 0.09, grain: 0.035, seed: SEED, w: W, h: Hh))
do {
    let blur = boxBlur(clayP.h, w: W, h: Hh, r: max(4, W / 340))
    let blur2 = boxBlur(clayP.h, w: W, h: Hh, r: max(14, W / 100))
    let g = Perlin(seed: SEED &+ 31)
    var out = [UInt8](repeating: 0, count: W * Hh * 3)
    let lo = hex(0x3B1FD1), mid = hex(0x5B42EE), hi = hex(0x7E6BFF)
    for j in 0..<Hh {
        let v = (Float(j) + 0.5) / Float(Hh)
        for i in 0..<W {
            let idx = j * W + i
            let h = clayP.h[idx]
            var c = ramp([(0.12, lo), (0.5, mid), (0.95, hi)], h)
            let ao = 1 - clamp01((blur[idx] - h) * 5.5) * 0.45 - clamp01((blur2[idx] - h) * 2.2) * 0.30     // cavities
            let cx = 1 + clamp01((h - blur[idx]) * 4.0) * 0.14                                              // convex edges catch glaze-free sheen
            let f = frame(u: (Float(i) + 0.5) / Float(W), v: v)
            let speck = 1 + 0.035 * g.noise(f.p * Float(W) * 0.31) + (mix64(UInt64(idx) &+ SEED) % 400 == 0 ? -0.10 : 0)
            c = c * ao * cx * speck
            out[idx * 3] = q8(c.x); out[idx * 3 + 1] = q8(c.y); out[idx * 3 + 2] = q8(c.z)
        }
    }
    writePNG(P("planet_clay_color.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: out)
}
lap("clay planet")

}
if PART != "planet" {
// ---- moon (Earth variant + Clay variant share the crater field; clay is deeper) ----
func bakeMoon(depth: Float) -> Baked {
    let raw = bake(w: W, h: Hh, fn: moonRaw(depth: depth))
    var s = raw.h; s.sort()
    let lo = s[Int(Float(s.count) * 0.004)], hi = s[Int(Float(s.count) * 0.996)]
    let k = 1 / (hi - lo)
    return Baked(h: raw.h.map { clamp01(($0 - lo) * k) }, gx: raw.gx.map { $0 * k }, gy: raw.gy.map { $0 * k })
}
let moon = bakeMoon(depth: 0.30)
lap("moon baked")
writeHeight("moon", moon.h)
writeHeight("moon_topo", boxBlur(boxBlur(moon.h, w: W, h: Hh, r: max(3, W / 640)), w: W, h: Hh, r: max(3, W / 640)))
writePNG(P("moon_normal.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: normalMap(moon, k: 0.060, w: W, h: Hh))
do {
    let blur = boxBlur(moon.h, w: W, h: Hh, r: max(3, W / 500))
    var out = [UInt8](repeating: 0, count: W * Hh * 3)
    let dark = hex(0x138C72), base = hex(0x38D4AB), light = hex(0xA6F4DE)
    for j in 0..<Hh {
        let v = (Float(j) + 0.5) / Float(Hh)
        for i in 0..<W {
            let idx = j * W + i
            let f = frame(u: (Float(i) + 0.5) / Float(W), v: v)
            let m = mareMask(f.p)
            let (_, br) = craters(f.p, depth: 0.30, mare: m)
            let hh = moon.h[idx]
            var c = mixc(base, hex(0x6FC9B4), 0.35 * (nK.fbm(f.p * 7, 3) * 0.5 + 0.5))      // grey-mint regolith variation
            c = mixc(c, dark, m * 0.62)                                                    // maria (dark flooded basins)
            c = mixc(c, light, clamp01(br) * 0.55)                                          // fresh ejecta / rims
            c = mixc(c, dark, clamp01(-br) * 0.65)                                          // crater floors
            c *= 0.90 + 0.20 * clamp01((hh - blur[idx]) * 14 + 0.5)                         // cavity / convexity
            out[idx * 3] = q8(c.x); out[idx * 3 + 1] = q8(c.y); out[idx * 3 + 2] = q8(c.z)
        }
    }
    writePNG(P("moon_color.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: out)
}
lap("moon colour")

let moonClay = bakeMoon(depth: 0.52)
writeHeight("moon_clay", moonClay.h)
writePNG(P("moon_clay_normal.png"), w: W, h: Hh, comps: 3, bits: 8,
         bytes: normalMap(moonClay, k: 0.10, grain: 0.035, seed: SEED &+ 5, w: W, h: Hh))
do {
    let blur = boxBlur(moonClay.h, w: W, h: Hh, r: max(4, W / 340))
    let blur2 = boxBlur(moonClay.h, w: W, h: Hh, r: max(12, W / 120))
    let g = Perlin(seed: SEED &+ 32)
    var out = [UInt8](repeating: 0, count: W * Hh * 3)
    let lo = hex(0x0E9F6F), mid = hex(0x1FC98E), hi = hex(0x55E8B0)
    for j in 0..<Hh {
        let v = (Float(j) + 0.5) / Float(Hh)
        for i in 0..<W {
            let idx = j * W + i
            let h = moonClay.h[idx]
            var c = ramp([(0.1, lo), (0.5, mid), (0.95, hi)], h)
            let ao = 1 - clamp01((blur[idx] - h) * 5.0) * 0.42 - clamp01((blur2[idx] - h) * 2.4) * 0.28
            let cx = 1 + clamp01((h - blur[idx]) * 4.0) * 0.12
            let f = frame(u: (Float(i) + 0.5) / Float(W), v: v)
            let speck = 1 + 0.035 * g.noise(f.p * Float(W) * 0.31) + (mix64(UInt64(idx) &+ SEED &+ 9) % 400 == 0 ? -0.10 : 0)
            c = c * ao * cx * speck
            out[idx * 3] = q8(c.x); out[idx * 3 + 1] = q8(c.y); out[idx * 3 + 2] = q8(c.z)
        }
    }
    writePNG(P("moon_clay_color.png"), w: W, h: Hh, comps: 3, bits: 8, bytes: out)
}
}
lap("done")

let recipe = """
{
  "seed": \(SEED), "width": \(W), "height": \(Hh),
  "noise": "improved Perlin 3D gradient noise (quintic fade, seeded permutation) sampled on the unit sphere: seamless, no pole pinching; fBm lacunarity 2.0, gain 0.5",
  "planet": {
    "continents": "fBm 6 octaves @ freq 1.18 over a domain warp (3 x fBm 4 octaves @ 1.5, amplitude 0.17)",
    "mountains": "ridged multifractal 5 octaves @ 2.6, land only, weight 0.46",
    "seaLevelQuantile": 0.63, "sea": \(planetShape().sea),
    "clouds": "warped fBm 7 octaves @ 2.3 + latitude belts, smoothstep(0.16, 0.40), alpha 0.88",
    "clay": "same continents, two sculpted terraces (smoothstep edges), flat oceans, ceramic grain in the normal map",
    "topo": "earth height box-blurred twice (smoother iso-lines)"
  },
  "moon": {
    "craters": "hashed 3D cells, 6 octaves, cell sizes \(craterCells); bowl + central peak + rim + ejecta, wobble 0.16/0.07, age softening",
    "maria": "fBm 4 octaves @ 0.85, smoothstep(0.10, 0.34)", "terrain": "fBm 6 octaves + ridged 4 octaves",
    "clay": "deeper craters (0.52 vs 0.30), ceramic grain"
  },
  "channels": "height 8-bit (planet: 0.5 = sea level) + 16-bit; normal = tangent space, OpenGL (G = north / up in the image); colour sRGB; roughness linear; clouds RGBA (alpha = density); row 0 = north pole; u 0..1 = longitude -180..180 degrees; PNGs are untagged"
}
"""
try! recipe.write(toFile: P("recipe.json"), atomically: true, encoding: .utf8)
