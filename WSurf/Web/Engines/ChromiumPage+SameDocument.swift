// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import CefKit
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

    /// Stop ends WSurf's own work now and the engine's on the next turn: a navigation started in the same turn (Back and Forward
    /// stop first, and so may a reload or a load) replaces the load anyway and drops the native stop (`supersedeStop`). Sent
    /// together, a stop that reaches the renderer late can abort that new navigation instead, with ERR_ABORTED, which WSurf
    /// ignores, and the tab stays on the old document, idle (seen on CI while an error page loaded).
    func stopLoading() {
        pendingLoad?.cancel()
        client?.documentResponses.reset()
        endUnstartedLoad()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            guard let self, !Task.isCancelled, !closing, !isClosed else { return }
            pendingStop = nil
            remote?.send(CefRemote.Op.stop)
            withBrowser { $0.pointee.stop_load?($0) }
        }
    }

    /// A navigation the page starts now drops a native stop not sent yet (`stopLoading`).
    func supersedeStop() {
        pendingStop?.cancel()
        pendingStop = nil
    }

    /// Stop ends a load that Chromium has not begun (no `willNavigate` yet). It reports no end of its own: `loading = false` is
    /// dropped while the wait holds and -3 is ignored, so the page would stay loading and `BrowserTab.reload` would take it for
    /// stuck and restart it, dropping Back and Forward.
    private func endUnstartedLoad() {
        guard awaitingNativeNavigation else { return }
        awaitingNativeNavigation = false
        sameDocumentWait = nil
        owner?.isLoading = false
        owner?.estimatedProgress = 1
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
