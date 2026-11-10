// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import WSurfVault

/// "Generate Password…" in a page's context menu, next to Pick Credential…: a new password, made natively from the right-clicked
/// field's rules and limits and shown in a sheet, is saved as a new login in a vault and only then filled into the field and its
/// confirmation.
///
/// - The field is Pick Credential…'s right-clicked field (`CredentialPicker.target`): the frame's own script saw a trusted contextmenu
///   event on it, in the frame the engine says. The two flows share that right-click, so one refuses while the other is under way.
/// - It is offered exactly where Pick Credential… is (`CredentialPicker.isOffered` with the tab's `allowed`), asked again after every
///   step: never in a private window, while password autofill is off, on a page that is not a secure HTTPS page, or in a tab an agent
///   or a connected app controls.
/// - The page gets nothing before Use Password. `generateTarget` reads the field's facts and sends no value in; the vaults are read as
///   candidates, which hold no secret, only to name them and to see which one already holds this website.
/// - Use Password saves first: one new login with nothing read before it (`commitAccounts` with `.absent`), under the unlock the sheet
///   was opened under. Then it fills, with the password put into the call's arguments at the engine's dispatch boundary after one
///   more check. A generated password is never in a page without being in the vault; a failed save fills nothing.
/// - The sheet closes as a Cancel on a lock or a change of policy (with the picker's sheets) and when an agent takes the tab
///   (`BrowserTab.agentControlChanged`).
@MainActor
final class PasswordGeneratorFlow {
    static let shared = PasswordGeneratorFlow()

    /// The right-clicked field as `__wsurfPasswords.generateTarget` reports it: page text and limits. Nothing is sent in to read it.
    nonisolated struct Field: Equatable, Sendable {
        nonisolated enum Kind: Equatable, Sendable {
            /// A field a new password goes into.
            case new
            /// Not a password field.
            case notPassword
            /// The current-password field of a form that asks for a new one.
            case currentPassword
        }

        var kind: Kind
        /// The form sends what it gets to this website only.
        var isSafe = false
        /// The field's `passwordrules`.
        var rules = PasswordRules()
        /// The field's `minlength` and `maxlength`, narrowed by its confirmation's.
        var limits = PasswordFieldLimits()
        /// The field has a confirmation field, which takes the same password.
        var hasConfirmation = false
        /// The username the form shows, page text of at most 500 characters.
        var username = ""

        /// Reads the script's answer; nil when the field is gone or the answer is not one.
        init?(_ answer: Any?) {
            guard let body = answer as? [String: Any], let isPassword = body["password"] as? Bool else { return nil }
            guard isPassword else {
                kind = .notPassword
                return
            }
            guard body["current"] as? Bool != true else {
                kind = .currentPassword
                return
            }
            kind = .new
            isSafe = body["safe"] as? Bool == true
            if let text = body["rules"] as? String {
                rules = PasswordRules(parsing: text)
            }
            limits = Self.limits(body["field"])
            if body["partner"] is [String: Any] {
                hasConfirmation = true
                limits = limits.narrowed(by: Self.limits(body["partner"]))
            }
            if let shown = body["username"] as? String, shown.count <= 500 {
                username = shown
            }
        }

        init(kind: Kind) {
            self.kind = kind
        }

        private static func limits(_ value: Any?) -> PasswordFieldLimits {
            let body = value as? [String: Any]
            return PasswordFieldLimits(
                minLength: (body?["minLength"] as? NSNumber)?.intValue, maxLength: (body?["maxLength"] as? NSNumber)?.intValue
            )
        }
    }

    /// A vault the password may be saved in: its identity, its label and the unlock it was read under. Nothing of its credentials.
    nonisolated struct Vault: Identifiable, Equatable, Sendable {
        let id: UUID
        let label: String
        let epoch: UInt64
    }

