// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

/// Page dialogs on shared tabs. An open dialog blocks the page, so the call that caused it returns the dialog instead of
/// waiting, and every other page call refuses until `handleDialog` answers it.
@MainActor
extension MCPBrowserSession {
    nonisolated static let maxDialogReplyBytes = 4_096
    /// Calls after which Chromium asks about a beforeunload dialog a moment later than the call.
    nonisolated static let navigationTools: Set<String> = ["navigate", "goBack", "reloadPage"]

    // MARK: Control

    /// While a call that can act on `tab` runs, dialogs the page opens come to this connection instead of the user's sheet.
    /// Nil for a read: it does not control the tab.
    func controlDialogs(of tab: BrowserTab, capability: Scope) -> PageDialogQueue.Claim? {
        guard capability != .read else { return nil }
        return tab.dialogs.claim(connection: id) { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.permits(tab, capability: .control)
        }
    }

    /// Runs `work`, or returns nil as soon as a dialog opens on `tab` or this request is cancelled. The work is not stopped
    /// when a dialog opens: it is blocked behind the dialog and finishes once `handleDialog` answers.
    func interrupting<T: Sendable>(_ tab: BrowserTab, _ work: @escaping @MainActor () async -> T) async -> T? {
        let task = Task { await work() }
        switch await tab.dialogs.race(task) {
        case .finished(let value)?:
            return value
        case .dialog?:
            tab.dialogs.park(task)
        case nil:
            task.cancel()
        }
        return nil
    }

    // MARK: Results

    /// The result for a call that `interrupting` cut short.
    func interruptedResult(_ tab: BrowserTab) -> CallTool.Result {
        guard !Task.isCancelled else { return failure("The request was cancelled.") }
        return dialogReply(
            "dialogOpened", tab, isError: false,
            "The action reached the page and a dialog opened. The page is blocked until the dialog is answered. "
                + "Call handleDialog with its dialogID, then read the page; the action finishes after the answer.")
    }

    /// The refusal for a call on a tab whose page is blocked by a dialog, or nil when none is open.
    func dialogRefusal(for tab: BrowserTab) -> CallTool.Result? {
        guard tab.dialogs.hasOpenDialog else { return nil }
        return dialogReply(
            "dialogPending", tab, isError: true,
            "A dialog is open and blocks this page, so nothing was done. Call handleDialog to see and answer it.")
    }

    private func dialogReply(_ status: String, _ tab: BrowserTab, isError: Bool, _ message: String) -> CallTool.Result {
        var object: [String: Value] = ["status": .string(status), "tabID": .string(tab.id.uuidString), "message": .string(message)]
        object["dialogs"] = .array(tab.dialogs.pending(for: id).map(\.value))
        let value: Value = .object(object)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: isError)
    }

    // MARK: handleDialog

    func handleDialog(_ arguments: [String: Value], tab: BrowserTab) async -> CallTool.Result {
        let queue = tab.dialogs
        func result(_ kind: MCPDevelopmentTools.Kind, _ message: String, _ fields: [String: Value] = [:]) -> CallTool.Result {
            MCPDevelopmentTools.result(kind, tabID: tab.id, message: message, fields)
        }
        if tab.developmentRelation(of: id) == .other {
            return result(.ownershipConflict, "Another connection is using development tools on this tab. Nothing was changed.")
        }
        let open = queue.pending(for: id)
        guard !open.isEmpty else { return result(.invalidInput, "No dialog is open on this tab.") }
        guard let dialogID = arguments["dialogID"]?.stringValue else {
            return result(.ok, "Call handleDialog again with a dialogID and an action to answer.", ["dialogs": .array(open.map(\.value))])
        }
        guard let action = arguments["action"]?.stringValue, action == "accept" || action == "dismiss" else {
            return result(.invalidInput, "action must be accept or dismiss.")
        }
        guard let dialog = open.first(where: { $0.id == dialogID }) else {
            return result(.stale, "That dialog is not open any more. Call handleDialog without a dialogID to see what is open.")
        }
        guard !dialog.userMustAnswer else {
            return result(.denied, "The user has to answer this dialog in WSurf. Say what is waiting for them and stop.")
        }
        let accepted = action == "accept"
        let reply = arguments["text"]?.stringValue
        if let reply {
            guard dialog.kind == .prompt, accepted, reply.utf8.count <= Self.maxDialogReplyBytes else {
                return result(.invalidInput, "text is only for accepting a prompt, and at most \(Self.maxDialogReplyBytes) bytes.")
            }
        }
        var authorization: PageDialogQueue.Authorization?
        if accepted, dialog.kind == .prompt {
            // The user reads the whole reply before approving it, so it has to fit the question.
            let answer = reply ?? queue.request(of: dialogID)?.defaultText ?? ""
            guard answer.unicodeScalars.count <= PageDialogText.maxReplyScalars else {
                return result(
                    .invalidInput,
                    reply == nil
                        ? "The prompt's default text is longer than \(PageDialogText.maxReplyScalars) characters, which the user cannot read whole. Send your own text."
                        : "A prompt reply is at most \(PageDialogText.maxReplyScalars) characters, so the user can read all of it before approving. Nothing was sent.")
            }
        }
        if accepted, let request = queue.request(of: dialogID) {
            switch await approval(for: request, reply: reply, tab: tab) {
            case .notNeeded:
                break
            case .granted(let granted):
                authorization = granted
            case .refused(let reason):
                return result(.denied, reason)
            }
            guard mayProceed(tab, capability: .control) else {
                return result(.denied, "Page access changed while the user was asked. Nothing was answered.")
            }
        }
        // Dialogs that the freed page opens next come back in this reply.
        let claim = controlDialogs(of: tab, capability: .control)
        defer { claim?.end() }
        guard queue.answer(dialogID, connection: id, with: .init(accepted: accepted, text: reply), authorization: authorization) else {
            return result(.stale, "That dialog is no longer waiting for an answer. Call handleDialog without a dialogID to see what is open.")
        }
        observations[tab.id] = nil
        await queue.settleParked()
        let answered: Value = .object([
            "dialogID": .string(dialogID), "type": .string(dialog.kind.rawValue), "answer": .string(accepted ? "accepted" : "dismissed"),
        ])
        return result(
            .ok, "The dialog was answered. Read the page again before acting on it.",
            ["answered": answered, "dialogs": .array(queue.pending(for: id).map(\.value))])
    }
}

