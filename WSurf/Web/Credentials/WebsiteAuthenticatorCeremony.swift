// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

/// What a finished ceremony hands to page delivery: the result plus the exact vault state it was checked against, so the
/// final dispatch can refuse a result whose authority or key material changed after that check.
nonisolated struct WebAuthnCeremonyOutcome: Sendable {
    let result: WebAuthnResult
    /// The vault authorization the ceremony ran under.
    let epoch: UInt64
    /// The settled vault content generation: assertions are re-read after their signature-time metadata commit;
    /// registrations are re-read after their creation commit, proving the saved key is still in the vault.
    let generation: UInt64
    /// Registration only: the saved revision. Non-nil means the passkey is saved whatever happens to delivery.
    let savedRevision: UInt64?
    let rpID: String
    let userName: String
}

extension String {
    /// Display-only cleanup of text a website supplied (user name, display name): control, format (bidi) and separator
    /// characters removed and the length bounded. Stored and exported values are never normalised with this.
    nonisolated var displaySafe: String {
        let scalars = unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                return false
            default:
                return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }
}

/// The native ceremony around the pure ES256 core: verified context, explicit per-operation confirmation, fresh user
/// verification, and a vault commit that is revalidated after every suspension.
extension WebsiteAuthenticator {
    @MainActor
    static func perform(
        _ request: WebAuthnRequest,
        context: WebAuthnContext,
        manager: CredentialManager,
        in anchor: ASPresentationAnchor,
        conditional: Bool = false
    ) async throws -> WebAuthnCeremonyOutcome {
        try await perform(request, context: context, manager: manager, in: anchor, conditional: conditional, interaction: NativeWebAuthnInteraction())
    }

    /// `interaction` is the only seam: production always passes `NativeWebAuthnInteraction`; tests pass a scripted
    /// user so cancellation, expiry and verification outcomes are reachable without a window or biometrics. A scripted
    /// user is not evidence of native presence or verification. `conditional` marks a request started by a page
    /// gesture: an explicit native offer precedes any unlock, verification or signing.
    @MainActor
    static func perform(
        _ request: WebAuthnRequest,
        context: WebAuthnContext,
        manager: CredentialManager,
        in anchor: ASPresentationAnchor,
        conditional: Bool = false,
        interaction: some WebAuthnCeremonyInteraction
    ) async throws -> WebAuthnCeremonyOutcome {
        switch request.options {
        case let .creation(options):
            guard context.operation == .create, !conditional else { throw WebsiteAuthenticatorError.invalidContext }
            return try await createCredential(request, options: options, context: context, manager: manager, anchor: anchor, interaction: interaction)
        case let .assertion(options):
            guard context.operation == .get else { throw WebsiteAuthenticatorError.invalidContext }
            return try await getCredential(request, options: options, context: context, manager: manager, anchor: anchor, conditional: conditional, interaction: interaction)
        }
    }

    // MARK: Registration

