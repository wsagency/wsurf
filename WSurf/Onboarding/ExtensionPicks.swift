// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

struct ExtensionPick: Identifiable, Sendable {
    let id: String
    let store: ExtensionStore
    let name: String
    let caption: LocalizedStringResource
    let symbol: String
}

enum ExtensionPicks {
    static let all: [ExtensionPick] = [
        ExtensionPick(
            id: "ddkjiahejlhfcafbddmgiahcphecmpfh",
            store: .chrome,
            name: "uBlock Origin Lite",
            caption: "Blocks ads and trackers.",
            symbol: "shield.lefthalf.filled"
        ),
        ExtensionPick(
            id: "violentmonkey",
            store: .firefox,
            name: "Violentmonkey",
            caption: "Runs userscripts on websites.",
            symbol: "curlybraces"
        ),
    ]
}
