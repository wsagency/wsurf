// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

nonisolated enum CredentialIdentity: Hashable, Sendable {
    case password(accountID: UUID)
    case passkey(accountID: UUID, passkeyID: UUID)
    case totp(accountID: UUID)
}

nonisolated struct CredentialImportConflict: Sendable {
    var incoming: CredentialIdentity
    var existing: CredentialIdentity
}

nonisolated enum CredentialImportDecision: Sendable {
    case keep(incoming: CredentialIdentity)
    case add(incoming: CredentialIdentity, targetAccountID: UUID?)
    case replace(incoming: CredentialIdentity, target: CredentialIdentity)
}

nonisolated struct CredentialImportPreview: Sendable {
    let base: VaultSnapshot
    let candidates: [CredentialAccount]
    let conflicts: [CredentialImportConflict]

    var revision: UInt64 { base.revision }
}

nonisolated struct CredentialExportSelection: Sendable {
    var accountID: UUID
    var password: Bool
    var passkeyIDs: Set<UUID>
    var totp: Bool
}

nonisolated struct CredentialExchangeError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    enum Reason: String, Equatable, Sendable {
        case invalidData
        case duplicateIdentifier
        case oversized
        case unsupported
    }

    enum Record: CustomStringConvertible, Sendable, Equatable {
        case exporter
        case account(index: Int)
        case item(account: Int, item: Int)
        case credential(account: Int, item: Int, credential: Int)
        case collection(account: Int, path: [Int])
        case payload

        var description: String {
            switch self {
            case .exporter:
                return "exporter"
            case let .account(index):
                return "account[\(index)]"
            case let .item(account, item):
                return "account[\(account)]/item[\(item)]"
            case let .credential(account, item, credential):
                return "account[\(account)]/item[\(item)]/credential[\(credential)]"
            case let .collection(account, path):
                let indices = path.prefix(33).map(String.init).joined(separator: "/")
                return "account[\(account)]/collection[\(indices)]"
            case .payload:
                return "payload"
            }
        }
    }

    let record: Record
    let reason: Reason

    var description: String { "\(reason.rawValue) at \(record.description)" }
    var errorDescription: String? { description }

    init(record: Record, underlying: any Error) {
        self.record = record
        switch underlying {
        case CredentialVaultError.duplicateIdentifier: reason = .duplicateIdentifier
        case CredentialVaultError.oversized: reason = .oversized
        default: reason = .invalidData
        }
    }

    init(record: Record, reason: Reason) {
        self.record = record
        self.reason = reason
    }
}



