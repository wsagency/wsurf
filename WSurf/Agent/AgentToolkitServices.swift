// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension AgentToolkit {
    struct Services {
        var search: (String) async -> [SearchHit]
        var resolveVideo: (String) async -> ResolvedVideo
        var chooseFiles: ((PageFileSelection.Parameters) async -> [URL]?)?

        static var live: Self {
            Self(
                search: { await SnippetFetcher.search(query: $0) },
                resolveVideo: { await YouTubeResolver().resolve(query: $0) }
            )
        }
    }
}