    @MainActor
    private static func createCredential(
        _ request: WebAuthnRequest,
        options: WebAuthnCreationOptions,
        context: WebAuthnContext,
        manager: CredentialManager,
        anchor: ASPresentationAnchor,
        interaction: some WebAuthnCeremonyInteraction
    ) async throws -> WebAuthnCeremonyOutcome {
        // A Mac that cannot verify refuses `required` before any unlock or prompt.
        let willVerify = try verificationPlan(options.userVerification, interaction: interaction)
        let bound = try await open(
            request, rawRPID: options.rpID, context: context, manager: manager, anchor: anchor,
            conditional: false, interaction: interaction
        )
        let listed = try await snapshot(manager, bound: bound)
        let candidates = registrationChoices(listed.accounts, rpID: bound.rpID, origin: context.origin)

        let decision = await interaction.decide(
            WebAuthnPrompt(
                operation: .create,
                origin: context.origin,
                topOrigin: context.topOrigin,
                rpID: bound.rpID,
                requestedUserName: options.userName.displaySafe,
                choices: candidates,
                offersNewAccount: true,
                userVerification: options.userVerification,
                willVerifyUser: willVerify
            ),
            in: anchor,
            until: request.deadline
        )
        let selected = try approval(decision)
        try await revalidate(request, context: context, manager: manager, bound: bound)
        if let selected, !candidates.contains(where: { $0.id == selected }) {
            throw WebsiteAuthenticatorError.notAllowed
        }

        let verified = try await verify(
            willVerify, interaction: interaction, request: request, context: context, manager: manager, bound: bound,
            reason: String(localized: "Create a passkey for \(bound.rpID)")
        )

        // Read again after every prompt: the account the user picked must be exactly what they saw.
        let current = try await snapshot(manager, bound: bound)
        let base: CredentialAccount
        let index: Int?
        if let selected {
            guard let found = current.accounts.firstIndex(where: { $0.id == selected }),
                  listed.accounts.first(where: { $0.id == selected }) == current.accounts[found] else {
                throw WebsiteAuthenticatorError.notAllowed
            }
            index = found
            base = current.accounts[found]
        } else {
            index = nil
            base = CredentialAccount(
                id: UUID(),
                username: options.userName,
                displayName: options.userDisplayName.isEmpty ? nil : options.userDisplayName,
                origins: URL(string: context.origin).flatMap(CredentialAccount.origin(for:)).map { [$0] } ?? [],
                loginURLs: [],
                password: nil,
                passkeys: [],
                totp: nil,
                exchangeAccountID: nil,
                exchangeItemID: nil
            )
        }
        // excludeCredentials covers the whole authenticator, not only the chosen account. It is reported only after the
        // user's gesture so a site cannot probe for credentials silently.
        if current.accounts.contains(where: { account in
            account.passkeys.contains { $0.rpID == bound.rpID && options.excludeCredentials.contains($0.credentialID) }
        }) { throw WebsiteAuthenticatorError.credentialExcluded }

        try await revalidate(request, context: context, manager: manager, bound: bound)
        let registration = try makeRegistration(
            request,
            client: bound.client,
            account: base,
            consent: WebAuthnConsent(requestID: request.requestID, userPresent: true, userVerified: verified)
        )
        var accounts = current.accounts
        if let index {
            accounts[index] = registration.account
        } else {
            accounts.append(registration.account)
        }

        // Cancellation up to the vault's own pre-write check stops the commit with nothing saved; a write that already
        // landed still returns its receipt, so the outcome reported is always the one on disk.
        try Task.checkCancellation()
        let revision = current.revision, epoch = bound.epoch
        let commit = Task { @MainActor in try await manager.commit(accounts, expectedRevision: revision, authorizedEpoch: epoch) }
        let receipt: VaultCommitReceipt
        do {
            receipt = try await withTaskCancellationHandler { try await commit.value } onCancel: { commit.cancel() }
        } catch { throw vaultFailure(error) }

        let savedPasskey = registration.account.passkeys.last
        let userName = (savedPasskey?.userName ?? options.userName).displaySafe
        let settled: Observed
        do {
            try Task.checkCancellation()
            try validateDeadline(request)
            try await revalidate(request, context: context, manager: manager, bound: bound)
            // The page may only be given a registration whose key is still in the vault: re-read under a stable generation
            // and require exactly the saved revision and record. Any other write (even an unrelated one) conservatively
            // refuses delivery; the receipt is kept and nothing is retried. Nothing suspends after this read.
            settled = try await snapshot(manager, bound: bound)
            guard settled.revision == receipt.revision,
                  let savedPasskey,
                  settled.accounts.contains(where: { $0.passkeys.contains(savedPasskey) }) else {
                throw WebsiteAuthenticatorError.notAllowed
            }
            try Task.checkCancellation()
            try validateDeadline(request)
            guard manager.authorizationEpoch == bound.epoch, manager.stableGeneration == settled.generation else {
                throw WebsiteAuthenticatorError.notAllowed
            }
        } catch {
            manager.noteUnconfirmedPasskey(rpID: bound.rpID, userName: userName, revision: receipt.revision)
            interaction.reportUnconfirmedRegistration(rpID: bound.rpID, userName: userName, in: anchor)
            throw WebsiteAuthenticatorError.savedNotDelivered(revision: receipt.revision)
        }
        return WebAuthnCeremonyOutcome(
            result: registration.result, epoch: bound.epoch, generation: settled.generation,
            savedRevision: receipt.revision, rpID: bound.rpID, userName: userName
        )
    }

    // MARK: Assertion

