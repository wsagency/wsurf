// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Task 7 (§11.1): what creates a revision inside `commit`. State is read back through the fixture (rows opened with the held DEK),
// and every store here runs on the injected wall clock `RevisionFixtures.stamp`.

// MARK: - Parameters

private nonisolated enum PasswordPartEdit: CaseIterable, Sendable {
    case username, basicAuthMetadata

    func apply(to account: inout CredentialAccount) {
        switch self {
        case .username:
            account.username = "grace"
        case .basicAuthMetadata:
            account.basicAuthenticationMetadata?.password?.label = "Other label"
        }
    }
}

private nonisolated enum TOTPPartEdit: CaseIterable, Sendable {
    case secret, algorithm, period, digits, issuer, userName

    func apply(to totp: inout TOTPGenerator) {
        switch self {
        case .secret:
            totp.secret = Data([9, 9, 9, 9, 9])
        case .algorithm:
            totp.algorithm = .sha256
        case .period:
            totp.period = 60
        case .digits:
            totp.digits = 8
        case .issuer:
            totp.issuer = "Other"
        case .userName:
            totp.userName = "ada@example.test"
        }
    }
}

private nonisolated enum MetadataEdit: CaseIterable, Sendable {
    case displayName, websites, exchangeFields

    func apply(to account: CredentialAccount) throws -> CredentialAccount {
        var edited = account
        switch self {
        case .displayName:
            edited.displayName = "Renamed"
        case .websites:
            edited.origins.append("https://other.example")
            edited.loginURLs.append(URL(string: "https://other.example/login")!)
        case .exchangeFields:
            edited = try account.editingExchange {
                $0.favorite.toggle()
                $0.tags = ["x"]
                $0.subtitle = "Changed"
            }
        }
        return edited
    }
}

/// An edit that would supersede the stored metadata.
private nonisolated enum SupersedingEdit: CaseIterable, Sendable {
    case displayName, validExchangeMetadata

    func apply(to account: CredentialAccount) throws -> CredentialAccount {
        var edited = account
        switch self {
        case .displayName:
            edited.displayName = "New name"
        case .validExchangeMetadata:
            edited.exchangeMetadata = try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata())
        }
        return edited
    }
}

// MARK: - Tests

struct VaultRevisionTests {
    private static let stamp = RevisionFixtures.stamp

    // MARK: Password

