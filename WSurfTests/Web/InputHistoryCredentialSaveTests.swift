// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Save as Credential from Input History: the vault is written only after the person confirms, through the same backend as a
/// save offer, and only into the account they were shown. Vaults are the registry-backed fixtures; values are synthetic.
@MainActor
struct InputHistoryCredentialSaveTests {
    private static let origin = "https://example.test"
    private static let typed = "dummy-new-456"
    private static let user = "ada@example.test"

    /// A list row for a value typed on `url`. Rows only come from the list model, over an Input History that has no store.
    private func row(
        _ value: String = InputHistoryCredentialSaveTests.typed, kind: InputHistoryPayload.Kind = .password,
        username: String? = InputHistoryCredentialSaveTests.user,
        url: String = "https://example.test/login", profile: Profile
    ) throws -> InputHistoryListModel.Row {
        let name = "InputHistoryCredentialSaveTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let history = InputHistory(ownsSession: false, makeStore: { _, _ in nil })
        let model = InputHistoryListModel(profile: profile, settings: BrowserSettings(defaults: defaults), history: history)
        let payload = InputHistoryPayload(url: url, frameOrigin: nil, title: "Sign in", label: "Password", kind: kind, value: value, username: username)
        model.show([InputHistoryEntry(id: "1800000000000-\(UUID().uuidString)", createdAt: Date(), expiresAt: nil, payload: payload)])
        return try #require(model.visible.first)
    }

    private func started(_ profile: Profile) async throws -> InputHistoryCredentialSave {
        let save = try #require(InputHistoryCredentialSave(row: try row(profile: profile), profile: profile))
        await save.start(in: VaultManagerFixture.anchor())
        return save
    }

    // MARK: - Writing

    @Test func createsTheLoginOnlyWhenConfirmed() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let save = try await started(profile)
            #expect(save.stage == .confirming)
            #expect(save.plan == .create)
            #expect(try await vaults[0].manager.snapshot().accounts.isEmpty, "nothing is written before Save")

