// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Outputs.swift - stills, seamless loops (H.264 via AVAssetWriter), GIF encoder, filmstrip frames.
import Foundation
import SceneKit
import AppKit
import CoreImage
import AVFoundation
import CoreVideo

let FPS = 30
let LOOP_SECONDS = 8.0
let LOOP_FRAMES = Int(LOOP_SECONDS) * FPS        // 240; frame 240 == frame 0

/// default ground per variant for loops (MP4 has no alpha)
func loopGround(_ v: TandemVariant) -> Ground { v == .clay ? .light : .dark }

func ensureDir(_ p: String) { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
func fileSize(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0 }

enum Stills {
    static func run() {
        ensureDir("stills")
        let plan: [(TandemVariant, [Ground], [Ground])] = [
            (.earthMoon, [.clear, .light, .dark], [.light, .dark]),
            (.clay, [.clear, .light, .dark], [.light, .dark]),
            (.topographic, [.clear, .dark], [.dark]),
        ]
        for (v, hero, wide) in plan {
            var shots: [Bool: Shot] = [:]
            func shot(_ g: Ground) -> Shot {
                let dark = g == .dark || (g == .clear && v != .clay)
                if let s = shots[dark] { return s }
                let s = Shot(v, dark: dark); shots[dark] = s; return s
            }
            for g in hero {
                let t0 = Date()
                let img = shot(g).still(size: CGSize(width: 2048, height: 2048), layout: .hero, ground: g)
                savePNG(img, "stills/\(v.rawValue)_hero_2048_\(g.rawValue).png"); tick("\(v.rawValue) hero \(g.rawValue)", t0)
            }
            for g in wide {
                let t0 = Date()
                let img = shot(g).still(size: CGSize(width: 1920, height: 1080), layout: .wide, ground: g)
                savePNG(img, "stills/\(v.rawValue)_wide_1920x1080_\(g.rawValue).png"); tick("\(v.rawValue) wide \(g.rawValue)", t0)
            }
        }
    }
}

// MARK: H.264 ----------------------------------------------------------------------------------
final class VideoWriter {
    static let tag = ProcessInfo.processInfo.environment["VIDTAG"] ?? "709"     // 709 | none | stream (stream = 709 tags in the file only)
    let writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    let size: CGSize
    init(path: String, size: CGSize, bitrate: Int) {
        self.size = size
        try? FileManager.default.removeItem(atPath: path)
        writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoMaxKeyFrameIntervalKey: FPS, AVVideoExpectedSourceFrameRateKey: FPS],
        ]
        if VideoWriter.tag != "none" {   // "709" and "stream" write BT.709 tags into the file
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: VideoWriter.tag == "yuv709" ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        precondition(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
    }
    func append(_ img: CIImage, frame: Int) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buf = pb!
        if VideoWriter.tag == "709" || VideoWriter.tag == "yuv709" {
            CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        ci.render(img, to: buf, bounds: CGRect(origin: .zero, size: size), colorSpace: sRGB)
        if frame == 0, ProcessInfo.processInfo.environment["DEBUGPX"] != nil {
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            FileHandle.standardError.write(Data("pixel buffer BGRA at (0,0): \(p[0]) \(p[1]) \(p[2]) \(p[3])\n".utf8))
            CVPixelBufferUnlockBaseAddress(buf, .readOnly)
        }
        precondition(adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(FPS))), "append failed: \(String(describing: writer.error))")
    }
    func finish(frames: Int) {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(FPS)))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        precondition(writer.status == .completed, "finish: \(String(describing: writer.error))")
    }
}

// MARK: GIF (own encoder: global palette, ordered dither, frame deltas, LZW) --------------------------
struct RGBA8 { var w: Int, h: Int, px: [UInt8] }
func rgba8(_ img: CIImage, size: CGSize) -> RGBA8 {
    let w = Int(size.width), h = Int(size.height)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    ci.render(img, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: sRGB)
    return RGBA8(w: w, h: h, px: px)
}