    /// What the sheet is opened with. The password is the first one, made before the sheet opens; the sheet makes the others.
    struct Proposal {
        /// The right-clicked frame's website, as the address bar draws it: the website the password is saved for.
        let host: String
        /// The page's website, when the right-clicked field is in a frame of another one.
        let pageHost: String?
        let field: Field
        let vaults: [Vault]
        /// The vault the sheet offers first (`preferredVault`).
        let vaultID: UUID
        /// Some vault is locked: the sheet offers to unlock it.
        let canUnlock: Bool
        let format: PasswordFormat
        let password: GeneratedPassword?
    }

    enum Answer {
        /// Use Password: save `password` in `vaultID`, then fill it.
        case use(GeneratedPassword, vaultID: UUID)
        /// Unlock Other Vaults…: unlock, then open the sheet again with a new password.
        case unlock
    }

    enum Failure: Equatable {
        /// The field, the page or the vault changed before anything was saved.
        case noField
        /// The form sends what it gets to another website: nothing was saved or filled.
        case unsafeForm
        /// At Use Password the field no longer matched what the sheet showed (its username, limits, rules or confirmation): nothing
        /// was saved or filled.
        case fieldChanged
        /// The right-clicked field takes no password.
        case notPasswordField
        /// The right-clicked field is the current password of a form that asks for a new one.
        case currentPasswordField
        /// No vault to save in, or one that Settings has to set up or repair first.
        case noVault
        /// The vault refused the new login: nothing was filled.
        case notSaved
        /// The login was saved for the website named, but the page changed before the fill, so nothing was filled.
        case savedNotFilled(host: String)
        /// The login was saved for the website named, but the form now sends what it gets to another website, so nothing was filled.
        case savedFormUnsafe(host: String)
    }

    enum Outcome: Equatable {
        case filled(Int), nothing, failed(Failure)
    }

    /// Tests answer the sheet, keyed by profile like `CredentialPicker.answersForTesting`. The answer sees the proposal before Use
    /// Password.
    static var answersForTesting: [UUID: @MainActor (Proposal) async -> Answer?] = [:]
    /// Tests act between the save and the fill, keyed by profile: the vault holds the new login and the page does not have it yet.
    static var savedForTesting: [UUID: @MainActor () async -> Void] = [:]

    private init() {}

    // MARK: - The menu item

    /// The menu item: a password for the right-clicked field. `allowed` is the tab's policy, asked again before every step;
    /// `setUpVault` opens Settings for a profile with no vault yet.
    func generate(
        in page: BrowserPage, menu: CredentialPicker.Menu, allowed: @escaping @MainActor @Sendable () -> Bool,
        setUpVault: @escaping @MainActor () -> Void
    ) {
        let picker = CredentialPicker.shared, key = ObjectIdentifier(page)
        guard !picker.picking.contains(key), let target = picker.target(for: page, menu: menu), let window = page.window,
              CredentialPicker.isOffered(in: page, allowedByTab: allowed()) else {
            NSSound.beep()
            return
        }
        picker.picking.insert(key)
        Task { [weak page] in
            guard let page else {
                CredentialPicker.shared.picking.remove(key)
                return
            }
            guard await CredentialPicker.isNamedFrame(target, by: menu, in: page) else {
                CredentialPicker.shared.picking.remove(key)
                NSSound.beep()
                return
            }
            let outcome = await self.run(target, in: page, window: window, allowed: allowed)
            CredentialPicker.shared.picking.remove(key)
            if case .failed(let failure) = outcome, page.window === window {
                await Self.report(failure, in: window, setUpVault: setUpVault)
            }
        }
    }

    // MARK: - The flow