/// Who has to agree before a connection's answer reaches the page.
private enum DialogApproval {
    case notNeeded
    case granted(PageDialogQueue.Authorization)
    case refused(String)
}

extension MCPBrowserSession {
    /// Accepting an alert needs nothing. Accepting a confirm, a beforeunload or a prompt can carry a decision, so the user is
    /// asked when the page's wording or the reply names a purchase, transfer, deletion or posting. A prompt is also
    /// the user's words in the page, so any accepted reply needs the user's approval, except from a connection with
    /// development access on a page on this Mac.
    fileprivate func approval(for request: PageDialogQueue.Request, reply: String?, tab: BrowserTab) async -> DialogApproval {
        let host = webURL(of: tab)?.host()
        func declined(_ what: String) -> DialogApproval {
            .refused("The user did not approve answering this dialog. \(what) Say what is waiting for them and stop.")
        }
        switch request.kind {
        case .alert:
            return .notNeeded
        case .confirm, .beforeUnload:
            guard let category = PageDialogText.consequence(of: request.message) else { return .notNeeded }
            let permitted = await AgentActionConsent.permit(
                label: String(request.message.prefix(80)), category: category, host: host, policy: nil)
            return permitted ? .granted(.consent) : declined("It \(category.consequenceForModel), so it is theirs to do.")
        case .prompt:
            let answer = reply ?? request.defaultText ?? ""
            let consequence = PageDialogText.consequence(of: request.message, reply: answer)
            if consequence == nil, developerMayAnswerPrompts(on: tab, origin: request.origin) {
                return .granted(.developer)
            }
            // Always asked here. A stored "always allow" for a consequence category and site (what `permit` honours) does not
            // answer for a prompt's reply, and a consequence is shown in this question, not asked in place of it.
            let permitted = await AgentActionConsent.permitPromptReply(answer, to: request.message, host: host, consequence: consequence)
            if permitted {
                return .granted(.consent)
            }
            return declined(consequence.map { "It \($0.consequenceForModel), so it is theirs to do." } ?? "A prompt asks for the user's words.")
        }
    }

    /// The development gate for prompts: this connection has development access and the page and the dialog are on this Mac.
    /// P4 hook: this is the one place to switch to the Developer tier (paired client, Developer profile, developer site,
    /// Developer access) when that exists.
    fileprivate func developerMayAnswerPrompts(on tab: BrowserTab, origin: String) -> Bool {
        guard grants[tab.id]?.access == .development, permits(tab, capability: .development), let url = webURL(of: tab) else {
            return false
        }
        return PageDialogText.isLoopbackOrigin(origin) && PageDialogText.isLoopbackOrigin(PageDialogText.origin(ofURL: url.absoluteString))
    }
}

extension PageDialogQueue.Summary {
    /// The dialog as a connection sees it. The message and default text are page text, so they are wrapped as untrusted.
    var value: Value {
        var object: [String: Value] = [
            "dialogID": .string(id), "type": .string(kind.rawValue), "message": .string(AgentToolkit.untrusted(message)),
            "origin": .string(origin), "truncated": .bool(truncated), "userMustAnswer": .bool(userMustAnswer),
        ]
        if let defaultText {
            object["defaultText"] = .string(AgentToolkit.untrusted(defaultText))
        }
        if kind == .beforeUnload {
            object["reload"] = .bool(isReload)
        }
        return .object(object)
    }
}