    @MainActor
    private static func getCredential(
        _ request: WebAuthnRequest,
        options: WebAuthnAssertionOptions,
        context: WebAuthnContext,
        manager: CredentialManager,
        anchor: ASPresentationAnchor,
        conditional: Bool,
        interaction: some WebAuthnCeremonyInteraction
    ) async throws -> WebAuthnCeremonyOutcome {
        let willVerify = try verificationPlan(options.userVerification, interaction: interaction)
        let bound = try await open(
            request, rawRPID: options.rpID, context: context, manager: manager, anchor: anchor,
            conditional: conditional, interaction: interaction
        )
        let listed = try await snapshot(manager, bound: bound)
        let candidates = assertionCandidates(listed.accounts, rpID: bound.rpID, allowed: options.allowCredentials)
        // No matching passkey is still a user-visible decision, never an immediate error: an instant failure would tell a
        // page whether this vault holds a passkey for it, with no origin-bearing native step. The prompt names the site and
        // has nothing to approve; the page learns NotAllowed only after the user dismissed it or the deadline passed.
        let decision = await interaction.decide(
            WebAuthnPrompt(
                operation: .get,
                origin: context.origin,
                topOrigin: context.topOrigin,
                rpID: bound.rpID,
                requestedUserName: nil,
                choices: candidates.map(\.choice),
                offersNewAccount: false,
                userVerification: options.userVerification,
                willVerifyUser: willVerify
            ),
            in: anchor,
            until: request.deadline
        )
        guard !candidates.isEmpty else {
            _ = try approval(decision)
            throw WebsiteAuthenticatorError.notAllowed
        }
        guard let selected = try approval(decision),
              let pick = candidates.first(where: { $0.choice.id == selected }) else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        try await revalidate(request, context: context, manager: manager, bound: bound)
        let verified = try await verify(
            willVerify, interaction: interaction, request: request, context: context, manager: manager, bound: bound,
            reason: String(localized: "Sign in to \(bound.rpID) with a passkey")
        )

        let current = try await snapshot(manager, bound: bound)
        guard let account = current.accounts.first(where: { $0.id == pick.accountID }),
              let passkey = account.passkeys.first(where: { $0.id == pick.choice.id }),
              passkey == pick.passkey else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        // The selected key was authorized under this exact revision/generation. Only the resulting local signature
        // advances its metadata; the receipt and a settled read prove the write before this outcome can be delivered.
        try await revalidate(request, context: context, manager: manager, bound: bound)
        guard manager.stableGeneration == current.generation else { throw WebsiteAuthenticatorError.notAllowed }
        let result = try makeAssertion(
            request,
            client: bound.client,
            passkey: passkey,
            consent: WebAuthnConsent(requestID: request.requestID, userPresent: true, userVerified: verified)
        )
        let signatureAt = Date()
        var updatedAccounts = current.accounts
        guard let accountIndex = updatedAccounts.firstIndex(where: { $0.id == account.id }),
              let passkeyIndex = updatedAccounts[accountIndex].passkeys.firstIndex(where: { $0.id == passkey.id }) else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        updatedAccounts[accountIndex].passkeys[passkeyIndex].lastSignedAt = signatureAt

        try Task.checkCancellation()
        try validateDeadline(request)
        let commit = Task { @MainActor in
            try await manager.commit(updatedAccounts, expectedRevision: current.revision, authorizedEpoch: bound.epoch)
        }
        let receipt: VaultCommitReceipt
        do {
            receipt = try await withTaskCancellationHandler { try await commit.value } onCancel: { commit.cancel() }
        } catch {
            throw vaultFailure(error)
        }

        try Task.checkCancellation()
        try validateDeadline(request)
        try await revalidate(request, context: context, manager: manager, bound: bound)
        let settled = try await snapshot(manager, bound: bound)
        guard settled.revision == receipt.revision,
              let settledPasskey = settled.accounts
                .first(where: { $0.id == account.id })?.passkeys.first(where: { $0.id == passkey.id }),
              settledPasskey == updatedAccounts[accountIndex].passkeys[passkeyIndex],
              settledPasskey.lastSignedAt == signatureAt,
              manager.authorizationEpoch == bound.epoch,
              manager.stableGeneration == settled.generation else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        try Task.checkCancellation()
        try validateDeadline(request)
        return WebAuthnCeremonyOutcome(
            result: result, epoch: bound.epoch, generation: settled.generation,
            savedRevision: nil, rpID: bound.rpID, userName: passkey.userName.displaySafe
        )
    }

    // MARK: Shared steps

    private struct Bound {
        let client: WebAuthnClientData
        let rpID: String
        let epoch: UInt64
    }

    /// A vault read together with the content generation it was read under.
    private struct Observed {
        let accounts: [CredentialAccount]
        let revision: UInt64
        let generation: UInt64
    }

