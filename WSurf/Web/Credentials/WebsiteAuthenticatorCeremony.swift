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
    /// user is not evidence of native presence or verification. `conditional` marks a request started from the fill
    /// dropdown's "Use a Passkey…" row: an explicit native offer precedes any unlock, verification or signing.
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
        let selected = try approval(decision, rpID: bound.rpID, context: context)
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

    // MARK: No vault

    /// What a profile with no usable vault does with a passkey request: the same origin-bearing step a vault shows, because a page
    /// must not be able to tell whether a profile has a vault. The request is checked exactly as the vault's ceremony checks it
    /// first, so a malformed one fails the same way, and then the user is asked. The only way on is the system's authenticator
    /// (`handOff`); every other answer is a refusal, and nothing is read, written, unlocked or verified.
    @MainActor
    static func offerSystemAuthenticator(
        _ request: WebAuthnRequest,
        context: WebAuthnContext,
        in anchor: ASPresentationAnchor,
        interaction: some WebAuthnCeremonyInteraction
    ) async throws -> Never {
        let rawRPID: String?, preference: WebAuthnUserVerification, operation: WebAuthnPrompt.Operation, userName: String?
        switch request.options {
        case let .creation(options):
            (rawRPID, preference, operation, userName) = (options.rpID, options.userVerification, .create, options.userName.displaySafe)
        case let .assertion(options):
            (rawRPID, preference, operation, userName) = (options.rpID, options.userVerification, .get, nil)
        }
        let willVerify = try verificationPlan(preference, interaction: interaction)
        try Task.checkCancellation()
        try validateDeadline(request)
        guard !context.isPrivate, let origin = URL(string: context.origin) else { throw WebsiteAuthenticatorError.invalidContext }
        let resolved: String
        do {
            resolved = try RelyingPartyPolicy.validate(rpID: rawRPID, origin: origin)
        } catch {
            throw WebsiteAuthenticatorError.invalidRequest
        }
        _ = try validateClient(
            WebAuthnClientData(origin: context.origin, topOrigin: context.topOrigin, crossOrigin: context.crossOrigin, rpID: resolved),
            rawRPID: rawRPID
        )
        try await context.validate()
        try validateDeadline(request)
        let decision = await interaction.decide(
            WebAuthnPrompt(
                operation: operation, origin: context.origin, topOrigin: context.topOrigin, rpID: resolved, requestedUserName: userName,
                choices: [], offersNewAccount: false, userVerification: preference, willVerifyUser: willVerify
            ),
            in: anchor,
            until: request.deadline
        )
        _ = try approval(decision, rpID: resolved, context: context)
        throw WebsiteAuthenticatorError.notAllowed
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
        if candidates.isEmpty {
            // Counts only: whether the vault holds this relying party at all (an allowCredentials mismatch) or only a related one
            // (an RP ID mismatch, such as example.com against login.example.com, which WebAuthn never matches).
            // ID lengths, never IDs, tell an encoding mismatch (20 bytes asked, 27 stored) from a passkey the site never had.
            let stored = listed.accounts.flatMap(\.passkeys)
            let sameRP = stored.filter { $0.rpID == bound.rpID }
            let related = stored.filter { $0.rpID != bound.rpID && ($0.rpID.hasSuffix("." + bound.rpID) || bound.rpID.hasSuffix("." + $0.rpID)) }.count
            let lengths = { (ids: [Data]) in Set(ids.map(\.count)).sorted().map(String.init).joined(separator: ",") }
            WebAuthnRefusal.note(
                "no-match", rpID: bound.rpID, profileID: context.profileID,
                counts: "allowCredentials=\(options.allowCredentials.count) matching=0 sameRP=\(sameRP.count) relatedRP=\(related)"
                    + " allowedIDBytes=[\(lengths(options.allowCredentials))] storedIDBytes=[\(lengths(sameRP.map(\.credentialID)))]"
            )
        }
        // No matching passkey is still a user-visible decision, never an immediate error or an immediate hand-off: either would tell
        // a page whether this vault holds a passkey for it, with no origin-bearing native step. The prompt names the site; with
        // nothing to approve it offers only the way to the system's authenticator, and the page hears of it only if the user
        // chose that. Dismissing it, or letting it expire, is the same refusal as dismissing a prompt that had an account to use.
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
            _ = try approval(decision, rpID: bound.rpID, context: context)
            throw WebsiteAuthenticatorError.notAllowed
        }
        guard let selected = try approval(decision, rpID: bound.rpID, context: context),
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
        // What a relying party that rejects this assertion would need to tell apart, without any ID or user data.
        WebAuthnRefusal.log(
            "asserted", rpID: bound.rpID,
            counts: "idBytes=\(passkey.credentialID.count) handleBytes=\(passkey.userHandle.count) candidates=\(candidates.count) "
                + "allowCredentials=\(options.allowCredentials.count)",
            info: "source=\(passkey.source.map { "\($0)" } ?? "unknown") discoverable=\(options.allowCredentials.isEmpty) "
                + "appid=\(options.appID != nil) uv=\(verified) be=\(passkey.backupEligible) bs=\(passkey.isBackedUp)"
        )
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
            _ = try approval(offer, rpID: resolved, context: context)
            try Task.checkCancellation()
            try await context.validate()
            try validateDeadline(request)
            // An offer made for an unlocked vault is not consent to unlock one that locked meanwhile.
            if !lockedAtOffer, manager.authorizationEpoch == nil {
                throw WebsiteAuthenticatorError.notAllowed
            }
        }

        if manager.authorizationEpoch == nil {
            // Our offer sheet and the system's unlock sheet never share the window: each is still closing for a moment after
            // its answer arrives (the next step would be refused, or the system sheet put behind ours).
            try await requireFreeWindow(anchor, rpID: resolved, context: context, "before unlock")
            do {
                try await manager.unlock(in: anchor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                WebAuthnRefusal.note("unlock-failed", rpID: resolved, profileID: context.profileID, info: "\(type(of: error))")
                throw WebsiteAuthenticatorError.notAllowed
            }
            try await requireFreeWindow(anchor, rpID: resolved, context: context, "after unlock")
            try Task.checkCancellation()
            try await context.validate()
            try validateDeadline(request)
        }
        guard let epoch = manager.authorizationEpoch else { throw WebsiteAuthenticatorError.notAllowed }
        return Bound(client: client, rpID: resolved, epoch: epoch)
    }

    /// Waits (bounded) for a sheet still closing on `anchor`; one that stays up is a logged refusal, never a queue behind it.
    @MainActor
    private static func requireFreeWindow(
        _ anchor: ASPresentationAnchor, rpID: String, context: WebAuthnContext, _ moment: String
    ) async throws {
        guard await NativeSheet.waitForSheetToClose(on: anchor) else {
            try Task.checkCancellation()
            WebAuthnRefusal.note("interaction-refused", rpID: rpID, profileID: context.profileID, info: "a sheet stayed up \(moment)")
            throw WebsiteAuthenticatorError.notAllowed
        }
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
        let snapshot: StoreSnapshot
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
        do {
            try await interaction.verifyUser(reason: reason, until: request.deadline)
        } catch let error as WebsiteAuthenticatorError {
            var name = "verification-failed"
            if case .expired = error { name = "timeout" }
            WebAuthnRefusal.note(name, rpID: bound.rpID, profileID: context.profileID)
            throw error
        }
        try await revalidate(request, context: context, manager: manager, bound: bound)
        return true
    }

    /// A step's answer. Every refusal is logged here by case; a cancel is logged by whoever cancelled, and a hand-off by the adapter.
    @MainActor
    private static func approval(_ decision: WebAuthnDecision, rpID: String, context: WebAuthnContext) throws -> UUID? {
        switch decision {
        case let .approved(choice):
            return choice
        case .declined:
            WebAuthnRefusal.note("user-declined", rpID: rpID, profileID: context.profileID)
            throw WebsiteAuthenticatorError.notAllowed
        case .expired:
            WebAuthnRefusal.note("timeout", rpID: rpID, profileID: context.profileID)
            throw WebsiteAuthenticatorError.expired
        case .unavailable:
            WebAuthnRefusal.note("interaction-refused", rpID: rpID, profileID: context.profileID, info: "window hidden or busy")
            throw WebsiteAuthenticatorError.notAllowed
        case .cancelled:
            throw CancellationError()
        case .handOff:
            throw WebsiteAuthenticatorError.handOff
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
            let name = passkey.userDisplayName == passkey.userName ? "" : passkey.userDisplayName.displaySafe
            let detail = [passkey.userName.displaySafe, name, "#" + passkey.id.uuidString]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return (passkey.id, label(account), detail)
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
