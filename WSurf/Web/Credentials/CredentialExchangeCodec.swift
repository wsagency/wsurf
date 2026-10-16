// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

nonisolated enum CredentialIdentity: Hashable, Sendable {
    case password(accountID: UUID)
    case passkey(accountID: UUID, passkeyID: UUID)
    case totp(accountID: UUID)
    case note(accountID: UUID)
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
    let base: StoreSnapshot
    let candidates: [CredentialAccount]
    let conflicts: [CredentialImportConflict]
    /// What the transfer held that WSurf did not keep. It never refuses a transfer.
    var omitted: [CredentialImportOmission] = []

    var revision: UInt64 {
        base.revision
    }
}

nonisolated struct CredentialExportSelection: Sendable {
    var accountID: UUID
    var password: Bool
    var passkeyIDs: Set<UUID>
    var totp: Bool
    var notes = false
}

nonisolated struct CredentialExchangeError: Error, LocalizedError, CustomStringConvertible, Sendable, Equatable {
    enum Reason: String, Equatable, Sendable {
        case invalidData
        case duplicateIdentifier
        case oversized
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

    /// The kind of credential an error was raised on: the SDK case name only, never a value. It lets an unsupported or
    /// invalid record be told apart when its index alone cannot.
    enum CredentialKind: String, Equatable, Sendable {
        case address, apiKey, basicAuthentication, creditCard, customFields, driversLicense, generatedPassword
        case identityDocument, itemReference, note, passkey, passport, personName, sshKey, totp, wifi, unknown

        init(_ credential: ASImportableCredential) {
            switch credential {
            case .address:
                self = .address
            case .apiKey:
                self = .apiKey
            case .basicAuthentication:
                self = .basicAuthentication
            case .creditCard:
                self = .creditCard
            case .customFields:
                self = .customFields
            case .driversLicense:
                self = .driversLicense
            case .generatedPassword:
                self = .generatedPassword
            case .identityDocument:
                self = .identityDocument
            case .itemReference:
                self = .itemReference
            case .note:
                self = .note
            case .passkey:
                self = .passkey
            case .passport:
                self = .passport
            case .personName:
                self = .personName
            case .sshKey:
                self = .sshKey
            case .totp:
                self = .totp
            case .wifi:
                self = .wifi
            @unknown default:
                self = .unknown
            }
        }
    }

    let record: Record
    let reason: Reason
    /// Set only when `record` is a credential.
    var credentialKind: CredentialKind?

    var description: String {
        credentialKind.map { "\(reason.rawValue) at \(record.description) (\($0.rawValue))" }
            ?? "\(reason.rawValue) at \(record.description)"
    }
    var errorDescription: String? {
        description
    }

    init(record: Record, underlying: any Error) {
        self.record = record
        switch underlying {
        case CredentialVaultError.duplicateIdentifier:
            reason = .duplicateIdentifier
        case CredentialVaultError.oversized:
            reason = .oversized
        default:
            reason = .invalidData
        }
    }

    init(record: Record, reason: Reason) {
        self.record = record
        self.reason = reason
    }
}

nonisolated enum CredentialExchangeCodec {
    struct ExternalItemID: Hashable {
        let account: Data
        let item: Data
    }
    private struct ExternalPasskeyID: Hashable {
        let relyingPartyID: String
        let credentialID: Data
    }
    struct ExchangeLink: Codable {
        var item: Data
        var account: Data?
    }
    struct ExchangeCollection: Codable {
        var id: Data
        var created: Date?
        var lastModified: Date?
        var title: String
        var subtitle: String?
        var items: [ExchangeLink]
        var subcollections: [ExchangeCollection]
    }
    struct ExchangeMetadata: Codable {
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

        mutating func add(_ value: String) throws {
            try add(value.utf8.count)
        }

        mutating func add(_ value: Data) throws {
            try add(value.count)
        }
    }

    /// The running state of one `preview` call. `record` names where an error is raised from.
    private struct ImportState {
        var budget = PayloadBudget()
        var metadataBudget = PayloadBudget()
        var seenAccountIDs = Set<Data>()
        var seenItemIDs = Set<ExternalItemID>()
        var seenPasskeyIDs = Set<ExternalPasskeyID>()
        var totalCredentials = 0
        var totalCollections = 0
        var candidates: [CredentialAccount] = []
        var omitted: [CredentialImportOmission] = []
        var itemTitle = ""
        var record = CredentialExchangeError.Record.exporter
        var credentialKind: CredentialExchangeError.CredentialKind?
    }

    static func preview(_ data: ASExportedCredentialData, against base: StoreSnapshot) throws -> CredentialImportPreview {
        guard data.formatVersion == .v1 else { throw CredentialVaultError.invalidData }
        try validateAccounts(base.accounts)
        guard base.accounts.count <= CredentialVaultLimits.accounts,
              data.accounts.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }

        var state = ImportState()
        do {
            try state.budget.add(data.exporterRelyingPartyIdentifier)
            try state.budget.add(data.exporterDisplayName)
            for (accountIndex, appleAccount) in data.accounts.enumerated() {
                try importAccount(appleAccount, index: accountIndex, state: &state)
            }

            state.record = .payload
            try validateAccounts(state.candidates)
            guard try encodedSize(state.candidates) <= CredentialVaultLimits.payloadBytes else {
                throw CredentialVaultError.oversized
            }
            let conflicts = try makeConflicts(state.candidates, against: base.accounts)
            return CredentialImportPreview(base: base, candidates: state.candidates, conflicts: conflicts, omitted: state.omitted)
        } catch {
            var failure = error as? CredentialExchangeError ?? CredentialExchangeError(record: state.record, underlying: error)
            if case .credential = failure.record {
                failure.credentialKind = state.credentialKind
            }
            throw failure
        }
    }

    private static func importAccount(
        _ appleAccount: ASImportableAccount,
        index accountIndex: Int,
        state: inout ImportState
    ) throws {
        state.record = .account(index: accountIndex)
        guard !appleAccount.id.isEmpty, state.seenAccountIDs.insert(appleAccount.id).inserted else {
            throw CredentialVaultError.duplicateIdentifier
        }
        try state.budget.add(appleAccount.id)
        try state.budget.add(appleAccount.userName)
        try state.budget.add(appleAccount.email)
        try state.budget.add(appleAccount.fullName ?? "")
        var collections: [ExchangeCollection] = []
        collections.reserveCapacity(min(appleAccount.collections.count, CredentialVaultLimits.accounts - state.totalCollections))
        for (collectionIndex, collection) in appleAccount.collections.enumerated() {
            state.record = .collection(account: accountIndex, path: [collectionIndex])
            collections.append(try importCollection(
                collection,
                budget: &state.budget,
                count: &state.totalCollections,
                depth: 0
            ))
        }

        for (itemIndex, item) in appleAccount.items.enumerated() {
            try importItem(
                item,
                from: appleAccount,
                at: (account: accountIndex, item: itemIndex),
                collections: collections,
                state: &state
            )
        }
    }

    /// What `importCredential` raises for a part WSurf cannot keep: the item stays, the part is named in `omitted`.
    private struct Skip: Error {
        let reason: CredentialImportOmission.Reason
    }

    /// Names a part of the transfer that was not kept, where `state` currently is.
    private static func omit(_ reason: CredentialImportOmission.Reason, _ state: inout ImportState) {
        state.omitted.append(CredentialImportOmission(
            record: state.record, title: state.itemTitle, kind: state.credentialKind, reason: reason
        ))
    }

    /// Whether `account` holds anything WSurf can keep: a login, a passkey, a code or a note.
    private static func hasContent(_ account: CredentialAccount) -> Bool {
        !account.username.isEmpty || account.password != nil || !account.passkeys.isEmpty || account.totp != nil || account.notes != nil
    }

    private static func importItem(
        _ item: ASImportableItem,
        from appleAccount: ASImportableAccount,
        at position: (account: Int, item: Int),
        collections: [ExchangeCollection],
        state: inout ImportState
    ) throws {
        state.record = .item(account: position.account, item: position.item)
        state.itemTitle = item.title
        let itemIdentity = ExternalItemID(account: appleAccount.id, item: item.id)
        guard state.candidates.count < CredentialVaultLimits.accounts,
              !item.id.isEmpty, state.seenItemIDs.insert(itemIdentity).inserted else { throw CredentialVaultError.invalidData }
        try state.budget.add(item.id)
        try state.budget.add(item.title)
        try state.budget.add(item.subtitle ?? "")
        for tag in item.tags {
            try state.budget.add(tag)
        }
        if #available(macOS 26.4, *), !item.extensions.isEmpty {
            omit(.sharingNotKept, &state)
        }
        guard item.credentials.count <= CredentialVaultLimits.accounts - state.totalCredentials else {
            throw CredentialVaultError.oversized
        }
        state.totalCredentials += item.credentials.count

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
        try state.metadataBudget.add(candidate.exchangeMetadata?.count ?? 0)
        try importScope(item.scope, into: &candidate, state: &state)

        for (credentialIndex, credential) in item.credentials.enumerated() {
            state.record = .credential(account: position.account, item: position.item, credential: credentialIndex)
            state.credentialKind = CredentialExchangeError.CredentialKind(credential)
            do {
                try importCredential(credential, into: &candidate, state: &state)
            } catch let skip as Skip {
                omit(skip.reason, &state)
            }
        }
        state.credentialKind = nil
        state.record = .item(account: position.account, item: position.item)
        guard hasContent(candidate) else {
            omit(.nothingToKeep, &state)
            return
        }
        try candidate.validate()
        state.candidates.append(candidate)
    }

    /// A part of an item is skipped, never the transfer, when WSurf has no place for it or cannot keep it as sent. The checks that
    /// guard the vault (duplicate identifiers, a login id used twice, size budgets) still refuse the whole transfer.
    private static func importCredential(
        _ credential: ASImportableCredential,
        into candidate: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        switch credential {
        case let .basicAuthentication(value):
            try importBasicAuthentication(value, into: &candidate, state: &state)
        case let .passkey(value):
            try importPasskey(value, into: &candidate, state: &state)
        case let .totp(value):
            try importTOTP(value, into: &candidate, state: &state)
        case let .note(value):
            try importNote(value, into: &candidate, state: &state)
        default:
            // Addresses, cards, keys, Wi-Fi and every kind added later: named in the review, not stored yet.
            throw Skip(reason: .unsupportedKind)
        }
    }

    private static func importBasicAuthentication(
        _ value: ASImportableCredential.BasicAuthentication,
        into candidate: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        guard candidate.basicAuthenticationMetadata == nil else { throw Skip(reason: .extraLogin) }
        let username = try value.userName.map { try importField($0, state: &state) }
        let password = try value.password.map { try importField($0, state: &state) }
        guard username != nil || password != nil else { throw Skip(reason: .emptyLogin) }
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
    }

    private static func importPasskey(
        _ value: ASImportableCredential.Passkey,
        into candidate: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        let passkeyID = ExternalPasskeyID(
            relyingPartyID: value.relyingPartyIdentifier.lowercased(),
            credentialID: value.credentialID
        )
        guard !state.seenPasskeyIDs.contains(passkeyID) else { throw CredentialVaultError.duplicateIdentifier }
        try state.budget.add(value.credentialID)
        try state.budget.add(value.relyingPartyIdentifier)
        try state.budget.add(value.userName)
        try state.budget.add(value.userDisplayName)
        try state.budget.add(value.userHandle)
        guard value.key.count <= PasskeyKeyEncoding.maximumDERBytes else { throw CredentialVaultError.oversized }
        try state.budget.add(value.key)
        // A key that is not ES256, cannot be read, or belongs to a website the vault will not serve cannot be kept.
        guard let key = try? PasskeyKeyEncoding.importPKCS8(value.key),
              let privateKey = try? PasskeyKeyEncoding.exportPKCS8(key) else { throw Skip(reason: .passkeyNotKept) }
        let passkey = WebsitePasskey(
            id: UUID(),
            credentialID: value.credentialID,
            rpID: value.relyingPartyIdentifier.lowercased(),
            userHandle: value.userHandle,
            userName: value.userName,
            userDisplayName: value.userDisplayName,
            algorithm: -7,
            privateKeyPKCS8: privateKey,
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: try importFIDO2Metadata(value, budget: &state.budget),
            source: .imported
        )
        guard (try? passkey.validate()) != nil,
              let origin = URL(string: "https://\(passkey.rpID)"),
              (try? RelyingPartyPolicy.validate(rpID: passkey.rpID, origin: origin)) == passkey.rpID else {
            throw Skip(reason: .passkeyNotKept)
        }
        guard !candidate.passkeys.contains(where: {
            $0.credentialID == passkey.credentialID && $0.rpID == passkey.rpID
        }) else {
            throw CredentialVaultError.duplicateIdentifier
        }
        state.seenPasskeyIDs.insert(passkeyID)
        candidate.passkeys.append(passkey)
    }

    private static func importTOTP(
        _ value: ASImportableCredential.TOTP,
        into candidate: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        guard candidate.totp == nil else { throw Skip(reason: .extraCode) }
        try state.budget.add(value.secret)
        try state.budget.add(value.issuer ?? "")
        try state.budget.add(value.userName ?? "")
        guard let algorithm = TOTPAlgorithm(rawValue: value.algorithm.rawValue) else { throw Skip(reason: .codeNotKept) }
        let generator = TOTPGenerator(
            secret: value.secret,
            algorithm: algorithm,
            period: value.period,
            digits: value.digits,
            issuer: value.issuer,
            userName: value.userName
        )
        guard (try? generator.validate()) != nil else { throw Skip(reason: .codeNotKept) }
        candidate.totp = generator
    }

    /// Notes are kept in the order the exporter sent them. An empty one holds nothing to keep. A plain field (no id, no label,
    /// ordinary text) is the default, so it is stored as none: the same text typed in WSurf then compares equal.
    private static func importNote(
        _ value: ASImportableCredential.Note,
        into candidate: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        let field = try importField(value.content, state: &state)
        guard !field.value.isEmpty else { return }
        var notes = candidate.notes ?? []
        guard notes.count < CredentialAccount.noteLimit else { throw CredentialVaultError.oversized }
        let isPlain = field.metadata.id == nil && field.metadata.label == nil && field.metadata.fieldType == .string
        notes.append(CredentialNote(text: field.value, field: isPlain ? nil : field.metadata))
        candidate.notes = notes
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

    /// A field of a type WSurf has no use for (a number, a date, ...) is kept as plain text, and one whose id or label is over the
    /// limit keeps its value without that description. Either way the field is named, since it will export as it is kept.
    private static func importField(
        _ field: ASImportableEditableField,
        state: inout ImportState
    ) throws -> (value: String, metadata: CredentialEditableFieldMetadata) {
        try state.budget.add(field.value)
        try state.budget.add(field.id ?? Data())
        try state.budget.add(field.label ?? "")
        var simplified = false
        let fieldType: CredentialEditableFieldType
        switch field.fieldType {
        case .string:
            fieldType = .string
        case .concealedString:
            fieldType = .concealedString
        case .email:
            fieldType = .email
        default:
            fieldType = .string
            simplified = true
        }
        var metadata = CredentialEditableFieldMetadata(id: field.id, label: field.label, fieldType: fieldType)
        if (try? metadata.validate()) == nil {
            metadata.id = nil
            metadata.label = nil
            simplified = true
        }
        if simplified {
            omit(.fieldDetailsSimplified, &state)
        }
        return (field.value, metadata)
    }

    /// The websites WSurf can keep: HTTPS addresses, stored without a user, query or fragment. Anything else is dropped from the
    /// item's websites and named; the item itself stays.
    private static func importScope(
        _ scope: ASImportableCredentialScope?,
        into account: inout CredentialAccount,
        state: inout ImportState
    ) throws {
        guard let scope else { return }
        guard scope.urls.count <= 64 else { throw CredentialVaultError.oversized }
        var origins = Set<String>()
        var loginURLs = Set<URL>()
        var dropped = false
        for url in scope.urls {
            try state.budget.add(url.absoluteString)
            guard let sanitized = try? CredentialAccount.sanitizedLoginURL(url),
                  let origin = CredentialAccount.origin(for: sanitized) else {
                dropped = true
                continue
            }
            origins.insert(origin)
            loginURLs.insert(sanitized)
        }
        if dropped {
            omit(.websitesNotKept, &state)
        }
        if !scope.androidApps.isEmpty {
            omit(.androidAppsNotKept, &state)
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
                // Identical notes need no decision: merging them adds nothing.
                if candidate.notes != nil, linked.notes != nil,
                   try CredentialContent.hash(.note(candidate)) != CredentialContent.hash(.note(linked)) {
                    conflicts.append(.init(
                        incoming: .note(accountID: candidate.id),
                        existing: .note(accountID: linked.id)
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

    static func identities(in account: CredentialAccount) -> [CredentialIdentity] {
        var result: [CredentialIdentity] = []
        if hasBasicAuthentication(account) {
            result.append(.password(accountID: account.id))
        }
        result += account.passkeys.map { .passkey(accountID: account.id, passkeyID: $0.id) }
        if account.totp != nil {
            result.append(.totp(accountID: account.id))
        }
        if account.notes != nil {
            result.append(.note(accountID: account.id))
        }
        return result
    }

    /// The identity a note follows when nobody decided it: the item's login, else its first passkey, else its code.
    static func leadIdentity(of account: CredentialAccount) -> CredentialIdentity? {
        identities(in: account).first {
            if case .note = $0 {
                return false
            }
            return true
        }
    }

    static func hasBasicAuthentication(_ account: CredentialAccount) -> Bool {
        account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
    }

    static func externalItemID(for account: CredentialAccount) throws -> ExternalItemID {
        ExternalItemID(
            account: try externalID(account.exchangeAccountID, fallback: account.id),
            item: try externalID(account.exchangeItemID, fallback: account.id)
        )
    }

    static func externalID(_ stored: Data?, fallback: UUID) throws -> Data {
        if let stored {
            guard !stored.isEmpty else { throw CredentialVaultError.invalidData }
            return stored
        }
        return withUnsafeBytes(of: fallback.uuid) { Data($0) }
    }

    static func validateAccounts(_ accounts: [CredentialAccount]) throws {
        guard accounts.count <= CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
        guard Set(accounts.map({ $0.id })).count == accounts.count else { throw CredentialVaultError.duplicateIdentifier }
        for account in accounts {
            try account.validate()
        }
        // Two accounts claiming one exporter item would make every later import and export ambiguous.
        guard try Set(accounts.map(externalItemID(for:))).count == accounts.count else { throw CredentialVaultError.duplicateIdentifier }
        guard try encodedSize(accounts) <= CredentialVaultLimits.payloadBytes else { throw CredentialVaultError.oversized }
    }

    static func encodedSize<T: Encodable>(_ value: T) throws -> Int {
        try JSONEncoder().encode(value).count
    }
}