            await save.confirm()
            #expect(save.stage == .finished(.saved))
            let accounts = try await vaults[0].manager.snapshot().accounts
            #expect(accounts.count == 1)
            #expect(accounts.first?.username == Self.user)
            #expect(accounts.first?.password == Self.typed)
            #expect(accounts.first?.origins == [Self.origin])
            #expect(accounts.first?.loginURLs.map(\.path) == ["/login"], "the page it was typed on is its login address")
        }
    }

    @Test func updatesTheSingleMatchingLogin() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let existing = VaultFixtures.account(username: Self.user, password: "dummy-old-123", origin: Self.origin)
            try await VaultManagerFixture.save([existing], in: vaults[0])

            let save = try await started(profile)
            #expect(save.plan == .update(existing.id))
            #expect(save.isUpdate)
            await save.confirm()
            #expect(save.stage == .finished(.saved))
            let accounts = try await vaults[0].manager.snapshot().accounts
            #expect(accounts.map(\.id) == [existing.id])
            #expect(accounts.map(\.password) == [Self.typed])
        }
    }

    @Test func anAlreadySavedPasswordWritesNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            try await VaultManagerFixture.save([VaultFixtures.account(username: Self.user, password: Self.typed, origin: Self.origin)], in: vaults[0])
            let before = try await vaults[0].manager.snapshot().revision

            let save = try await started(profile)
            #expect(save.stage == .finished(.alreadySaved))
            #expect(try await vaults[0].manager.snapshot().revision == before)
        }
    }

    @Test func severalMatchingLoginsWriteNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let pair = [
                VaultFixtures.account(username: Self.user, password: "dummy-a", origin: Self.origin),
                VaultFixtures.account(username: Self.user, password: "dummy-b", origin: Self.origin),
            ]
            try await VaultManagerFixture.save(pair, in: vaults[0])
            let before = try await vaults[0].manager.snapshot().revision

            let save = try await started(profile)
            #expect(save.stage == .finished(.ambiguous), "which login to change is the person's choice in Credential Manager")
            #expect(try await vaults[0].manager.snapshot().revision == before)
        }
    }

    @Test func cancellingWritesNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let save = try await started(profile)
            #expect(save.stage == .confirming)
            save.cancel()
            #expect(save.stage == .canceled)
            #expect(!save.canSave)
            await save.confirm()
            #expect(try await vaults[0].manager.snapshot().accounts.isEmpty)
        }
    }

    // MARK: - What the person is shown

    @Test func thePlanFollowsAnEditedUsername() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let existing = VaultFixtures.account(username: Self.user, password: "dummy-old-123", origin: Self.origin)
            try await VaultManagerFixture.save([existing], in: vaults[0])
            let save = try await started(profile)
            #expect(save.plan == .update(existing.id))

            save.edit(username: "grace@example.test")
            #expect(await waitUntil { save.plan == .create && !save.isRefreshing })
            save.edit(username: Self.user)
            #expect(await waitUntil { save.plan == .update(existing.id) && !save.isRefreshing })

            save.edit(username: "grace@example.test")
            #expect(await waitUntil { save.plan == .create && !save.isRefreshing })
            await save.confirm()
            let accounts = try await vaults[0].manager.snapshot().accounts
            #expect(Set(accounts.map(\.username)) == [Self.user, "grace@example.test"])
            #expect(accounts.first { $0.id == existing.id }?.password == "dummy-old-123", "the account that was not shown is untouched")
        }
    }

    @Test func loginsThatChangedSinceThePlanWriteNothingAndAskAgainOnce() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let save = try await started(profile)
            #expect(save.plan == .create)

            // Another window saves the same username meanwhile.
            let other = VaultFixtures.account(username: Self.user, password: "dummy-other", origin: Self.origin)
            try await VaultManagerFixture.save([other], in: vaults[0])
            await save.confirm()
            #expect(save.stage == .confirming)
            #expect(save.notice != nil)
            #expect(save.plan == .update(other.id))
            #expect(try await vaults[0].manager.snapshot().accounts.map(\.password) == ["dummy-other"])

            // Confirming what is shown now writes it.
            await save.confirm()
            #expect(save.stage == .finished(.saved))
            #expect(try await vaults[0].manager.snapshot().accounts.map(\.password) == [Self.typed])
        }
    }

    @Test func aVaultLockedAfterThePlanWritesNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let save = try await started(profile)
            #expect(save.stage == .confirming)
            vaults[0].manager.lock(reason: .manual)

            await save.confirm()
            guard case .finished(.failed) = save.stage else {
                Issue.record("a locked vault must end the save, not wait: \(save.stage)")
                return
            }
            try await VaultManagerFixture.unlock(vaults[0])
            #expect(try await vaults[0].manager.snapshot().accounts.isEmpty)
        }
    }

    @Test func aLockedVaultIsNotOpenedBeforeTheClick() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, passkeys, vaults in
            let asked = passkeys.assertions.count
            let save = try #require(InputHistoryCredentialSave(row: try row(profile: profile), profile: profile))
            #expect(save.stage == .working)
            #expect(!vaults[0].manager.isUnlocked)
            #expect(passkeys.assertions.count == asked, "making the save asks for nothing; only start, on the click, may")
        }
    }

    @Test func aProfileWithoutAVaultIsTold() async throws {
        try await VaultManagerFixture.with(vaults: []) { profile, _, _ in
            let save = try await started(profile)
            #expect(save.stage == .finished(.unavailable))
        }
    }

    // MARK: - Rows that cannot be saved

    @Test func onlyHTTPSPasswordRowsOfAPersistentProfileCanBeSaved() throws {
        let profile = Profile(id: UUID(), name: "Test", symbol: "key", color: .blue)
        let saveable = try row(profile: profile)
        #expect(saveable.canSaveAsCredential)
        #expect(InputHistoryCredentialSave(row: saveable, profile: profile) != nil)

        let http = try row(url: "http://example.test/login", profile: profile)
        #expect(!http.canSaveAsCredential)
        #expect(InputHistoryCredentialSave(row: http, profile: profile) == nil)

        let text = try row(kind: .text, profile: profile)
        #expect(!text.canSaveAsCredential)
        #expect(InputHistoryCredentialSave(row: text, profile: profile) == nil)

        let tooLong = try row(String(repeating: "x", count: 4_097), profile: profile)
        #expect(InputHistoryCredentialSave(row: tooLong, profile: profile) == nil, "the vault would refuse it")

        #expect(InputHistoryCredentialSave(row: saveable, profile: .privateBrowsing()) == nil)
    }
}