func medianCut(hist: [Int], colors: Int) -> [(UInt8, UInt8, UInt8)] {
    struct Box { var bins: [Int]; var count: Int }
    func ch(_ bin: Int, _ c: Int) -> Int { c == 0 ? (bin >> 10) & 31 : (c == 1 ? (bin >> 5) & 31 : bin & 31) }
    var boxes = [Box(bins: (0..<32768).filter { hist[$0] > 0 }, count: hist.reduce(0, +))]
    while boxes.count < colors {
        guard let bi = boxes.indices.filter({ boxes[$0].bins.count > 1 }).max(by: { boxes[$0].count < boxes[$1].count }) else { break }
        let b = boxes[bi]
        var best = 0, bestRange = -1
        for c in 0..<3 { let v = b.bins.map { ch($0, c) }; let r = v.max()! - v.min()!; if r > bestRange { bestRange = r; best = c } }
        let sorted = b.bins.sorted { ch($0, best) < ch($1, best) }
        var acc = 0, cut = 1
        for (i, bin) in sorted.enumerated() { acc += hist[bin]; if acc * 2 >= b.count { cut = max(1, min(i + 1, sorted.count - 1)); break } }
        let a = Array(sorted[..<cut]), c = Array(sorted[cut...])
        boxes[bi] = Box(bins: a, count: a.reduce(0) { $0 + hist[$1] })
        boxes.append(Box(bins: c, count: c.reduce(0) { $0 + hist[$1] }))
    }
    return boxes.map { b in
        var r = 0, g = 0, bl = 0, n = 0
        for bin in b.bins { let k = hist[bin]; r += ch(bin, 0) * k; g += ch(bin, 1) * k; bl += ch(bin, 2) * k; n += k }
        n = max(n, 1)
        func e(_ v: Int) -> UInt8 { UInt8(min(255, (v * 8 / n) + 4)) }
        return (e(r), e(g), e(bl))
    }
}

func lzw(_ data: [UInt8], minCode: Int) -> [UInt8] {
    var out = [UInt8](); var cur: UInt32 = 0, nbits = 0
    func emit(_ code: Int, _ size: Int) {
        cur |= UInt32(code) << UInt32(nbits); nbits += size
        while nbits >= 8 { out.append(UInt8(cur & 255)); cur >>= 8; nbits -= 8 }
    }
    let clear = 1 << minCode, eoi = clear + 1
    var dict = [Int: Int](); dict.reserveCapacity(8192)
    var next = eoi + 1, size = minCode + 1
    emit(clear, size)
    guard var prefix = data.first.map({ Int($0) }) else { emit(eoi, size); if nbits > 0 { out.append(UInt8(cur & 255)) }; return out }
    for c in data.dropFirst() {
        let key = prefix << 8 | Int(c)
        if let code = dict[key] { prefix = code; continue }
        emit(prefix, size)
        if next < 4096 {
            dict[key] = next
            if next == (1 << size) { size += 1 }
            next += 1
        } else {
            emit(clear, size); dict.removeAll(keepingCapacity: true); next = eoi + 1; size = minCode + 1
        }
        prefix = Int(c)
    }
    emit(prefix, size); emit(eoi, size)
    if nbits > 0 { out.append(UInt8(cur & 255)) }
    return out
}

