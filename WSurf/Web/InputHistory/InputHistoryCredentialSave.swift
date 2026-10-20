// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Observation

/// Saves a password from Input History into Credential Manager, only when the person asks and then confirms what is written.
///
/// It uses the same backend as the save offer on a page: the vault route, `CredentialAccountSelection.savePlan` and `commitSave`.
/// It does not use the page-bound offer, which needs the original document to be on screen. Nothing is written until `confirm`.
/// A vault the person did not unlock for this is never opened: `start` runs from the click on Save as Credential.
@MainActor
@Observable
final class InputHistoryCredentialSave: Identifiable {
    enum Outcome: Equatable {
        case saved
        case alreadySaved
        /// More than one saved login matches the username. Which one to change is the person's to decide in Credential Manager.
        case ambiguous
        /// No vault can take the login: none is set up, or it needs attention in Settings.
        case unavailable
        case failed(String)
    }

    enum Stage: Equatable {
        /// Choosing and unlocking a vault. System prompts are showing, so there is nothing to confirm yet.
        case working
        case confirming
        case finished(Outcome)
        case canceled
    }

    let id = UUID()
    let profile: Profile
    /// The HTTPS origin the login would belong to.
    let origin: String
    /// The page the field was on, kept with a new login as the vault does for a save offer. Nil when it is not on `origin`.
    let loginURL: URL?
    private(set) var username: String
    private(set) var stage = Stage.working
    /// What saving does now: it follows the username as it is edited.
    private(set) var plan = CredentialSavePlan.create
    private(set) var isBusy = false
    private(set) var notice: String?

    @ObservationIgnored private var password: String
    @ObservationIgnored private var manager: CredentialManager?
    /// The vault's authorization when the person was shown what saving does. A lock since then writes nothing.
    @ObservationIgnored private var epoch: UInt64?
    /// Observed: `canSave` reads it, so Save turns back on when the check for an edited username ends.
    private var planCheck: Task<Void, Never>?
    @ObservationIgnored private var reviewedOnce = false

    /// Nil for a row that cannot be saved: not a password, an HTTP address, or a value Credential Manager would refuse.
    init?(row: InputHistoryListModel.Row, profile: Profile) {
        guard !profile.isPrivate, row.canSaveAsCredential, let origin = row.credentialOrigin,
              (try? SavedPassword(website: origin, username: row.username ?? "", password: row.value)) != nil else { return nil }
        self.profile = profile
        self.origin = origin
        loginURL = URL(string: row.location).flatMap { CredentialAccountSelection.loginURL(for: $0, origin: origin) }
        username = row.username ?? ""
        password = row.value
    }

    var isRefreshing: Bool {
        planCheck != nil
    }

    var isUpdate: Bool {
        if case .update = plan {
            return true
        }
        return false
    }

    /// Saving needs something to write, and exactly one place to write it.
    var canSave: Bool {
        guard stage == .confirming, !isBusy, !isRefreshing else { return false }
        return plan == .create || isUpdate
    }

    // MARK: - Choosing the vault

    /// Picks the vault (the person chooses when more than one could hold it), unlocks it, and works out what saving would do.
    func start(in anchor: ASPresentationAnchor) async {
        guard stage == .working, manager == nil else { return }
        let route = await CredentialRouting.route(profile: profile, origin: origin, username: username.isEmpty ? nil : username)
        if case .unavailable = route {
            finish(.unavailable)
            return
        }
        guard let chosen = await route.resolve(profile: profile, in: anchor), chosen.profileID == profile.id else {
            cancel()
            return
        }
        if !chosen.isUnlocked {
            do {
                try await chosen.unlock(in: anchor)
            } catch {
                cancel()
                return
            }
        }
        guard stage == .working else { return }
        manager = chosen
        epoch = chosen.authorizationEpoch
        guard let fresh = await currentPlan() else { return }
        plan = fresh
        switch fresh {
        case .unchanged:
            finish(.alreadySaved)
        case .ambiguous:
            finish(.ambiguous)
        case .create, .update:
            stage = .confirming
        }
    }

    // MARK: - Confirming

    /// The username can be corrected before saving; the plan follows it.
    func edit(username text: String) {
        guard stage == .confirming else { return }
        username = String(text.prefix(InputHistoryLimits.username))
        planCheck?.cancel()
        let edited = username
        planCheck = Task { [weak self] in
            let fresh = await self?.currentPlan()
            guard let self, !Task.isCancelled, stage == .confirming, username == edited else { return }
            planCheck = nil
            if let fresh {
                plan = fresh
            }
        }
    }

    /// Writes the login, unless the saved logins changed since the person was shown what saving does. In that case nothing is
    /// written and the new plan is shown once for another confirmation.
    func confirm() async {
        guard canSave, let manager else { return }
        guard let epoch, manager.authorizationEpoch == epoch else {
            finish(.failed(Self.message(for: CredentialVaultError.unauthorized)))
            return
        }
        isBusy = true
        notice = nil
        defer { isBusy = false }
        do {
            let login = try SavedPassword(website: origin, username: username, password: password)
            let snapshot = try await manager.snapshot()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let outcome = try await CredentialAccountSelection.commitSave(
                login, origin: origin, offered: plan, loginURL: loginURL, snapshot: snapshot, manager: manager, epoch: epoch
            )
            switch outcome {
            case .saved:
                finish(.saved)
            case .unchanged:
                finish(.alreadySaved)
            case .needsReview:
                try review(login, in: snapshot)
            }
        } catch {
            finish(.failed(Self.message(for: error)))
        }
    }

    func cancel() {
        guard stage != .finished(.saved) else { return }
        planCheck?.cancel()
        planCheck = nil
        password = ""
        stage = .canceled
    }

    // MARK: - Planning

    private func login() -> SavedPassword? {
        try? SavedPassword(website: origin, username: username, password: password)
    }

    /// What saving would do against the vault as it is now. Nil, with the sheet showing why, when the vault cannot be read.
    private func currentPlan() async -> CredentialSavePlan? {
        guard let manager, let login = login() else {
            finish(.failed(Self.message(for: CredentialVaultError.invalidData)))
            return nil
        }
        guard let snapshot = try? await manager.snapshot() else {
            finish(.failed(Self.message(for: CredentialVaultError.unauthorized)))
            return nil
        }
        return CredentialAccountSelection.savePlan(for: login, origin: origin, accountID: nil, in: snapshot.accounts)
    }

    private func review(_ login: SavedPassword, in snapshot: StoreSnapshot) throws {
        guard !reviewedOnce else { throw CredentialVaultError.staleRevision }
        reviewedOnce = true
        let fresh = CredentialAccountSelection.savePlan(for: login, origin: origin, accountID: nil, in: snapshot.accounts)
        plan = fresh
        switch fresh {
        case .unchanged:
            finish(.alreadySaved)
        case .ambiguous:
            finish(.ambiguous)
        case .create, .update:
            notice = String(localized: "The saved logins changed. Check the details and save again.")
        }
    }

    private func finish(_ outcome: Outcome) {
        planCheck?.cancel()
        planCheck = nil
        password = ""
        stage = .finished(outcome)
    }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            String(localized: "Credential Manager locked before this was saved. Nothing was changed.")
        case CredentialVaultError.staleRevision:
            String(localized: "The saved logins changed. Nothing was changed. Try again.")
        default:
            String(localized: "Couldn’t save this login. Nothing was changed.")
        }
    }
}
