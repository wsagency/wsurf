// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// The address bar's Download PDF control. It appears while the tab in front shows a PDF, in either engine's viewer.
struct PDFDownloadBadge: View {
    let browser: BrowserModel

    var body: some View {
        if let tab = browser.activeTab, tab.shownPDF != nil {
            ChromeIcon(
                symbol: "arrow.down.doc",
                weight: .semibold,
                help: String(localized: "Download PDF")
            ) {
                tab.savePDF()
            }
            .accessibilityLabel(Text("Download PDF"))
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }
}
