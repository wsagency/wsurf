// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

struct FaviconImage: View {
    let image: NSImage
    var tint: Color?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let needsInk = FaviconContrast.needsInk(image, isDark: scheme == .dark)
        let shift = FaviconArt.shift(of: image)
        Image(nsImage: image)
            .renderingMode(needsInk ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(tint ?? (scheme == .dark ? Color.white : Color.black))
            .colorEffect(
                ShaderLibrary.wsurfFaviconTint(.color(tint ?? .white)),
                isEnabled: tint != nil && !needsInk
            )
            // The art, not the image, is what meets the title beside it. An icon with more padding below than above
            // moves down by half the difference, which keeps the art inside the frame it was drawn in.
            .visualEffect { content, proxy in
                content.offset(y: proxy.size.height * shift)
            }
    }
}

/// How far the art of a favicon sits from the middle of its image, kept for as long as the image lives.
@MainActor
enum FaviconArt {
    private static let cache = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    /// The shift that centers the art, as a fraction of the drawn height: positive moves the image down.
    static func shift(of image: NSImage) -> CGFloat {
        if let cached = cache.object(forKey: image) {
            return CGFloat(cached.doubleValue)
        }
        let shift = FaviconInk.artMiddle(of: image).map { 0.5 - $0 } ?? 0
        cache.setObject(NSNumber(value: shift), forKey: image)
        return CGFloat(shift)
    }
}

@MainActor
enum FaviconContrast {
    private static let cache = NSMapTable<NSImage, NSNumber>.weakToStrongObjects()

    static func needsInk(_ image: NSImage, isDark: Bool) -> Bool {
        let flags: Int
        if let cached = cache.object(forKey: image) {
            flags = cached.intValue
        } else {
            let contrast = FaviconInk.contrast(of: image)
            flags = (contrast.onLight ? 1 : 0) | (contrast.onDark ? 2 : 0)
            cache.setObject(NSNumber(value: flags), forKey: image)
        }
        return flags & (isDark ? 2 : 1) != 0
    }
}
