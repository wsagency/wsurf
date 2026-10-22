// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// main.swift - driver. `mark3d sheet` renders a quick review sheet; other commands are added below.
import Foundation
import SceneKit
import AppKit
import AVFoundation

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "sheet"
let outDir = "out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let R = Renderer()

struct View { let name: String; var cam: TandemCamera; var wallGap: CGFloat }
func heroCam() -> TandemCamera {
    if let h = ProcessInfo.processInfo.environment["HERO"] {
        let v = h.split(separator: ",").map { CGFloat(Double($0)!) }
        return TandemCamera(yaw: v[0], pitch: v[1], fov: v[2], framing: v[3])
    }
    return TandemCamera(yaw: 28, pitch: -14, fov: 36, framing: 0.8)
}
let stillViews: [View] = [
    View(name: "front", cam: TandemCamera(yaw: 0, pitch: 0), wallGap: 0.30),
    View(name: "threeq", cam: TandemCamera(yaw: -25, pitch: 10, fov: 12, framing: 0.9), wallGap: 0.65),
    View(name: "hero", cam: heroCam(), wallGap: 0.65),
]

func spec(dark: Bool, wallGap: CGFloat = 0.65) -> TandemSpec {
    var s = TandemSpec(); s.dark = dark; s.wallGap = wallGap
    s.shadowOpacity = dark ? 0.6 : 0.30
    let env = ProcessInfo.processInfo.environment
    if let f = env["FILLET"], let v = Double(f) { s.fillet = CGFloat(v) }
    if let f = env["CHAMFER"], let v = Double(f) { s.chamfer = CGFloat(v) }
    if let f = env["SQUARE"], let v = Double(f) { s.edgeSquare = CGFloat(v) }
    if let f = env["TIP"], let v = Double(f) { s.tipRound = CGFloat(v) }
    if let f = env["LEADD"], let v = Double(f) { s.leadDepth = CGFloat(v) }
    if let f = env["FOLD"], let v = Double(f) { s.followerDepth = CGFloat(v) }
    if let f = env["LIFT"], let v = Double(f) { s.followerLift = CGFloat(v) }
    return s
}
func shadowTint(dark: Bool) -> (Double, Double, Double) { dark ? (0, 0, 0) : (0.03, 0.02, 0.14) }

