// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import LocalAuthentication

/// One selectable account in a ceremony prompt. `id` is the vault account ID (registration) or the passkey ID
/// (assertion); it is never a username, so duplicate or case-distinct usernames stay distinct.
nonisolated struct WebAuthnPromptChoice: Sendable, Equatable {
    let id: UUID
    let title: String
    let detail: String
}

nonisolated struct WebAuthnPrompt: Sendable, Equatable {
    enum Operation: Sendable { case create, get }

    let operation: Operation
    /// The native, verified origin of the document (never page-supplied text).
    let origin: String
    let topOrigin: String?
    let rpID: String
    /// Registration only: the user name the site asked to register.
    let requestedUserName: String?
    let choices: [WebAuthnPromptChoice]
    /// Registration only: whether "new account" is offered. It is always the default; nothing merges by username.
    let offersNewAccount: Bool
    let userVerification: WebAuthnUserVerification
    let willVerifyUser: Bool
}

nonisolated enum WebAuthnDecision: Sendable, Equatable {
    /// `nil` selects "new account" (registration only).
    case approved(choice: UUID?)
    case declined
    case expired
    case cancelled
    /// "Use Another Device or Key…": the request goes to the system's own authenticator. Nothing was written or signed.
    case handOff
}

/// Everything a ceremony needs from the user. The native implementation is the only production one; tests may script
/// it to reach cancellation, expiry and verification outcomes without a window. A scripted user is not evidence of
/// native user presence or verification.
@MainActor
protocol WebAuthnCeremonyInteraction {
    var canVerifyUser: Bool { get }
    func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision
    /// Explicit origin-bearing native step before any unlock, verification or signing: always for a conditional
    /// (dropdown-started) request, and for a modal request whenever the vault is locked, so the system unlock sheet is never
    /// the first thing a page can put in front of the user. Every step of the vault's own UI also offers the way out to the
    /// system's authenticator, so the user is never stuck with the vault's answer.
    func offerStart(operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision
    /// Fresh system user verification. Returns only on success; every other outcome throws.
    func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws
    /// Best effort: tells the user a registration was saved although delivery to the website could not be confirmed.
    func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor)
}

