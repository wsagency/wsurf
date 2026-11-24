// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP

/// Injectable blind-fill bridge for MCP `vaultHint` and `requestUserLogin`.
///
/// Production delegates all Vault access to `VaultBlindLoginBridge` under `WSurf/Web/Autofill/`, so MCP code never reads
/// Vault stores and never receives saved passwords. Unit tests inject a deterministic in-memory provider without touching
/// the Keychain.
@MainActor
struct MCPVaultProvider {
    typealias AccountSummary = VaultBlindLoginBridge.Summary

    /// Returns matching saved-login labels for `(tab, url)` ordered with any `accountHint` matches first.
    var savedAccounts: @MainActor (BrowserTab, URL, String?) async -> [AccountSummary]
    /// Blind-fills the user-approved login directly into `view`, registering the password with the session's output
    /// scrubber before touching the DOM. Returns nil if the Vault entry could not be read.
    var blindFill: @MainActor (
        BrowserTab, BrowserPage, URL, AccountSummary, Bool, @MainActor (String) -> Void
    ) async -> PageDriver.VaultFillResult?

    static func live(browser: BrowserModel) -> MCPVaultProvider {
        MCPVaultProvider(
            savedAccounts: { [weak browser] tab, url, hint in
                guard let browser else { return [] }
                return await VaultBlindLoginBridge.savedSummaries(in: browser, tab: tab, url: url, accountHint: hint)
            },
            blindFill: { [weak browser] tab, view, url, account, submit, registerSecret in
                guard let browser else { return nil }
                return await VaultBlindLoginBridge.blindFill(
                    account: account, submit: submit, in: browser, tab: tab, view: view, url: url,
                    registerSecret: registerSecret)
            }
        )
    }
}

/// Document-scoped credential protection (`credentialTainted`), anonymized `vaultHint`, and `requestUserLogin`.
@MainActor
extension MCPBrowserSession {
    /// Identifies a document that WSurf Vault filled credentials into. Cleared automatically once navigation commits to
    /// another document.
    struct CredentialTaint: Equatable, Sendable {
        let runtimeDocumentID: String
        let mainDocumentID: String?
    }

    // MARK: Credential protection

    /// Marks `tab`'s current document as credential-tainted and strips any already-buffered diagnostics bodies/previews on it.
    func markCredentialTainted(tab: BrowserTab, runtimeDocumentID: String, mainDocumentID: String?) {
        credentialTaintedDocuments[tab.id] = CredentialTaint(runtimeDocumentID: runtimeDocumentID, mainDocumentID: mainDocumentID)
        if let mainDocumentID {
            ownLease(tab)?.diagnostics?.taintDocument(mainDocumentID)
        }
    }

    /// Explicitly marks `(tab, documentID)` as user-approved for sensitive script inspection (never granted automatically).
    func approveSensitiveInspection(for tab: BrowserTab, documentID: String) {
        inspectionApprovedDocuments[tab.id] = documentID
    }

    /// Whether `mainDocumentID` on `tab` is currently marked `credentialTainted` from a Vault fill. Prunes stale taint
    /// automatically once navigation commits to a new main document.
    func isMainDocumentCredentialTainted(tab: BrowserTab, mainDocumentID: String) -> Bool {
        guard let taint = credentialTaintedDocuments[tab.id] else { return false }
        if let taintedMain = taint.mainDocumentID {
            if taintedMain == mainDocumentID {
                return true
            }
            credentialTaintedDocuments[tab.id] = nil
            return false
        }
        return false
    }

    /// Whether `tab`'s current document must block `evaluateScript`: true whenever (a) WSurf Vault filled credentials into
    /// this document (`credentialTainted`) OR (b) the DOM currently holds a non-empty sensitive secret field that the user has
    /// not explicitly approved for inspection. Fails closed if the page cannot be probed.
    func isDocumentCredentialProtected(tab: BrowserTab, view: BrowserPage) async -> Bool {
        guard let state = await PageDriver.protectedSecretState(in: view) else { return true }
        if let taint = credentialTaintedDocuments[tab.id] {
            let sameRuntime = taint.runtimeDocumentID == state.documentID
            let sameMain = taint.mainDocumentID != nil && taint.mainDocumentID == view.mainDocumentID
            if sameRuntime || sameMain {
                return true
            }
            // Navigation committed to a new document: clear stale taint automatically.
            credentialTaintedDocuments[tab.id] = nil
        }
        if state.hasFilledSecret {
            return inspectionApprovedDocuments[tab.id] != state.documentID
        }
        if let approved = inspectionApprovedDocuments[tab.id], approved != state.documentID {
            inspectionApprovedDocuments[tab.id] = nil
        }
        return false
    }

    // MARK: Anonymized vaultHint

    /// Returns `{ hasSavedLogin: Bool, requiresUserApproval: true }` when `view` currently displays a visible login/password
    /// form, or nil otherwise. Never discloses usernames, account counts, or passwords.
    func vaultHint(for tab: BrowserTab, view: BrowserPage, url: URL) async -> Value? {
        guard await PageDriver.hasLoginForm(in: view) else { return nil }
        let accounts = await vaultProvider.savedAccounts(tab, url, nil)
        guard isConnected, available(), !Task.isCancelled, webURL(of: tab) == url else { return nil }
        return .object([
            "hasSavedLogin": .bool(!accounts.isEmpty),
            "requiresUserApproval": .bool(true),
        ])
    }

    // MARK: requestUserLogin