    /// The field's facts, a vault, the sheet, then save and fill. Every suspension is followed by the picker's check: the page, its
    /// window, its profile and the right-click are still the ones it started from, and the policy still offers the item.
    func run(
        _ target: CredentialPicker.Target, in page: BrowserPage, window: NSWindow, allowed: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let profile = target.context.profile
        let isCurrent = CredentialPicker.shared.currentCheck(for: target, in: page, window: window, allowed: allowed)
        guard isCurrent() else { return .nothing }
        let field = await Self.field(of: target, in: page)
        guard isCurrent() else { return .nothing }
        guard let field else { return .failed(.noField) }
        switch field.kind {
        case .notPassword:
            AutofillDiagnostics.note(.generatorRefused, kind: .password)
            return .failed(.notPasswordField)
        case .currentPassword:
            AutofillDiagnostics.note(.generatorRefused, kind: .password)
            return .failed(.currentPasswordField)
        case .new:
            guard field.isSafe else {
                AutofillDiagnostics.note(.generatorRefused, kind: .password)
                return .failed(.unsafeForm)
            }
        }
        // No vault yet, or one Settings has to set up first: a password that cannot be saved is not offered.
        guard let store = try? CredentialManager.store(for: profile), await store.openState().isProvisional,
              (try? await store.listing())?.isEmpty == false else {
            return isCurrent() ? .failed(.noVault) : .nothing
        }
        var unlocking = await AutofillSuggestions.allVaultsLocked(of: profile)
        while true {
            if unlocking {
                guard await AutofillSuggestions.shared.unlockVault(of: profile, in: window, while: isCurrent), isCurrent() else {
                    return .nothing
                }
            }
            guard isCurrent(), let proposal = await makeProposal(for: target, field: field), isCurrent() else { return .nothing }
            AutofillDiagnostics.note(.generatorShown, kind: .password)
            switch await choose(proposal, target: target, in: window) {
            case .use(let password, let vaultID)?:
                guard isCurrent(), let vault = proposal.vaults.first(where: { $0.id == vaultID }) else { return .nothing }
                return await save(password, in: vault, shown: proposal.field, target: target, in: page, isCurrent: isCurrent)
            case .unlock?:
                unlocking = true
            case nil:
                return .nothing
            }
        }
    }

    /// The field's facts, if the frame's document still has the right-clicked field.
    static func field(of target: CredentialPicker.Target, in page: BrowserPage) async -> Field? {
        if let chromium = page.chromium, (try? await chromium.isLive(frame: target.frame)) != true {
            return nil
        }
        let answer = try? await page.callAsyncJavaScript(
            "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return null; return globalThis.__wsurfPasswords?.generateTarget(token, url) ?? null;",
            arguments: ["documentID": target.documentID, "token": target.token, "url": target.frameURL.absoluteString],
            in: target.frame, contentWorld: PasswordAutofill.world
        )
        return Field(answer)
    }

