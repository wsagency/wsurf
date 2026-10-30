// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import WebKit

/// "Code from Messages or Mail…": the last row of the dropdown of a verification-code field. Choosing it puts a native field over the
/// page's field (`MessagesCodeBridge`), where macOS lists the codes that reached Messages or Mail, and the code picked there fills
/// that one page field through the transport a vault code uses (`__wsurfPasswords.fill`). A code is never read from Messages or Mail
/// by WSurf: it is whatever the person picks in the system's own list, and it is never kept (no log, history, pasteboard or vault).
extension AutofillSuggestions {
    /// Whether a field is offered the row, decided before anything is read: a code field of a normal window, in no tab the
    /// assistant or a connected app controls, whatever the vault holds or whether it is locked.
    nonisolated static func offersMessagesCode(
        kind: AutofillSaveKind, field: CredentialAutofillField, isPrivate: Bool, underAssistantControl: Bool
    ) -> Bool {
        kind == .password && field == .totp && !isPrivate && !underAssistantControl
    }

    static func messagesCodeRow(kind: AutofillSaveKind, field: CredentialAutofillField, origin: String, in page: BrowserPage) -> AutofillSuggestion? {
        guard offersMessagesCode(kind: kind, field: field, isPrivate: page.context.profile.isPrivate, underAssistantControl: isAgentControlled(page)) else {
            return nil
        }
        return AutofillSuggestion(id: UUID(), title: String(localized: "Code from Messages or Mail…"), detail: "", origin: origin)
    }

    /// The field the page just got its focus back in, until `until`: its own focus event is not a reason to open the dropdown.
    struct Quiet {
        let page: ObjectIdentifier
        let documentID: String
        let fieldID: String
        let until: ContinuousClock.Instant
    }

    /// Where a code goes: the frame, the document and the field token of the request that asked, and nowhere else.
    struct CodeDestination {
        let frame: BrowserFrame
        let world: WKContentWorld
        let bridge: String
        let token: String
        let url: String
        let documentID: String
    }

    /// Delivers `code` into the field `destination` names, in its frame only, through the call every dropdown fill uses. The page
    /// script fills only while the field's token, URL and document are the ones it gave, the field is still the lone code field of a
    /// safe form, and it is still where it was; `authority` is asked at the engine's dispatch boundary. Whether the page took it.
    static func deliverCode(
        _ code: String, to destination: CodeDestination, in page: BrowserPage, authority: @escaping @MainActor @Sendable () throws -> Void
    ) async throws -> Bool {
        nonisolated(unsafe) let fields: [String: Any] = ["code": code]
        let answer = try await page.callAsyncJavaScript(
            "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return 0; return globalThis[bridge]?.fill(token, url, fields) || 0;",
            in: destination.frame,
            contentWorld: destination.world,
            prepareArguments: {
                try authority()
                return [
                    "bridge": destination.bridge, "token": destination.token, "url": destination.url, "fields": fields,
                    "documentID": destination.documentID,
                ]
            }
        )
        return ((answer as? NSNumber)?.intValue ?? 0) > 0
    }

    /// The row was chosen: the panel closes and the native field takes its place, over the field that asked. Only while the request
    /// is still the page's, its frame and field are as they were and the tab is in front.
    func openMessagesCode(_ request: Request, in page: BrowserPage) {
        messagesCode?.end(.replaced)
        dismiss()
        request.isMessagesCode = true
        let key = ObjectIdentifier(page)
        Task { [weak self, weak page] in
            guard let self, let page, requests[key] === request, (try? await validate(request, in: page, requiresFocus: true)) != nil,
                  requests[key] === request, let site = SavedPassword.origin(for: request.frameURL).flatMap(WebsiteLookalike.displayHost(of:)) else {
                return
            }
            messagesCode = MessagesCodeBridge(
                page: page, rect: request.rect, site: site,
                isCurrent: { [weak self, weak page] in
                    guard let self, let page else { return false }
                    return (try? requireAuthority(request, in: page)) != nil
                },
                deliver: { [weak self, weak page] code in
                    guard let self, let page else { return false }
                    return await forwardMessagesCode(code, request: request, in: page)
                },
                finished: { [weak self] bridge, ending in
                    guard let self, messagesCode === bridge else { return }
                    messagesCode = nil
                    // The page's own focus event, which follows a returned focus, would open the dropdown again over the filled field.
                    quiet = ending.returnsFocus
                        ? Quiet(page: key, documentID: request.documentID, fieldID: request.fieldID, until: .now.advanced(by: .seconds(2))) : nil
                }
            )
        }
    }

    /// The picked code, checked once more: the request is still the page's with its frame, document and field unchanged (focus is
    /// not asked for, the native field holds it), and the bridge is still open at the moment the engine dispatches.
    private func forwardMessagesCode(_ code: String, request: Request, in page: BrowserPage) async -> Bool {
        do {
            try await validate(request, in: page)
            let destination = CodeDestination(
                frame: request.frame, world: request.world, bridge: request.bridge, token: request.token,
                url: request.frameURL.absoluteString, documentID: request.documentID
            )
            return try await Self.deliverCode(code, to: destination, in: page) { [weak self, weak page] in
                guard let self, let page, messagesCode?.isOpen == true, !page.isParked else { throw ContactAutofillError.changedPage }
                try requireAuthority(request, in: page)
            }
        } catch {
            return false
        }
    }

    func isQuiet(_ page: BrowserPage, documentID: String, fieldID: String) -> Bool {
        guard let quiet else { return false }
        return quiet.page == ObjectIdentifier(page) && quiet.documentID == documentID && quiet.fieldID == fieldID && .now < quiet.until
    }
}