nonisolated enum CredentialExchangeCodec {
    private struct ExternalItemID: Hashable {
        let account: Data
        let item: Data
    }
    private struct ExternalPasskeyID: Hashable {
        let relyingPartyID: String
        let credentialID: Data
    }
    private struct ExchangeLink: Codable {
        var item: Data
        var account: Data?
    }
    private struct ExchangeCollection: Codable {
        var id: Data
        var created: Date?
        var lastModified: Date?
        var title: String
        var subtitle: String?
        var items: [ExchangeLink]
        var subcollections: [ExchangeCollection]
    }
    private struct ExchangeMetadata: Codable {
        var accountName: String
        var email: String
        var fullName: String?
        var collections: [ExchangeCollection]
        var subtitle: String?
        var created: Date?
        var lastModified: Date?
        var favorite: Bool
        var tags: [String]
    }

    private struct PayloadBudget {
        var bytes = 0

        mutating func add(_ count: Int) throws {
            let (sum, overflow) = bytes.addingReportingOverflow(count)
            guard count >= 0, !overflow, sum <= CredentialVaultLimits.payloadBytes else {
                throw CredentialVaultError.oversized
            }
            bytes = sum
        }

        mutating func add(_ value: String) throws { try add(value.utf8.count) }
        mutating func add(_ value: Data) throws { try add(value.count) }
    }

    static func preview(_ data: ASExportedCredentialData, against base: VaultSnapshot) throws -> CredentialImportPreview {
        guard data.formatVersion == .v1 else { throw CredentialVaultError.invalidData }
        try validateAccounts(base.accounts)
        guard base.accounts.count <= CredentialVaultLimits.accounts,
              data.accounts.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }

        var budget = PayloadBudget()
        var metadataBudget = PayloadBudget()
        var seenAccountIDs = Set<Data>()
        var seenItemIDs = Set<ExternalItemID>()
        var seenPasskeyIDs = Set<ExternalPasskeyID>()
        var totalCredentials = 0
        var totalCollections = 0
        var candidates: [CredentialAccount] = []
        var record = CredentialExchangeError.Record.exporter

        do {
            try budget.add(data.exporterRelyingPartyIdentifier)
            try budget.add(data.exporterDisplayName)
            for (accountIndex, appleAccount) in data.accounts.enumerated() {
                record = .account(index: accountIndex)
                guard !appleAccount.id.isEmpty, seenAccountIDs.insert(appleAccount.id).inserted else {
                    throw CredentialVaultError.duplicateIdentifier
                }
                try budget.add(appleAccount.id)
                try budget.add(appleAccount.userName)
                try budget.add(appleAccount.email)
                try budget.add(appleAccount.fullName ?? "")
                let collections = try appleAccount.collections.enumerated().map { collectionIndex, collection in
                    record = .collection(account: accountIndex, path: [collectionIndex])
                    return try importCollection(collection, budget: &budget, count: &totalCollections, depth: 0)
                }

                for (itemIndex, item) in appleAccount.items.enumerated() {
                    record = .item(account: accountIndex, item: itemIndex)
                    let itemIdentity = ExternalItemID(account: appleAccount.id, item: item.id)
                    guard candidates.count < CredentialVaultLimits.accounts,
                          !item.id.isEmpty, seenItemIDs.insert(itemIdentity).inserted,
                          !item.credentials.isEmpty else { throw CredentialVaultError.invalidData }
                    try budget.add(item.id)
                    try budget.add(item.title)
                    try budget.add(item.subtitle ?? "")
                    for tag in item.tags { try budget.add(tag) }
                    if #available(macOS 26.4, *), !item.extensions.isEmpty {
                        throw CredentialExchangeError(record: record, reason: .unsupported)
                    }
                    try addScope(item.scope, to: &budget)
                    guard item.credentials.count <= CredentialVaultLimits.accounts - totalCredentials else {
                        throw CredentialVaultError.oversized
                    }
                    totalCredentials += item.credentials.count

                    let itemCollections = collections.compactMap {
                        collection($0, linkedTo: item.id, accountID: appleAccount.id)
                    }
                    var candidate = CredentialAccount(
                        id: UUID(),
                        username: "",
                        displayName: item.title.isEmpty ? nil : item.title,
                        origins: [],
                        loginURLs: [],
                        password: nil,
                        passkeys: [],
                        totp: nil,
                        exchangeAccountID: appleAccount.id,
                        exchangeItemID: item.id,
                        basicAuthenticationMetadata: nil
                    )
                    candidate.exchangeMetadata = try JSONEncoder().encode(ExchangeMetadata(
                        accountName: appleAccount.userName,
                        email: appleAccount.email,
                        fullName: appleAccount.fullName,
                        collections: itemCollections,
                        subtitle: item.subtitle,
                        created: item.created,
                        lastModified: item.lastModified,
                        favorite: item.favorite,
                        tags: item.tags
                    ))
                    // Shared collection ancestry is re-encoded into every linked item; charge what is retained.
                    try metadataBudget.add(candidate.exchangeMetadata?.count ?? 0)
                    try applyScope(item.scope, to: &candidate)

                    for (credentialIndex, credential) in item.credentials.enumerated() {
                        record = .credential(account: accountIndex, item: itemIndex, credential: credentialIndex)
                        switch credential {
                        case let .basicAuthentication(value):
                            guard candidate.basicAuthenticationMetadata == nil else { throw CredentialVaultError.invalidData }
                            let username = try value.userName.map { try importField($0, budget: &budget) }
                            let password = try value.password.map { try importField($0, budget: &budget) }
                            guard username != nil || password != nil else { throw CredentialVaultError.invalidData }
                            candidate.username = username?.value ?? ""
                            candidate.password = password?.value
                            candidate.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
                                username: username?.metadata,
                                password: password?.metadata
                            )
                            if let usernameID = username?.metadata.id,
                               usernameID == password?.metadata.id {
                                throw CredentialVaultError.duplicateIdentifier
                            }
                        case let .passkey(value):
                            let passkeyID = ExternalPasskeyID(
                                relyingPartyID: value.relyingPartyIdentifier.lowercased(),
                                credentialID: value.credentialID
                            )
                            guard seenPasskeyIDs.insert(passkeyID).inserted else {
                                throw CredentialVaultError.duplicateIdentifier
                            }
                            try budget.add(value.credentialID)
                            try budget.add(value.relyingPartyIdentifier)
                            try budget.add(value.userName)
                            try budget.add(value.userDisplayName)
                            try budget.add(value.userHandle)
                            guard value.key.count <= PasskeyKeyEncoding.maximumDERBytes else { throw CredentialVaultError.oversized }
                            try budget.add(value.key)
                            let key = try PasskeyKeyEncoding.importPKCS8(value.key)
                            let passkey = WebsitePasskey(
                                id: UUID(),
                                credentialID: value.credentialID,
                                rpID: value.relyingPartyIdentifier.lowercased(),
                                userHandle: value.userHandle,
                                userName: value.userName,
                                userDisplayName: value.userDisplayName,
                                algorithm: -7,
                                privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(key),
                                backupEligible: true,
                                backupState: false,
                                exchangeFIDO2Metadata: try importFIDO2Metadata(value, budget: &budget)
                            )
                            try passkey.validate()
                            guard let origin = URL(string: "https://\(passkey.rpID)"),
                                  (try? RelyingPartyPolicy.validate(rpID: passkey.rpID, origin: origin)) == passkey.rpID else {
                                throw CredentialVaultError.invalidData
                            }
                            guard !candidate.passkeys.contains(where: {
                                $0.credentialID == passkey.credentialID && $0.rpID == passkey.rpID
                            }) else {
                                throw CredentialVaultError.duplicateIdentifier
                            }
                            candidate.passkeys.append(passkey)
                        case let .totp(value):
                            guard candidate.totp == nil else { throw CredentialVaultError.invalidData }
                            try budget.add(value.secret)
                            try budget.add(value.issuer ?? "")
                            try budget.add(value.userName ?? "")
                            guard let algorithm = TOTPAlgorithm(rawValue: value.algorithm.rawValue) else {
                                throw CredentialVaultError.invalidData
                            }
                            let generator = TOTPGenerator(
                                secret: value.secret,
                                algorithm: algorithm,
                                period: value.period,
                                digits: value.digits,
                                issuer: value.issuer,
                                userName: value.userName
                            )
                            try generator.validate()
                            candidate.totp = generator
                        case .generatedPassword(_):
                            throw CredentialExchangeError(record: record, reason: .unsupported)
                        default:
                            throw CredentialExchangeError(record: record, reason: .unsupported)
                        }
                    }
                    record = .item(account: accountIndex, item: itemIndex)
                    try candidate.validate()
                    candidates.append(candidate)
                }
            }

            record = .payload
            try validateAccounts(candidates)
            guard try encodedSize(candidates) <= CredentialVaultLimits.payloadBytes else {
                throw CredentialVaultError.oversized
            }
            let conflicts = try makeConflicts(candidates, against: base.accounts)
            return CredentialImportPreview(base: base, candidates: candidates, conflicts: conflicts)
        } catch let error as CredentialExchangeError {
            throw error
        } catch {
            throw CredentialExchangeError(record: record, underlying: error)
        }
    }
    /// Applies `decisions` to `preview`. A decision may name any identity the preview's candidates hold; every
    /// real conflict must have exactly one. A record without a decision keeps the default: merged into the
    /// account sharing its external identifiers, otherwise added under its own. Nothing is mutated: the result
    /// is a new array, and any invalid, unknown or repeated decision rejects the whole call.
    static func apply(_ preview: CredentialImportPreview, decisions: [CredentialImportDecision]) throws -> [CredentialAccount] {
        try validateAccounts(preview.base.accounts)
        try validateAccounts(preview.candidates)
        let conflictByIncoming = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.incoming, $0) })
        let incomingIdentities = Set(preview.candidates.flatMap(identities(in:)))
        let baseIdentities = Set(preview.base.accounts.flatMap(identities(in:)))
        let baseAccountIDs = Set(preview.base.accounts.map(\.id))
        var decisionsByIncoming: [CredentialIdentity: CredentialImportDecision] = [:]
        for decision in decisions {
            let incoming: CredentialIdentity
            switch decision {
            case let .keep(value), let .add(value, _): incoming = value
            case let .replace(value, _): incoming = value
            }
            guard incomingIdentities.contains(incoming),
                  decisionsByIncoming.updateValue(decision, forKey: incoming) == nil else {
                throw CredentialVaultError.invalidData
            }
            switch decision {
            case .keep:
                break
            case let .add(_, targetAccountID):
                guard targetAccountID.map(baseAccountIDs.contains) ?? true else { throw CredentialVaultError.invalidData }
            case let .replace(_, target):
                // A conflict is replaced only at the stored credential it matched; any other replacement
                // needs a stored credential of the same kind to overwrite.
                if let conflict = conflictByIncoming[incoming] {
                    guard target == conflict.existing else { throw CredentialVaultError.invalidData }
                } else {
                    guard baseIdentities.contains(target), sameKind(incoming, target) else { throw CredentialVaultError.invalidData }
                }
            }
        }
        guard conflictByIncoming.keys.allSatisfy({ decisionsByIncoming[$0] != nil }) else { throw CredentialVaultError.invalidData }

        var result = preview.base.accounts
        for candidate in preview.candidates {
            let candidateExternalID = try externalItemID(for: candidate)
            let linkedIndices = try result.indices.filter {
                try externalItemID(for: result[$0]) == candidateExternalID
            }
            guard linkedIndices.count <= 1 else { throw CredentialVaultError.duplicateIdentifier }
            let linkedIndex = linkedIndices.first
            var unattached = emptyLike(candidate)
            var unattachedPlaced = false
            // The exporter's item identifiers (and the metadata under them) belong to exactly one account: the
            // stored one that already holds them, else the first destination of this item's credentials. Every
            // other destination is given fresh identifiers and a remapped copy of the metadata.
            var claimed = linkedIndex != nil
            var carried = Set<UUID>()

            func addToSeparateAccount(_ identity: CredentialIdentity, forceFork: Bool) throws {
                if !unattachedPlaced {
                    if claimed || forceFork {
                        try fork(&unattached, from: candidate, candidateID: candidateExternalID)
                    } else {
                        claimed = true
                    }
                    unattachedPlaced = true
                }
                try add(identity, from: candidate, to: &unattached)
            }

            for identity in identities(in: candidate) {
                if let decision = decisionsByIncoming[identity] {
                    switch decision {
                    case .keep:
                        continue
                    case let .replace(_, target):
                        try replace(identity, from: candidate, target: target, in: &result)
                    case let .add(_, targetAccountID):
                        if let targetAccountID {
                            guard let index = result.firstIndex(where: { $0.id == targetAccountID }) else {
                                throw CredentialVaultError.invalidData
                            }
                            try carry(candidate, id: candidateExternalID, into: &result[index], claimed: &claimed, carried: &carried)
                            try merge(identity, from: candidate, into: &result[index])
                        } else {
                            try addToSeparateAccount(identity, forceFork: conflictByIncoming[identity] != nil)
                        }
                    }
                } else if conflictByIncoming[identity] != nil {
                    throw CredentialVaultError.invalidData
                } else if let linkedIndex {
                    try carry(candidate, id: candidateExternalID, into: &result[linkedIndex], claimed: &claimed, carried: &carried)
                    try merge(identity, from: candidate, into: &result[linkedIndex])
                } else {
                    try addToSeparateAccount(identity, forceFork: false)
                }
            }
            if !identities(in: unattached).isEmpty { result.append(unattached) }
        }
        try validateAccounts(result)
        return result
    }

    private static func sameKind(_ lhs: CredentialIdentity, _ rhs: CredentialIdentity) -> Bool {
        switch (lhs, rhs) {
        case (.password, .password), (.passkey, .passkey), (.totp, .totp): true
        default: false
        }
    }

    static func export(
        _ snapshot: VaultSnapshot,
        selection: [CredentialExportSelection],
        format: ASExportedCredentialData.FormatVersion
    ) throws -> ASExportedCredentialData {
        try validateAccounts(snapshot.accounts)
        guard snapshot.accounts.count <= CredentialVaultLimits.accounts,
              selection.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
        guard format == .v1 else { throw CredentialVaultError.invalidData }

        var seenSelections = Set<UUID>()
        var accountByID: [UUID: CredentialAccount] = [:]
        for account in snapshot.accounts { accountByID[account.id] = account }
        var groupedItems: [Data: [ASImportableItem]] = [:]
        var groupMetadata: [Data: ExchangeMetadata] = [:]
        var groupCollections: [Data: [ExchangeCollection]] = [:]
        var groupOrder: [Data] = []
        var totalItems = 0
        var totalCredentials = 0

        for chosen in selection {
            guard seenSelections.insert(chosen.accountID).inserted,
                  let account = accountByID[chosen.accountID] else { throw CredentialVaultError.invalidData }
            let allPasskeyIDs = Set(account.passkeys.map(\.id))
            guard chosen.passkeyIDs.isSubset(of: allPasskeyIDs) else { throw CredentialVaultError.invalidData }

            let basic = chosen.password ? exportBasicAuthentication(account) : nil
            let selectedCredentialCount = chosen.passkeyIDs.count + (basic == nil ? 0 : 1) +
                (chosen.totp && account.totp != nil ? 1 : 0)
            guard selectedCredentialCount <= CredentialVaultLimits.accounts - totalCredentials else {
                throw CredentialVaultError.oversized
            }
            totalCredentials += selectedCredentialCount

            var credentials: [ASImportableCredential] = []
            if let basic {
                credentials.append(.basicAuthentication(basic))
            }
            for passkey in account.passkeys where chosen.passkeyIDs.contains(passkey.id) {
                credentials.append(.passkey(try exportPasskey(passkey)))
            }
            if chosen.totp, let totp = account.totp {
                try totp.validate()
                guard let algorithm = ASImportableCredential.TOTP.Algorithm(rawValue: totp.algorithm.rawValue) else {
                    throw CredentialVaultError.invalidData
                }
                credentials.append(.totp(.init(
                    secret: totp.secret,
                    period: totp.period,
                    digits: totp.digits,
                    userName: totp.userName,
                    algorithm: algorithm,
                    issuer: totp.issuer
                )))
            }
            guard !credentials.isEmpty else { continue }
            totalItems += 1
            guard totalItems <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }

            let externalAccountID = try externalID(account.exchangeAccountID, fallback: account.id)
            let externalItemID = try externalID(account.exchangeItemID, fallback: account.id)
            let metadata = try exchangeMetadata(for: account)
            if let originalMetadata = groupMetadata[externalAccountID] {
                guard originalMetadata.accountName == metadata.accountName,
                      originalMetadata.email == metadata.email,
                      originalMetadata.fullName == metadata.fullName else {
                    throw CredentialVaultError.invalidData
                }
                try mergeCollections(metadata.collections, into: &groupCollections[externalAccountID, default: []])
            } else {
                groupOrder.append(externalAccountID)
                groupMetadata[externalAccountID] = metadata
                groupCollections[externalAccountID] = metadata.collections
            }
            let urls = try exportURLs(account)
            let scope = urls.isEmpty ? nil : ASImportableCredentialScope(urls: urls, androidApps: [])
            var item = makeItem(
                id: externalItemID,
                created: metadata.created,
                lastModified: metadata.lastModified,
                title: account.displayName ?? (account.exchangeMetadata == nil ? account.username : ""),
                scope: scope,
                credentials: credentials,
                tags: metadata.tags
            )
            item.subtitle = metadata.subtitle
            item.favorite = metadata.favorite
            groupedItems[externalAccountID, default: []].append(item)
        }

        var accounts: [ASImportableAccount] = []
        for id in groupOrder {
            guard let items = groupedItems[id] else { continue }
            guard Set(items.map(\.id)).count == items.count else { throw CredentialVaultError.duplicateIdentifier }
            guard let metadata = groupMetadata[id] else { throw CredentialVaultError.invalidData }
            let selectedIDs = Set(items.map(\.id))
            let collectionMetadata = groupCollections[id] ?? []
            let collections = try collectionMetadata.compactMap {
                try exportCollection($0, accountID: id, selectedItemIDs: selectedIDs)
            }
            accounts.append(ASImportableAccount(
                id: id,
                userName: metadata.accountName,
                email: metadata.email,
                fullName: metadata.fullName,
                collections: collections,
                items: items
            ))
        }
        let data = ASExportedCredentialData(
            accounts: accounts,
            formatVersion: format,
            exporterRelyingPartyIdentifier: PasskeyVaultUnlocker.relyingParty,
            exporterDisplayName: "WSurf",
            timestamp: Date()
        )
        guard try encodedSize(data) <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.oversized }
        return data
    }
    private static func collection(
        _ collection: ExchangeCollection,
        linkedTo itemID: Data,
        accountID: Data
    ) -> ExchangeCollection? {
        let items = collection.items.filter {
            $0.item == itemID && ($0.account == nil || $0.account == accountID)
        }
        let subcollections = collection.subcollections.compactMap {
            self.collection($0, linkedTo: itemID, accountID: accountID)
        }
        guard !items.isEmpty || !subcollections.isEmpty else { return nil }
        return ExchangeCollection(
            id: collection.id,
            created: collection.created,
            lastModified: collection.lastModified,
            title: collection.title,
            subtitle: collection.subtitle,
            items: items,
            subcollections: subcollections
        )
    }

    private static func mergeCollections(
        _ incoming: [ExchangeCollection],
        into existing: inout [ExchangeCollection]
    ) throws {
        for collection in incoming {
            if let index = existing.firstIndex(where: { $0.id == collection.id }) {
                guard existing[index].created == collection.created,
                      existing[index].lastModified == collection.lastModified,
                      existing[index].title == collection.title,
                      existing[index].subtitle == collection.subtitle else {
                    throw CredentialVaultError.invalidData
                }
                for item in collection.items where !existing[index].items.contains(where: {
                    $0.item == item.item && $0.account == item.account
                }) {
                    existing[index].items.append(item)
                }
                try mergeCollections(collection.subcollections, into: &existing[index].subcollections)
            } else {
                existing.append(collection)
            }
        }
    }

    private static func importCollection(
        _ collection: ASImportableCollection,
        budget: inout PayloadBudget,
        count: inout Int,
        depth: Int
    ) throws -> ExchangeCollection {
        guard depth <= 32, count < CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
        count += 1
        try budget.add(collection.id)
        try budget.add(collection.title)
        try budget.add(collection.subtitle ?? "")
        let items = try collection.items.map { item in
            try budget.add(item.item)
            try budget.add(item.account ?? Data())
            return ExchangeLink(item: item.item, account: item.account)
        }
        let subcollections = try collection.subcollections.map {
            try importCollection($0, budget: &budget, count: &count, depth: depth + 1)
        }
        return ExchangeCollection(
            id: collection.id,
            created: collection.created,
            lastModified: collection.lastModified,
            title: collection.title,
            subtitle: collection.subtitle,
            items: items,
            subcollections: subcollections
        )
    }
    private static func exchangeMetadata(for account: CredentialAccount) throws -> ExchangeMetadata {
        guard let data = account.exchangeMetadata else {
            return ExchangeMetadata(
                accountName: "",
                email: "",
                fullName: nil,
                collections: [],
                subtitle: nil,
                created: nil,
                lastModified: nil,
                favorite: false,
                tags: []
            )
        }
        return try JSONDecoder().decode(ExchangeMetadata.self, from: data)
    }

    private static func forkMetadata(
        _ data: Data?,
        from old: ExternalItemID,
        to new: ExternalItemID
    ) throws -> Data? {
        guard let data else { return nil }
        var metadata = try JSONDecoder().decode(ExchangeMetadata.self, from: data)
        func remap(_ collections: inout [ExchangeCollection]) {
            for index in collections.indices {
                for itemIndex in collections[index].items.indices {
                    let link = collections[index].items[itemIndex]
                    guard link.item == old.item, link.account == nil || link.account == old.account else { continue }
                    collections[index].items[itemIndex].item = new.item
                    if link.account != nil { collections[index].items[itemIndex].account = new.account }
                }
                remap(&collections[index].subcollections)
            }
        }
        remap(&metadata.collections)
        return try JSONEncoder().encode(metadata)
    }

    private static func exportCollection(
        _ collection: ExchangeCollection,
        accountID: Data,
        selectedItemIDs: Set<Data>
    ) throws -> ASImportableCollection? {
        let items = collection.items.filter {
            selectedItemIDs.contains($0.item) && ($0.account == nil || $0.account == accountID)
        }.map { ASImportableLinkedItem(item: $0.item, account: $0.account) }
        let subcollections = try collection.subcollections.compactMap {
            try exportCollection($0, accountID: accountID, selectedItemIDs: selectedItemIDs)
        }
        guard !items.isEmpty || !subcollections.isEmpty else { return nil }
        return ASImportableCollection(
            id: collection.id,
            created: collection.created,
            lastModified: collection.lastModified,
            title: collection.title,
            subtitle: collection.subtitle,
            items: items,
            subcollections: subcollections
        )
    }
    private static func importField(
        _ field: ASImportableEditableField,
        budget: inout PayloadBudget
    ) throws -> (value: String, metadata: CredentialEditableFieldMetadata) {
        try budget.add(field.value)
        try budget.add(field.id ?? Data())
        try budget.add(field.label ?? "")
        let fieldType: CredentialEditableFieldType
        switch field.fieldType {
        case .string: fieldType = .string
        case .concealedString: fieldType = .concealedString
        case .email: fieldType = .email
        default: throw CredentialVaultError.invalidData
        }
        let metadata = CredentialEditableFieldMetadata(id: field.id, label: field.label, fieldType: fieldType)
        try metadata.validate()
        return (field.value, metadata)
    }

    private static func addScope(_ scope: ASImportableCredentialScope?, to budget: inout PayloadBudget) throws {
        guard let scope else { return }
        guard scope.urls.count <= 64, scope.androidApps.isEmpty else { throw CredentialVaultError.invalidData }
        for url in scope.urls { try budget.add(url.absoluteString) }
    }

    private static func applyScope(_ scope: ASImportableCredentialScope?, to account: inout CredentialAccount) throws {
        guard let scope else { return }
        var origins = Set<String>()
        var loginURLs = Set<URL>()
        for url in scope.urls {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil else {
                throw CredentialVaultError.invalidData
            }
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard let origin = CredentialAccount.origin(for: sanitized) else { throw CredentialVaultError.invalidData }
            origins.insert(origin)
            loginURLs.insert(sanitized)
        }
        account.origins = origins.sorted()
        account.loginURLs = loginURLs.sorted { $0.absoluteString < $1.absoluteString }
    }

    private static func importFIDO2Metadata(
        _ passkey: ASImportableCredential.Passkey,
        budget: inout PayloadBudget
    ) throws -> Data? {
        if #available(macOS 26.4, *) {
            guard let metadata = passkey.fido2Extensions else { return nil }
            if let hmac = metadata.hmacCredentials {
                try budget.add(hmac.credentialWithUV)
                try budget.add(hmac.credentialWithoutUV)
            }
            if let largeBlob = metadata.largeBlob {
                try budget.add(largeBlob.data)
            }
            return try JSONEncoder().encode(metadata)
        }
        return nil
    }

    private static func makeConflicts(
        _ candidates: [CredentialAccount],
        against existing: [CredentialAccount]
    ) throws -> [CredentialImportConflict] {
        var existingByExternalID: [ExternalItemID: CredentialAccount] = [:]
        for account in existing {
            let key = try externalItemID(for: account)
            guard existingByExternalID.updateValue(account, forKey: key) == nil else {
                throw CredentialVaultError.duplicateIdentifier
            }
        }

        var conflicts: [CredentialImportConflict] = []
        for candidate in candidates {
            let linked = existingByExternalID[try externalItemID(for: candidate)]
            if let linked {
                if hasBasicAuthentication(candidate), hasBasicAuthentication(linked) {
                    conflicts.append(.init(
                        incoming: .password(accountID: candidate.id),
                        existing: .password(accountID: linked.id)
                    ))
                }
                if candidate.totp != nil, linked.totp != nil {
                    conflicts.append(.init(
                        incoming: .totp(accountID: candidate.id),
                        existing: .totp(accountID: linked.id)
                    ))
                }
            }
            for passkey in candidate.passkeys {
                let matches = existing.flatMap { account in
                    account.passkeys.filter {
                        $0.credentialID == passkey.credentialID && $0.rpID == passkey.rpID
                    }.map { (account, $0) }
                }
                guard matches.count <= 1 else { throw CredentialVaultError.duplicateIdentifier }
                if let (account, existingPasskey) = matches.first {
                    conflicts.append(.init(
                        incoming: .passkey(accountID: candidate.id, passkeyID: passkey.id),
                        existing: .passkey(accountID: account.id, passkeyID: existingPasskey.id)
                    ))
                }
            }
        }
        return conflicts
    }

    private static func identities(in account: CredentialAccount) -> [CredentialIdentity] {
        var result: [CredentialIdentity] = []
        if hasBasicAuthentication(account) { result.append(.password(accountID: account.id)) }
        result += account.passkeys.map { .passkey(accountID: account.id, passkeyID: $0.id) }
        if account.totp != nil { result.append(.totp(accountID: account.id)) }
        return result
    }

    private static func hasBasicAuthentication(_ account: CredentialAccount) -> Bool {
        account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
    }

    private static func emptyLike(_ account: CredentialAccount) -> CredentialAccount {
        CredentialAccount(
            id: account.id,
            username: "",
            displayName: account.displayName,
            origins: account.origins,
            loginURLs: account.loginURLs,
            password: nil,
            passkeys: [],
            totp: nil,
            exchangeAccountID: account.exchangeAccountID,
            exchangeItemID: account.exchangeItemID,
            exchangeMetadata: account.exchangeMetadata,
            basicAuthenticationMetadata: nil
        )
    }

    private static func isSameItem(_ source: CredentialAccount, _ target: CredentialAccount) -> Bool {
        guard let lhs = try? externalItemID(for: source), let rhs = try? externalItemID(for: target) else { return false }
        return lhs == rhs
    }

    /// The stored account that already holds `candidate`'s exporter item, which is where its credentials go unless
    /// the user decides otherwise. `nil` when the item is new here.
    static func linkedAccountID(for candidate: CredentialAccount, in accounts: [CredentialAccount]) -> UUID? {
        accounts.first { isSameItem(candidate, $0) }?.id
    }

    /// A credential can be merged into `target` when nothing of the exporter's item would be lost: the item
    /// is the same one (its metadata is refreshed), or `target` is a plain account with no exchange identity
    /// of its own and no different name, which then takes the item's name and metadata. Another imported item,
    /// or an account the user has named differently, is refused rather than silently overwritten.
    static func canMerge(_ source: CredentialAccount, into target: CredentialAccount) -> Bool {
        if isSameItem(source, target) { return true }
        if let title = source.displayName, !title.isEmpty,
           let existing = target.displayName, !existing.isEmpty, existing != title { return false }
        guard source.exchangeMetadata != nil else { return true }
        return target.exchangeMetadata == nil && target.exchangeAccountID == nil && target.exchangeItemID == nil
    }

    /// Gives `account` fresh exporter identifiers and a copy of the item's metadata remapped to them.
    private static func fork(_ account: inout CredentialAccount, from source: CredentialAccount, candidateID: ExternalItemID) throws {
        let newAccountID = try externalID(nil, fallback: UUID())
        let newItemID = try externalID(nil, fallback: UUID())
        account.exchangeAccountID = newAccountID
        account.exchangeItemID = newItemID
        account.exchangeMetadata = try forkMetadata(
            source.exchangeMetadata,
            from: candidateID,
            to: ExternalItemID(account: newAccountID, item: newItemID)
        )
    }

    /// Brings the imported item's name and metadata into `target`, once per target. The first destination of an
    /// item takes its identifiers; a later one takes a fork, so no two accounts ever claim the same item.
    private static func carry(
        _ source: CredentialAccount,
        id: ExternalItemID,
        into target: inout CredentialAccount,
        claimed: inout Bool,
        carried: inout Set<UUID>
    ) throws {
        guard carried.insert(target.id).inserted else { return }
        if isSameItem(source, target) {
            if source.exchangeMetadata != nil { target.exchangeMetadata = source.exchangeMetadata }
            claimed = true
            return
        }
        guard canMerge(source, into: target) else { throw CredentialVaultError.invalidData }
        if target.displayName?.isEmpty ?? true, let title = source.displayName, !title.isEmpty {
            target.displayName = title
        }
        guard source.exchangeMetadata != nil else { return }
        if claimed {
            try fork(&target, from: source, candidateID: id)
        } else {
            target.exchangeAccountID = source.exchangeAccountID
            target.exchangeItemID = source.exchangeItemID
            target.exchangeMetadata = source.exchangeMetadata
            claimed = true
        }
    }

    private static func merge(_ identity: CredentialIdentity, from source: CredentialAccount, into target: inout CredentialAccount) throws {
        switch identity {
        case .password:
            guard !hasBasicAuthentication(target) else { throw CredentialVaultError.invalidData }
            copyBasicAuthentication(from: source, to: &target)
        case let .passkey(_, passkeyID):
            guard let value = source.passkeys.first(where: { $0.id == passkeyID }),
                  !target.passkeys.contains(where: {
                      $0.credentialID == value.credentialID && $0.rpID == value.rpID
                  }) else {
                throw CredentialVaultError.duplicateIdentifier
            }
            target.passkeys.append(value)
        case .totp:
            guard target.totp == nil else { throw CredentialVaultError.invalidData }
            target.totp = source.totp
        }
    }

    private static func replace(
        _ incoming: CredentialIdentity,
        from source: CredentialAccount,
        target: CredentialIdentity,
        in accounts: inout [CredentialAccount]
    ) throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountID(for: target) }) else {
            throw CredentialVaultError.invalidData
        }
        // The same exporter item is being refreshed, so its newer metadata comes with the credential.
        if source.exchangeMetadata != nil,
           let lhs = try? externalItemID(for: source), let rhs = try? externalItemID(for: accounts[index]), lhs == rhs {
            accounts[index].exchangeMetadata = source.exchangeMetadata
        }
        switch (incoming, target) {
        case (.password, .password):
            copyBasicAuthentication(from: source, to: &accounts[index])
        case let (.passkey(_, incomingID), .passkey(_, targetID)):
            guard let sourcePasskey = source.passkeys.first(where: { $0.id == incomingID }),
                  let targetIndex = accounts[index].passkeys.firstIndex(where: { $0.id == targetID }) else {
                throw CredentialVaultError.invalidData
            }
            var replacement = sourcePasskey
            replacement.id = targetID
            accounts[index].passkeys[targetIndex] = replacement
        case (.totp, .totp):
            accounts[index].totp = source.totp
        default:
            throw CredentialVaultError.invalidData
        }
    }

    private static func add(_ identity: CredentialIdentity, from source: CredentialAccount, to target: inout CredentialAccount) throws {
        switch identity {
        case .password:
            copyBasicAuthentication(from: source, to: &target)
        case let .passkey(_, passkeyID):
            guard let value = source.passkeys.first(where: { $0.id == passkeyID }) else { throw CredentialVaultError.invalidData }
            target.passkeys.append(value)
        case .totp:
            target.totp = source.totp
        }
    }

    private static func copyBasicAuthentication(from source: CredentialAccount, to target: inout CredentialAccount) {
        target.username = source.username
        target.password = source.password
        target.basicAuthenticationMetadata = source.basicAuthenticationMetadata
    }

    private static func accountID(for identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(accountID), let .totp(accountID): accountID
        case let .passkey(accountID, _): accountID
        }
    }

    private static func exportBasicAuthentication(_ account: CredentialAccount) -> ASImportableCredential.BasicAuthentication? {
        let username: ASImportableEditableField?
        let password: ASImportableEditableField?
        if let metadata = account.basicAuthenticationMetadata {
            username = metadata.username.map { makeField(account.username, metadata: $0) } ??
                (account.username.isEmpty ? nil : ASImportableEditableField(id: nil, fieldType: .string, value: account.username))
            if let value = account.password, let field = metadata.password {
                password = makeField(value, metadata: field)
            } else {
                password = nil
            }
        } else {
            username = account.username.isEmpty ? nil : ASImportableEditableField(id: nil, fieldType: .string, value: account.username)
            password = account.password.map { ASImportableEditableField(id: nil, fieldType: .concealedString, value: $0) }
        }
        guard username != nil || password != nil else { return nil }
        return ASImportableCredential.BasicAuthentication(userName: username, password: password)
    }

    private static func makeField(_ value: String, metadata: CredentialEditableFieldMetadata) -> ASImportableEditableField {
        let fieldType: ASImportableEditableField.FieldType
        switch metadata.fieldType {
        case .string: fieldType = .string
        case .concealedString: fieldType = .concealedString
        case .email: fieldType = .email
        }
        return ASImportableEditableField(id: metadata.id, fieldType: fieldType, value: value, label: metadata.label)
    }

    private static func exportPasskey(_ passkey: WebsitePasskey) throws -> ASImportableCredential.Passkey {
        try passkey.validate()
        if let metadata = passkey.exchangeFIDO2Metadata {
            guard #available(macOS 26.4, *) else { throw CredentialVaultError.invalidData }
            let fido2 = try JSONDecoder().decode(ASImportableFIDO2Extensions.self, from: metadata)
            return ASImportableCredential.Passkey(
                credentialID: passkey.credentialID,
                relyingPartyIdentifier: passkey.rpID,
                userName: passkey.userName,
                userDisplayName: passkey.userDisplayName,
                userHandle: passkey.userHandle,
                key: passkey.privateKeyPKCS8,
                fido2Extensions: fido2
            )
        }
        return ASImportableCredential.Passkey(
            credentialID: passkey.credentialID,
            relyingPartyIdentifier: passkey.rpID,
            userName: passkey.userName,
            userDisplayName: passkey.userDisplayName,
            userHandle: passkey.userHandle,
            key: passkey.privateKeyPKCS8
        )
    }
    private static func makeItem(
        id: Data,
        created: Date?,
        lastModified: Date?,
        title: String,
        scope: ASImportableCredentialScope?,
        credentials: [ASImportableCredential],
        tags: [String]
    ) -> ASImportableItem {
        // The macOS 26.0 initializer requires dates although the properties are optional; restore the source
        // values before returning so absent dates are never exported as invented timestamps.
        var item = ASImportableItem(
            id: id,
            created: created ?? .distantPast,
            lastModified: lastModified ?? .distantPast,
            title: title,
            scope: scope,
            credentials: credentials,
            tags: tags
        )
        item.created = created
        item.lastModified = lastModified
        return item
    }

    private static func exportURLs(_ account: CredentialAccount) throws -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        var representedOrigins = Set<String>()
        for url in account.loginURLs {
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard let origin = CredentialAccount.origin(for: sanitized), account.origins.contains(origin) else {
                throw CredentialVaultError.invalidData
            }
            representedOrigins.insert(origin)
            if seen.insert(sanitized.absoluteString).inserted { result.append(sanitized) }
        }
        for origin in account.origins where !representedOrigins.contains(origin) {
            guard let url = URL(string: origin) else { throw CredentialVaultError.invalidData }
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard CredentialAccount.origin(for: sanitized) == origin else { throw CredentialVaultError.invalidData }
            if seen.insert(sanitized.absoluteString).inserted { result.append(sanitized) }
        }
        guard result.count <= 64 else { throw CredentialVaultError.oversized }
        return result
    }

    private static func externalItemID(for account: CredentialAccount) throws -> ExternalItemID {
        ExternalItemID(
            account: try externalID(account.exchangeAccountID, fallback: account.id),
            item: try externalID(account.exchangeItemID, fallback: account.id)
        )
    }
    private static func externalID(_ stored: Data?, fallback: UUID) throws -> Data {
        if let stored {
            guard !stored.isEmpty else { throw CredentialVaultError.invalidData }
            return stored
        }
        return withUnsafeBytes(of: fallback.uuid) { Data($0) }
    }

    private static func validateAccounts(_ accounts: [CredentialAccount]) throws {
        guard accounts.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
        guard Set(accounts.map({ $0.id })).count == accounts.count else { throw CredentialVaultError.duplicateIdentifier }
        for account in accounts { try account.validate() }
        // Two accounts claiming one exporter item would make every later import and export ambiguous.
        guard try Set(accounts.map(externalItemID(for:))).count == accounts.count else { throw CredentialVaultError.duplicateIdentifier }
        guard try encodedSize(accounts) <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.oversized }
    }

    private static func encodedSize<T: Encodable>(_ value: T) throws -> Int {
        try JSONEncoder().encode(value).count
    }
}
