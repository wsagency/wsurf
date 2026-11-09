// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension ChromiumPage {
    /// What a native navigation that may stay inside its document holds back: the last loading state CEF reported while
    /// `awaitingNativeNavigation` dropped it.
    struct SameDocumentWait {
        var held: Bool?
    }

    func awaitHistoryMove() {
        awaitingNativeNavigation = true
        sameDocumentWait = SameDocumentWait()
    }

    /// A load reaches `willNavigate`, which ends the wait; this also drops what an earlier history move left.
    func awaitLoad() {
        awaitingNativeNavigation = true
        sameDocumentWait = nil
    }

    /// A Back, Forward or history jump that stays inside the document never calls `willNavigate`, the only
    /// other place that ends the wait for a native navigation. Without this, `isLoading` latched on, because the matching
    /// `loading = false` was held back. Like WebKit, a same-document move reports no navigation start or finish.
    func completeAwaitedMoveWithinDocument() {
        guard awaitingNativeNavigation, let wait = sameDocumentWait else { return }
        awaitingNativeNavigation = false
        sameDocumentWait = nil
        navigationStarted = false
        // CEF may have reported nothing, or only the end, of a move it treats as one step; only a `true` is still open.
        if wait.held != true {
            owner?.isLoading = false
            owner?.estimatedProgress = 1
        }
    }

    func didChangeProgress(_ progress: Double) {
        owner?.estimatedProgress = progress
    }

    func didHoverLink(_ url: URL?) {
        owner?.onLinkHovered?(url)
    }
    func didChangeFullscreen(_ enabled: Bool) {
        owner?.isFullscreen = enabled
    }
}