    @Test func passwordReplaceMakesOneRevisionAndSetsModifiedAt() async throws {
        let account = VaultFixtures.account(username: "ada", password: "old-secret")
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            let before = try await rig.snapshot()
            let marks = try f.marks()
            var edited = account
            edited.password = "new-secret"

            let receipt = try await rig.commit([edited], cause: "rotated")

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revisions = try f.revisions()
            let revision = try #require(revisions.first)
            #expect(revisions.count == 1)
            #expect(revision.ownerID == account.id)
            #expect(revision.subject == .password)
            #expect(revision.version == 1)
            #expect(revision.recordID != account.id)
            #expect(revision.body.recordedAt == Self.stamp)
            #expect(revision.body.cause == "rotated")
            let superseded = PasswordValue(username: "ada", password: "old-secret", basicAuthenticationMetadata: nil)
            #expect(try revision.value(PasswordValue.self) == superseded)

            let after = try await rig.snapshot()
            let live = try after.account(account.id)
            #expect(live.password == "new-secret")
            #expect(live.modifiedAt == Self.stamp)
            #expect(live.createdAt == nil)
            let versionBefore = try #require(before.stamps[account.id]).version
            #expect(try #require(after.stamps[account.id]).version == versionBefore + 1)
            #expect(try f.recordIDs(of: f.trashID, kind: .revision).isEmpty)
            #expect(try f.recordIDs(of: f.trashID, kind: .trashEntry).isEmpty)
            try f.verify()
        }
    }

    @Test(arguments: PasswordPartEdit.allCases)
    private func usernameAndBasicAuthReplaceMakeRevisions(_ edit: PasswordPartEdit) async throws {
        let account = RevisionFixtures.basicAuthAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            let marks = try f.marks()
            var edited = account
            edit.apply(to: &edited)
            #expect(edited != account)

            let receipt = try await rig.commit([edited], cause: nil)

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revisions = try f.revisions()
            let revision = try #require(revisions.first)
            #expect(revisions.count == 1, "\(edit)")
            #expect(revision.subject == .password, "\(edit)")
            #expect(revision.ownerID == account.id, "\(edit)")
            #expect(revision.version == 1, "\(edit)")
            let superseded = PasswordValue(
                username: account.username, password: account.password, basicAuthenticationMetadata: account.basicAuthenticationMetadata
            )
            #expect(try revision.value(PasswordValue.self) == superseded, "\(edit)")
            let live = try await rig.snapshot().account(account.id)
            #expect(live.username == edited.username, "\(edit)")
            #expect(live.basicAuthenticationMetadata == edited.basicAuthenticationMetadata, "\(edit)")
            #expect(live.modifiedAt == Self.stamp, "\(edit)")
            try f.verify()
        }
    }

    // MARK: TOTP

    @Test(arguments: TOTPPartEdit.allCases)
    private func totpReplaceMakesARevision(_ edit: TOTPPartEdit) async throws {
        let account = RevisionFixtures.totpAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            let marks = try f.marks()
            var edited = account
            edit.apply(to: &edited.totp!)
            #expect(edited.totp != account.totp)

            let receipt = try await rig.commit([edited], cause: "totp edit")

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revisions = try f.revisions()
            let revision = try #require(revisions.first)
            #expect(revisions.count == 1, "\(edit)")
            #expect(revision.subject == .totp, "\(edit)")
            #expect(revision.ownerID == account.id, "\(edit)")
            #expect(revision.version == 1, "\(edit)")
            #expect(revision.body.recordedAt == Self.stamp, "\(edit)")
            #expect(revision.body.cause == "totp edit", "\(edit)")
            #expect(try revision.value(TOTPGenerator.self) == VaultFixtures.totp(), "\(edit)")
            let live = try await rig.snapshot().account(account.id)
            #expect(live.totp == edited.totp, "\(edit)")
            #expect(live.password == account.password, "\(edit)")
            #expect(live.modifiedAt == Self.stamp, "\(edit)")
            try f.verify()
        }
    }

    // MARK: Metadata

    @Test(arguments: MetadataEdit.allCases)
    private func metadataChangeStoresTheTypedProjectionWithoutSecrets(_ edit: MetadataEdit) async throws {
        let account = try RevisionFixtures.plantedAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            let marks = try f.marks()
            let edited = try edit.apply(to: account)
            #expect(edited != account)

            let receipt = try await rig.commit([edited], cause: nil)

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revisions = try f.revisions()
            let revision = try #require(revisions.first)
            #expect(revisions.count == 1, "\(edit)")
            #expect(revision.subject == .metadata, "\(edit)")
            #expect(revision.ownerID == account.id, "\(edit)")
            #expect(revision.version == 1, "\(edit)")
            let projection = MetadataProjection(
                displayName: "Work",
                origins: ["https://example.test"],
                loginURLs: [URL(string: "https://example.test/login")!],
                exchange: try VaultFixtures.sortedJSON(VaultFixtures.exchangeMetadata()),
                exchangeAccountID: Data([9]),
                exchangeItemID: Data([8])
            )
            #expect(try revision.value(MetadataProjection.self) == projection, "\(edit)")

            // Only the typed projection keys exist, and no secret of the account appears in them or in the whole row plaintext.
            let object = try #require(JSONSerialization.jsonObject(with: revision.body.value) as? [String: Any])
            let keys: Set<String> = ["displayName", "origins", "loginURLs", "exchange", "exchangeAccountID", "exchangeItemID"]
            #expect(Set(object.keys).isSubset(of: keys), "\(edit)")
            for secret in RevisionFixtures.plantedSecrets(of: account) {
                #expect(!revision.body.value.includes(secret), "\(edit)")
                #expect(!revision.plaintext.includes(secret), "\(edit)")
            }

            let live = try await rig.snapshot().account(account.id)
            #expect(live.modifiedAt == Self.stamp, "\(edit)")
            #expect(live.password == account.password, "\(edit)")
            try f.verify()
        }
    }

    @Test func exchangeDateOnlyChangeMakesNoRevision() async throws {
        let account = try VaultFixtures.richAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let edited = try account.editingExchange {
                $0.created = VaultFixtures.reference(5_000)
                $0.lastModified = VaultFixtures.reference(6_000)
            }
            #expect(edited.exchangeMetadata != account.exchangeMetadata)

            try await expectPersistOnly(rig, edited: edited)
        }
    }

    @Test func opaqueExchangeIDRefreshMakesNoRevision() async throws {
        let account = try VaultFixtures.richAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            var edited = account
            edited.exchangeAccountID = Data([7])
            edited.exchangeItemID = Data([6])

            try await expectPersistOnly(rig, edited: edited)
        }
    }

    /// The commit is persisted (live row rewritten, head and registry advance) with no revision, journal or history row and no `modifiedAt`.
    private func expectPersistOnly(_ rig: RevisionRig, edited: CredentialAccount) async throws {
        let f = rig.f
        let marks = try f.marks()
        let sourceJournal = try f.journalRows(of: f.vaultID)
        let trashJournal = try f.journalRows(of: f.trashID)

        let receipt = try await rig.commit([edited], cause: "ignored")

        try f.expectOneWrite(since: marks, receipt: receipt)
        #expect(try f.recordIDs(of: f.vaultID, kind: .revision).isEmpty)
        #expect(try f.recordIDs(of: f.trashID, kind: .revision).isEmpty)
        #expect(try f.recordIDs(of: f.trashID, kind: .trashEntry).isEmpty)
        #expect(try f.journalRows(of: f.vaultID) == sourceJournal)
        #expect(try f.journalRows(of: f.trashID) == trashJournal)
        let live = try await rig.snapshot().account(edited.id)
        #expect(live == edited)
        #expect(live.modifiedAt == nil)
        try f.verify()
    }

    // MARK: Combined edit

    @Test func combinedEditMakesOneRevisionPerChangedKindInOneTransaction() async throws {
        var account = VaultFixtures.account(username: "ada", password: "old-pw", passkeys: [try VaultFixtures.passkey()])
        account.totp = VaultFixtures.totp()
        let original = account
        try await VaultStoreFixture.withRig(accounts: [original]) { rig in
            let f = rig.f
            let before = try await rig.snapshot()
            let marks = try f.marks()
            let journalBefore = try f.journalRows(of: f.vaultID)
            var edited = original
            edited.password = "new-pw"
            edited.totp?.secret = Data([7, 7, 7, 7, 7])
            edited.origins.append("https://other.example")
            edited.loginURLs.append(URL(string: "https://other.example/login")!)

            let receipt = try await rig.commit([edited], cause: "combined")

            try f.expectOneWrite(since: marks, receipt: receipt)
            let revisions = try f.revisions()
            #expect(revisions.count == 3)
            #expect(Set(revisions.map(\.subject)) == [.password, .totp, .metadata])
            #expect(Set(revisions.map(\.recordID)).count == 3)
            for revision in revisions {
                #expect(revision.ownerID == original.id)
                #expect(revision.version == 1)
                #expect(revision.body.recordedAt == Self.stamp)
                #expect(revision.body.cause == "combined")
            }
            let password = try #require(revisions.first { $0.subject == .password })
            #expect(try password.value(PasswordValue.self) == PasswordValue(username: "ada", password: "old-pw", basicAuthenticationMetadata: nil))
            let totp = try #require(revisions.first { $0.subject == .totp })
            #expect(try totp.value(TOTPGenerator.self) == VaultFixtures.totp())
            let metadata = try #require(revisions.first { $0.subject == .metadata })
            let projection = try metadata.value(MetadataProjection.self)
            #expect(projection.origins == original.origins)
            #expect(projection.loginURLs == original.loginURLs)

            // One transaction: one live-row version step, one head bump, one journal row carrying all three adds.
            let after = try await rig.snapshot()
            let live = try after.account(original.id)
            let versionBefore = try #require(before.stamps[original.id]).version
            #expect(try #require(after.stamps[original.id]).version == versionBefore + 1)
            #expect(live.modifiedAt == Self.stamp)
            #expect(live.password == "new-pw")
            #expect(live.totp == edited.totp)
            #expect(live.origins == edited.origins)
            #expect(try VaultFixtures.sortedJSON(live.passkeys) == VaultFixtures.sortedJSON(original.passkeys))
            let journal = try f.journalRows(of: f.vaultID)
            #expect(journal.count == journalBefore.count + 1)
            #expect(journal.last?.ops.count == 3)
            try f.verify()
        }
    }

    // MARK: Provenance

    @Test func provenanceIsExplicitOrNil() async throws {
        let account = RevisionFixtures.totpAccount()
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            var passwordEdit = account
            passwordEdit.password = "second-secret"
            _ = try await rig.commit([passwordEdit], cause: nil)
            var totpEdit = try await rig.snapshot().account(account.id)
            totpEdit.totp?.digits = 8
            _ = try await rig.commit([totpEdit], cause: "imported from CSV")

            let revisions = try f.revisions()
            #expect(revisions.count == 2)
            let password = try #require(revisions.first { $0.subject == .password })
            #expect(password.body.cause == nil)
            #expect(password.body.recordedAt == Self.stamp)
            let totp = try #require(revisions.first { $0.subject == .totp })
            #expect(totp.body.cause == "imported from CSV")
            #expect(totp.body.recordedAt == Self.stamp)
            try f.verify()
        }
    }

    // MARK: Refusal

    @Test(arguments: SupersedingEdit.allCases)
    private func undecodableExchangeMetadataRefusesTheSupersedingCommit(_ edit: SupersedingEdit) async throws {
        var seeded = VaultFixtures.account(username: "ada", password: "pw")
        seeded.exchangeMetadata = Data(#"{"not":"typed"}"#.utf8)
        let account = seeded
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            let f = rig.f
            let image = try f.headWriteImage()
            let revision = try f.headRevision(of: f.vaultID)
            let edited = try edit.apply(to: account)

            await #expect(throws: CredentialStoreError.metadataUndecodable) {
                _ = try await rig.commit([edited], cause: nil)
            }

            #expect(try f.headWriteImage() == image, "\(edit)")
            #expect(try f.headRevision(of: f.vaultID) == revision, "\(edit)")
            let snapshot = try await rig.snapshot()
            #expect(snapshot.revision == revision, "\(edit)")
            #expect(snapshot.accounts == [account], "\(edit)")
            try f.verify()
        }
    }

    // MARK: Journal and reopen

    @Test func revisionsAreJournalledAndTheStoreStillVerifies() async throws {
        let owner = VaultFixtures.account(username: "owner", password: "owner-pw")
        let account = VaultFixtures.account(username: "ada", password: "old-pw")
        try await VaultStoreFixture.withRig(accounts: [owner, account], historyRows: 2) { rig in
            let f = rig.f
            let sourceBefore = try f.journalRows(of: f.vaultID)
            let trashBefore = try f.journalRows(of: f.trashID)
            #expect(!sourceBefore.isEmpty)
            let known = Set(try f.recordIDs(of: f.vaultID, kind: .revision))
            var edited = account
            edited.password = "new-pw"
            edited.displayName = "Renamed"

            _ = try await rig.commit([owner, edited], cause: nil)

            let added = try f.revisions(excluding: known)
            #expect(Set(added.map(\.subject)) == [.password, .metadata])
            let source = try f.journalRows(of: f.vaultID)
            #expect(source.count == sourceBefore.count + 1)
            #expect(Array(source.dropLast()) == sourceBefore)
            let row = try #require(source.last)
            #expect(row.transfer == nil)
            #expect(row.ops.count == added.count)
            for revision in added {
                let op = try #require(row.ops.first { $0.recordID == revision.recordID })
                #expect(op.op == .add)
                #expect(op.kind == .revision)
                #expect(op.ownerID == revision.ownerID)
                #expect(op.subject == revision.subject)
                #expect(op.version == revision.version)
                #expect(op.rowDigest == StoreSeal.digest(revision.sealed))
            }
            #expect(try f.journalRows(of: f.trashID) == trashBefore)
            try f.verify()
        }
    }

    @Test func freshUnlockAfterRevisionsVerifiesAndReturnsTheCommittedAccounts() async throws {
        let owner = VaultFixtures.account(username: "owner", password: "owner-pw")
        let account = VaultFixtures.account(username: "ada", password: "old-pw")
        try await VaultStoreFixture.withRig(accounts: [owner, account]) { rig in
            let f = rig.f
            var edited = account
            edited.password = "new-pw"
            edited.displayName = "Renamed"

            let receipt = try await rig.commit([owner, edited], cause: "rotated")
            let committed = try await rig.snapshot()

            // A fresh store re-verifies registry, heads, rows and journals from disk on unlock.
            let (fresh, freshAccess) = try await f.reopenedStore(proving: f.proof)
            let reloaded = try await fresh.snapshot(vaultID: f.vaultID, using: freshAccess)
            #expect(reloaded.revision == receipt.revision)
            #expect(reloaded.stamps == committed.stamps)
            #expect(try reloaded.account(owner.id) == owner)
            var live = try reloaded.account(account.id)
            #expect(live.modifiedAt == Self.stamp)
            live.modifiedAt = nil
            #expect(live == edited)
            try f.verify()
        }
    }

    // MARK: Reading the values

    @Test func revisionValuePageReturnsSupersededValuesNewestFirst() async throws {
        let account = VaultFixtures.account(username: "ada", password: "pw-1")
        try await VaultStoreFixture.withRig(accounts: [account]) { rig in
            var second = try await rig.snapshot().account(account.id)
            second.password = "pw-2"
            _ = try await rig.commit([second], cause: "rotated")
            var third = try await rig.snapshot().account(account.id)
            third.password = "pw-3"
            third.displayName = "Renamed"
            _ = try await rig.commit([third], cause: CredentialChangeCause.import)

            let page = try await rig.store.revisionValuePage(vaultID: rig.f.vaultID, accountID: account.id, after: nil, using: rig.access)
            let listing = try await rig.store.revisionPage(vaultID: rig.f.vaultID, accountID: account.id, after: nil, using: rig.access)
            #expect(page.items.map(\.item) == listing.items)
            #expect(page.next == nil && page.items.count == 3)
            // The commit that made pw-3 comes first, then the one that made pw-2.
            let passwords = try page.items.filter { $0.item.subject == .password }
                .map { try JSONDecoder().decode(PasswordValue.self, from: $0.value).password }
            #expect(passwords == ["pw-2", "pw-1"])
            #expect(page.items.map(\.item.cause).prefix(2).allSatisfy { $0 == CredentialChangeCause.import })
            #expect(page.items.last?.item.cause == "rotated")
            let details = try #require(page.items.first { $0.item.subject == .metadata })
            #expect(try JSONDecoder().decode(MetadataProjection.self, from: details.value).displayName == nil)
        }
    }

    @Test func revisionValuePageRefusesAnotherAccountsRow() async throws {
        let first = VaultFixtures.account(username: "ada", password: "ada-1")
        let other = VaultFixtures.account(username: "grace", password: "grace-1")
        try await VaultStoreFixture.withRig(accounts: [first, other]) { rig in
            var edited = try await rig.snapshot().accounts
            for index in edited.indices {
                edited[index].password = (edited[index].password ?? "") + "-edited"
            }
            _ = try await rig.commit(edited)

            let page = try await rig.store.revisionValuePage(vaultID: rig.f.vaultID, accountID: first.id, after: nil, using: rig.access)
            let owned = try rig.f.revisions().filter { $0.ownerID == first.id }.map(\.recordID)
            #expect(page.items.map(\.item.id) == owned)
            let values = try page.items.map { try JSONDecoder().decode(PasswordValue.self, from: $0.value).password }
            #expect(values == ["ada-1"])
            let unknown = try await rig.store.revisionValuePage(vaultID: rig.f.vaultID, accountID: UUID(), after: nil, using: rig.access)
            #expect(unknown.items.isEmpty && unknown.next == nil)
        }
    }
}
