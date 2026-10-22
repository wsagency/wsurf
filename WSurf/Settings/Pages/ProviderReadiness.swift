// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum ProviderReadiness: Equatable {
    case ready(String)
    case needsKey
    case notRunning(String)
    case checking
    case unsupported(String)

    var level: StatusLevel {
        switch self {
        case .ready:
            .ready
        case .needsKey, .notRunning, .unsupported:
            .attention
        case .checking:
            .idle
        }
    }
}
