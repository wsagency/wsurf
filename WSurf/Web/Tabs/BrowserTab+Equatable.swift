// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

extension BrowserTab: Equatable {
    nonisolated static func == (lhs: BrowserTab, rhs: BrowserTab) -> Bool {
        lhs === rhs
    }
}
