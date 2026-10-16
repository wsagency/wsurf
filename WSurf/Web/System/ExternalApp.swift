// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import os

nonisolated struct ExternalAppMatch: Sendable {
    let url: URL
    let name: String
    var bundleIdentifier: String?
}

@MainActor
enum ExternalApp {
    typealias Match = ExternalAppMatch

    private nonisolated static let webSchemes: Set<String> = [
        "http", "https", "about", "blob", "data", "file", "javascript", "webkit-extension",
    ]

    nonisolated static func staysInWebView(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return webSchemes.contains(scheme)
    }

    /// Why an offer ended without opening anything and without the person saying no.
    enum Drop: String, Sendable {
        /// The offer's task was cancelled.
        case cancelled
        /// The tab, or the web view that asked, is gone.
        case tabClosed
        /// The document that asked was replaced, and nothing lets the approval follow it.
        case documentChanged
        /// The frame that asked was replaced or removed.
        case frameChanged
        /// The tab now shows another site than the one the prompt named.
        case siteChanged
        /// Another navigation began before an unattributed or first-redirect request was answered.
        case navigated
        /// Nothing can show the prompt.
        case noWindow
        /// Another prompt is already open.
        case busy
        /// The request could not be tied to a live document, and the caller has no better reason.
        case stale
    }

    private nonisolated static let log = Logger(subsystem: "io.wsagency.wsurf", category: "app-handoff")

    static var openerForTesting: ((URL) -> Void)?
    static var requestObserverForTesting: ((URL, String) -> Void)?
    static var dropObserverForTesting: ((String, Drop) -> Void)?
    static var resolverForTesting: ((URL) async -> Match?)?
    static var presenterForTesting: ((NSAlert) async -> NSApplication.ModalResponse)?

    private static var isAsking = false
    static var hasPendingOfferForTesting: Bool {
        isAsking
    }

    /// Records that nothing was opened. A link can carry a sign-in code in its path or query,
    /// so only the scheme and the reason are logged.
    static func noteDropped(_ url: URL, _ reason: Drop) {
        let scheme = url.scheme?.lowercased() ?? ""
        log.notice("app link not opened scheme=\(scheme, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        dropObserverForTesting?(scheme, reason)
    }

    /// Offers `url` to the app that handles it. The caller says whether its request is still current
    /// before anything is shown or opened without asking.
    static func offerToOpen(
        _ url: URL,
        from origin: String,
        policy: TabExternalAppPolicy,
        in window: NSWindow?,
        isCurrent: () async -> Bool
    ) async {
        await offerToOpen(url, from: origin, policy: policy, in: window, staleness: { await isCurrent() ? nil : .stale })
    }

    /// `staleness` answers nil while the request is current, or says why it is not. It gates the prompt and
    /// any saved approval. `approvalStaleness` gates only the person's own approval of the prompt that was
    /// shown. It defaults to `staleness`; a caller passes it when the person's choice outlives the document
    /// that asked. Either way the app and the link are the ones the prompt showed, never a new lookup.
    static func offerToOpen(
        _ url: URL,
        from origin: String,
        policy: TabExternalAppPolicy,
        in window: NSWindow?,
        staleness: () async -> Drop?,
        approvalStaleness: (() async -> Drop?)? = nil
    ) async {
        if let reason = await stale(staleness) {
            noteDropped(url, reason)
            return
        }
        let origin = SitePermissions.webOrigin(for: URL(string: origin))
        requestObserverForTesting?(url, origin)
        guard window != nil || presenterForTesting != nil else {
            noteDropped(url, .noWindow)
            return
        }
        guard !isAsking else {
            noteDropped(url, .busy)
            return
        }
        isAsking = true
        defer { isAsking = false }
        let match = if let resolverForTesting {
            await resolverForTesting(url)
        } else {
            await application(toOpen: url)
        }
        if let reason = await stale(staleness) {
            noteDropped(url, reason)
            return
        }

        guard let match else {
            let alert = NSAlert()
            alert.messageText = String(localized: "No app can open this link.")
            alert.informativeText = String(localized: "No app installed on this Mac handles \(url.scheme ?? "") links.")
            alert.addButton(withTitle: String(localized: "OK"))
            _ = await present(alert, in: window)
            return
        }

        let permission = match.bundleIdentifier.flatMap { bundleIdentifier -> ExternalAppPermission? in
            guard !bundleIdentifier.isEmpty, let scheme = url.scheme, !scheme.isEmpty else { return nil }
            return ExternalAppPermission(scheme: scheme.lowercased(), bundleIdentifier: bundleIdentifier, name: match.name)
        }
        if let permission, policy.allows(permission, from: origin) {
            open(url, in: match)
            return
        }

        let alert = confirmation(
            for: match,
            from: origin,
            canRemember: permission != nil && !origin.isEmpty,
            isPrivate: policy.isPrivate
        )
        guard await present(alert, in: window) == .alertFirstButtonReturn else { return }
        let afterApproval = if let approvalStaleness {
            await stale(approvalStaleness)
        } else {
            await stale(staleness)
        }
        if let reason = afterApproval {
            noteDropped(url, reason)
            return
        }
        if let permission, alert.suppressionButton?.state == .on {
            policy.remember(permission, from: origin)
        }
        open(url, in: match)
    }

    private static func stale(_ staleness: () async -> Drop?) async -> Drop? {
        Task.isCancelled ? .cancelled : await staleness()
    }

    private static func confirmation(for app: Match, from origin: String, canRemember: Bool, isPrivate: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.messageText = String(localized: "Open \(app.name)?")
        if origin.isEmpty {
            alert.informativeText = String(localized: "This page wants to open \(app.name).")
        } else {
            let site = SitePermissions.displayName(for: origin)
            alert.informativeText = String(localized: "\(site) wants to open \(app.name).")
        }
        alert.addButton(withTitle: String(localized: "Open \(app.name)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = canRemember
        alert.suppressionButton?.title = isPrivate
            ? String(localized: "Allow for this private tab")
            : String(localized: "Always allow for this website")
        return alert
    }

    private static func open(_ url: URL, in app: Match) {
        if let openerForTesting {
            openerForTesting(url)
        } else {
            // Open the handler the user approved, not a newly resolved default.
            let scheme = url.scheme?.lowercased() ?? ""
            NSWorkspace.shared.open(
                [url], withApplicationAt: app.url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                // The error message can quote the link, so only its domain and code are logged.
                guard let error = error as NSError? else { return }
                log.error("""
                app link failed to open scheme=\(scheme, privacy: .public) \
                domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)
                """)
            }
        }
    }

    private nonisolated static func application(toOpen url: URL) async -> Match? {
        await Task.detached(priority: .userInitiated) {
            guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
            let bundle = Bundle(url: app)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? app.deletingPathExtension().lastPathComponent
            return Match(url: app, name: name, bundleIdentifier: bundle?.bundleIdentifier)
        }.value
    }

    private static func present(
        _ alert: NSAlert,
        in window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        if let presenterForTesting {
            return await presenterForTesting(alert)
        }
        guard let window else { return .cancel }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