@MainActor
struct NativeWebAuthnInteraction: WebAuthnCeremonyInteraction {
    /// Capability discovery only; a throwaway context is never an approval.
    var canVerifyUser: Bool {
        let context = LAContext()
        defer { context.invalidate() }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
        guard !Task.isCancelled else { return .cancelled }
        // A window already showing a sheet is refused, never queued behind it by AppKit.
        guard anchor.isVisible, !anchor.isMiniaturized, anchor.attachedSheet == nil else { return .declined }

        let nothing = Self.hasNothingToApprove(prompt)
        let alert = NSAlert()
        alert.messageText = Self.title(for: prompt)
        alert.informativeText = Self.body(for: prompt)
        if nothing {
            // Nothing of ours to approve, but the step is the same one with the same origin: the way on is the system's
            // authenticator, and Cancel is Cancel.
            alert.addButton(withTitle: Self.handOffTitle)
            alert.addButton(withTitle: String(localized: "Cancel"))
        } else {
            alert.addButton(withTitle: prompt.operation == .create
                ? String(localized: "Create Passkey") : String(localized: "Use Passkey"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: Self.handOffTitle)
        }

        let popup = Self.makeChooser(for: prompt)
        popup.map { alert.accessoryView = $0 }

        switch await NativeSheet.present(alert, in: anchor, until: deadline) {
        case .expired:
            return .expired
        case .cancelled:
            return .cancelled
        case let .response(response):
            if nothing {
                return response == .alertFirstButtonReturn ? .handOff : .declined
            }
            if response == .alertThirdButtonReturn {
                return .handOff
            }
            guard response == .alertFirstButtonReturn else { return .declined }
            guard let popup else { return .approved(choice: prompt.offersNewAccount ? nil : prompt.choices.first?.id) }
            return Self.decision(from: popup)
        }
    }

    /// The same words on every sheet that offers it: choosing it hands the request to the system's own authenticator, which is
    /// where passkeys kept in Apple Passwords, on a phone or on a security key live.
    static let handOffTitle = String(localized: "Use Another Device or Key…")

    /// Declining leaves a conditional page request pending and fails a modal one; nothing is unlocked either way.
    func offerStart(operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
        guard !Task.isCancelled else { return .cancelled }
        guard anchor.isVisible, !anchor.isMiniaturized, anchor.attachedSheet == nil else { return .declined }
        let alert = NSAlert()
        alert.messageText = operation == .create
            ? String(localized: "Create a passkey?") : String(localized: "Sign in with a saved passkey?")
        alert.informativeText = String(localized: "Website: \(origin)")
            + "\n" + (locked
                ? String(localized: "Credential Manager is locked. You will unlock it, then choose an account.")
                : String(localized: "You will choose an account next."))
        alert.addButton(withTitle: locked ? String(localized: "Unlock and Choose…") : String(localized: "Choose…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: Self.handOffTitle)
        switch await NativeSheet.present(alert, in: anchor, until: deadline) {
        case .expired:
            return .expired
        case .cancelled:
            return .cancelled
        case let .response(response):
            switch response {
            case .alertFirstButtonReturn:
                return .approved(choice: nil)
            case .alertThirdButtonReturn:
                return .handOff
            default:
                return .declined
            }
        }
    }

    func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {
        // A new context per ceremony with no reuse window: vault unlock, card access or an earlier ceremony can
        // never stand in for this verification.
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var capability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &capability) else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        final class Flag: @unchecked Sendable { var expired = false }
        let flag = Flag()
        nonisolated(unsafe) let unsafeContext = context
        // No deadline (a conditional request) means no timer: only cancellation ends the verification early.
        let timer = deadline.map { deadline in
            Task {
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                flag.expired = true
                unsafeContext.invalidate()
            }
        }
        defer { timer?.cancel() }
        let verified: Bool
        do {
            verified = try await withTaskCancellationHandler {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } onCancel: {
                unsafeContext.invalidate()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw flag.expired ? WebsiteAuthenticatorError.expired : WebsiteAuthenticatorError.notAllowed
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        guard verified else { throw WebsiteAuthenticatorError.notAllowed }
    }

    func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {
        // Best effort only: the manager's notice (memory-only, at most 16) is shown in Credential Settings while this session lives.
        guard anchor.isVisible, !anchor.isMiniaturized, anchor.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Passkey saved, but not confirmed")
        alert.informativeText = String(localized: """
            A passkey for “\(userName)” on \(rpID) was saved to Credential Manager, but WSurf could not confirm \
            that the website received it. Test signing in on the website, and remove the passkey in Settings if it does not work.
            """)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: anchor)
    }

    // MARK: Prompt text

    struct Entry { let id: UUID?; let title: String }

    /// Registration always lists "New account" first; assertion lists exactly the matching passkeys, or nothing
    /// to pick when there is a single one.
    static func entries(for prompt: WebAuthnPrompt) -> [Entry] {
        var entries: [Entry] = []
        if prompt.offersNewAccount {
            let name = prompt.requestedUserName.map { " “\($0)”" } ?? ""
            entries.append(Entry(id: nil, title: String(localized: "New account\(name)")))
        }
        entries += prompt.choices.map { Entry(id: $0.id, title: "\($0.title) — \($0.detail)") }
        return prompt.offersNewAccount || prompt.choices.count > 1 ? entries : []
    }

    /// One distinct menu item per entry, each carrying its own identity. `NSPopUpButton.addItem(withTitle:)` would
    /// remove an existing item with the same title, so a title can never be what identifies the chosen account.
    static func makeChooser(for prompt: WebAuthnPrompt) -> NSPopUpButton? {
        let entries = entries(for: prompt)
        guard !entries.isEmpty else { return nil }
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.representedObject = entry
            button.menu?.addItem(item)
        }
        button.selectItem(at: 0)
        return button
    }

    /// The answer for whatever is selected right now, or a refusal when nothing identifiable is.
    static func decision(from chooser: NSPopUpButton) -> WebAuthnDecision {
        guard let entry = chooser.selectedItem?.representedObject as? Entry else { return .declined }
        return .approved(choice: entry.id)
    }

    /// Neither an account to use nor a new one to create: a vault that holds no passkey for the request, or a profile that has no
    /// vault. The user is still asked, with the website named, so a page learns nothing from which of these it met.
    static func hasNothingToApprove(_ prompt: WebAuthnPrompt) -> Bool {
        prompt.choices.isEmpty && !prompt.offersNewAccount
    }

    private static func title(for prompt: WebAuthnPrompt) -> String {
        switch prompt.operation {
        case .create:
            return String(localized: "Create a passkey for \(prompt.rpID)?")
        case .get:
            return String(localized: "Sign in to \(prompt.rpID) with a passkey?")
        }
    }

    private static func body(for prompt: WebAuthnPrompt) -> String {
        var lines = [String(localized: "Website: \(prompt.origin)")]
        if let top = prompt.topOrigin { lines.append(String(localized: "Embedded in: \(top)")) }
        lines.append(String(localized: "Relying party: \(prompt.rpID)"))
        if hasNothingToApprove(prompt) {
            lines.append("")
            lines.append(prompt.operation == .get
                ? String(localized: "No passkey for this website in WSurf.")
                : String(localized: "WSurf can’t save a passkey here: Credential Manager has no vault yet."))
            return lines.joined(separator: "\n")
        }
        if prompt.operation == .get, prompt.choices.count == 1, let only = prompt.choices.first {
            lines.append(String(localized: "Account: \(only.title) — \(only.detail)"))
        }
        if prompt.operation == .create, !prompt.offersNewAccount, prompt.choices.count == 1, let only = prompt.choices.first {
            lines.append(String(localized: "Account: \(only.title) — \(only.detail)"))
        }
        lines.append("")
        if prompt.operation == .create {
            lines.append(String(localized: "The passkey is saved in Credential Manager."))
        }
        lines.append(prompt.willVerifyUser
            ? String(localized: "You will be asked to verify with your Mac next.")
            : String(localized: "Your Mac will not ask for further verification."))
        return lines.joined(separator: "\n")
    }
}
