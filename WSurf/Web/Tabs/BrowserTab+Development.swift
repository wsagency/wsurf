// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum DevelopmentReleaseReason: Equatable {
    case reset, disconnect, grantDowngrade, tabClosed, engineReplaced, documentDenied
}

enum DevelopmentAcquisition {
    case acquired(DevelopmentOwner), alreadyOwned(DevelopmentOwner), conflict, pageGone
}

enum DevelopmentRelation: String {
    case none, own, other
}

/// The one development lease a tab can have. Everything an MCP connection changes for development (viewport, device
/// emulation, media and network emulation, diagnostics capture) is recorded here so one release removes exactly that and
/// nothing else.
@MainActor
final class DevelopmentOwner {
    let connection: UUID
    let pageGeneration: Int
    weak var page: BrowserPage?
    /// Set by the owning session: whether the connection may still use development tools on this tab.
    var isAuthorized: () -> Bool = { true }
    /// Releases this lease from native-event context (for example when a navigation leaves the grant).
    var requestRelease: ((DevelopmentReleaseReason) -> Void)?
    var viewport: DevelopmentViewportState?
    /// Color scheme, reduced motion and offline mode this lease emulates; nil when it emulates none.
    var media: DevelopmentMediaState?
    var diagnostics: DevelopmentDiagnostics?
    private var releases: [(DevelopmentReleaseReason) -> Void] = []
    private(set) var isReleased = false
    /// Finishes when the page's device emulation this lease applied has actually been removed (nil: nothing to remove).
    /// Reserved on the page's emulation queue at release, so a later lease applies after it.
    private(set) var cleanup: Task<Void, Never>?

    init(connection: UUID, pageGeneration: Int, page: BrowserPage?) {
        self.connection = connection
        self.pageGeneration = pageGeneration
        self.page = page
    }

    func onRelease(_ body: @escaping (DevelopmentReleaseReason) -> Void) {
        releases.append(body)
    }

    fileprivate func release(_ reason: DevelopmentReleaseReason) {
        guard !isReleased else { return }
        isReleased = true
        // Both cleanups queue on the page in this order, so the later one ending means the page is clean.
        let viewportCleanup = viewport?.remove(from: self)
        cleanup = media?.remove(from: self) ?? viewportCleanup
        viewport = nil
        media = nil
        diagnostics?.stop()
        diagnostics = nil
        let callbacks = releases
        releases = []
        callbacks.forEach { $0(reason) }
    }
}

extension BrowserTab {
    /// Synchronous on the main actor with no suspension between check and set: two connections racing yield one owner.
    /// A lease that is no longer current or authorized is released first, so it can never block or be inherited.
    func acquireDevelopment(connection: UUID, page: BrowserPage, isAuthorized: @escaping () -> Bool) -> DevelopmentAcquisition {
        releaseInvalidDevelopment()
        guard !isClosed, liveView === page else { return .pageGone }
        if let owner = developmentOwner {
            return owner.connection == connection ? .alreadyOwned(owner) : .conflict
        }
        let owner = DevelopmentOwner(connection: connection, pageGeneration: pageGeneration, page: page)
        owner.isAuthorized = isAuthorized
        owner.requestRelease = { [weak self, weak owner] reason in
            guard let owner else { return }
            self?.releaseDevelopment(owner, reason: reason)
        }
        developmentOwner = owner
        return .acquired(owner)
    }

    func developmentRelation(of connection: UUID) -> DevelopmentRelation {
        releaseInvalidDevelopment()
        guard let owner = developmentOwner else { return .none }
        return owner.connection == connection ? .own : .other
    }

    /// True while `owner` still holds this tab's lease for the live page it was acquired for. Check after every suspension.
    func isCurrent(_ owner: DevelopmentOwner) -> Bool {
        developmentOwner === owner && pageGeneration == owner.pageGeneration && !isClosed
            && owner.page != nil && owner.page === liveView
    }

    /// True while `view` is still this tab's live page of `generation`. Unlike `page`, never materializes a view.
    func isLive(_ view: BrowserPage, generation: Int) -> Bool {
        !isClosed && liveView === view && pageGeneration == generation
    }

    /// Releases exactly `owner` and removes only what it applied; a different or newer lease is untouched.
    func releaseDevelopment(_ owner: DevelopmentOwner, reason: DevelopmentReleaseReason) {
        guard developmentOwner === owner else { return }
        developmentOwner = nil
        owner.release(reason)
    }

    /// Tab lifecycle events (page replaced, tab closed) end whatever lease exists.
    func releaseCurrentDevelopment(reason: DevelopmentReleaseReason) {
        if let owner = developmentOwner {
            releaseDevelopment(owner, reason: reason)
        }
    }

    /// Releases the lease when its page was replaced, the tab closed, or its connection no longer has development access to the
    /// current document. Runs from native events (page transition, navigation commit, policy change) and again at every acquire.
    func releaseInvalidDevelopment() {
        guard let owner = developmentOwner else { return }
        if !isCurrent(owner) {
            releaseDevelopment(owner, reason: isClosed ? .tabClosed : .engineReplaced)
        } else if !owner.isAuthorized() {
            releaseDevelopment(owner, reason: .documentDenied)
        }
    }

    /// A new document committed: an unauthorized one ends the lease, otherwise capture follows the document.
    func developmentDocumentChanged() {
        releaseInvalidDevelopment()
        developmentOwner?.diagnostics?.documentMayHaveChanged()
    }
}
