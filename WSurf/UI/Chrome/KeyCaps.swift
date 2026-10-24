// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// A shortcut drawn as the keys that make it: ⇧⌘N is three caps. The caps are `KeyCap`, Settings' themed control surface;
/// this only groups them and says them as one thing to VoiceOver.
struct KeyCaps: View {
    let caps: [String]

    /// One cap per character, as the shortcut is written for menus and the palette: "⇧⌘N", "⌃⌘→", "⌘↩".
    init(_ shortcut: String) {
        caps = shortcut.map(String.init)
    }

    /// Keys that are more than a character, such as the "left ⌘" a recorded shortcut can name.
    init(caps: [String]) {
        self.caps = caps
    }

    /// What VoiceOver says: "⇧⌘N" as written, and words kept apart ("left ⌘ ⌥").
    var spoken: String {
        caps.joined(separator: caps.allSatisfy { $0.count == 1 } ? "" : " ")
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(caps.enumerated(), id: \.offset) { _, cap in
                KeyCap(cap)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }
}