    func requestUserLogin(_ arguments: [String: Value], tab: BrowserTab) async -> CallTool.Result {
        let mode = arguments["mode"]?.stringValue ?? "vaultOrManual"
        guard ["vaultOrManual", "vaultFill", "manualLogin"].contains(mode) else {
            return failure("mode must be vaultOrManual, vaultFill, or manualLogin.")
        }
        let reason = arguments["reason"]?.stringValue
        if let reason, reason.utf8.count > 200 {
            return failure("reason must be at most 200 UTF-8 bytes.")
        }
        let accountHint = arguments["accountHint"]?.stringValue
        if let accountHint, accountHint.utf8.count > 100 {
            return failure("accountHint must be at most 100 UTF-8 bytes.")
        }

        if mode == "manualLogin" {
            handBack(tab)
            return loginResult(
                status: "waitingForUser", tabID: tab.id,
                message: "Control was handed to the user. Ask the user to sign in in WSurf and share control again.")
        }

        tab.setExternalAutomationWorking(true)
        defer { tab.setExternalAutomationWorking(false) }
        tab.realizeDeferredSession()
        let view = tab.page
        let generation = tab.pageGeneration
        guard tab.isLive(view, generation: generation), let url = webURL(of: tab) else {
            return failure("The webpage is unavailable.")
        }

        let accounts = await vaultProvider.savedAccounts(tab, url, accountHint)
        guard mayProceed(tab, capability: .control), tab.isLive(view, generation: generation), webURL(of: tab) == url else {
            return failure("Page access changed before login approval.")
        }

        if mode == "vaultFill", accounts.isEmpty {
            return loginResult(
                status: "noSavedLogin", tabID: tab.id,
                message: "No saved WSurf Vault login is available for this website. Call requestUserLogin with mode \"manualLogin\" or \"vaultOrManual\" to let the user sign in.")
        }

        let choice = await loginConsent(clientName, url, !accounts.isEmpty, accounts.map(\.label), reason)
        guard isConnected, available(), !Task.isCancelled else {
            return failure("Connection is unavailable. Reconnect and request access again.")
        }
        guard mayProceed(tab, capability: .control), tab.isLive(view, generation: generation), webURL(of: tab) == url else {
            return failure("Page access changed while waiting for login approval.")
        }

        switch choice {
        case .decline:
            return loginResult(status: "declined", tabID: tab.id, message: "The user declined the login request.")
        case .takeOver:
            handBack(tab)
            return loginResult(
                status: "waitingForUser", tabID: tab.id,
                message: "The user chose to sign in themselves. Ask the user to sign in in WSurf and share control again.")
        case .fill, .fillAndSignIn:
            guard let account = accounts.first else {
                return loginResult(
                    status: "noSavedLogin", tabID: tab.id,
                    message: "No saved WSurf Vault login is available for this website.")
            }
            guard mayProceed(tab, capability: .control), isReachable(tab),
                tab.isLive(view, generation: generation), webURL(of: tab) == url
            else {
                return failure("Page access changed before credentials could be filled.")
            }
            let preSubmitMainDocumentID = view.mainDocumentID
            let guardScope = PageAutomationGuard(
                documentURL: url.absoluteString, snapshot: nil,
                validate: { [weak self, weak tab, weak view] in
                    guard let self, let tab, let view, tab.isLive(view, generation: generation) else { return false }
                    return self.mayProceed(tab, capability: .control) && self.isReachable(tab)
                })
            let (preSubmitRuntimeDocumentID, fillResult) = await PageAutomationGuard.$current.withValue(guardScope) {
                let preState = await PageDriver.protectedSecretState(in: view)
                let filled = await vaultProvider.blindFill(tab, view, url, account, choice == .fillAndSignIn) { [secrets] secret in
                    secrets.register(secret)
                    secrets.confirm(secret)
                }
                return (preState?.documentID, filled)
            }
            AutofillSuggestions.shared.dismiss(in: view)
            tab.autofillSave.clear()
            guard let fill = fillResult else {
                return failure("Could not read the saved login from WSurf Vault. Ask the user to unlock WSurf Vault or sign in manually.")
            }
            guard fill.ok else {
                return failure(fill.error ?? "Could not fill the login form.")
            }
            if let documentID = fill.documentID ?? preSubmitRuntimeDocumentID {
                markCredentialTainted(tab: tab, runtimeDocumentID: documentID, mainDocumentID: preSubmitMainDocumentID)
            }
            let message = fill.submitted
                ? "WSurf Vault filled the login form and requested sign-in. Values remain hidden and this document is credential-protected."
                : "WSurf Vault filled the login form without submitting. Values remain hidden and this document is credential-protected."
            return loginResult(
                status: "filledByVault",
                tabID: tab.id,
                message: message,
                extra: [
                    "submitted": .bool(fill.submitted),
                    "fieldsFilled": .array(fill.fieldsFilled.map { .string($0) }),
                    "valuesHidden": .bool(true),
                    "documentProtected": .bool(true),
                ])
        }
    }

    private func loginResult(
        status: String, tabID: UUID, message: String, extra: [String: Value] = [:]
    ) -> CallTool.Result {
        var object = extra
        object["status"] = .string(status)
        object["tabID"] = .string(tabID.uuidString)
        object["message"] = .string(message)
        let value: Value = .object(object)
        return CallTool.Result(
            content: [.text(text: encoded(value), annotations: nil, _meta: nil)],
            structuredContent: Optional.some(value),
            isError: false)
    }
}
