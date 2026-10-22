// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserTab {
    /// The connection that holds this tab's development lease and still has development access, if any. Such a connection is
    /// in control of the tab even between calls, so the tab's dialogs come to it.
    var dialogLeaseHolder: UUID? {
        guard let owner = developmentOwner, isCurrent(owner), owner.isAuthorized() else { return nil }
        return owner.connection
    }
}
