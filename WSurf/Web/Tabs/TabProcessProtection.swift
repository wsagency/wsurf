// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

enum TabProtectionReason: Equatable {
    case editedForm
    case activeDownload
    case deviceAccess
    case agentWorking
    case mediaPlayback
    case visibleInSplit
    case alwaysKeepActive
    case privateBrowsing
    case extensionPage
}

enum TabReclaimState: Equatable {
    case none
    case unloaded
    case reloading
}