    /// Every unlocked vault of the profile, in ordinal order, each read as candidates under its own unlock (no secret), and the first
    /// password. A locked vault is never read. Nil when no vault is unlocked.
    private func makeProposal(for target: CredentialPicker.Target, field: Field) async -> Proposal? {
        let profile = target.context.profile
        guard !profile.isPrivate, let store = try? CredentialManager.store(for: profile), let host = WebsiteLookalike.displayHost(of: target.origin),
              let listing = try? await store.listing() else { return nil }
        let unlocked = CredentialManager.unlockedManagers(for: profile)
        var vaults: [Vault] = []
        var holders: [UUID] = []
        var hasLockedVault = false
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let manager = unlocked.first(where: { $0.vaultID == vault.vaultID }), let epoch = manager.authorizationEpoch,
                  let candidates = try? await manager.autofillCandidates(), manager.authorizationEpoch == epoch else {
                hasLockedVault = true
                continue
            }
            vaults.append(Vault(id: vault.vaultID, label: vault.label, epoch: epoch))
            if candidates.candidates.contains(where: { $0.origins.contains(target.origin) }) {
                holders.append(vault.vaultID)
            }
        }
        let defaultID = await store.defaultVaultID()
        guard let vaultID = Self.preferredVault(vaults.map(\.id), holders: holders, defaultID: defaultID) else { return nil }
        let pageOrigin = target.page?.url.flatMap(CredentialAccountSelection.origin(for:))
        let pageHost = pageOrigin.flatMap { $0 == target.origin ? nil : WebsiteLookalike.displayHost(of: $0) }
        let format = Self.initialFormat(for: field)
        return Proposal(
            host: host, pageHost: pageHost, field: field, vaults: vaults, vaultID: vaultID, canUnlock: hasLockedVault, format: format,
            password: Self.password(format, for: field)
        )
    }

    /// The vault a new password goes to first (UX default 2): the one unlocked vault that already holds a login for this website;
    /// otherwise the default vault, if it is unlocked (Settings' choice, else the first vault); otherwise the first unlocked one.
    nonisolated static func preferredVault(_ unlocked: [UUID], holders: [UUID], defaultID: UUID?) -> UUID? {
        if holders.count == 1, unlocked.contains(holders[0]) {
            return holders[0]
        }
        if let defaultID, unlocked.contains(defaultID) {
            return defaultID
        }
        return unlocked.first
    }

    /// Website's Rules when the field has rules; otherwise Easy to Type, unless the field allows fewer than 13 characters, where
    /// Letters and Digits is the stronger format.
    nonisolated static func initialFormat(for field: Field) -> PasswordFormat {
        if !field.rules.isEmpty {
            return .websiteRules
        }
        if let bounds = PasswordGenerator.lengthBounds(for: .easyToType, rules: field.rules, field: field.limits),
           bounds.upperBound < PasswordGenerator.easyToTypeShortest {
            return .lettersAndDigits
        }
        return .easyToType
    }

    /// A password of `format` at `length` for the field. Every format keeps the field's limits and the rules' length limits; Website's
    /// Rules also draws from the rules' characters (`PasswordGenerator.lengthBounds`).
    nonisolated static func password(
        _ format: PasswordFormat, length: Int = PasswordGenerator.defaultLength, for field: Field
    ) -> GeneratedPassword? {
        PasswordGenerator.generate(format, length: length, rules: field.rules, field: field.limits)
    }

    private func choose(_ proposal: Proposal, target: CredentialPicker.Target, in window: NSWindow) async -> Answer? {
        if let answer = Self.answersForTesting[target.context.profile.id] {
            return await answer(proposal)
        }
        guard let page = target.page else { return nil }
        return await PasswordGeneratorSheet.present(proposal, profileID: target.context.profile.id, page: page, in: window)
    }

    /// Use Password: the field is read again and must still be what the sheet showed (`shown`: still there, still safe, the same
    /// username, limits, rules and confirmation, since the password and the sentence under it were made for those), the vault is the
    /// one the sheet was opened under, a new login is written with nothing read first, and only then the password goes into the
    /// field and its confirmation.
    private func save(
        _ password: GeneratedPassword, in vault: Vault, shown: Field, target: CredentialPicker.Target, in page: BrowserPage,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let context = target.context
        let field = await Self.field(of: target, in: page)
        guard isCurrent() else { return .nothing }
        guard let field, field.kind == .new else { return .failed(.noField) }
        guard field.isSafe else { return .failed(.unsafeForm) }
        guard field == shown else { return .failed(.fieldChanged) }
        guard let manager = CredentialPicker.manager(of: context, vaultID: vault.id, epoch: vault.epoch),
              let host = WebsiteLookalike.displayHost(of: target.origin) else { return .failed(.noField) }
        let username = field.username.isEmpty ? Self.rememberedUsername(in: page, origin: target.origin, documentID: target.documentID) : field.username
        let login = CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: [target.origin],
            loginURLs: CredentialAccountSelection.loginURL(for: target.frameURL, origin: target.origin).map { [$0] } ?? [],
            password: password.revealed, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        do {
            _ = try await manager.commitAccounts(
                [AccountWrite(accountID: login.id, expected: .absent, replacement: login)], authorizedEpoch: vault.epoch
            )
        } catch {
            return isCurrent() ? .failed(.notSaved) : .nothing
        }
        AutofillDiagnostics.note(.generatorSaved, kind: .password)
        if let saved = Self.savedForTesting[context.profile.id] {
            await saved()
        }
        // Saved: from here a page or policy that changed is told, since the vault holds a login the page never got.
        guard isCurrent() else { return .failed(.savedNotFilled(host: host)) }
        let vaultID = vault.id, epoch = vault.epoch
        let token = target.token, url = target.frameURL.absoluteString, documentID = target.documentID
        let prepare: @MainActor @Sendable () throws -> [String: Any] = {
            guard isCurrent(), CredentialPicker.manager(of: context, vaultID: vaultID, epoch: epoch) === manager else {
                throw ContactAutofillError.changedPage
            }
            return ["token": token, "url": url, "documentID": documentID, "password": password.revealed]
        }
        let answer: Any?
        do {
            answer = try await page.callAsyncJavaScript(
                "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return {count: 0}; return globalThis.__wsurfPasswords?.generateFill(token, url, password) ?? {count: 0};",
                in: target.frame, contentWorld: PasswordAutofill.world, prepareArguments: prepare
            )
        } catch {
            return .failed(.savedNotFilled(host: host))
        }
        let count = ((answer as? [String: Any])?["count"] as? NSNumber)?.intValue ?? 0
        // -1 is the script's "the form sends what it gets to another website now".
        guard count > 0 else { return .failed(count < 0 ? .savedFormUnsafe(host: host) : .savedNotFilled(host: host)) }
        AutofillDiagnostics.note(.generatorFilled, kind: .password, count: count)
        if isCurrent() {
            context.autofillLastUsed.record(account: login.id, origin: target.origin, in: manager)
        }
        return .filled(count)
    }

    /// The username an identifier-first sign-up asked for on an earlier step, when the form with the password shows none: the tab's
    /// remembered step for this website, by the save path's own rule (`AutofillSaveCoordinator.receive`): from this website, done or
    /// from another document, and less than five minutes old.
    static func rememberedUsername(in page: BrowserPage, origin: String, documentID: String) -> String {
        guard let remembered = AutofillSaveCoordinator.shared.session(for: page)?.username, remembered.origin == origin,
              remembered.completed || remembered.documentID != documentID, Date.now.timeIntervalSince(remembered.date) < 300 else {
            return ""
        }
        return remembered.value
    }

    // MARK: - Alerts

    private static func report(_ failure: Failure, in window: NSWindow, setUpVault: @escaping @MainActor () -> Void) async {
        let alert = NSAlert()
        switch failure {
        case .savedNotFilled(let host):
            alert.messageText = String(localized: "Password Saved but Not Filled")
            alert.informativeText = String(
                localized: "WSurf saved the password for \(host), but the field changed, so nothing was filled. Right-click the field and choose Pick Credential… to fill it."
            )
        case .savedFormUnsafe(let host):
            alert.messageText = String(localized: "Password Saved but Not Filled")
            alert.informativeText = String(
                localized: "WSurf saved the password for \(host), but this form now sends what you type to another website, so nothing was filled."
            )
        case .fieldChanged:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(
                localized: "The field changed while the sheet was open, so nothing was saved or filled. Right-click the field and choose Generate Password… to try again."
            )
        case .notSaved:
            alert.messageText = String(localized: "Couldn’t Save the Password")
            alert.informativeText = String(localized: "The vault didn’t save the new password, so nothing was filled. Try again.")
        case .noVault:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(localized: "WSurf saves a generated password in a vault. Set up a vault in Settings first.")
            alert.addButton(withTitle: String(localized: "Set Up Vault…"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                setUpVault()
            }
            return
        case .notPasswordField:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(localized: "Right-click a password field to generate a password.")
        case .currentPasswordField:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(localized: "Right-click the new password field to generate a password.")
        case .unsafeForm:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(localized: "This form sends what you type to another website, so nothing was filled.")
        case .noField:
            alert.messageText = String(localized: "Couldn’t Generate a Password")
            alert.informativeText = String(localized: "Right-click the field and choose Generate Password… to try again.")
        }
        await alert.beginSheetModal(for: window)
    }
}

nonisolated extension PasswordFieldLimits {
    /// These limits and `other`'s together: the larger minimum and the smaller maximum, as a field and its confirmation must both
    /// take the password. A negative value is the DOM's "none".
    func narrowed(by other: PasswordFieldLimits) -> PasswordFieldLimits {
        func real(_ value: Int?) -> Int? {
            value.flatMap { $0 >= 0 ? $0 : nil }
        }
        return PasswordFieldLimits(
            minLength: [minLength, other.minLength].compactMap(real).max(), maxLength: [maxLength, other.maxLength].compactMap(real).min()
        )
    }
}
