#!/usr/bin/env swift

// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

//
// Draws optional WSurf disk-image artwork and writes two PNG files.
//
//     swift Tools/make-dmg-background.swift Tools/dmg
//
// Tools/make-dmg-artwork.sh joins the two files into background.tiff.
// Release disk images use Finder's native layout and do not embed this artwork.
// The 1280x800 canvas keeps the optional composition anchored at the top left.
//

import AppKit

let width: CGFloat = 1280
let height: CGFloat = 800

let paper = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1)
let ink = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.094, alpha: 1)
let arrowColor = NSColor(srgbRed: 0.741, green: 0.741, blue: 0.776, alpha: 1)

func markPath(size: CGFloat, origin: CGPoint) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: origin.x, y: origin.y + size * 0.65))
    path.curve(to: CGPoint(x: origin.x + size * 0.5, y: origin.y + size * 0.65),
               controlPoint1: CGPoint(x: origin.x + size * 0.16, y: origin.y - size * 0.05),
               controlPoint2: CGPoint(x: origin.x + size * 0.35, y: origin.y + size * 1.25))
    path.curve(to: CGPoint(x: origin.x + size, y: origin.y + size * 0.65),
               controlPoint1: CGPoint(x: origin.x + size * 0.66, y: origin.y - size * 0.05),
               controlPoint2: CGPoint(x: origin.x + size * 0.85, y: origin.y + size * 1.25))
    path.lineWidth = size * 0.22
    path.lineCapStyle = .round
    return path
}

func arrowPath(from: CGPoint, to: CGPoint, thickness: CGFloat, head: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let shaftEnd = to.x - head
    path.appendRoundedRect(NSRect(x: from.x, y: from.y - thickness / 2,
                                  width: shaftEnd - from.x, height: thickness),
                           xRadius: thickness / 2, yRadius: thickness / 2)
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: to.x, y: to.y))
    tip.line(to: NSPoint(x: shaftEnd, y: to.y + head * 0.66))
    tip.line(to: NSPoint(x: shaftEnd, y: to.y - head * 0.66))
    tip.close()
    path.append(tip)
    return path
}

func render(scale: CGFloat, to url: URL) {
    let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let markSize: CGFloat = 26
    let title = "WSurf"
    let font = NSFont.systemFont(ofSize: 21, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let titleSize = title.size(withAttributes: attributes)
    let gap: CGFloat = 12
    let groupWidth = markSize + gap + titleSize.width
    let groupX = 330 - groupWidth / 2
    let groupY: CGFloat = height - 78

    ink.setFill()
    markPath(size: markSize, origin: CGPoint(x: groupX, y: groupY)).stroke()
    title.draw(at: NSPoint(x: groupX + markSize + gap,
                           y: groupY + (markSize - titleSize.height) / 2 + 1),
               withAttributes: attributes)

    arrowColor.setFill()
    arrowPath(from: CGPoint(x: 268, y: height - 190), to: CGPoint(x: 392, y: height - 190),
              thickness: 10, head: 30).fill()

    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

let out = CommandLine.arguments[1]
render(scale: 1, to: URL(fileURLWithPath: "\(out)/background.png"))
render(scale: 2, to: URL(fileURLWithPath: "\(out)/background@2x.png"))
