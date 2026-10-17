// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Video.swift - turntable encoders: AVAssetWriter (H.264 / HEVC with alpha) and ImageIO GIF.
import AVFoundation
import CoreVideo
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Frames are transparent, premultiplied sRGB RGBA CGImages of equal size. `bg` != nil flattens them first.
func writeVideo(frames: [CGImage], to url: URL, codec: AVVideoCodecType, fps: Int32 = 30, bg: NSColor?, bitrate: Int = 12_000_000) throws {
    try? FileManager.default.removeItem(at: url)
    let w = frames[0].width, h = frames[0].height
    let alpha = codec == .hevcWithAlpha
    let writer = try AVAssetWriter(outputURL: url, fileType: alpha ? .mov : .mp4)
    var settings: [String: Any] = [
        AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ]
    var props: [String: Any] = [AVVideoExpectedSourceFrameRateKey: Int(fps), AVVideoMaxKeyFrameIntervalKey: Int(fps)]
    if alpha { props[AVVideoQualityKey] = 0.8 } else { props[AVVideoAverageBitRateKey] = bitrate; props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
    settings[AVVideoCompressionPropertiesKey] = props
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
    ])
    precondition(writer.canAdd(input)); writer.add(input)
    precondition(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    for (i, f) in frames.enumerated() {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if let bg { ctx.setFillColor(bg.usingColorSpace(.sRGB)!.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.draw(f, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        precondition(adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)), "append \(i): \(String(describing: writer.error))")
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "video", code: 1) }
}

/// Looping GIF from the frames flattened on `bg`, scaled to `size` x `size`. `step` keeps every n-th frame.
func writeGIF(frames: [CGImage], to url: URL, size: Int, bg: NSColor, step: Int, fps: Int) throws {
    try? FileManager.default.removeItem(at: url)
    let picked = stride(from: 0, to: frames.count, by: step).map { frames[$0] }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, picked.count, nil) else { throw NSError(domain: "gif", code: 1) }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    // GIF delays are whole centiseconds: spread 100/fps*step (6.67 cs) as 7,7,6 so the loop is exactly (frames / fps) long
    let totalCS = Double(frames.count) / Double(fps) * 100
    var spent = 0.0
    for (i, f) in picked.enumerated() {
        let target = totalCS * Double(i + 1) / Double(picked.count)
        let cs = (target - spent).rounded(); spent += cs
        let delay = cs / 100
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setFillColor(bg.usingColorSpace(.sRGB)!.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(f, in: CGRect(x: 0, y: 0, width: size, height: size))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(dest), "gif finalize")
    // ImageIO labels the file GIF87a but writes 89a-only blocks (graphic control, NETSCAPE loop): fix the signature
    var d = try Data(contentsOf: url); d.replaceSubrange(0..<6, with: Array("GIF89a".utf8)); try d.write(to: url)
}
