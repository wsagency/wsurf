// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

nonisolated enum UpdateFeed {
    static let owner = "wsagency"
    static let repository = "wsurf"

    static let appcastURL = URL(
        string: "https://github.com/\(owner)/\(repository)/releases/latest/download/appcast.xml"
    )!

    // A name of its own: a `tip` release that loses its pre-release flag becomes "latest", and one shared name would then serve previews to everyone.
    static let previewAppcastURL = URL(
        string: "https://github.com/\(owner)/\(repository)/releases/download/tip/appcast-tip.xml"
    )!

    static func appcastURL(for channel: UpdateChannel) -> URL {
        switch channel {
        case .release:
            appcastURL
        case .preview:
            previewAppcastURL
        }
    }

    static let newIssueURL = URL(
        string: "https://github.com/\(owner)/\(repository)/issues/new/choose"
    )!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
