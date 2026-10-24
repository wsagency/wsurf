// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    var isShowingPin: Bool {
        guard let pinnedURL else { return false }
        return urlString == pinnedURL.absoluteString
    }
}
