// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0
// Renders TandemLoaderMark frames to PNG with ImageRenderer.
//   harness frames <outdir> <size> <count> <light|dark> <clear|ground>   -> f000.png ... (progress i/count)
//   harness at <out.png> <size> <progress> <light|dark> <clear|ground> [reduce-opacity]
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
func render(progress: Double, size: Int, dark: Bool, ground: Bool, followerOpacity: Double = 1) -> CGImage {
    let g: Color = dark ? Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255) : Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    let view = ZStack {
        if ground { g }
        TandemLoaderMark(size: CGFloat(size), progress: progress, followerOpacity: followerOpacity)
    }
    .frame(width: CGFloat(size), height: CGFloat(size))
    .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: view)
    r.scale = 1
    r.isOpaque = ground
    return r.cgImage!
}

func writePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "png write failed: \(path)")
}

@main
struct Harness {
    @MainActor static func main() {
        let a = CommandLine.arguments
        switch a[1] {
        case "frames":
            let dir = a[2], size = Int(a[3])!, count = Int(a[4])!, dark = a[5] == "dark", ground = a[6] == "ground"
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for i in 0..<count {
                writePNG(render(progress: Double(i) / Double(count), size: size, dark: dark, ground: ground), String(format: "%@/f%03d.png", dir, i))
            }
        case "at":
            let op = a.count > 7 ? Double(a[7])! : 1
            writePNG(render(progress: Double(a[4])!, size: Int(a[3])!, dark: a[5] == "dark", ground: a[6] == "ground", followerOpacity: op), a[2])
        default: fatalError("usage")
        }
    }
}
