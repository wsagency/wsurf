// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension AppCoordinator {
    /// The tab Reader acts on: the one in front. A Peek over it or a split of several pages shows no Reader, so those have none.
    var readerTab: BrowserTab? {
        guard shownPeek == nil, browser.activeSplit == nil else { return nil }
        return browser.activeTab
    }

    func toggleReader() {
        readerTab?.reader.toggle()
    }
}
