// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The padlock that locks Credentials is a toolbar chip with no text: it keeps the height and a click target like the other toolbar
/// buttons. Its tooltip and VoiceOver label are the chip's label (`.help` and `.accessibilityLabel`); a probe of the hosted view's
/// accessibility tree did not report that label in a test run, so those two are not asserted here. Synthetic: no vault, no data.
@MainActor
struct ToolbarChipTests {
    private func lock(showsLabel: Bool) -> ToolbarChip {
        ToolbarChip(symbol: "lock", label: "Lock Credentials", showsLabel: showsLabel) {}
    }

    @Test func anIconOnlyChipIsAsTallAsTheLabelledOnesAndAsWideAsAToolbarButton() {
        let icon = NSHostingView(rootView: lock(showsLabel: false)).fittingSize
        let labelled = NSHostingView(rootView: lock(showsLabel: true)).fittingSize
        #expect(icon.height == 28)
        #expect(icon.height == labelled.height)
        #expect(icon.width >= 30, "the width of ToolbarButton")
        #expect(icon.width < labelled.width, "the text is gone")
    }
}
