// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Render.swift - offscreen SceneKit snapshots + CoreGraphics compositing helpers.
import SceneKit
import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

final class Renderer {
    let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    var aa: SCNAntialiasingMode = .multisampling4X

    /// Transparent-background colour pass only (premultiplied sRGB RGBA).
    func render(_ rig: TandemRig, size: Int) -> CGImage { snap(rig.beauty, size) }

    func snap(_ l: TandemRig.Layer, _ size: Int, aa: SCNAntialiasingMode? = nil) -> CGImage {
        r.scene = l.scene
        r.pointOfView = l.camera
        let img = r.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: aa ?? self.aa)
        return normalise(img, size: size)
    }

    /// Colour pass + soft shadow layer. SceneKit cannot put a shadow-only plane into alpha, so each shadow light is
    /// rendered on lit white catcher planes with the mark invisible; coverage = 1 - L / Lmax becomes the alpha of a
    /// tinted layer drawn under the mark. Result is transparent-background premultiplied RGBA.
    func renderWithShadow(_ rig: TandemRig, size: Int, tint: (Double, Double, Double) = (0.03, 0.02, 0.14)) -> CGImage {
        let mark = snap(rig.beauty, size)
        guard let sh = rig.shadow, !rig.shadowLights.isEmpty else { return mark }
        let mpx = rgba(mark)
        let n = size * size
        var keep = [Double](repeating: 1, count: n)   // product of (1 - opacity*coverage)
        let weights = [rig.spec.shadowOpacity, rig.spec.shadowOpacity * 0.6]
        func lin(_ v: Double) -> Double { pow(v / 255, 2.2) }
        for j in rig.shadowLights.indices {
            for (i, node) in rig.shadowLights.enumerated() { node.isHidden = i != j }
            let px = rgba(snap(sh, size, aa: .multisampling4X))
            var mx = 1.0
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 250 { mx = max(mx, Double(px[i])) }
            var cov = [Double](repeating: 0, count: n), valid = [Bool](repeating: true, count: n)
            for i in 0..<n {
                cov[i] = px[i * 4 + 3] < 250 ? 0 : max(0, min(1, 1 - lin(Double(px[i * 4])) / lin(mx)))
                valid[i] = mpx[i * 4 + 3] == 0     // the (black) mark itself is not shadow: refill it from outside pixels
            }
            for _ in 0..<6 {
                var nc = cov, nv = valid
                for y in 1..<(size - 1) { for x in 1..<(size - 1) where !valid[y * size + x] {
                    var s = 0.0, c = 0.0
                    for dy in -1...1 { for dx in -1...1 where valid[(y + dy) * size + x + dx] { s += cov[(y + dy) * size + x + dx]; c += 1 } }
                    if c > 0 { nc[y * size + x] = s / c; nv[y * size + x] = true }
                } }
                cov = nc; valid = nv
            }
            // the PCF sampling leaves faint radial streaks: smooth them away (shadows are low-frequency anyway)
            for _ in 0..<3 { cov = boxBlur(cov, size, radius: max(2, size / 220)) }
            let w = Double(weights[min(j, weights.count - 1)])
            for i in 0..<n { keep[i] *= 1 - w * cov[i] }
        }
        var out = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let a = 1 - keep[i]
            out[i * 4] = UInt8((tint.0 * a * 255).rounded()); out[i * 4 + 1] = UInt8((tint.1 * a * 255).rounded())
            out[i * 4 + 2] = UInt8((tint.2 * a * 255).rounded()); out[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        return composite(mark, over: nil, under: fromRGBA(&out, size))
    }

    func boxBlur(_ a: [Double], _ size: Int, radius r: Int) -> [Double] {
        var t = a, o = a
        let w = Double(2 * r + 1)
        for y in 0..<size {   // horizontal, edge-clamped running sum
            var acc = 0.0
            for k in -r...r { acc += a[y * size + min(max(k, 0), size - 1)] }
            for x in 0..<size {
                t[y * size + x] = acc / w
                acc += a[y * size + min(x + r + 1, size - 1)] - a[y * size + max(x - r, 0)]
            }
        }
        for x in 0..<size {   // vertical
            var acc = 0.0
            for k in -r...r { acc += t[min(max(k, 0), size - 1) * size + x] }
            for y in 0..<size {
                o[y * size + x] = acc / w
                acc += t[min(y + r + 1, size - 1) * size + x] - t[max(y - r, 0) * size + x]
            }
        }
        return o
    }

    func normalise(_ img: NSImage, size: Int) -> CGImage {
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        let src = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }
}

/// `fg` over a solid colour (nil = keep transparency), optionally over a transparent `under` layer first.
/// Result is premultipliedLast sRGB.
func composite(_ fg: CGImage, over bg: NSColor?, under: CGImage? = nil) -> CGImage {
    let w = fg.width, h = fg.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let bg { ctx.setFillColor(bg.usingColorSpace(.sRGB)!.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    if let under { ctx.draw(under, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    ctx.draw(fg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

func rgba(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setBlendMode(.copy)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px
}

func fromRGBA(_ px: inout [UInt8], _ size: Int) -> CGImage {
    let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let d = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d), "png write failed: \(path)")
}

func readPNG(_ path: String) -> CGImage {
    let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(s, 0, nil)!
}

/// Rounded app-icon tile (824/1024, r 185) with the mark centred at `markScale` of the tile.
func iconTile(mark: CGImage, size: Int, tile: NSColor, markScale: CGFloat = 0.62, shadow: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    let t = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let rr = CGPath(roundedRect: t, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: NSColor(white: 0, alpha: 0.28).cgColor) }
    ctx.setFillColor(tile.usingColorSpace(.sRGB)!.cgColor)
    ctx.addPath(rr); ctx.fillPath()
    ctx.restoreGState()
    // the render is a 1024-canvas framing: mark spans 784 px wide there; scale so that span = markScale * 824
    let s = markScale * 824 / 784
    let side = CGFloat(size) * s
    ctx.draw(mark, in: CGRect(x: (CGFloat(size) - side) / 2, y: (CGFloat(size) - side) / 2, width: side, height: side))
    return ctx.makeImage()!
}
