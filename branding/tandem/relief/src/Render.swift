// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Render.swift - offscreen driver: stills, loops, MP4/GIF, filmstrips for TandemPlanets.
//   build/render preview <variant> <clear|dark|light> <W>x<H> <layout> <out.png> [t]
//   build/render stills            build/render loops [variant]            build/render film
// layouts: hero (square, pair centred), wide (pair on the right third), loop (full orbit)
import Foundation
import SceneKit
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB, .cacheIntermediates: false])

enum Ground: String { case clear, dark, light
    var ci: CIColor? {
        switch self {
        case .clear: return nil
        case .dark: return CIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, colorSpace: sRGB)
        case .light: return CIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, colorSpace: sRGB)
        }
    }
}
enum Layout: String { case hero, wide, loop }

func savePNG(_ img: CGImage, _ path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    precondition(CGImageDestinationFinalize(dst), "write failed \(path)")
}
func saveJPG(_ img: CGImage, _ path: String, q: Double = 0.88) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    precondition(CGImageDestinationFinalize(dst), "write failed \(path)")
}

/// One configured scene + renderer. Everything is rendered on clear, supersampled, then composited.
final class Shot {
    let ts: TandemScene
    let renderer: SCNRenderer
    let variant: TandemVariant
    var ss = 2
    var baseLine: Float
    init(_ variant: TandemVariant, dark: Bool, tweak: ((inout TandemParams) -> Void)? = nil) {
        var p = TandemParams(variant: variant, dark: dark)
        p.texturesDir = ProcessInfo.processInfo.environment["TEX"] ?? "textures"
        tweak?(&p)
        if let kv = ProcessInfo.processInfo.environment["TWEAK"] {       // dev: TWEAK="heroLongitudeDeg=90,gap=0.2"
            for pair in kv.split(separator: ",") {
                let a = pair.split(separator: "="); guard a.count == 2, let v = Double(a[1]) else { continue }
                switch a[0] {
                case "heroLongitudeDeg": p.heroLongitudeDeg = v
                case "heroPhaseDeg": p.heroPhaseDeg = v
                case "moonFaceDeg": p.moonFaceDeg = v
                case "viewElevationDeg": p.viewElevationDeg = v
                case "inclinationDeg": p.inclinationDeg = v
                case "orbitRadius": p.orbitRadius = v
                case "gap": p.gap = v
                case "shadows": p.shadows = v != 0
                case "axialTiltDeg": p.axialTiltDeg = v
                default: break
                }
            }
        }
        baseLine = p.lineWidthPx
        ts = TandemScene(p)
        renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = ts.scene
        renderer.pointOfView = ts.cameraNode
        self.variant = variant
    }

    /// planet centre / radius in output px for a layout (also adapts topographic line density to the size)
    func layout(_ l: Layout, _ size: CGSize) -> (CGPoint, CGFloat) {
        let (c, r) = rawLayout(l, size)
        let k = Float(min(1, max(0.5, (r / 700).squareRoot())))
        ts.setTopoDetail(k); baseLine = max(0.9, ts.params.lineWidthPx * k)
        return (c, r)
    }
    func rawLayout(_ l: Layout, _ size: CGSize) -> (CGPoint, CGFloat) {
        ts.setTime(0)
        let m = ts.moonNode.worldPosition
        let mx = CGFloat(m.x), my = CGFloat(m.y), mr = CGFloat(TandemScene.moonRatio)
        switch l {
        case .hero:
            let x0 = min(-1, mx - mr), x1 = max(1, mx + mr), y0 = min(-1, my - mr), y1 = max(1, my + mr)
            let R = 0.76 * min(size.width / (x1 - x0), size.height / (y1 - y0))
            let c = CGPoint(x: size.width / 2 - (x0 + x1) / 2 * R, y: size.height / 2 + (y0 + y1) / 2 * R)
            return (c, R)
        case .wide:
            let R = size.height * 0.255
            let x1 = max(1, mx + mr), y0 = min(-1, my - mr), y1 = max(1, my + mr)
            let cx = size.width - size.width * 0.06 - x1 * R
            return (CGPoint(x: cx, y: size.height / 2 + (y0 + y1) / 2 * R), R)
        case .loop:
            let reach = CGFloat(ts.params.orbitRadius) + CGFloat(TandemScene.moonRatio)
            if size.width > size.height * 1.2 {                       // wide loop: orbit sits on the right
                let R = size.height * 0.2
                return (CGPoint(x: size.width - size.width * 0.045 - reach * R, y: size.height / 2), R)
            }
            return (CGPoint(x: size.width / 2, y: size.height / 2), size.width * 0.93 / (2 * reach))
        }
    }

