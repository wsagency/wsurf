// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// What the import memory holds and where (`ImportTrace`, `ImportMemoryKey`): keyed digests only, sealed inside the vault, the same on
// every Mac of the vault, kept by a merge and a purge, and part of what sync sends for a merge. Every value is synthetic.
@MainActor
extension CredentialCSVTests {
    static let traceNeedles = ["lovelace-unique-name", "secret-pw-4711", "memory-host.test", "a note nobody may read"]

    @Test func theImportMemoryHoldsKeyedDigestsOnlyAndOnlyTheVaultsKeyMatchesThem() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await stage(f, [row(Self.traceNeedles[0], Self.traceNeedles[1], url: "https://memory-host.test/in", notes: Self.traceNeedles[3])])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let account = try await saved(f, Self.traceNeedles[0])
            let trace = try #require(account.importTrace)
            let key = try await f.manager.importMemoryKey()
            #expect(trace.logins == [key.login(origin: "https://memory-host.test", username: Self.traceNeedles[0])])
            #expect(trace.password == key.password(Self.traceNeedles[1]) && trace.note == key.note(Self.traceNeedles[3]))
            #expect(key.trace(of: account) == trace)

            // No value, in any spelling, and nothing an unkeyed hash or another vault's key reproduces.
            let encoded = try JSONEncoder().encode(trace)
            let digests = trace.logins + [trace.password, trace.note].compactMap { $0 }
            for needle in Self.traceNeedles {
                let bytes = Data(needle.utf8)
                #expect(!encoded.includes(bytes) && !encoded.includes(Data(bytes.base64EncodedString().utf8)), "\(needle)")
                #expect(!digests.contains { $0.includes(bytes) || $0 == Data(SHA256.hash(data: bytes)) })
            }
            let elsewhere = ImportMemoryKey.derive(dek: SymmetricKey(size: .bits256), profileID: f.profile.id, vaultID: f.manager.vaultID)
            #expect(elsewhere.login(origin: "https://memory-host.test", username: Self.traceNeedles[0]) != trace.logins[0])
            #expect(String(describing: key) == "ImportMemoryKey" && String(reflecting: key) == "ImportMemoryKey")
        }
    }

    @Test func aMergeRemembersWhatItTookInAndAPurgeKeepsOnlyDigests() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await stage(f, [row("ada", "pw"), row("ada (1)", "pw"), row("grace", "pw-g", url: Self.otherSite)])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let key = try await f.manager.importMemoryKey()
            let copy = try await saved(f, "ada (1)")
            try await merge(f, [copy], into: try await saved(f, "ada"))
            let link = try #require(try await saved(f, "ada").mergedFrom?.first)
            #expect(link.accountID == copy.id && link.trace == key.trace(of: copy), "the store's merge commit fills it in")

            try await delete(f, try await saved(f, "grace").id)
            try await purgeTrash(f)
            let tombstones = try await f.manager.removedIdentifiers().items.filter { $0.isTombstone && $0.passkeyCredentialID == nil }
            #expect(tombstones.count == 2)
            let logins = Set(tombstones.flatMap { $0.trace?.logins ?? [] })
            #expect(logins.contains(key.login(origin: "https://other.test", username: "grace")))
            #expect(logins.contains(key.login(origin: "https://example.test", username: "ada (1)")))
        }
    }

    @Test func aMergeIsPartOfWhatSyncSendsAndAPlainEntryKeepsItsBase() throws {
        let key = ImportMemoryKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        let plain = base.account(username: "ada", password: "pw")
        #expect(try SyncParts.of(plain).metadata == CredentialContent.hash(.metadata(plain)), "no merge: the base is as it was")

        var merged = plain
        merged.mergedFrom = [MergedItemLink(accountID: UUID(), exchangeAccountID: Data([1]), exchangeItemID: Data([2]))]
        #expect(try SyncParts.of(merged).metadata != SyncParts.of(plain).metadata, "a merge alone is sent")
        var remembered = merged
        remembered.mergedFrom?[0].trace = key.trace(of: base.account(username: "ada (1)", password: "pw"))
        #expect(try SyncParts.of(remembered).metadata != SyncParts.of(merged).metadata, "what it remembers goes with it")
        var observed = remembered
        observed.mergedFrom?[0].passwordBase = ExchangeBase(contentHash: Data(repeating: 7, count: 32), itemID: Data([2]))
        observed.importTrace = key.trace(of: plain)
        #expect(try SyncParts.of(observed) == SyncParts.of(remembered), "an observed base or an import trace is not a part")

        // A removed state carries what the entry stood for, sealed: it opens only as itself, and a Mac that never held the entry keeps it.
        let syncKey = VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        let trace = key.trace(of: plain)
        let removed = SyncItem(accountID: plain.id, version: 2, account: nil, trace: trace)
        let envelope = try VaultSyncCodec.sealItem(removed, key: syncKey)
        #expect(try VaultSyncCodec.openItem(envelope, accountID: plain.id, key: syncKey) == removed)
        #expect(throws: VaultSyncError.authenticationFailed) { try VaultSyncCodec.openItem(envelope, accountID: UUID(), key: syncKey) }
        for digest in trace.logins + [trace.password].compactMap({ $0 }) {
            #expect(!envelope.includes(digest), "sealed, not only keyed")
        }
        let bare = try VaultSyncCodec.sealItem(SyncItem(accountID: plain.id, version: 2, account: nil), key: syncKey)
        #expect(bare.count == VaultSyncCodec.headerBytes + VaultSyncCodec.sealOverhead, "without a trace it is as small as before")
        #expect(try CredentialSyncMerge.decide(removed, local: nil, base: nil, index: SyncLocalIndex(accounts: [], removed: .init(items: [])))
            == .remember(trace, SyncBase(version: 2, parts: .removedParts)))
        #expect(try CredentialSyncMerge.decide(SyncItem(accountID: plain.id, version: 2, account: nil), local: nil, base: nil,
                                               index: SyncLocalIndex(accounts: [], removed: .init(items: [])))
            == .keep(SyncBase(version: 2, parts: .removedParts)), "nothing to remember")

        let taken = CredentialSyncMerge.merge(local: plain, incoming: observed, taking: SyncTaking(parts: [.password, .metadata]))
        #expect(taken.importTrace == observed.importTrace && taken.mergedFrom == observed.mergedFrom)
        #expect(CredentialSyncMerge.merge(local: plain, incoming: observed, taking: SyncTaking(parts: [.totp])).importTrace == nil)
    }
}