    /// Verifies the request/context/manager triple and returns the access epoch every later step is held to.
    /// A locked vault is unlocked here only after the user accepted an origin-bearing native offer for this very
    /// request, so the system unlock sheet is never the first thing a page can show. A conditional request always gets
    /// that offer (a page click is not an account choice).
    @MainActor
    private static func open(
        _ request: WebAuthnRequest,
        rawRPID: String?,
        context: WebAuthnContext,
        manager: CredentialManager,
        anchor: ASPresentationAnchor,
        conditional: Bool,
        interaction: some WebAuthnCeremonyInteraction
    ) async throws -> Bound {
        try Task.checkCancellation()
        try validateDeadline(request)
        guard !context.isPrivate, context.profileID == manager.profileID,
              let origin = URL(string: context.origin) else { throw WebsiteAuthenticatorError.invalidContext }
        let resolved: String
        do {
            resolved = try RelyingPartyPolicy.validate(rpID: rawRPID, origin: origin)
        } catch {
            throw WebsiteAuthenticatorError.invalidRequest
        }
        let client = WebAuthnClientData(origin: context.origin, topOrigin: context.topOrigin, crossOrigin: context.crossOrigin, rpID: resolved)
        _ = try validateClient(client, rawRPID: rawRPID)
        try await context.validate()
        try validateDeadline(request)

        let lockedAtOffer = manager.authorizationEpoch == nil
        if conditional || lockedAtOffer {
            let offer = await interaction.offerStart(
                operation: context.operation == .create ? .create : .get,
                origin: context.origin, locked: lockedAtOffer, in: anchor, until: request.deadline
            )
            _ = try approval(offer)
            try Task.checkCancellation()
            try await context.validate()
            try validateDeadline(request)
            // An offer made for an unlocked vault is not consent to unlock one that locked meanwhile.
            if !lockedAtOffer, manager.authorizationEpoch == nil {
                throw WebsiteAuthenticatorError.notAllowed
            }
        }

        if manager.authorizationEpoch == nil {
            do {
                try await manager.unlock(in: anchor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Task.isCancelled ? CancellationError() : WebsiteAuthenticatorError.notAllowed
            }
            try Task.checkCancellation()
            try await context.validate()
            try validateDeadline(request)
        }
        guard let epoch = manager.authorizationEpoch else { throw WebsiteAuthenticatorError.notAllowed }
        return Bound(client: client, rpID: resolved, epoch: epoch)
    }

    /// Re-establishes, synchronously after the preceding await, that the page context and vault access are still the
    /// ones the ceremony started with, and that the request has not expired while the context was being proved.
    @MainActor
    private static func revalidate(
        _ request: WebAuthnRequest,
        context: WebAuthnContext,
        manager: CredentialManager,
        bound: Bound
    ) async throws {
        try Task.checkCancellation()
        try validateDeadline(request)
        try await context.validate()
        try Task.checkCancellation()
        try validateDeadline(request)
        guard manager.authorizationEpoch == bound.epoch, context.profileID == manager.profileID else {
            throw WebsiteAuthenticatorError.notAllowed
        }
    }

    @MainActor
    private static func snapshot(_ manager: CredentialManager, bound: Bound) async throws -> Observed {
        guard manager.authorizationEpoch == bound.epoch, let before = manager.stableGeneration else {
            throw WebsiteAuthenticatorError.notAllowed
        }
        let snapshot: VaultSnapshot
        do { snapshot = try await manager.snapshot() } catch { throw vaultFailure(error) }
        try Task.checkCancellation()
        guard manager.authorizationEpoch == bound.epoch else { throw WebsiteAuthenticatorError.notAllowed }
        // A write that started or ended while the read was in flight makes the read untrustworthy for key material.
        guard manager.stableGeneration == before else { throw WebsiteAuthenticatorError.notAllowed }
        return Observed(accounts: snapshot.accounts, revision: snapshot.revision, generation: before)
    }

    /// `required` must verify (and is refused up front if this Mac cannot); `preferred` verifies when it can;
    /// `discouraged` never asks.
    @MainActor
    private static func verificationPlan(
        _ preference: WebAuthnUserVerification,
        interaction: some WebAuthnCeremonyInteraction
    ) throws -> Bool {
        switch preference {
        case .discouraged:
            return false
        case .preferred:
            return interaction.canVerifyUser
        case .required:
            guard interaction.canVerifyUser else { throw WebsiteAuthenticatorError.notAllowed }
            return true
        }
    }

    /// Fresh system verification when the plan calls for it. The result is the UV flag: it is true only when this call
    /// just succeeded, never because the vault happens to be unlocked.
    @MainActor
    private static func verify(
        _ willVerify: Bool,
        interaction: some WebAuthnCeremonyInteraction,
        request: WebAuthnRequest,
        context: WebAuthnContext,
        manager: CredentialManager,
        bound: Bound,
        reason: String
    ) async throws -> Bool {
        guard willVerify else { return false }
        try await interaction.verifyUser(reason: reason, until: request.deadline)
        try await revalidate(request, context: context, manager: manager, bound: bound)
        return true
    }

    private static func approval(_ decision: WebAuthnDecision) throws -> UUID? {
        switch decision {
        case let .approved(choice):
            return choice
        case .declined:
            throw WebsiteAuthenticatorError.notAllowed
        case .expired:
            throw WebsiteAuthenticatorError.expired
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func vaultFailure(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError:
            return error
        case CredentialVaultError.staleRevision:
            return WebsiteAuthenticatorError.notAllowed
        case CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.authenticationFailed,
             CredentialVaultError.missingVault, CredentialVaultError.noUnlocks:
            return WebsiteAuthenticatorError.notAllowed
        default:
            return error
        }
    }

    // MARK: Prompt content

    /// Accounts scoped to this origin or already holding a passkey for this relying party. Identity is the account ID;
    /// the label is only what the user needs to tell neighbours apart.
    static func registrationChoices(_ accounts: [CredentialAccount], rpID: String, origin: String) -> [WebAuthnPromptChoice] {
        let normalized = URL(string: origin).flatMap(CredentialAccount.origin(for:))
        let related = accounts.filter { account in
            normalized.map(account.origins.contains) == true || account.passkeys.contains { $0.rpID == rpID }
        }
        return disambiguated(related.map { account in
            let kinds = [
                account.passkeys.isEmpty ? nil : String(localized: "\(account.passkeys.count) passkey(s)"),
                account.password == nil ? nil : String(localized: "password"),
                account.totp == nil ? nil : String(localized: "verification code"),
            ].compactMap { $0 }
            return (account.id, label(account), ([account.username.displaySafe] + kinds).filter { !$0.isEmpty }.joined(separator: " · "))
        })
    }

    struct AssertionCandidate {
        let accountID: UUID
        let passkey: WebsitePasskey
        var choice: WebAuthnPromptChoice
    }

    /// Every ES256 passkey for this relying party the request allows, one entry per passkey ID.
    static func assertionCandidates(_ accounts: [CredentialAccount], rpID: String, allowed: [Data]) -> [AssertionCandidate] {
        var found: [(CredentialAccount, WebsitePasskey)] = []
        for account in accounts {
            for passkey in account.passkeys
            where passkey.rpID == rpID && passkey.algorithm == -7 && (allowed.isEmpty || allowed.contains(passkey.credentialID)) {
                found.append((account, passkey))
            }
        }
        let choices = disambiguated(found.map { account, passkey in
            (passkey.id, label(account), [passkey.userName.displaySafe, passkey.userDisplayName == passkey.userName ? "" : passkey.userDisplayName.displaySafe]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        })
        return zip(found, choices).map { AssertionCandidate(accountID: $0.0.id, passkey: $0.1, choice: $1) }
    }

    private static func label(_ account: CredentialAccount) -> String {
        if let name = account.displayName?.displaySafe, !name.isEmpty {
            return name
        }
        let user = account.username.displaySafe
        return user.isEmpty ? String(localized: "Unnamed account") : user
    }

    /// Identical labels get an identifier suffix so the user can still choose the intended one. The suffix is the shortest
    /// prefix of the account/passkey ID, at least four characters, that no other entry with that label shares.
    private static func disambiguated(_ items: [(id: UUID, title: String, detail: String)]) -> [WebAuthnPromptChoice] {
        var groups: [String: [UUID]] = [:]
        for item in items { groups[item.title + "\u{0}" + item.detail, default: []].append(item.id) }
        return items.map { item in
            let group = groups[item.title + "\u{0}" + item.detail, default: []]
            guard group.count > 1 else { return WebAuthnPromptChoice(id: item.id, title: item.title, detail: item.detail) }
            return WebAuthnPromptChoice(
                id: item.id,
                title: item.title,
                detail: item.detail + " · #" + item.id.shortestUniquePrefix(in: group)
            )
        }
    }
}
