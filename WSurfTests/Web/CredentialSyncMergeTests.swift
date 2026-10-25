// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurfVault

// iCloud sync, the per-part three-way merge (spec amendment 2026-10-22, §13.3 classes). Every case names the incoming item, the local
// account and the base the Mac kept, and reads the decision. A clock decides nothing.

private nonisolated func entry(id: UUID = UUID()) -> CredentialAccount {
    var account = VaultFixtures.account(id: id, username: "ada", password: "secret-1")
    account.displayName = "Work"
    account.totp = VaultFixtures.totp()
    account.notes = [CredentialNote(text: "note-1")]
    account.secureItems = [SecureItemFixtures.custom(label: "Locker")]
    return account
}

private nonisolated func changed(_ account: CredentialAccount, _ part: SyncPart, _ tag: String = "2") -> CredentialAccount {
    var copy = account
    switch part {
    case .password:
        copy.password = "secret-\(tag)"
    case .totp:
        copy.totp = TOTPGenerator(secret: Data(tag.utf8), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
    case .notes:
        copy.notes = [CredentialNote(text: "note-\(tag)")]
    case .secureItems:
        copy.secureItems = [SecureItemFixtures.custom(label: "Locker-\(tag)")]
    case .metadata:
        copy.displayName = "Name-\(tag)"
    }
    return copy
}

private nonisolated func parts(_ account: CredentialAccount) throws -> SyncParts {
    try SyncParts.of(account)
}

private nonisolated func base(_ account: CredentialAccount, version: UInt64 = 1) throws -> SyncBase {
    SyncBase(version: version, parts: try parts(account))
}

private nonisolated var removedBase: SyncBase {
    SyncBase(version: 1, parts: .removedParts)
}

private nonisolated func removal(of id: UUID, tombstone: Bool = false, passkeyCredentialID: Data? = nil) -> RemovedIdentifier {
    RemovedIdentifier(
        entryID: UUID(), isTombstone: tombstone, accountID: id, exchangeAccountID: nil, exchangeItemID: nil,
        passkeyCredentialID: passkeyCredentialID, rpID: passkeyCredentialID == nil ? nil : "example.test", removedAt: nil
    )
}

private nonisolated func index(_ accounts: [CredentialAccount] = [], removed: [RemovedIdentifier] = []) -> SyncLocalIndex {
    SyncLocalIndex(accounts: accounts, removed: RemovedIdentifiers(items: removed))
}

private nonisolated func live(_ account: CredentialAccount, version: UInt64 = 2) -> SyncItem {
    SyncItem(accountID: account.id, version: version, account: account)
}

private nonisolated func gone(_ id: UUID, version: UInt64 = 2) -> SyncItem {
    SyncItem(accountID: id, version: version, account: nil)
}

private nonisolated func decide(
    _ item: SyncItem, local: CredentialAccount?, base: SyncBase?, others: [CredentialAccount] = [], removed: [RemovedIdentifier] = []
) throws -> SyncDecision {
    try CredentialSyncMerge.decide(item, local: local, base: base, index: index((local.map { [$0] } ?? []) + others, removed: removed))
}

private extension SyncDecision {
    nonisolated var written: CredentialAccount? {
        if case .write(let account, _) = self {
            account
        } else {
            nil
        }
    }

    nonisolated var recorded: SyncBase? {
        switch self {
        case .keep(let base), .write(_, let base), .moveToTrash(let base), .remember(_, let base):
            base
        case .ignore, .review:
            nil
        }
    }

    nonisolated var kind: SyncConflictKind? {
        if case .review(let kind, _) = self {
            kind
        } else {
            nil
        }
    }
}

enum PasskeyScene: CaseIterable, CustomTestStringConvertible {
    case addedThere, removedThere, addedHere, removedHere

    var testDescription: String {
        "\(self)"
    }
}

struct CredentialSyncMergeTests {
    // MARK: Unchanged, one-sided and mixed changes

    @Test func unchangedOnlyRecordsTheBase() throws {
        let account = entry()
        var same = account
        same.modifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        same.passwordEvents = CredentialEvents(lastImportedAt: Date(timeIntervalSinceReferenceDate: 400))
        let accepted = try base(account, version: 4)
        #expect(try decide(live(same, version: 4), local: account, base: try base(account, version: 3)) == .keep(accepted))
        #expect(try decide(live(same, version: 4), local: account, base: nil) == .keep(accepted), "equal needs no common base")
        #expect(try decide(live(same, version: 4), local: account, base: removedBase) == .keep(accepted))
    }

    @Test(arguments: SyncPart.allCases)
    func remoteChangeApplies(part: SyncPart) throws {
        let agreed = entry()
        let incoming = changed(agreed, part)
        let decision = try decide(live(incoming), local: agreed, base: try base(agreed))
        #expect(decision.written == incoming)
        #expect(decision.recorded == SyncBase(version: 2, parts: try parts(incoming)))
        // Nothing to echo: the Mac holds what the base says.
        #expect(try parts(try #require(decision.written)) == decision.recorded?.parts)
    }

    @Test(arguments: SyncPart.allCases)
    func localChangeIsKept(part: SyncPart) throws {
        let agreed = entry()
        let mine = changed(agreed, part)
        let decision = try decide(live(agreed), local: mine, base: try base(agreed))
        #expect(decision == .keep(SyncBase(version: 2, parts: try parts(agreed))))
        #expect(try parts(mine) != decision.recorded?.parts, "so the next upload carries this Mac's version")
    }

    @Test func changesToDifferentPartsMerge() throws {
        let agreed = entry()
        let incoming = changed(agreed, .password)
        let mine = changed(agreed, .notes)
        let decision = try decide(live(incoming), local: mine, base: try base(agreed))
        let merged = try #require(decision.written)
        #expect(merged.password == incoming.password)
        #expect(merged.notes == mine.notes)
        #expect(merged.totp == agreed.totp && merged.secureItems == agreed.secureItems && merged.displayName == agreed.displayName)
        #expect(decision.recorded?.parts == (try parts(incoming)))
        #expect(try parts(merged) != decision.recorded?.parts, "this Mac's notes go up next")
    }

    @Test(arguments: SyncPart.allCases)
    func bothChangedWaitsForReview(part: SyncPart) throws {
        let agreed = entry()
        let incoming = changed(changed(agreed, part, "there"), .metadata == part ? .notes : .metadata, "there")
        let mine = changed(agreed, part, "here")
        let decision = try decide(live(incoming), local: mine, base: try base(agreed))
        #expect(decision == .review(.bothChanged, parts: [part]))
    }

    @Test func noCommonBaseWaitsUnlessEqual() throws {
        let account = entry()
        let different = changed(account, .password)
        #expect(try decide(live(different), local: account, base: nil) == .review(.noCommonBase, parts: [.password]))
        #expect(try decide(live(different), local: account, base: removedBase) == .review(.noCommonBase, parts: [.password]))
        var sameDifferentDates = account
        sameDifferentDates.createdAt = Date(timeIntervalSinceReferenceDate: 1)
        #expect(try decide(live(sameDifferentDates), local: account, base: nil) == .keep(SyncBase(version: 2, parts: try parts(account))))
    }

    @Test func newEntryIsAdded() throws {
        let incoming = entry()
        let decision = try decide(live(incoming), local: nil, base: nil)
        #expect(decision == .write(incoming, SyncBase(version: 2, parts: try parts(incoming))))
    }

    // MARK: Deletes

    @Test func remoteDeleteMovesAnUnchangedEntryToTrash() throws {
        let account = entry()
        let removed = SyncBase(version: 2, parts: .removedParts)
        #expect(try decide(gone(account.id), local: account, base: try base(account)) == .moveToTrash(removed))
        #expect(try decide(gone(account.id), local: nil, base: try base(account)) == .keep(removed), "already gone here")
        #expect(try decide(gone(account.id), local: nil, base: nil) == .keep(removed))
    }

    @Test func remoteDeleteOfAnEntryWithFilesWaitsInsteadOfMovingItToTrash() throws {
        let account = entry()
        var withFiles = account
        withFiles.attachments = [
            CredentialAttachment(
                id: UUID(), name: "scan.pdf", contentType: "com.adobe.pdf", size: 1, sha256: Data(count: 32),
                wrappedKey: Data(count: CredentialAttachment.wrappedKeyBytes), addedAt: nil
            ),
        ]
        // The files are not synced, so the Trash would hold their only copy and the owner was not asked.
        #expect(try decide(gone(account.id), local: withFiles, base: try base(account)) == .review(.deletedThereChangedHere, parts: []))
        // Answered, it is the owner's decision.
        let answer = try CredentialSyncMerge.resolve(
            gone(account.id), kind: .deletedThereChangedHere, local: withFiles, base: try base(account), keepLocal: false, index: index([withFiles])
        )
        #expect(answer == .moveToTrash(SyncBase(version: 2, parts: .removedParts)))
    }

    @Test func deleteAgainstAnEditWaits() throws {
        let agreed = entry()
        let edited = changed(agreed, .password)
        #expect(try decide(gone(agreed.id), local: edited, base: try base(agreed)) == .review(.deletedThereChangedHere, parts: []))
        #expect(try decide(gone(agreed.id), local: agreed, base: nil) == .review(.deletedThereChangedHere, parts: []), "no base: not known unchanged")
        #expect(try decide(live(edited), local: nil, base: try base(agreed)) == .review(.changedThereDeletedHere, parts: []))
    }

    @Test(arguments: [false, true])
    func previouslyRemovedWaitsWithoutABase(tombstone: Bool) throws {
        let incoming = entry()
        let removed = [removal(of: incoming.id, tombstone: tombstone)]
        #expect(try decide(live(incoming), local: nil, base: nil, removed: removed) == .review(.previouslyRemoved, parts: []))
        // Another entry's removal, or a removed passkey, is no reason to wait.
        let others = [removal(of: UUID(), tombstone: tombstone), removal(of: incoming.id, passkeyCredentialID: Data([1]))]
        #expect(try decide(live(incoming), local: nil, base: nil, removed: others).written == incoming)
    }

    @Test func restoreElsewhereAfterASyncedDeleteIsAdded() throws {
        let incoming = entry()
        // This Mac moved the entry to Trash for the synced delete, so Trash lists it; the base says that was agreed.
        let decision = try decide(live(incoming, version: 3), local: nil, base: SyncBase(version: 2, parts: .removedParts), removed: [removal(of: incoming.id)])
        #expect(decision == .write(incoming, SyncBase(version: 3, parts: try parts(incoming))))
    }

    @Test(arguments: [1, 2] as [UInt64])
    func replayedOrEqualVersionIsIgnored(version: UInt64) throws {
        let agreed = entry()
        let held = try base(agreed, version: 2)
        #expect(try decide(live(changed(agreed, .password), version: version), local: agreed, base: held) == .ignore)
        #expect(try decide(gone(agreed.id, version: version), local: agreed, base: held) == .ignore)
        #expect(try decide(live(agreed, version: version), local: nil, base: held) == .ignore)
        // One version higher is news.
        #expect(try decide(live(changed(agreed, .password), version: 3), local: agreed, base: held).written != nil)
    }

    @Test func anItemForAnotherAccountIsRefused() throws {
        #expect(throws: VaultSyncError.malformed) {
            _ = try decide(live(entry()), local: entry(), base: nil)
        }
    }

    // MARK: Passkeys

    @Test func passkeyWithAnotherKeyIsNeverReplaced() throws {
        let credential = Data(repeating: 7, count: 32)
        let mine = try VaultFixtures.passkey(credentialID: credential)
        let theirs = try VaultFixtures.passkey(credentialID: credential)
        var agreed = entry()
        agreed.passkeys = [mine]
        var incoming = changed(agreed, .notes)
        incoming.passkeys = [theirs]

        let first = try decide(live(incoming), local: agreed, base: try base(agreed))
        let merged = try #require(first.written)
        #expect(merged.passkeys == [mine], "the stored key stays")
        #expect(merged.notes == incoming.notes)
        let localHash = try parts(merged).passkeys
        #expect(first.recorded?.parts.passkeys == localHash, "the base holds this Mac's key, not the other one")
        #expect(first.recorded?.parts.sum == (try parts(merged)).sum, "nothing is left to upload")

        // The same item again, one version later: nothing changes and nothing loops.
        let again = try decide(live(incoming, version: 3), local: merged, base: first.recorded)
        guard case .keep(let next) = again else { throw MergeTestFailure("\(again)") }
        #expect(next.parts.sum == (try parts(merged)).sum)
    }

    @Test(arguments: PasskeyScene.allCases)
    func passkeyAddedOrRemovedOnOneSideFollows(scene: PasskeyScene) throws {
        let key = try VaultFixtures.passkey(credentialID: Data(repeating: 9, count: 32))
        var without = entry()
        without.passkeys = []
        var with = without
        with.passkeys = [key]
        let id = PasskeyPart.identity(of: key)
        switch scene {
        case .addedThere:
            let decision = try decide(live(with), local: without, base: try base(without))
            #expect(decision.written?.passkeys == [key])
            #expect(decision.recorded?.parts.passkeys.map(\.identity) == [id])
        case .removedThere:
            let decision = try decide(live(without), local: with, base: try base(with))
            #expect(try #require(decision.written).passkeys.isEmpty)
            #expect(decision.recorded?.parts.passkeys.isEmpty == true)
        case .addedHere:
            let decision = try decide(live(without), local: with, base: try base(without))
            #expect(decision == .keep(try base(without, version: 2)))
            #expect(try parts(with).passkeys.map(\.identity) == [id], "so it goes up next")
        case .removedHere:
            let decision = try decide(live(with), local: without, base: try base(with))
            #expect(decision == .keep(try base(with, version: 2)))
            #expect(decision.recorded?.parts.passkeys.map(\.identity) == [id], "this Mac's removal goes up next")
        }
    }

    @Test func passkeyHeldByAnotherEntryIsLeftOut() throws {
        let key = try VaultFixtures.passkey(credentialID: Data(repeating: 3, count: 32))
        var holder = entry()
        holder.passkeys = [key]
        var elsewhere = key
        elsewhere.id = UUID()  // the same credential id in another entry
        let agreed = entry()
        var incoming = agreed
        incoming.passkeys = [elsewhere]

        // Present here: the passkey is not added, and the base leaves it out, so it does not come back as an upload.
        let decision = try decide(live(incoming), local: agreed, base: try base(agreed), others: [holder])
        #expect(decision == .keep(try base(agreed, version: 2)))
        #expect(decision.recorded?.parts.sum == (try parts(agreed)).sum)

        // New here: the entry is added without it.
        var fresh = entry()
        fresh.passkeys = [elsewhere]
        let added = try decide(live(fresh), local: nil, base: nil, others: [holder])
        #expect(try #require(added.written).passkeys.isEmpty)
        #expect(added.recorded?.parts.passkeys.isEmpty == true)

        // An entry that was only that passkey would be empty: the vault cannot take it.
        let only = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [elsewhere])
        #expect(try decide(live(only), local: nil, base: nil, others: [holder]) == .review(.refused, parts: []))
    }

    @Test func classificationFollowsTheBase() {
        let (a, b, c) = (Data([1]), Data([2]), Data([3]))
        #expect(CredentialSyncMerge.classify(incoming: a, local: a, base: nil) == .unchanged)
        #expect(CredentialSyncMerge.classify(incoming: a, local: b, base: nil) == .noCommonBase)
        #expect(CredentialSyncMerge.classify(incoming: a, local: b, base: b) == .remoteChanged)
        #expect(CredentialSyncMerge.classify(incoming: b, local: a, base: b) == .localChanged)
        #expect(CredentialSyncMerge.classify(incoming: a, local: b, base: c) == .bothChanged)

        #expect(CredentialSyncMerge.classifyPasskey(incoming: a, local: a, base: nil) == .unchanged)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: a, local: b, base: a) == .passkeyHardConflict)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: a, local: nil, base: nil) == .new)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: a, local: nil, base: a) == .localChanged)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: nil, local: a, base: a) == .remoteChanged)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: nil, local: a, base: nil) == .localChanged)
        #expect(CredentialSyncMerge.classifyPasskey(incoming: nil, local: a, base: b) == .localChanged)
    }

    // MARK: Identity

    @Test func sameItemFromPasswordsInTwoEntriesIsAmbiguous() throws {
        let (account, item) = (Data([8]), Data([9]))
        var holder = entry()
        holder.exchangeAccountID = account
        holder.exchangeItemID = item
        var incoming = entry()
        incoming.exchangeAccountID = account
        incoming.exchangeItemID = item
        #expect(try decide(live(incoming), local: nil, base: nil, others: [holder]) == .review(.ambiguous, parts: []))

        // An item merged into the holder counts as held too.
        var merged = entry()
        merged.mergedFrom = [MergedItemLink(accountID: UUID(), exchangeAccountID: account, exchangeItemID: item)]
        #expect(try decide(live(incoming), local: nil, base: nil, others: [merged]) == .review(.ambiguous, parts: []))

        // Another item is no clash, and the entry is its own holder.
        incoming.exchangeItemID = Data([10])
        #expect(try decide(live(incoming), local: nil, base: nil, others: [holder]).written == incoming)

        // A merge that would copy a held identity into a present entry waits too.
        let agreed = entry()
        var named = changed(agreed, .metadata)
        named.exchangeAccountID = account
        named.exchangeItemID = item
        #expect(try decide(live(named), local: agreed, base: try base(agreed), others: [holder]) == .review(.ambiguous, parts: []))
    }

    // MARK: Nothing but content decides

    @Test func noDateDecides() throws {
        let agreed = entry()
        let remote = changed(agreed, .password, "there")
        let mine = changed(agreed, .notes, "here")
        let rival = changed(agreed, .password, "here")
        let stamps: [Date?] = [nil, Date(timeIntervalSinceReferenceDate: 1), Date(timeIntervalSinceReferenceDate: 9e8)]
        var decisions: [[SyncDecision]] = []
        for stamp in stamps {
            var incoming = remote
            incoming.createdAt = stamp
            incoming.modifiedAt = stamp
            incoming.migratedAt = stamp
            decisions.append([
                try decide(live(incoming), local: agreed, base: try base(agreed)),  // one-sided
                try decide(live(incoming), local: mine, base: try base(agreed)),  // mixed
                try decide(live(incoming), local: rival, base: try base(agreed)),  // both changed
            ])
        }
        // Whatever the incoming dates say, the decision, the merged account and the base are the same, and the merge keeps this Mac's dates.
        #expect(decisions[0] == decisions[1] && decisions[1] == decisions[2])
        #expect(decisions[0][0].written?.modifiedAt == nil && decisions[0][0].written?.createdAt == nil)
        #expect(decisions[0][2] == .review(.bothChanged, parts: [.password]))
    }

    @Test func filesDatesAndSignInTimesStayLocal() throws {
        let key = try VaultFixtures.passkey(credentialID: Data(repeating: 5, count: 32))
        var agreed = entry()
        agreed.passkeys = [key]
        var mine = agreed
        mine.attachments = [
            CredentialAttachment(
                id: UUID(), name: "scan.pdf", contentType: "com.adobe.pdf", size: 1, sha256: Data(count: 32),
                wrappedKey: Data(count: CredentialAttachment.wrappedKeyBytes), addedAt: nil
            ),
        ]
        mine.createdAt = Date(timeIntervalSinceReferenceDate: 100)
        mine.modifiedAt = Date(timeIntervalSinceReferenceDate: 200)
        mine.migratedAt = Date(timeIntervalSinceReferenceDate: 300)
        mine.passkeys[0].lastSignedAt = Date(timeIntervalSinceReferenceDate: 400)
        var incoming = changed(agreed, .notes)
        incoming.createdAt = Date(timeIntervalSinceReferenceDate: 1)
        incoming.modifiedAt = Date(timeIntervalSinceReferenceDate: 2)
        incoming.migratedAt = Date(timeIntervalSinceReferenceDate: 3)
        incoming.passkeys[0].lastSignedAt = Date(timeIntervalSinceReferenceDate: 4)

        let merged = try #require(try decide(live(incoming), local: mine, base: try base(agreed)).written)
        #expect(merged.notes == incoming.notes)
        #expect(merged.attachments == mine.attachments)
        #expect(merged.createdAt == mine.createdAt && merged.modifiedAt == mine.modifiedAt && merged.migratedAt == mine.migratedAt)
        #expect(merged.passkeys[0].lastSignedAt == mine.passkeys[0].lastSignedAt)
        #expect(merged.id == mine.id)

        // None of them is a part: a change to one alone is no change.
        var moved = agreed
        moved.createdAt = Date(timeIntervalSinceReferenceDate: 7)
        moved.passkeys[0].lastSignedAt = Date(timeIntervalSinceReferenceDate: 8)
        moved.attachments = mine.attachments
        #expect(try parts(moved) == parts(agreed))
    }

    @Test func theItemsMergedIntoAnEntryAreItsMetadataButTheirObservedBasesAreNot() throws {
        let agreed = entry()
        var merged = agreed
        merged.mergedFrom = [MergedItemLink(accountID: UUID(), exchangeAccountID: Data([1]), exchangeItemID: Data([2]))]
        // A merge that changes nothing else is still a change, or the other Macs never learn that the entry merged away is in it.
        #expect(try parts(merged).metadata != parts(agreed).metadata)
        #expect(try parts(merged).password == parts(agreed).password && parts(merged).notes == parts(agreed).notes)
        #expect(try decide(live(merged), local: agreed, base: try base(agreed)).written?.mergedFrom == merged.mergedFrom)

        // What the other app last sent for a link is not.
        var observed = merged
        observed.mergedFrom?[0].passwordBase = ExchangeBase(contentHash: Data(repeating: 1, count: 32), itemID: Data([4]))
        #expect(try parts(observed) == parts(merged))
    }

    /// Not the Same on a merge suggestion is vault data of both entries: it is part of `metadata`, so it reaches the other Macs, and an
    /// entry without it, or one merged into before without it, keeps the base it had.
    @Test func notTheSameIsMetadataAndLeavesEveryEarlierBaseAsItWas() throws {
        let agreed = entry()
        #expect(try parts(agreed).metadata == CredentialContent.hash(.metadata(agreed)))
        var merged = agreed
        merged.mergedFrom = [MergedItemLink(accountID: UUID(), exchangeAccountID: Data([1]), exchangeItemID: Data([2]))]
        let mergedMetadata = try parts(merged).metadata

        var apart = agreed
        apart.notSameAs = [UUID()]
        #expect(try parts(apart).metadata != parts(agreed).metadata)
        #expect(try parts(apart).password == parts(agreed).password && parts(apart).notes == parts(agreed).notes)
        let decision = try decide(live(apart), local: agreed, base: try base(agreed))
        #expect(decision.written?.notSameAs == apart.notSameAs)
        #expect(decision.recorded?.parts == (try parts(apart)))

        var both = merged
        both.notSameAs = apart.notSameAs
        #expect(try parts(both).metadata != mergedMetadata)
        #expect(try parts(merged).metadata == mergedMetadata, "an entry merged into before keeps its base")
        // Suggest Again on the other Mac takes it away here too.
        #expect(try decide(live(agreed), local: apart, base: try base(apart)).written?.notSameAs == nil)
    }

    @Test func appleBasesTravelWithTheirPart() throws {
        let agreed = entry()
        var incoming = changed(agreed, .password)
        incoming.passwordBase = ExchangeBase(contentHash: Data(repeating: 1, count: 32), itemID: Data([4]))
        incoming.passwordEvents = CredentialEvents(lastImportedAt: Date(timeIntervalSinceReferenceDate: 10))
        incoming.totpBase = ExchangeBase(contentHash: Data(repeating: 2, count: 32), itemID: Data([5]))
        var mine = agreed
        mine.totpBase = ExchangeBase(contentHash: Data(repeating: 3, count: 32), itemID: Data([6]))

        let merged = try #require(try decide(live(incoming), local: mine, base: try base(agreed)).written)
        #expect(merged.passwordBase == incoming.passwordBase && merged.passwordEvents == incoming.passwordEvents, "with the login")
        #expect(merged.totpBase == mine.totpBase, "the code did not change, so its base stays this Mac's")
        #expect(merged.password == incoming.password)

        let codes = changed(incoming, .totp)
        let both = try #require(try decide(live(codes), local: mine, base: try base(agreed)).written)
        #expect(both.totpBase == codes.totpBase, "with the code")
    }

    // MARK: Parts

    @Test func partsIgnoreWhatIsNotAPart() throws {
        let key = try VaultFixtures.passkey(credentialID: Data(repeating: 6, count: 32))
        var account = entry()
        account.passkeys = [key]
        var noise = account
        noise.createdAt = Date(timeIntervalSinceReferenceDate: 1)
        noise.modifiedAt = Date(timeIntervalSinceReferenceDate: 2)
        noise.passwordBase = ExchangeBase(contentHash: Data(count: 32), itemID: nil)
        noise.passwordEvents = CredentialEvents(lastImportedAt: Date(timeIntervalSinceReferenceDate: 3))
        noise.passkeys[0].lastSignedAt = Date(timeIntervalSinceReferenceDate: 4)
        #expect(try parts(noise) == parts(account))
        #expect(try parts(account).sum == parts(noise).sum)
        for part in SyncPart.allCases {
            #expect(try parts(changed(account, part)).sum != parts(account).sum, "\(part)")
        }
        #expect(try parts(account).sum != SyncParts.removedParts.sum)
    }

    @Test func partsListPasskeysInAStableOrder() throws {
        let one = try VaultFixtures.passkey(rpID: "one.example", credentialID: Data(repeating: 1, count: 32))
        let two = try VaultFixtures.passkey(rpID: "two.example", credentialID: Data(repeating: 2, count: 32))
        var forward = entry()
        forward.passkeys = [one, two]
        var backward = forward
        backward.passkeys = [two, one]
        #expect(try parts(forward) == parts(backward))
        #expect(try parts(forward).passkeys.count == 2)
        // The identity folds the site's case and is the credential's own id.
        var shouting = one
        shouting.rpID = "ONE.example"
        #expect(PasskeyPart.identity(of: shouting) == PasskeyPart.identity(of: one))

        var twice = forward
        twice.passkeys = [one, one]
        #expect(throws: CredentialVaultError.duplicateIdentifier) { _ = try SyncParts.of(twice) }
    }

    @Test func removedPartsAreNeverLiveParts() throws {
        let account = entry()
        let live = try parts(account)
        #expect(SyncParts.removedParts.removed && !live.removed)
        #expect(SyncParts.removedParts.sum != live.sum)
        #expect(SyncParts.removedParts.passkeys.isEmpty)
        #expect(try JSONDecoder().decode(SyncParts.self, from: JSONEncoder().encode(live)) == live)
    }

    // MARK: Answering a review

    @Test(arguments: [true, false])
    func bothChangedAndNoCommonBaseAreAnsweredByKeepingOrTaking(keepLocal: Bool) throws {
        let agreed = entry()
        let incoming = changed(agreed, .password, "there")
        let mine = changed(changed(agreed, .password, "here"), .notes, "here")
        let accepted = SyncBase(version: 2, parts: try parts(incoming))
        for kind in [SyncConflictKind.bothChanged, .noCommonBase] {
            let answer = try CredentialSyncMerge.resolve(
                live(incoming), kind: kind, local: mine, base: kind == .bothChanged ? try base(agreed) : nil, keepLocal: keepLocal, index: index([mine])
            )
            if keepLocal {
                #expect(answer == .keep(accepted), "this Mac's version goes up next")
            } else {
                let result = try #require(answer.written)
                #expect(result.password == incoming.password, "the other version is taken")
                #expect(result.notes == incoming.notes || kind == .bothChanged && result.notes == mine.notes)
                #expect(answer.recorded == accepted)
            }
        }
    }

    @Test(arguments: [true, false])
    func deletesAreAnsweredByRestoringOrRemoving(keepLocal: Bool) throws {
        let account = entry()
        let removed = SyncBase(version: 2, parts: .removedParts)
        let accepted = SyncBase(version: 2, parts: try parts(account))
        let there = try CredentialSyncMerge.resolve(
            gone(account.id), kind: .deletedThereChangedHere, local: account, base: try base(account), keepLocal: keepLocal, index: index([account])
        )
        #expect(there == (keepLocal ? .keep(removed) : .moveToTrash(removed)))
        for kind in [SyncConflictKind.changedThereDeletedHere, .previouslyRemoved] {
            let here = try CredentialSyncMerge.resolve(live(account), kind: kind, local: nil, base: nil, keepLocal: keepLocal, index: index())
            #expect(here == (keepLocal ? .keep(accepted) : .write(account, accepted)))
        }
    }

    @Test func informationRowsAreDismissedByAnyAnswerAndWriteNothing() throws {
        let account = entry()
        let agreed = entry(id: account.id)
        for kind in [SyncConflictKind.ambiguous, .refused] {
            for keepLocal in [true, false] {
                // Without a base there is nothing to keep: the row goes and the dismissal changes nothing at all.
                let alone = try CredentialSyncMerge.resolve(live(account), kind: kind, local: nil, base: nil, keepLocal: keepLocal, index: index())
                #expect(alone == .ignore)
                // With one, the base takes the version the row stands for and keeps its parts, so this Mac’s next version is the one after
                // it and nothing is agreed or written.
                let known = try CredentialSyncMerge.resolve(
                    live(account, version: 4), kind: kind, local: agreed, base: try base(agreed), keepLocal: keepLocal, index: index([agreed])
                )
                #expect(known == .keep(SyncBase(version: 4, parts: try parts(agreed))))
                #expect(known.written == nil)
            }
        }
    }

    @Test(arguments: [true, false])
    func everyRowCanBeAnsweredWhateverHappenedToTheEntryMeanwhile(keepLocal: Bool) throws {
        let agreed = entry()
        let theirs = changed(agreed, .password)
        let mine = changed(agreed, .notes)
        let accepted = SyncBase(version: 2, parts: try parts(theirs))
        let removed = SyncBase(version: 2, parts: .removedParts)
        // Both changed, and then the entry was deleted here: the answer is the one for a change there and a deletion here.
        let deletedHere = try CredentialSyncMerge.resolve(
            live(theirs), kind: .bothChanged, local: nil, base: try base(agreed), keepLocal: keepLocal, index: index()
        )
        #expect(deletedHere == (keepLocal ? .keep(accepted) : .write(theirs, accepted)))
        // Deleted there and changed here, and then deleted here too: nothing is left to move.
        let goneBoth = try CredentialSyncMerge.resolve(
            gone(agreed.id), kind: .deletedThereChangedHere, local: nil, base: try base(agreed), keepLocal: keepLocal, index: index()
        )
        #expect(goneBoth == .keep(removed))
        // Changed there and deleted here, and then the entry came back here: the two versions are the ones to choose from.
        let restored = try CredentialSyncMerge.resolve(
            live(theirs), kind: .changedThereDeletedHere, local: mine, base: try base(agreed), keepLocal: keepLocal, index: index([mine])
        )
        if keepLocal {
            #expect(restored == .keep(accepted))
        } else {
            #expect(try #require(restored.written).password == theirs.password)
        }
    }
}

private struct MergeTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
