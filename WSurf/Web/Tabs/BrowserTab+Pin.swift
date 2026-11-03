// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension BrowserTab {
    var isAwayFromPin: Bool {
        guard let pinnedURL else { return false }
        return !urlString.isEmpty && urlString != pinnedURL.absoluteString
    }

    /// Above the pin line: a pin, a Favorite, or a page in a pinned folder at any depth. Only the person removes these;
    /// closing one unloads it. `BrowserModel.settlePinnedPages()` gives each its pinned page in `pinnedURL`.
    var isPinnedForProfile: Bool {
        pinnedURL != nil || pinID != nil
    }

    /// A Start pin shows its page while the tab is on the Start page, which a new tab shows with no address of its own.
    var isShowingPin: Bool {
        guard let pinnedURL else { return false }
        if SystemPages.isStart(pinnedURL) {
            return urlString.isEmpty || SystemPages.isStart(URL(string: urlString))
        }
        return urlString == pinnedURL.absoluteString
    }

    /// The page a pin of this tab keeps: the address it shows, or the Start page for a new tab that shows it.
    var pinnableURL: URL? {
        guard !urlString.isEmpty else {
            return SystemPages.showsStartFace(self) ? SystemPages.start : nil
        }
        return URL(string: urlString)
    }
}
