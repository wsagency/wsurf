// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

extension CredentialExchangeTests {
    @Test func sameOriginDoesNotReplaceNeighboursAndExplicitConflictDecisionIsLocal() throws {
        let protectedKey = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let protectedPasskey = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x99]),
            rpID: "example.test",
            userHandle: Data([0x99]),
            userName: "user-0",
            userDisplayName: "User Zero",
            algorithm: -7,
            privateKeyPKCS8: protectedKey,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let protectedTOTP = TOTPGenerator(secret: Data([0x70]), algorithm: .sha256, period: 45, digits: 8, issuer: "Protected", userName: "user-0")
        let existing = [
            account(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                externalID: Data([0xA0, 0x00]),
                itemID: Data([0xB0, 0x00]),
                username: "user-0",
                password: "password-0",
                passkeys: [protectedPasskey],
                totp: protectedTOTP
            ),
        ] + (1..<10).map { index in
            account(
                id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index + 1))!,
                externalID: Data([0xA0, UInt8(index)]),
                itemID: Data([0xB0, UInt8(index)]),
                username: "user-\(index)",
                password: "password-\(index)"
            )
        }
        let incoming = data(
            accountID: Data([0xA0, 0x00]),
            itemID: Data([0xB0, 0x00]),
            credentials: [basicAuthentication(username: "user-0", password: "attacker-replacement")]
        )
        let base = snapshot(existing)
        let preview = try CredentialExchangeCodec.preview(incoming, against: base)
        let conflict = try #require(preview.conflicts.first)
        guard case let .password(conflictingAccountID) = conflict.existing else {
            Issue.record("Expected a conflict with the incoming password identity")
            return
        }
        #expect(conflictingAccountID == existing[0].id)
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.apply(preview, decisions: []) }

        let kept = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)])
        #expect(kept.map(\.id) == existing.map(\.id))
        #expect(kept.map(\.password) == (0..<10).map { "password-\($0)" })

        let replaced = try CredentialExchangeCodec.apply(
            preview,
            decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)]
        )
        #expect(replaced.map(\.password) == ["attacker-replacement"] + (1..<10).map { "password-\($0)" })
        #expect(replaced[0].passkeys.first?.credentialID == Data([0xC0, 0x99]))
        #expect(replaced[0].totp?.secret == protectedTOTP.secret)

        let sameDomainNewRecord = data(
            accountID: Data([0xA0, 0x55]),
            itemID: Data([0xB0, 0x55]),
            credentials: [basicAuthentication(username: "new-user", password: "new-password")]
        )
        let addPreview = try CredentialExchangeCodec.preview(sameDomainNewRecord, against: base)
        #expect(addPreview.conflicts.isEmpty)
        let added = try CredentialExchangeCodec.apply(addPreview, decisions: [])
        #expect(added.count == 11)
        #expect(Array(added.prefix(10)).map(\.id) == existing.map(\.id))
        #expect(Array(added.prefix(10)).map(\.password) == existing.map(\.password))
    }
    @Test func addingConflictSeparatelyForksTheExternalItemIdentity() throws {
        let existing = account(externalID: accountExternalID, itemID: itemExternalID)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "new-password")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([existing]))
        let conflict = try #require(preview.conflicts.first)
        let added = try CredentialExchangeCodec.apply(
            preview,
            decisions: [.add(incoming: conflict.incoming, targetAccountID: nil)]
        )

        #expect(added.count == 2)
        let exported = try CredentialExchangeCodec.export(
            snapshot(added),
            selection: added.map {
                .init(accountID: $0.id, password: true, passkeyIDs: [], totp: false)
            },
            format: .v1
        )
        let items = exported.accounts.flatMap(\.items)
        #expect(items.count == 2)
        #expect(Set(exported.accounts.map(\.id)).count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        _ = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
    }

    @Test func anExplicitSkipWorksForARecordThatIsNotAConflict() throws {
        let existing = [account(username: "grace", password: "kept")]
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot(existing))
        #expect(preview.conflicts.isEmpty)
        let candidate = try #require(preview.candidates.first)

        let result = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: .password(accountID: candidate.id))])
        #expect(result.map(\.id) == existing.map(\.id))
        #expect(result.map(\.password) == ["kept"])
    }

    @Test func aNonConflictingAddKeepsTheExporterIdentifiers() throws {
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let result = try CredentialExchangeCodec.apply(preview, decisions: [])
        let added = try #require(result.first)
        #expect(result.count == 1)
        #expect(added.exchangeAccountID == Data([0xA0, 0x01]))
        #expect(added.exchangeItemID == Data([0xB0, 0x01]))
    }

    @Test func mergingTakesTheChosenTargetsWebsitesAndKeepsItsOtherSecrets() throws {
        var bare = account(username: "", password: nil, totp: TOTPGenerator(
            secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil
        ))
        bare.origins = [origin, "https://second.example.test"]
        let neighbour = account(username: "grace", password: "neighbour")
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare, neighbour]))
        let candidate = try #require(preview.candidates.first)
        let identity = CredentialIdentity.password(accountID: candidate.id)

        let result = try CredentialExchangeCodec.apply(
            preview, decisions: [.add(incoming: identity, targetAccountID: bare.id)]
        )
        #expect(result.count == 2)
        let merged = try #require(result.first { $0.id == bare.id })
        #expect(merged.password == "incoming")
        #expect(merged.totp?.secret == Data([0x71]))
        #expect(merged.origins == bare.origins)
        #expect(result.first { $0.id == neighbour.id } == neighbour)
    }

    @Test func mergingCarriesTheImportedItemsMetadataAndRefusesAnotherImportedItem() throws {
        let totp = TOTPGenerator(secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        let bare = account(username: "", password: nil, totp: totp)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)
        let identity = CredentialIdentity.password(accountID: candidate.id)
        #expect(candidate.exchangeMetadata != nil)

        // A plain account takes the item's identifiers and metadata, so its tags, dates and collections survive.
        #expect(CredentialExchangeCodec.canMerge(candidate, into: bare))
        let merged = try #require(CredentialExchangeCodec.apply(
            preview, decisions: [.add(incoming: identity, targetAccountID: bare.id)]
        ).first)
        #expect(merged.exchangeMetadata == candidate.exchangeMetadata)
        #expect(merged.exchangeAccountID == candidate.exchangeAccountID && merged.exchangeItemID == candidate.exchangeItemID)
        #expect(merged.totp?.secret == Data([0x71]))

        // An account that already stands for a different exporter item would lose one of the two: refused.
        let other = account(externalID: Data([0xA0, 0x09]), itemID: Data([0xB0, 0x09]), username: "", password: nil, totp: totp)
        #expect(!CredentialExchangeCodec.canMerge(candidate, into: other))
        let refused = try CredentialExchangeCodec.preview(incoming, against: snapshot([other]))
        let refusedIdentity = CredentialIdentity.password(accountID: try #require(refused.candidates.first).id)
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.apply(refused, decisions: [.add(incoming: refusedIdentity, targetAccountID: other.id)])
        }
    }

    private func passkeyOnlyAccount(_ seed: UInt8) throws -> CredentialAccount {
        let stored = WebsitePasskey(
            id: UUID(),
            credentialID: Data([0xC0, seed]),
            rpID: "example.test",
            userHandle: Data([seed]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        return account(username: "", password: nil, passkeys: [stored])
    }

    private func externalIdentities(_ accounts: [CredentialAccount]) -> Set<Data> {
        Set(accounts.flatMap { [$0.exchangeAccountID, $0.exchangeItemID].compactMap { $0 } })
    }

    @Test func anItemSplitAcrossDestinationsGivesTheIdentifiersToOneAndForksTheRest() throws {
        let destination = try passkeyOnlyAccount(1)
        let second = try passkeyOnlyAccount(2)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming"), totp()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([destination, second]))
        let candidate = try #require(preview.candidates.first)
        let login = CredentialIdentity.password(accountID: candidate.id)
        let code = CredentialIdentity.totp(accountID: candidate.id)
        #expect(candidate.displayName == "Example account" && candidate.exchangeMetadata != nil)

        // The login goes into one account; the code, undecided, becomes its own account. Both keep the name and
        // metadata, exactly one holds the exporter's identifiers, and the whole plan is valid.
        let oneMerged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: destination.id)])
        #expect(oneMerged.count == 3)
        let merged = try #require(oneMerged.first { $0.id == destination.id })
        let separate = try #require(oneMerged.last)
        #expect(merged.password == "incoming" && merged.totp == nil && merged.displayName == "Example account")
        #expect(merged.exchangeItemID == candidate.exchangeItemID && merged.exchangeMetadata == candidate.exchangeMetadata)
        #expect(separate.totp != nil && separate.password == nil && separate.displayName == "Example account")
        #expect(separate.exchangeItemID != candidate.exchangeItemID && separate.exchangeMetadata != nil)
        #expect(externalIdentities(oneMerged.filter { $0.id == merged.id || $0.id == separate.id }).count == 4)

        // Each credential into its own plain account.
        let twoMerged = try CredentialExchangeCodec.apply(preview, decisions: [
            .add(incoming: login, targetAccountID: destination.id),
            .add(incoming: code, targetAccountID: second.id),
        ])
        #expect(twoMerged.count == 2)
        let first = try #require(twoMerged.first { $0.id == destination.id })
        let other = try #require(twoMerged.first { $0.id == second.id })
        #expect(first.exchangeItemID == candidate.exchangeItemID)
        #expect(other.exchangeItemID != candidate.exchangeItemID && other.exchangeItemID != nil && other.totp != nil)
        #expect(first.displayName == "Example account" && other.displayName == "Example account")
        #expect(other.exchangeMetadata != nil)

        // Both into one account carry the item once.
        let both = try CredentialExchangeCodec.apply(preview, decisions: [
            .add(incoming: login, targetAccountID: destination.id),
            .add(incoming: code, targetAccountID: destination.id),
        ])
        #expect(both.count == 2)
        let combined = try #require(both.first { $0.id == destination.id })
        #expect(combined.password == "incoming" && combined.totp != nil && combined.exchangeItemID == candidate.exchangeItemID)
    }

    @Test func aDifferentlyNamedAccountIsNeverRenamedByAMerge() throws {
        var named = try passkeyOnlyAccount(3)
        named.displayName = "My own name"
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([named]))
        let candidate = try #require(preview.candidates.first)
        #expect(!CredentialExchangeCodec.canMerge(candidate, into: named))
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.apply(
                preview, decisions: [.add(incoming: .password(accountID: candidate.id), targetAccountID: named.id)]
            )
        }

        named.displayName = "Example account"
        #expect(CredentialExchangeCodec.canMerge(candidate, into: named))
    }

    @Test func decisionsTheImportDoesNotOfferAreRejected() throws {
        let bare = account(username: "", password: nil, totp: TOTPGenerator(
            secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil
        ))
        let withLogin = account(username: "grace", password: "neighbour")
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare, withLogin]))
        let identity = CredentialIdentity.password(accountID: try #require(preview.candidates.first).id)

        // Unknown incoming record, two decisions for one record, a target that doesn't exist and one that already
        // holds a login.
        let rejected: [[CredentialImportDecision]] = [
            [.keep(incoming: .password(accountID: UUID()))],
            [.keep(incoming: identity), .add(incoming: identity, targetAccountID: nil)],
            [.add(incoming: identity, targetAccountID: UUID())],
            [.add(incoming: identity, targetAccountID: withLogin.id)],
        ]
        for decisions in rejected {
            #expect(throws: (any Error).self) { try CredentialExchangeCodec.apply(preview, decisions: decisions) }
        }
        // The preview is a value: a refused decision set leaves it, and so the next valid one, untouched.
        #expect(try CredentialExchangeCodec.apply(preview, decisions: []).count == 3)
    }

    @Test func localAccountsUseExporterFallbackIDsForConflictMatching() throws {
        let localID = UUID(uuidString: "10000000-0000-4000-8000-000000000099")!
        let fallbackID = withUnsafeBytes(of: localID.uuid) { Data($0) }
        let local = account(id: localID, externalID: nil, itemID: nil)
        let incoming = data(accountID: fallbackID, itemID: fallbackID, credentials: [
            basicAuthentication(username: "ada", password: "incoming-password")
        ])

        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        #expect(conflict.existing == .password(accountID: localID))
    }

    @Test func exportPreservesOriginsWithoutLoginURLHints() throws {
        var source = account(id: accountID)
        source.origins = ["https://example.test", "https://second.example.test"]
        source.loginURLs = [URL(string: "https://example.test/login")!]

        let exported = try CredentialExchangeCodec.export(
            snapshot([source]),
            selection: [.init(accountID: accountID, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let urls = try #require(exported.accounts.first?.items.first?.scope?.urls)
        #expect(urls == [
            URL(string: "https://example.test/login")!,
            URL(string: "https://second.example.test")!,
        ])
    }

    @Test func oversizedRawFIDO2DataIsRejectedDuringBudgetAccounting() throws {
        guard #available(macOS 26.4, *) else { return }
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let metadata = ASImportableFIDO2Extensions(
            hmacCredentials: nil,
            largeBlob: .init(
                uncompressedSize: CredentialVaultLimits.payloadBytes,
                data: Data(repeating: 0, count: CredentialVaultLimits.payloadBytes)
            )
        )
        let credential = ASImportableCredential.passkey(.init(
            credentialID: Data([0xC0, 0x09]),
            relyingPartyIdentifier: "example.test",
            userName: "ada",
            userDisplayName: "Ada",
            userHandle: Data([0x49]),
            key: key,
            fido2Extensions: metadata
        ))
        do {
            _ = try CredentialExchangeCodec.preview(data(credentials: [credential]), against: snapshot([]))
            Issue.record("Expected oversized FIDO2 data rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 0, credential: 0))
            #expect(diagnostic.reason == .oversized)
            #expect(diagnostic.limit == .itemBytes)
        }
    }

    /// A chain of 32 nested collections whose `titleBytes` titles are linked from every one of `itemCount` items. Each item
    /// re-encodes the whole chain into its own metadata, so the chain is paid for once per item.
    private func sharedAncestryTransfer(titleBytes: Int, itemCount: Int) -> ASExportedCredentialData {
        let providerID = Data([0xA0, 0x90])
        let itemIDs = (0..<itemCount).map { ExchangeScale.itemID($0) }
        var chain = ASImportableCollection(
            id: Data([0xC0, 0]), created: nil, lastModified: nil, title: String(repeating: "a", count: titleBytes),
            subtitle: nil, items: itemIDs.map { ASImportableLinkedItem(item: $0, account: providerID) }, subcollections: []
        )
        for level in 1..<32 {
            chain = ASImportableCollection(
                id: Data([0xC0, UInt8(level)]), created: nil, lastModified: nil,
                title: String(repeating: "a", count: titleBytes), subtitle: nil, items: [], subcollections: [chain]
            )
        }
        return ASExportedCredentialData(
            accounts: [
                ASImportableAccount(
                    id: providerID, userName: "ada", email: "", collections: [chain],
                    items: itemIDs.enumerated().map { index, id in
                        importableItem(id: id, title: "item \(index)", credentials: [basicAuthentication(username: "u\(index)", password: "p")])
                    }
                ),
            ],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func sharedCollectionAncestryOverTheItemBoundIsRefusedAtThatItem() throws {
        // 32 levels of 130 KB titles: 4.16 MB of metadata in every linked item, over the 4 MB an item may hold.
        let exported = sharedAncestryTransfer(titleBytes: 130_000, itemCount: 3)
        do {
            _ = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
            Issue.record("Expected the item's metadata to be rejected")
        } catch let error as CredentialExchangeError {
            #expect(error.reason == .oversized)
            #expect(error.limit == .itemBytes)
            #expect(error.record == .item(account: 0, item: 0))
        }
    }

    @Test func sharedCollectionAncestryReencodedPerItemIsBudgetedBeforeItIsRetained() throws {
        // 32 levels of 120 KB titles: 3.84 MB per item, inside the item bound. The chain is re-encoded into every linked item,
        // so the transfer reaches its 128 MB budget at about the 33rd item and is refused there, not after every item is kept.
        let exported = sharedAncestryTransfer(titleBytes: 120_000, itemCount: 40)
        do {
            _ = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
            Issue.record("Expected the multiplied metadata to be rejected")
        } catch let error as CredentialExchangeError {
            #expect(error.reason == .oversized)
            #expect(error.limit == .transferBytes)
            guard case let .item(account, item) = error.record else {
                Issue.record("Expected the refusal at an item, got \(error.record)")
                return
            }
            #expect(account == 0 && (30...34).contains(item))
        }
    }

    @Test func exportSelectionContainsOnlyRequestedCredentialKinds() throws {
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let p = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x02]),
            rpID: "example.test",
            userHandle: Data([0x42]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: key,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let siblingID = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
        let sibling = WebsitePasskey(
            id: siblingID,
            credentialID: Data([0xC0, 0x03]),
            rpID: "example.test",
            userHandle: Data([0x43]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let sourceWithSibling = account(id: accountID, passkeys: [p, sibling], totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: "Issuer", userName: "ada"))
        let selected = try CredentialExchangeCodec.export(
            snapshot([sourceWithSibling]),
            selection: [.init(accountID: accountID, password: false, passkeyIDs: [passkeyID], totp: false)],
            format: .v1
        )
        #expect(selected.exporterRelyingPartyIdentifier == "wsurf.app")
        let exported = credentials(in: selected)
        #expect(exported.count == 1)
        guard case let .passkey(exportedPasskey) = try #require(exported.first) else {
            Issue.record("Selection exported a credential other than the requested passkey")
            return
        }
        #expect(exportedPasskey.credentialID == Data([0xC0, 0x02]))
    }

    @Test func supportedFIDO2MetadataSurvivesTheExchange() throws {
        if #available(macOS 26.4, *) {
            let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
            let metadata = ASImportableFIDO2Extensions(
                hmacCredentials: .init(algorithm: .sha256, credentialWithUV: Data([1, 2]), credentialWithoutUV: Data([3, 4])),
                largeBlob: .init(uncompressedSize: 4, data: Data([5, 6, 7, 8]))
            )
            let credential = ASImportableCredential.passkey(.init(
                credentialID: Data([0xC0, 0x03]),
                relyingPartyIdentifier: "example.test",
                userName: "ada",
                userDisplayName: "Ada",
                userHandle: Data([0x43]),
                key: key,
                fido2Extensions: metadata
            ))
            let preview = try CredentialExchangeCodec.preview(data(credentials: [credential]), against: snapshot([]))
            let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
            #expect(imported.first?.passkeys.first?.exchangeFIDO2Metadata != nil)
            let output = try CredentialExchangeCodec.export(
                snapshot(imported),
                selection: [.init(accountID: try #require(imported.first?.id), password: false, passkeyIDs: [try #require(imported.first?.passkeys.first?.id)], totp: false)],
                format: .v1
            )
            let exportedPasskey = try #require(credentials(in: output).compactMap { credential -> ASImportableCredential.Passkey? in
                guard case let .passkey(value) = credential else { return nil }
                return value
            }.first)
            let roundTrip = try #require(exportedPasskey.fido2Extensions)
            #expect(roundTrip.hmacCredentials?.algorithm == metadata.hmacCredentials?.algorithm)
            #expect(roundTrip.hmacCredentials?.credentialWithUV == metadata.hmacCredentials?.credentialWithUV)
            #expect(roundTrip.hmacCredentials?.credentialWithoutUV == metadata.hmacCredentials?.credentialWithoutUV)
            #expect(roundTrip.largeBlob?.uncompressedSize == metadata.largeBlob?.uncompressedSize)
            #expect(roundTrip.largeBlob?.data == metadata.largeBlob?.data)
        }
    }

    /// Reported as SKIPPED (not passed) on macOS 26.4 and later, where FIDO2 metadata is exportable.
    nonisolated static let isOlderThanFIDO2Metadata: Bool = {
        if #available(macOS 26.4, *) {
            return false
        }
        return true
    }()

    @Test(.enabled(if: CredentialExchangeTests.isOlderThanFIDO2Metadata))
    func olderSystemsRejectFIDO2MetadataInsteadOfDroppingIt() throws {
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let metadataPasskey = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x04]),
            rpID: "example.test",
            userHandle: Data([0x44]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: key,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: Data([0x7b, 0x7d])
        )
        let source = account(id: accountID, passkeys: [metadataPasskey])
        #expect {
            try CredentialExchangeCodec.export(
                snapshot([source]),
                selection: [.init(accountID: accountID, password: false, passkeyIDs: [passkeyID], totp: false)],
                format: .v1
            )
        } throws: { error in
            guard case CredentialVaultError.invalidData = error else { return false }
            return true
        }
    }

    /// Spec §13.2(a): what an import brought in is recorded, so the next one can tell which side changed. A part the user kept
    /// different from the incoming one is not an observation of it.
    @Test func appliedImportRecordsTheObservedBaseOfEachPart() throws {
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "v1"), totp()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let candidate = try #require(preview.candidates.first)
        let imported = try #require(CredentialExchangeCodec.apply(preview, decisions: []).first)
        #expect(imported.passwordBase == ExchangeBase(contentHash: try CredentialContent.hash(.password(candidate)), itemID: itemExternalID))
        #expect(imported.totpBase == ExchangeBase(contentHash: try CredentialContent.hash(.totp(candidate)), itemID: itemExternalID))
        #expect(imported.passwordEvents == nil && imported.totpEvents == nil, "no date is recorded: an unknown date is not now")

        // The same item again, with another password. The code is the same, so it is a conflict too, and every conflict needs a decision.
        let changed = try CredentialExchangeCodec.preview(
            data(credentials: [basicAuthentication(username: "ada", password: "v2"), totp()]), against: snapshot([imported])
        )
        let login = try #require(changed.conflicts.first { if case .password = $0.incoming { true } else { false } })
        let code = try #require(changed.conflicts.first { if case .totp = $0.incoming { true } else { false } })
        let keepCode = CredentialImportDecision.keep(incoming: code.incoming)

        // Kept out by the user: nothing changes, and the base is still the first one's.
        #expect(try CredentialExchangeCodec.apply(changed, decisions: [.keep(incoming: login.incoming), keepCode]) == [imported])

        // Replacing is an observation of the new version; adding it separately is a new item that is paired with nothing.
        let replaced = try #require(
            CredentialExchangeCodec.apply(changed, decisions: [.replace(incoming: login.incoming, target: login.existing), keepCode]).first
        )
        let newCandidate = try #require(changed.candidates.first)
        let newHash = try CredentialContent.hash(.password(newCandidate))
        #expect(replaced.password == "v2" && replaced.passwordBase?.contentHash == newHash)
        #expect(replaced.passwordBase != imported.passwordBase)
        let added = try CredentialExchangeCodec.apply(changed, decisions: [.add(incoming: login.incoming, targetAccountID: nil), keepCode])
        #expect(added.count == 2 && added.first == imported && added.last?.passwordBase == nil)
    }
}