    /// transparent, supersampled-then-downsampled RGBA layer
    func layer(t: Double, size: CGSize, center: CGPoint, radius: CGFloat) -> CIImage {
        ts.setTime(t)
        let s = CGFloat(ss), big = CGSize(width: size.width * s, height: size.height * s)
        ts.frame(size: big, planetCenter: CGPoint(x: center.x * s, y: center.y * s), planetRadius: radius * s)
        ts.setLineWidth(baseLine * Float(ss))
        let img = renderer.snapshot(atTime: 0, with: big, antialiasingMode: .multisampling4X)
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var out = CIImage(cgImage: cg)
        if ss > 1 {
            let f = CIFilter(name: "CILanczosScaleTransform")!
            f.setValue(out, forKey: kCIInputImageKey); f.setValue(1 / s, forKey: kCIInputScaleKey); f.setValue(1, forKey: kCIInputAspectRatioKey)
            out = f.outputImage!
        }
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// glow + ground composite
    func compose(_ layer: CIImage, ground: Ground, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var img = layer
        if variant == .topographic {
            // glow comes from the bright iso-lines only: subtract the dark body fill before blurring
            let lines = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.18, y: -0.18, z: -0.18, w: 0)]).applyingFilter("CIColorClamp")
            func glow(_ sigma: Double, _ gain: Double) -> CIImage {
                let b = lines.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
                return b.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain)])
            }
            let k = Double(size.height) / 1080
            img = img.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow(3 * k, 0.85)])
            img = img.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: glow(14 * k, 0.50)])
        }
        guard let c = ground.ci else { return img }
        return img.composited(over: CIImage(color: c).cropped(to: rect))
    }

    func cgImage(_ img: CIImage, size: CGSize) -> CGImage {
        ci.createCGImage(img, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: sRGB)!
    }
    func still(t: Double = 0, size: CGSize, layout l: Layout, ground: Ground) -> CGImage {
        let (c, r) = layout(l, size)
        let lay = layer(t: t, size: size, center: c, radius: r)
        return cgImage(compose(lay, ground: ground, size: size), size: size)
    }
}

func parseSize(_ s: String) -> CGSize { let p = s.split(separator: "x").map { Double($0)! }; return CGSize(width: p[0], height: p[1]) }
func tick(_ label: String, _ t0: Date) { FileHandle.standardError.write(Data(String(format: "  %@ %.1fs\n", label, Date().timeIntervalSince(t0)).utf8)) }

@main struct Main {
    static func main() {
        let a = CommandLine.arguments
        guard a.count > 1 else { print("usage: render preview|stills|loops|film"); return }
        switch a[1] {
        case "preview":
            let v = TandemVariant(rawValue: a[2])!, g = Ground(rawValue: a[3])!, size = parseSize(a[4]), l = Layout(rawValue: a[5])!
            let t = a.count > 7 ? Double(a[7])! : 0
            let shot = Shot(v, dark: g != .light)
            let t0 = Date()
            let (c0, r0) = shot.layout(l, size); let mw = shot.ts.moonNode.worldPosition
            FileHandle.standardError.write(Data("layout center \(c0) R \(r0) moon world \(mw)\n".utf8))
            if let h = ProcessInfo.processInfo.environment["HIDE"] {
                if h.contains("glow") { shot.ts.glowNode.isHidden = true }
                if h.contains("rim") { shot.ts.rimNode.isHidden = true }
                if h.contains("cloud") { shot.ts.cloudNode.isHidden = true }
                if h.contains("planet") { shot.ts.planetNode.isHidden = true }
            }
            if ProcessInfo.processInfo.environment["NOMOON"] != nil { shot.ts.moonNode.isHidden = true; shot.ts.cutter.isHidden = true }
            let outImg = shot.still(t: t, size: size, layout: l, ground: g)
            if ProcessInfo.processInfo.environment["BBOX"] != nil {
                let w = outImg.width, h = outImg.height
                let d = outImg.dataProvider!.data! as Data
                var x0 = w, x1 = 0, y0 = h, y1 = 0
                for y in 0..<h { for x in 0..<w where d[(y * w + x) * 4 + 3] > 128 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
                FileHandle.standardError.write(Data("bbox x \(x0)...\(x1) y \(y0)...\(y1)  -> centre (\(Double(x0 + x1) / 2), \(Double(y0 + y1) / 2)) R \(Double(x1 - x0) / 2)\n".utf8))
            }
            savePNG(outImg, a[6]); tick("preview", t0)
        case "stills": Stills.run()
        case "loops": Loops.run(only: a.count > 2 ? TandemVariant(rawValue: a[2]) : nil)
        case "film": Loops.film()
        default: print("unknown command")
        }
    }
}
