// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

nonisolated extension CredentialExchangeCodec {
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
        for account in snapshot.accounts {
            accountByID[account.id] = account
        }
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
        case .string:
            fieldType = .string
        case .concealedString:
            fieldType = .concealedString
        case .email:
            fieldType = .email
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
            if seen.insert(sanitized.absoluteString).inserted {
                result.append(sanitized)
            }
        }
        for origin in account.origins where !representedOrigins.contains(origin) {
            guard let url = URL(string: origin) else { throw CredentialVaultError.invalidData }
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard CredentialAccount.origin(for: sanitized) == origin else { throw CredentialVaultError.invalidData }
            if seen.insert(sanitized.absoluteString).inserted {
                result.append(sanitized)
            }
        }
        guard result.count <= 64 else { throw CredentialVaultError.oversized }
        return result
    }
}
