// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserTab {
    /// Asks the page whether it holds an article. A tab behind another waits until it is brought to the front.
    func probeReader() {
        guard !isClosed, isFrontTab(), isMaterialised, isShowingRealPage, !isShowingError else { return }
        let session = reader
        Task { await session.probe() }
    }

    /// A move inside the document ends Reader when the address changes beyond its fragment, and the new page is asked again.
    func readerPageMoved(from previous: String) {
        guard Self.withoutFragment(urlString) != Self.withoutFragment(previous) else { return }
        reader.pageChanged()
        probeReader()
    }

    /// The page the person is looking at: the article while Reader shows it, the website otherwise. Find and Print act on it.
    var shownPage: BrowserPage {
        reader.isActive ? (reader.presentedPage ?? page) : page
    }

    nonisolated static func withoutFragment(_ address: String) -> Substring {
        address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }
}
