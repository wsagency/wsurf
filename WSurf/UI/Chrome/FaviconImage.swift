// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct FaviconImage: View {
    let image: NSImage
    var tint: Color?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let needsInk = FaviconContrast.needsInk(image, isDark: scheme == .dark)
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
