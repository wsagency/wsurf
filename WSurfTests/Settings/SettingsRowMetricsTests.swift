// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The gap between two settings options is two row paddings and one hairline. A row adds no space of its own, so a
/// page cannot grow back what `SettingsMetrics.rowPaddingV` took out.
@MainActor
struct SettingsRowMetricsTests {
    private func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.frame(width: 500)).fittingSize.height
    }

    private var control: some View {
        Color.clear.frame(width: 40, height: SettingsMetrics.controlHeight)
    }

    private var rowHeight: CGFloat {
        SettingsMetrics.controlHeight + 2 * SettingsMetrics.rowPaddingV
    }

    @Test func aRowIsItsControlAndTwoPaddings() {
        let row = DetailRow(verbatimTitle: "Option") { control }

        #expect(abs(height(row) - rowHeight) < 0.5)
    }

    @Test func twoRowsAreSeparatedByTwoPaddingsAndAHairline() {
        let rows = VStack(alignment: .leading, spacing: 0) {
            DetailRow(verbatimTitle: "First") { control }
            RowSeparator()
            DetailRow(verbatimTitle: "Second") { control }
        }

        #expect(abs(height(rows) - (2 * rowHeight + 1)) < 0.5)
    }

    /// The rows of a disclosure group, such as the colors of a theme, sit as close as the rows of any other card.
    @Test func disclosureContentAddsNoSpaceBetweenItsChildren() {
        let child: CGFloat = 20

        func disclosure(children: Int) -> CGFloat {
            height(
                DisclosureGroup("Header", isExpanded: .constant(true)) {
                    ForEach(0..<children, id: \.self) { _ in
                        Color.clear.frame(width: 40, height: child)
                    }
                }
                .disclosureGroupStyle(ClickableDisclosureStyle())
            )
        }

        #expect(abs(disclosure(children: 3) - disclosure(children: 2) - child) < 0.5)
    }
}