/// SceneKit's USD writer omits MaterialBindingAPI and writes a constant `inputs:normal = (1,1,1)` that is not a valid
/// tangent-space normal. Round-trip through usdcat/usdzip (Xcode command line tools) to fix both; usdchecker then passes.
func fixUSDZ(_ url: URL) throws {
    func run(_ tool: String, _ a: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)"); p.arguments = a
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        precondition(p.terminationStatus == 0, "\(tool) failed"); return d
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-usd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let base = url.deletingPathExtension().lastPathComponent
    var text = String(decoding: try run("usdcat", [url.path, "--flatten"]), as: UTF8.self)
    text = text.replacingOccurrences(of: #"(?m)^(\s*)def Mesh "(\w+)"\n"#, with: "$1def Mesh \"$2\" (\n$1    prepend apiSchemas = [\"MaterialBindingAPI\"]\n$1)\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?m)^\s*normal3f inputs:normal = \(1, 1, 1\)\n"#, with: "", options: .regularExpression)
    // SceneKit writes the sRGB-encoded colour; UsdPreviewSurface constants are linear, so every other viewer would render it too light.
    let re = try NSRegularExpression(pattern: #"(color3f inputs:diffuseColor = \()([0-9.eE+-]+), ([0-9.eE+-]+), ([0-9.eE+-]+)\)"#)
    func lin(_ s: String) -> String { let v = Double(s)!; return String(format: "%.6f", v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
    for mt in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        let g = (1...4).map { String(text[Range(mt.range(at: $0), in: text)!]) }
        text.replaceSubrange(Range(mt.range, in: text)!, with: "\(g[0])\(lin(g[1])), \(lin(g[2])), \(lin(g[3])))")
    }
    let usda = tmp.appendingPathComponent("\(base).usda"), usdc = tmp.appendingPathComponent("\(base).usdc")
    try text.write(to: usda, atomically: true, encoding: .utf8)
    _ = try run("usdcat", [usda.path, "-o", usdc.path])
    try? FileManager.default.removeItem(at: url)
    _ = try run("usdzip", [url.path, usdc.path])
}

switch cmd {
case "sheet":
    let size = Int(args.count > 2 ? args[2] : "900") ?? 900
    for dark in [false, true] {
        for v in stillViews {
            let rig = TandemStudio.rig(spec: spec(dark: dark, wallGap: v.wallGap), camera: v.cam)
            let img = R.renderWithShadow(rig, size: size, tint: shadowTint(dark: dark))
            writePNG(composite(img, over: TandemColors.surface(dark: dark)), "\(outDir)/sheet-\(v.name)-\(dark ? "dark" : "light").png")
        }
    }
case "stills":
    let dir = "stills"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let size = 2048
    for v in stillViews {
        for dark in [false, true] {
            var rig = TandemStudio.rig(spec: spec(dark: dark, wallGap: v.wallGap), camera: v.cam)
            let img = R.renderWithShadow(rig, size: size, tint: shadowTint(dark: dark))
            writePNG(composite(img, over: TandemColors.surface(dark: dark)), "\(dir)/\(v.name)-\(dark ? "on-1C1C1E" : "on-F5F5F7").png")
            writePNG(img, "\(dir)/\(v.name)-transparent\(dark ? "-dark" : "").png")
            if !dark {
                var s = spec(dark: false, wallGap: v.wallGap); s.shadow = .none
                rig = TandemStudio.rig(spec: s, camera: v.cam)
                writePNG(R.render(rig, size: size), "\(dir)/\(v.name)-transparent-noshadow.png")
            }
            print("still \(v.name) \(dark ? "dark" : "light")")
        }
    }
case "icons":
    let dir = "icons"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for dark in [false, true] {
        let rig = TandemStudio.rig(spec: spec(dark: dark, wallGap: 0.30), camera: TandemCamera())
        let mark = R.renderWithShadow(rig, size: 2048, tint: shadowTint(dark: dark))
        let tile = dark ? TandemColors.surface(dark: true) : NSColor.white
        writePNG(iconTile(mark: mark, size: 1024, tile: tile), "\(dir)/icon-3d-\(dark ? "dark" : "light").png")
    }
case "turntable":
    let dir = "video"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let n = 120, fps: Int32 = 30, size = Int(args.count > 2 ? args[2] : "1080") ?? 1080
    func cam(_ t: Double) -> TandemCamera {   // gentle +-30 degree sway, 4 s, seamless (t in [0,1))
        TandemCamera(yaw: CGFloat(30 * sin(2 * .pi * t)), pitch: CGFloat(5 - 3 * sin(2 * .pi * t)), fov: 12, framing: 0.95)
    }
    for dark in [false, true] {
        var rig = TandemStudio.rig(spec: spec(dark: dark, wallGap: 0.65), camera: cam(0))
        var frames: [CGImage] = []
        let t0 = Date()
        for i in 0..<n { rig.setView(cam(Double(i) / Double(n))); frames.append(R.renderWithShadow(rig, size: size, tint: shadowTint(dark: dark))) }
        print("rendered \(n) frames (\(dark ? "dark" : "light")) in \(Int(Date().timeIntervalSince(t0))) s")
        let tag = dark ? "dark" : "light"
        try writeVideo(frames: frames, to: URL(fileURLWithPath: "\(dir)/turntable-\(tag).mp4"), codec: .h264, fps: fps, bg: TandemColors.surface(dark: dark))
        if !dark {
            do { try writeVideo(frames: frames, to: URL(fileURLWithPath: "\(dir)/turntable-alpha.mov"), codec: .hevcWithAlpha, fps: fps, bg: nil) }
            catch { print("hevcWithAlpha failed: \(error)") }
        }
        try writeGIF(frames: frames, to: URL(fileURLWithPath: "\(dir)/turntable-\(tag)-480.gif"), size: 480, bg: TandemColors.surface(dark: dark), step: 2, fps: Int(fps))
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.contains(tag) || f.contains("alpha") {
            print(f, (try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(f)")[.size]) ?? 0)
        }
        if dark || true { writePNG(composite(frames[0], over: TandemColors.surface(dark: dark)), "\(outDir)/turn-\(tag)-0.png"); writePNG(composite(frames[n / 4], over: TandemColors.surface(dark: dark)), "\(outDir)/turn-\(tag)-q.png") }
    }
case "overlay":
    // 4x zoom crops of the 2048 front silhouette: 2D SVG outline (red) over the 3D alpha (grey), at the fillet tips and the gap
    let size = 2048
    var s = spec(dark: false); s.shadow = .none
    let rig = TandemStudio.rig(spec: s, camera: TandemCamera())
    let a = rgba(R.render(rig, size: size)), b = rgba(readPNG("ref/ref2048.png"))
    func edge(_ p: [UInt8], _ x: Int, _ y: Int) -> Bool {
        func on(_ x: Int, _ y: Int) -> Bool { p[(y * size + x) * 4 + 3] > 127 }
        return on(x, y) && !(on(x - 1, y) && on(x + 1, y) && on(x, y - 1) && on(x, y + 1))
    }
    let crops: [(String, Int, Int)] = [("tip-left", 300, 800), ("tip-bottom", 790, 1546), ("bite-arc", 809, 1006)]
    let w = 240, z = 4
    for (name, cx, cy) in crops {
        var out = [UInt8](repeating: 255, count: w * z * w * z * 4)
        for y in 0..<(w * z) { for x in 0..<(w * z) {
            let sx = cx + x / z, sy = cy + y / z
            let o = (y * w * z + x) * 4
            let v = UInt8(255 - Int(a[(sy * size + sx) * 4 + 3]) * 70 / 255)   // 3D silhouette in light grey
            out[o] = v; out[o + 1] = v; out[o + 2] = v
            if edge(b, sx, sy) && (x % z == 1 || x % z == 2) && (y % z == 1 || y % z == 2) { out[o] = 235; out[o + 1] = 30; out[o + 2] = 60 }
        } }
        writePNG(fromRGBA(&out, w * z), "\(outDir)/overlay-\(name).png")
    }
case "strip":
    // pull frames from the finished MP4 (also proves it decodes)
    for tag in ["light", "dark"] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: "video/turntable-\(tag).mp4")))
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 540, height: 540)
        for k in 0..<6 {
            let t = CMTime(value: CMTimeValue(k * 20), timescale: 30)
            writePNG(try gen.copyCGImage(at: t, actualTime: nil), "\(outDir)/strip-\(tag)-\(k).png")
        }
    }
case "alphacheck":
    let asset = AVURLAsset(url: URL(fileURLWithPath: "video/turntable-alpha.mov"))
    let track = asset.tracks(withMediaType: .video)[0]
    let descs = track.formatDescriptions as! [CMFormatDescription]
    print("ContainsAlphaChannel:", CMFormatDescriptionGetExtension(descs[0], extensionKey: "ContainsAlphaChannel" as CFString) as Any, "codec", CMFormatDescriptionGetMediaSubType(descs[0]) == kCMVideoCodecType_HEVCWithAlpha ? "hvc1+alpha" : "other")
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var count = 0
    while let sb = out.copyNextSampleBuffer() {
        if count == 0 || count == 30 {
            let pb = CMSampleBufferGetImageBuffer(sb)!
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
            func a(_ x: Int, _ y: Int) -> String { let p = base + y * bpr + x * 4; return "bgra(\(p[0]),\(p[1]),\(p[2]),\(p[3]))" }
            print("frame \(count): corner", a(4, 4), "mark", a(620, 420), "shadow-ish", a(800, 900))
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        count += 1
    }
    print("frames decoded:", count)
case "yaws":
    for dark in [false, true] {
        var rig = TandemStudio.rig(spec: spec(dark: dark, wallGap: 0.65), camera: TandemCamera())
        for (k, y) in [-30.0, -15, 0, 15, 30].enumerated() {
            rig.setView(TandemCamera(yaw: CGFloat(y), pitch: 5, fov: 12, framing: 0.95))
            writePNG(composite(R.renderWithShadow(rig, size: 480, tint: shadowTint(dark: dark)), over: TandemColors.surface(dark: dark)), "\(outDir)/yaw-\(dark ? "dark" : "light")-\(k).png")
        }
    }
case "usdz":
    let dir = "usdz"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for dark in [false, true] {
        var s = spec(dark: dark); s.shadow = .none
        let url = URL(fileURLWithPath: "\(dir)/mark-3d\(dark ? "-dark" : "").usdz")
        try? FileManager.default.removeItem(at: url)
        let ok = TandemMark.exportUSDZ(spec: s, to: url)
        try fixUSDZ(url)
        let back = try SCNScene(url: url, options: nil)
        var found: [String] = []
        back.rootNode.enumerateHierarchy { n, _ in if let g = n.geometry { found.append("\(n.name ?? "?")(\(g.sources(for: .vertex).first?.vectorCount ?? 0) verts, \(g.materials.count) mat)") } }
        let (mn, mx) = back.rootNode.boundingBox
        print("\(url.lastPathComponent) written=\(ok) bytes=\((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? 0) nodes=\(found) bbox=(\(mn.x),\(mn.y),\(mn.z))-(\(mx.x),\(mx.y),\(mx.z))")
    }
case "usdzcheck":
    // sanity render of the re-imported USDZ (default lighting) next to the live scene
    for dark in [false, true] {
        var scene = try SCNScene(url: URL(fileURLWithPath: "usdz/mark-3d\(dark ? "-dark" : "").usdz"), options: nil)
        var live = false
        for pass in 0..<2 {
        if pass == 1 { var s = spec(dark: dark); s.shadow = .none; scene = TandemMark.exportScene(spec: s); live = true }
        scene.background.contents = TandemColors.surface(dark: dark)
        scene.lightingEnvironment.contents = TandemStudio.environment(exposure: 1)
        scene.lightingEnvironment.intensity = 1
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.usesOrthographicProjection = true; cam.camera!.orthographicScale = 0.11; cam.camera!.zNear = 0.01; cam.camera!.zFar = 10
        cam.position = SCNVector3(0, 0.067, 0.5); scene.rootNode.addChildNode(cam)
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 800; key.eulerAngles = SCNVector3(-0.5, -0.4, 0)
        scene.rootNode.addChildNode(key)
        R.r.scene = scene; R.r.pointOfView = cam
        writePNG(R.normalise(R.r.snapshot(atTime: 0, with: CGSize(width: 800, height: 800), antialiasingMode: .multisampling4X), size: 800), "\(outDir)/usdz-reimport-\(dark ? "dark" : "light")\(live ? "-live" : "").png")
        let px = rgba(readPNG("\(outDir)/usdz-reimport-\(dark ? "dark" : "light")\(live ? "-live" : "").png"))
        let o = (330 * 800 + 480) * 4
        print(dark ? "dark" : "light", live ? "live " : "usdz ", "lead px", px[o], px[o + 1], px[o + 2])
        }
    }
case "check":
    // front orthographic silhouette of the 3D mark vs the 2D SVG raster (ref/ref2048.png, rendered by headless Chrome)
    let size = 2048
    var spec = TandemSpec(); spec.shadow = .none
    let rig = TandemStudio.rig(spec: spec, camera: TandemCamera())
    let a = rgba(R.render(rig, size: size)), b = rgba(readPNG("ref/ref2048.png"))
    var only3d = 0, only2d = 0, both = 0, soft = 0.0
    var diff = [UInt8](repeating: 0, count: size * size * 4)
    for i in 0..<(size * size) {
        let x = a[i * 4 + 3] > 127, y = b[i * 4 + 3] > 127
        if x && y { both += 1 } else if x { only3d += 1; diff[i * 4] = 255; diff[i * 4 + 3] = 255 } else if y { only2d += 1; diff[i * 4 + 2] = 255; diff[i * 4 + 3] = 255 }
        soft += abs(Double(a[i * 4 + 3]) - Double(b[i * 4 + 3])) / 255
    }
    print("silhouette 2048: both \(both)  only3D \(only3d)  only2D \(only2d)  IoU \(Double(both) / Double(both + only3d + only2d))  soft-alpha diff area \(Int(soft)) px")
    writePNG(fromRGBA(&diff, size), "\(outDir)/check-diff.png")
case "swatch":
    for dark in [false, true] {
        var spec = TandemSpec(); spec.dark = dark; spec.shadow = .none
        let rig = TandemStudio.rig(spec: spec, camera: TandemCamera())
        let px = rgba(R.render(rig, size: 1024))
        func at(_ x: Int, _ y: Int) -> String { let o = (y * 1024 + x) * 4; return "\(px[o]),\(px[o+1]),\(px[o+2])" }
        func hexs(_ c: NSColor) -> String { let c = c.usingColorSpace(.sRGB)!; return "\(Int((c.redComponent*255).rounded())),\(Int((c.greenComponent*255).rounded())),\(Int((c.blueComponent*255).rounded()))" }
        print(dark ? "dark " : "light", "lead TL", at(450, 330), "C", at(620, 450), "BR", at(700, 650), "| target", hexs(TandemColors.lead(dark: dark)))
        print("      follower TL", at(230, 640), "C", at(280, 690), "BR", at(340, 750), "| target", hexs(TandemColors.follower(dark: dark)))
    }
default:
    print("unknown command \(cmd)")
}
