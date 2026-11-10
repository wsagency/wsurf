// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension ChromiumPage {
    /// The wait of a native navigation that may stay inside its document.
    struct SameDocumentWait {
        /// The last loading state CEF reported while `awaitingNativeNavigation` dropped it; nil before any report.
        var held: Bool?
    }

    func awaitHistoryMove() {
        awaitingNativeNavigation = true
        sameDocumentWait = SameDocumentWait()
    }

    /// A load stays inside the document only when it differs from the address by its fragment; a reload never does.
    func awaitLoad(of target: URL?) {
        awaitingNativeNavigation = true
        sameDocumentWait = nil
        guard let target, target.fragment != nil, let current = owner?.url else { return }
        var base = URLComponents(url: target, resolvingAgainstBaseURL: false)
        var now = URLComponents(url: current, resolvingAgainstBaseURL: false)
        base?.fragment = nil
        now?.fragment = nil
        if base != nil, base == now {
            sameDocumentWait = SameDocumentWait()
        }
    }

    /// A Back, Forward, history jump or fragment load that stays inside the document never calls `willNavigate`, the only
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
}
