// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

@MainActor
enum AgentActionConsent {
    enum Decision {
        case allowOnce
        case allowAlways
        case decline
    }

    @TaskLocal static var decisionForTesting: Stub?
    @TaskLocal static var scopedPolicy: AgentActionPolicy?
    @TaskLocal static var scopedWindow: ExtensionWindowAdapter?
    @TaskLocal static var externalClientName: String?

    struct Stub: @unchecked Sendable {
        let decide: @MainActor (String, SensitiveAction.Category, String?, NSWindow?) async -> Decision

        init(_ decide: @escaping @MainActor (String, SensitiveAction.Category, String?, NSWindow?) async -> Decision) {
            self.decide = decide
        }
    }

    static func permit(
        label: String,
        category: SensitiveAction.Category,
        host: String?,
        authoredByAI: Bool = false,
        policy: AgentActionPolicy? = nil
    ) async -> Bool {
        guard !Task.isCancelled, hasCurrentWindow, let policy = scopedPolicy ?? policy else { return false }
        if policy.isAlwaysAllowed(category, host: host) {
            return true
        }

        let window = scopedWindow?.nativeWindow
        let decision: Decision
        if let stub = decisionForTesting {
            decision = await stub.decide(label, category, host, window)
        } else {
            guard let window else { return false }
            decision = await ask(label: label, category: category, host: host, authoredByAI: authoredByAI, in: window)
        }
        guard !Task.isCancelled, hasCurrentWindow, scopedWindow?.nativeWindow === window else { return false }

        switch decision {
        case .allowOnce:
            return true
        case .allowAlways:
            policy.allowAlways(category, host: host)
            return true
        case .decline:
            return false
        }
    }

    private static var hasCurrentWindow: Bool {
        guard let scopedWindow else { return true }
        guard let browser = scopedWindow.browser, browser.sessionClosedAt == nil,
              browser.context.isRegistered(browser) else { return false }
        return browser.context.extensions.adapter(for: browser) === scopedWindow
    }

    /// Never wait for an unanswered native authorization sheet in automated tests.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func ask(
        label: String,
        category: SensitiveAction.Category,
        host: String?,
        authoredByAI: Bool = false,
        in window: NSWindow
    ) async -> Decision {
        guard !isRunningTests, !Task.isCancelled else { return .decline }
        let site = AgentActionPolicy.normalizedHost(host)

        let alert = NSAlert()
        // Localize each heading where it is written. A ternary of literals puts
        // only the first in the catalog.
        alert.messageText = site.map { String(localized: "Allow “\(label)” on \($0)?") }
            ?? String(localized: "Allow “\(label)”?")
        alert.informativeText = body(
            label: label,
            category: category,
            site: site,
            authoredByAI: authoredByAI
        )
        if let externalClientName {
            alert.informativeText = String(localized: "Requested by the external connection “\(externalClientName)”.")
                + "\n\n" + alert.informativeText
        }

        alert.addButton(withTitle: String(localized: "Allow Once"))
        if let site {
            let title = externalClientName == nil
                ? String(localized: "Always Allow on \(site)")
                : String(localized: "Allow on \(site) for This Connection")
            alert.addButton(withTitle: title)
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.abort }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .abort) }
        }

        guard !Task.isCancelled else { return .decline }

        switch response {
        case .alertFirstButtonReturn:
            return .allowOnce
        case .alertSecondButtonReturn:
            return site == nil ? .decline : .allowAlways
        default:
            return .decline
        }
    }

    static func body(
        label: String,
        category: SensitiveAction.Category,
        site: String?,
        authoredByAI: Bool = false
    ) -> String {
        let location = site.map { String(localized: "on \($0)") } ?? String(localized: "on this page")
        let stakes = String(localized: """
            The assistant wants to click “\(label)” \(location). This \(String(localized: category.consequence)) \
            and usually can’t be undone.
            """)
        let injection = String(localized: """
            Webpages can carry hidden instructions aimed at the assistant. Allow this only if \
            it’s what you asked for.
            """)

        guard authoredByAI, category == .publication else {
            return stakes + "\n\n" + injection
        }

        let authored = String(localized: """
            The text in this form was written by AI, not by you. Publishing it puts \
            AI-generated text out under your name.
            """)
        return stakes + "\n\n" + authored + "\n\n" + injection
    }
}
