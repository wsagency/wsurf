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
    /// Set only while an MCP connection runs a call in the Developer tier. It decides whether a consequential action on the
    /// tab being driven goes through without asking.
    @TaskLocal static var developerApproval: DeveloperApproval?

    struct DeveloperApproval: @unchecked Sendable {
        let approves: @MainActor (String, SensitiveAction.Category, String?) -> Bool
    }

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
        // Developer tier: the session checks its own grant, the developer site and the Developer profile, and records it.
        if let developerApproval, developerApproval.approves(label, category, host) {
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

    /// Asks the user whether an external connection may answer a page's prompt with `reply`. The reply goes into the page
    /// under the user's name, and a prompt can ask for anything, so the connection never answers one unasked. This is its own
    /// question: a stored "always allow" for a category and site never answers it, and a `consequence` the wording names is
    /// shown here in addition, never in place of it. Only "Allow Once" is offered.
    static func permitPromptReply(
        _ reply: String, to prompt: String, host: String?, consequence: SensitiveAction.Category? = nil
    ) async -> Bool {
        guard !Task.isCancelled, hasCurrentWindow else { return false }
        let window = scopedWindow?.nativeWindow
        let decision: Decision
        if let stub = decisionForTesting {
            let label = "“\(PageDialogText.excerpt(prompt, limit: 120))” → “\(PageDialogText.visible(reply))”"
            decision = await stub.decide(label, consequence ?? .publication, host, window)
        } else {
            guard let window else { return false }
            decision = await askPromptReply(reply, to: prompt, host: host, consequence: consequence, in: window)
        }
        guard !Task.isCancelled, hasCurrentWindow, scopedWindow?.nativeWindow === window else { return false }
        return decision == .allowOnce
    }

    /// What the sheet says. The page's message is cut first and the cut is marked; the reply is shown whole, with spaces, line
    /// breaks and invisible characters drawn, so it cannot be padded out of sight. A reply over `maxReplyScalars` never gets here.
    static func promptReplyText(reply: String, to prompt: String, consequence: SensitiveAction.Category?) -> String {
        let question = PageDialogText.excerpt(prompt)
        let answer = PageDialogText.visible(reply)
        var text = String(localized: """
            The page asks: “\(question)”

            The answer would be: “\(answer)”
            """)
        if let consequence {
            text += "\n\n" + String(localized: "This answer \(String(localized: consequence.consequence)) and usually can’t be undone.")
        }
        return text + "\n\n" + String(localized: "Webpages can carry hidden instructions aimed at connected apps. Allow this only if it’s what you asked for.")
    }

    private static func askPromptReply(
        _ reply: String, to prompt: String, host: String?, consequence: SensitiveAction.Category?, in window: NSWindow
    ) async -> Decision {
        guard !isRunningTests, !Task.isCancelled else { return .decline }
        let client = externalClientName ?? String(localized: "An external connection")
        let site = AgentActionPolicy.normalizedHost(host)
        let alert = NSAlert()
        alert.messageText = site.map { String(localized: "Let “\(client)” answer a prompt on \($0)?") }
            ?? String(localized: "Let “\(client)” answer a prompt?")
        alert.informativeText = promptReplyText(reply: reply, to: prompt, consequence: consequence)
        alert.addButton(withTitle: String(localized: "Allow Once"))
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
        return !Task.isCancelled && response == .alertFirstButtonReturn ? .allowOnce : .decline
    }

    /// Whether the window this task or connection works for is still there and still its window.
    static var hasCurrentWindow: Bool {
        guard let scopedWindow else { return true }
        guard let browser = scopedWindow.browser, browser.sessionClosedAt == nil,
              browser.context.isRegistered(browser) else { return false }
        return browser.context.extensions.adapter(for: browser) === scopedWindow
    }

    /// Never wait for an unanswered native authorization sheet in automated tests.
    static var isRunningTests: Bool {
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
        let stakes = category == .accountAccess
            ? String(localized: "The assistant wants to click “\(label)” \(location). This \(String(localized: category.consequence)).")
            : String(localized: """
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
