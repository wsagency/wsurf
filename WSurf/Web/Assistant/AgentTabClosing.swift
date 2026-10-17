// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Whether an agent may close an ordinary tab without asking. It counts only under the Allow Control default
/// (`SitePermissions.allowsClosingTabsWithoutAsking`); everywhere else the question comes first.
nonisolated enum AssistantTabClosing: String, Codable, CaseIterable, Sendable {
    case ask
    case allow

    var label: LocalizedStringResource {
        switch self {
        case .ask:
            "Ask to close tabs"
        case .allow:
            "Allow closing tabs"
        }
    }

    /// The Settings caption. The setting is the assistant's: connected apps never read it (see `MCPBrowserSession.closeTab`).
    nonisolated static let caption: LocalizedStringResource =
        "Pinned tabs are never closed. The assistant can always close tabs it opened. Connected apps ask unless they opened the tab or have Developer access."
}

/// The question before an agent closes a tab, and what the person may answer.
///
/// Pinned tabs never get here: no agent closes those, under any setting. Tabs the agent opened itself, in this task or on this
/// connection, close without asking, and the caller (which knows them) skips the question for them.
@MainActor
enum AgentTabClosing {
    enum Answer: Equatable {
        case close
        /// Close it, and stop asking for the rest of this task (in-app) or connection (external).
        case closeAndStopAsking
        case keepOpen
    }

    /// What the sheet is about.
    struct Question: Equatable {
        let title: String
        let isPrivate: Bool
        /// The external connection that wants to close the tab; nil for the in-app assistant.
        let client: String?
    }

    struct Stub: @unchecked Sendable {
        let decide: @MainActor (Question) async -> Answer

        init(_ decide: @escaping @MainActor (Question) async -> Answer) {
            self.decide = decide
        }
    }

    @TaskLocal static var decisionForTesting: Stub?

    /// The person's answer. Anything but a clear yes keeps the tab open: no window to ask in, a task or connection that ended
    /// while the sheet was open, or a window that went away.
    static func ask(title: String, isPrivate: Bool) async -> Answer {
        guard !Task.isCancelled, AgentActionConsent.hasCurrentWindow else { return .keepOpen }
        let window = AgentActionConsent.scopedWindow?.nativeWindow
        let question = Question(title: title, isPrivate: isPrivate, client: AgentActionConsent.externalClientName)
        let answer: Answer
        if let stub = decisionForTesting {
            answer = await stub.decide(question)
        } else {
            guard let window, !AgentActionConsent.isRunningTests else { return .keepOpen }
            answer = await present(question, in: window)
        }
        guard !Task.isCancelled, AgentActionConsent.hasCurrentWindow,
            AgentActionConsent.scopedWindow?.nativeWindow === window
        else { return .keepOpen }
        return answer
    }

    /// The page's title for a sheet: one line, cut at `limit` characters with "…" so the cut shows.
    static func shown(_ title: String, limit: Int = 80) -> String {
        let flat = String(String.UnicodeScalarView(title.unicodeScalars.map {
            $0.properties.generalCategory == .control || $0.properties.isWhitespace ? " " : $0
        }))
        let words = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard words.count > limit else { return words }
        return String(words.prefix(limit)) + "…"
    }

    static func heading(for question: Question) -> String {
        let name = shown(question.title)
        return name.isEmpty ? String(localized: "Close this tab?") : String(localized: "Close “\(name)”?")
    }

    static func body(for question: Question) -> String {
        let wants = question.client.map { String(localized: "“\($0)” wants to close this tab.") }
            ?? String(localized: "The assistant wants to close this tab.")
        // A private tab leaves no record to reopen.
        guard !question.isPrivate else { return wants }
        return wants + " " + String(localized: "You can reopen it with Reopen Last Closed Tab.")
    }

    private static func present(_ question: Question, in window: NSWindow) async -> Answer {
        let alert = NSAlert()
        alert.messageText = heading(for: question)
        alert.informativeText = body(for: question)
        alert.addButton(withTitle: String(localized: "Close Tab"))
        alert.addButton(withTitle: String(localized: "Keep Open"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = question.client == nil
            ? String(localized: "Don’t ask again for this task")
            : String(localized: "Don’t ask again for this connection")
        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.abort }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .abort) }
        }
        guard !Task.isCancelled, response == .alertFirstButtonReturn else { return .keepOpen }
        return alert.suppressionButton?.state == .on ? .closeAndStopAsking : .close
    }
}
