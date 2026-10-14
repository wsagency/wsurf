// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum DevelopmentReleaseReason: Equatable {
    case reset, disconnect, grantDowngrade, tabClosed, engineReplaced, documentDenied
}

enum DevelopmentAcquisition {
    case acquired(DevelopmentOwner), alreadyOwned(DevelopmentOwner), conflict
}

enum DevelopmentRelation: String {
    case none, own, other
}

/// The one development lease a tab can have. Everything an MCP connection changes for development (viewport, device
/// emulation, diagnostics capture) is recorded here so one release removes exactly that and nothing else.
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
    var diagnostics: DevelopmentDiagnostics?
    private var releases: [(DevelopmentReleaseReason) -> Void] = []
    private(set) var isReleased = false

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
        viewport?.remove(from: self)
        viewport = nil
        diagnostics?.stop()
        diagnostics = nil
        let callbacks = releases
        releases = []
        callbacks.forEach { $0(reason) }
    }
}

extension BrowserTab {
    /// Synchronous on the main actor with no suspension between check and set: two connections racing yield one owner.
    func acquireDevelopment(connection: UUID, page: BrowserPage) -> DevelopmentAcquisition {
        if let owner = developmentOwner {
            return owner.connection == connection ? .alreadyOwned(owner) : .conflict
        }
        guard !isClosed else { return .conflict }
        let owner = DevelopmentOwner(connection: connection, pageGeneration: pageGeneration, page: page)
        owner.requestRelease = { [weak self, weak owner] reason in self?.releaseDevelopment(owner, reason: reason) }
        developmentOwner = owner
        return .acquired(owner)
    }

    func developmentRelation(of connection: UUID) -> DevelopmentRelation {
        guard let owner = developmentOwner else { return .none }
        return owner.connection == connection ? .own : .other
    }

    /// True while `owner` still holds this tab's lease for the page it was acquired for. Check after every suspension.
    func isCurrent(_ owner: DevelopmentOwner) -> Bool {
        developmentOwner === owner && pageGeneration == owner.pageGeneration && !isClosed
    }

    /// Releases `owner` (or whoever holds the lease when nil) and removes only what that owner applied.
    func releaseDevelopment(_ owner: DevelopmentOwner? = nil, reason: DevelopmentReleaseReason) {
        guard let current = developmentOwner, owner == nil || owner === current else { return }
        developmentOwner = nil
        current.release(reason)
    }
}