func writeGIF(frames: [RGBA8], delayCS: Int, bg: (UInt8, UInt8, UInt8), colors: Int, dither: Float, path: String) {
    let w = frames[0].w, h = frames[0].h
    // global palette from a histogram of all frames (15-bit), forced exact background entry
    var hist = [Int](repeating: 0, count: 32768)
    for f in frames { for i in stride(from: 0, to: f.px.count, by: 4) { hist[Int(f.px[i] >> 3) << 10 | Int(f.px[i + 1] >> 3) << 5 | Int(f.px[i + 2] >> 3)] += 1 } }
    var pal = medianCut(hist: hist, colors: colors - 2)
    pal.insert(bg, at: 0)                       // palette index 1 = exact ground
    pal.insert((0, 0, 0), at: 0)                // index 0 = transparent
    while pal.count < 256 { pal.append((0, 0, 0)) }
    var lut = [UInt8](repeating: 0, count: 32768)
    for bin in 0..<32768 {
        let r = Int((bin >> 10) & 31) * 8 + 4, g = Int((bin >> 5) & 31) * 8 + 4, b = Int(bin & 31) * 8 + 4
        var best = 1, bd = Int.max
        for i in 1..<(colors) { let p = pal[i]; let d = (r - Int(p.0)) * (r - Int(p.0)) + (g - Int(p.1)) * (g - Int(p.1)) + (b - Int(p.2)) * (b - Int(p.2)); if d < bd { bd = d; best = i } }
        lut[bin] = UInt8(best)
    }
    let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    func quant(_ f: RGBA8) -> [UInt8] {
        var idx = [UInt8](repeating: 1, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let r = f.px[i], g = f.px[i + 1], b = f.px[i + 2]
            if r == bg.0 && g == bg.1 && b == bg.2 { idx[y * w + x] = 1; continue }
            let t = (bayer[(y & 3) * 4 + (x & 3)] - 7.5) / 16 * dither
            func q(_ v: UInt8) -> Int { min(31, max(0, Int((Float(v) + t) / 8))) }
            idx[y * w + x] = lut[q(r) << 10 | q(g) << 5 | q(b)]
        } }
        return idx
    }
    var data = Data("GIF89a".utf8)
    func u16(_ v: Int) { data.append(UInt8(v & 255)); data.append(UInt8(v >> 8)) }
    u16(w); u16(h); data.append(0xF7); data.append(1); data.append(0)
    for p in pal { data.append(contentsOf: [p.0, p.1, p.2]) }
    data.append(contentsOf: [0x21, 0xFF, 0x0B]); data.append(contentsOf: Array("NETSCAPE2.0".utf8)); data.append(contentsOf: [3, 1, 0, 0, 0])
    var prev: [UInt8]? = nil
    for f in frames {
        let cur = quant(f)
        var x0 = 0, y0 = 0, x1 = w - 1, y1 = h - 1
        var px = cur
        if let p = prev {
            x0 = w; y0 = h; x1 = -1; y1 = -1
            for y in 0..<h { for x in 0..<w where cur[y * w + x] != p[y * w + x] { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
            if x1 < 0 { x0 = 0; y0 = 0; x1 = 0; y1 = 0 }
            for i in 0..<(w * h) where cur[i] == p[i] { px[i] = 0 }     // unchanged -> transparent
        }
        let fw = x1 - x0 + 1, fh = y1 - y0 + 1
        var crop = [UInt8](); crop.reserveCapacity(fw * fh)
        for y in y0...y1 { crop.append(contentsOf: px[(y * w + x0)...(y * w + x1)]) }
        data.append(contentsOf: [0x21, 0xF9, 4, 0x05]); u16(delayCS); data.append(0); data.append(0)     // disposal 1 + transparency flag
        data.append(0x2C); u16(x0); u16(y0); u16(fw); u16(fh); data.append(0)
        data.append(8)
        let comp = lzw(crop, minCode: 8)
        var o = 0
        while o < comp.count { let n = min(255, comp.count - o); data.append(UInt8(n)); data.append(contentsOf: comp[o..<(o + n)]); o += n }
        data.append(0)
        prev = cur
    }
    data.append(0x3B)
    try! data.write(to: URL(fileURLWithPath: path))
}

enum Loops {
    static func run(only: TandemVariant?) {
        ensureDir("loops")
        for v in TandemVariant.allCases where only == nil || only == v {
            let g = loopGround(v)
            let shot = Shot(v, dark: g == .dark)
            for (name, size) in [("1080x1080", CGSize(width: 1080, height: 1080)), ("1920x1080", CGSize(width: 1920, height: 1080))] {
                let t0 = Date()
                let (c, r) = shot.layout(.loop, size)
                let path = (ProcessInfo.processInfo.environment["LOOPDIR"] ?? "loops") + "/\(v.rawValue)_loop_\(name).mp4"
                let vw = VideoWriter(path: path, size: size, bitrate: name == "1080x1080" ? 7_000_000 : 9_000_000)
                for i in 0..<LOOP_FRAMES {
                    let lay = shot.layer(t: Double(i) / Double(FPS), size: size, center: c, radius: r)
                    vw.append(shot.compose(lay, ground: g, size: size), frame: i)
                    if i % 60 == 59 { tick("\(v.rawValue) \(name) frame \(i + 1)", t0) }
                }
                vw.finish(frames: LOOP_FRAMES)
                tick("\(path) \(fileSize(path) / 1024) KB", t0)
            }
            if v == .earthMoon { gif(shot, ground: g) }
        }
    }

    /// 480x480 GIF, 100 frames at 8 cs = exactly 8.0 s
    static func gif(_ shot: Shot, ground g: Ground, colors: Int = 128, dither: Float = 5) {
        let t0 = Date()
        let size = CGSize(width: 480, height: 480)
        let (c, r) = shot.layout(.loop, size)
        let saved = shot.ss; shot.ss = 3
        var frames = [RGBA8]()
        for i in 0..<100 {
            let lay = shot.layer(t: Double(i) * 0.08, size: size, center: c, radius: r)
            frames.append(rgba8(shot.compose(lay, ground: g, size: size), size: size))
        }
        shot.ss = saved
        let bgc = g.ci!
        let bg = (UInt8((bgc.red * 255).rounded()), UInt8((bgc.green * 255).rounded()), UInt8((bgc.blue * 255).rounded()))
        let path = "loops/earthMoon_loop_480.gif"
        writeGIF(frames: frames, delayCS: 8, bg: bg, colors: colors, dither: dither, path: path)
        tick("\(path) \(fileSize(path) / 1024) KB", t0)
    }

    /// 6 frames per loop for the proof page
    static func film() {
        ensureDir("proof")
        for v in TandemVariant.allCases {
            let g = loopGround(v), shot = Shot(v, dark: g == .dark)
            let size = CGSize(width: 540, height: 540)
            let (c, r) = shot.layout(.loop, size)
            for k in 0..<6 {
                let lay = shot.layer(t: LOOP_SECONDS * Double(k) / 6, size: size, center: c, radius: r)
                saveJPG(shot.cgImage(shot.compose(lay, ground: g, size: size), size: size), "proof/film_\(v.rawValue)_\(k).jpg", q: 0.9)
            }
            tick("film \(v.rawValue)", Date())
        }
    }
}
