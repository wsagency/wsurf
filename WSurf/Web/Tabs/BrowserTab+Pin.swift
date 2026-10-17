// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserTab {
    var isAwayFromPin: Bool {
        guard let pinnedURL else { return false }
        return !urlString.isEmpty && urlString != pinnedURL.absoluteString
    }

    /// A bookmarked tab, or a page in a pinned folder. Only the person removes these.
    var isPinnedForProfile: Bool {
        pinnedURL != nil || pinID != nil
    }

    var isShowingPin: Bool {
        guard let pinnedURL else { return false }
        return urlString == pinnedURL.absoluteString
    }
}
