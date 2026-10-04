#!/usr/bin/env swift

// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

//
// Draws WSurf's wave mark and writes WSurf/AppIcon.icon.
//
//     swift Tools/make-app-icon.swift
//
// The icon is generated rather than drawn by hand so it stays editable: the
// geometry below is the source, and the mark PNG is build output that happens
// to be committed. Re-run from the repository root after changing anything.
//
// Output is an **Icon Composer document**, not an .appiconset. That is the only
// way to get a light/dark app icon on macOS 26: actool accepts `appearances` on
// an .appiconset for iOS, but for the mac idiom it silently drops every dark
// image and ships the light one twice. In this format we supply just the mark
// on a transparent canvas and the system draws the tile, the material and the
// shadow - which is also why the icon picks up the tinted and clear appearances
// for free.
//
// The schema below (specialization lists whose *unlabelled* entry is the base
// value) was read off a shipping .icon document; `Icon Composer.app` can open
// this file if you would rather edit it there.

import AppKit
import CoreGraphics
import Foundation

// MARK: - The mark
//
// Three rounded crests form a wave and a compact "w". Coordinates match the
// SVG brand assets; Icon Composer provides the platform tile and material.

let canvas = 1024

func renderMark() -> CGImage {
    let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    // Any opaque colour will do: the layer fill below recolours the shape per
    // appearance, using this image purely as a mask.
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

    let path = CGMutablePath()
    path.move(to: CGPoint(x: 338, y: 571))
    path.addCurve(to: CGPoint(x: 292, y: 568), control1: CGPoint(x: 327, y: 579), control2: CGPoint(x: 310, y: 579))
    path.addCurve(to: CGPoint(x: 282, y: 499), control1: CGPoint(x: 269, y: 554), control2: CGPoint(x: 269, y: 522))
    path.addCurve(to: CGPoint(x: 369, y: 466), control1: CGPoint(x: 301, y: 466), control2: CGPoint(x: 339, y: 454))
    path.addCurve(to: CGPoint(x: 429, y: 520), control1: CGPoint(x: 392, y: 474), control2: CGPoint(x: 412, y: 497))
    path.addCurve(to: CGPoint(x: 575, y: 594), control1: CGPoint(x: 489, y: 594), control2: CGPoint(x: 530, y: 615))
    path.addCurve(to: CGPoint(x: 605, y: 550), control1: CGPoint(x: 606, y: 579), control2: CGPoint(x: 610, y: 559))
    path.addCurve(to: CGPoint(x: 565, y: 543), control1: CGPoint(x: 590, y: 558), control2: CGPoint(x: 577, y: 559))
    path.addCurve(to: CGPoint(x: 573, y: 481), control1: CGPoint(x: 550, y: 523), control2: CGPoint(x: 553, y: 498))
    path.addCurve(to: CGPoint(x: 657, y: 473), control1: CGPoint(x: 601, y: 457), control2: CGPoint(x: 630, y: 456))
    path.addCurve(to: CGPoint(x: 753, y: 592), control1: CGPoint(x: 696, y: 497), control2: CGPoint(x: 724, y: 552))
    path.addCurve(to: CGPoint(x: 900, y: 610), control1: CGPoint(x: 799, y: 657), control2: CGPoint(x: 862, y: 653))
    path.addCurve(to: CGPoint(x: 903, y: 576), control1: CGPoint(x: 908, y: 599), control2: CGPoint(x: 910, y: 584))
    path.addCurve(to: CGPoint(x: 860, y: 575), control1: CGPoint(x: 887, y: 586), control2: CGPoint(x: 874, y: 585))
    path.addCurve(to: CGPoint(x: 807, y: 504), control1: CGPoint(x: 840, y: 564), control2: CGPoint(x: 824, y: 536))
    path.addCurve(to: CGPoint(x: 677, y: 372), control1: CGPoint(x: 772, y: 437), control2: CGPoint(x: 735, y: 380))
    path.addCurve(to: CGPoint(x: 546, y: 413), control1: CGPoint(x: 627, y: 361), control2: CGPoint(x: 584, y: 381))
    path.addCurve(to: CGPoint(x: 488, y: 439), control1: CGPoint(x: 525, y: 430), control2: CGPoint(x: 507, y: 443))
    path.addCurve(to: CGPoint(x: 391, y: 379), control1: CGPoint(x: 452, y: 432), control2: CGPoint(x: 433, y: 398))
    path.addCurve(to: CGPoint(x: 252, y: 391), control1: CGPoint(x: 337, y: 356), control2: CGPoint(x: 293, y: 366))
    path.addCurve(to: CGPoint(x: 167, y: 480), control1: CGPoint(x: 220, y: 411), control2: CGPoint(x: 181, y: 443))
    path.addCurve(to: CGPoint(x: 180, y: 594), control1: CGPoint(x: 143, y: 540), control2: CGPoint(x: 163, y: 575))
    path.addCurve(to: CGPoint(x: 296, y: 618), control1: CGPoint(x: 218, y: 637), control2: CGPoint(x: 259, y: 635))
    path.addCurve(to: CGPoint(x: 338, y: 571), control1: CGPoint(x: 326, y: 606), control2: CGPoint(x: 343, y: 587))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
    return ctx.makeImage()!
}

// MARK: - The document

/// Ocean blue on the light tile, turquoise on the dark one. The tile itself is
/// left to the system (`system-light` / `system-dark`) so it tracks whatever
/// macOS considers the standard icon ground.
let lightInk = "srgb:0.03529,0.41176,0.94118,1.00000"
let darkInk = "srgb:0.08235,0.82353,0.84314,1.00000"

let document: [String: Any] = [
    "fill-specializations": [
        ["value": "system-light"],
        ["appearance": "dark", "value": "system-dark"],
    ],
    "groups": [
        [
            "layers": [
                [
                    "image-name": "Mark.png",
                    "name": "Mark",
                    "glass": false,
                    "hidden": false,
                    "fill-specializations": [
                        ["value": ["solid": lightInk]],
                        ["appearance": "dark", "value": ["solid": darkInk]],
                    ],
                ],
            ],
            "lighting": "individual",
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5],
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]

// MARK: - Write

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("WSurf").path) else {
    FileHandle.standardError.write(Data("run this from the repository root\n".utf8))
    exit(1)
}

let icon = root.appendingPathComponent("WSurf/AppIcon.icon")
let assets = icon.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let image = renderMark()
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: image.width, height: image.height)
try rep.representation(using: .png, properties: [:])!
    .write(to: assets.appendingPathComponent("Mark.png"))

let json = try JSONSerialization.data(withJSONObject: document,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: icon.appendingPathComponent("icon.json"))

let preview = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
preview.setFillColor(CGColor(red: 0.957, green: 0.957, blue: 0.965, alpha: 1))
preview.addPath(CGPath(roundedRect: bounds, cornerWidth: 180, cornerHeight: 180, transform: nil))
preview.fillPath()
preview.clip(to: bounds, mask: image)
let colors = [
    CGColor(red: 0.03529, green: 0.41176, blue: 0.94118, alpha: 1),
    CGColor(red: 0.08235, green: 0.82353, blue: 0.84314, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
preview.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 512), end: CGPoint(x: 904, y: 512), options: [])
let previewRep = NSBitmapImageRep(cgImage: preview.makeImage()!)
try previewRep.representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent(".github/assets/app-icon.png"))

print("wrote \(icon.path)")
