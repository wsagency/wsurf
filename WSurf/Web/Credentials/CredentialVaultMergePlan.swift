// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Review and apply current native entries. Only the display-safe rows outlive the unlocked snapshots used to compare them.
nonisolated enum CredentialVaultMergePlan {
    enum Kind: Hashable, Sendable { case new, duplicate, conflict }
    enum Choice: Hashable, Sendable { case copy, skip, replace }

    struct Row: Identifiable, Sendable, Equatable {
        let id: UUID
        let title: String
        let matches: [String]
        let kind: Kind
        let choices: [Choice]
        let differences: [String]
        let reason: String?
        let targetID: UUID?
    }

    /// A vault stores one holder of each of these, including the identifiers carried forward by a prior merge.
    private enum Claim: Hashable {
        case account(UUID), exporter(CredentialExchangeCodec.ExternalItemID), passkey(UUID), credential(Data)

        static func all(in account: CredentialAccount) throws -> Set<Claim> {
            var claims: Set<Claim> = [.account(account.id), .exporter(try CredentialExchangeCodec.externalItemID(for: account))]
            for link in account.mergedFrom ?? [] {
                claims.insert(.account(link.accountID))
                claims.insert(.exporter(link.identity))
            }
            for key in account.passkeys {
                claims.insert(.passkey(key.id))
                claims.insert(.credential(key.credentialID))
            }
            return claims
        }
    }

    private struct Login: Hashable {
        let site: String
        let username: Data
    }

    /// Authenticated file names, types and sizes narrow the lookup. Equality additionally checks each plaintext digest.
    private struct FileLabel: Hashable {
        let name: Data
        let type: Data
        let size: Int64

        init(_ file: CredentialAttachment) {
            name = Data(file.name.utf8)
            type = Data(file.contentType.utf8)
            size = file.size
        }
    }

    private struct Content: Hashable {
        let login: Data
        let code: Data?
        let notes: Data?
        let items: Data?
        let metadata: Data
        let opaqueExchange: Data?
        let keys: [Data]
        let files: [FileLabel]

        init(_ account: CredentialAccount) throws {
            login = try CredentialContent.hash(.password(account))
            code = try account.totp.map { _ in try CredentialContent.hash(.totp(account)) }
            notes = try account.notes.map { _ in try CredentialContent.hash(.note(account)) }
            items = try account.secureItems.map { _ in try CredentialContent.hash(.secureItems(account)) }
            // Sync compares semantic metadata. Keep older, unreadable bytes separate so one such entry can still be reviewed and skipped.
            if let semantic = try? CredentialContent.hash(.metadata(account)) {
                metadata = semantic
                opaqueExchange = nil
            } else {
                var plain = account
                plain.exchangeMetadata = nil
                metadata = try CredentialContent.hash(.metadata(plain))
                opaqueExchange = account.exchangeMetadata
            }
            keys = try account.passkeys.map { try CredentialContent.hash(.passkey($0)) }
            files = (account.attachments ?? []).map(FileLabel.init)
        }
    }

    private enum Lookup: Hashable {
        case claim(Claim), login(Login), content(Content), title(String), notes(Data), items(Data), code(Data)
        case card(String), network(Data), issuer(Data, user: Data), fileName(Data)
    }

    private enum Field: CaseIterable {
        case login, password, code, notes, items, metadata, passkeys, files

        var title: String {
            switch self {
            case .login:
                String(localized: "Login")
            case .password:
                String(localized: "Password")
            case .code:
                String(localized: "Verification code")
            case .notes:
                String(localized: "Notes")
            case .items:
                String(localized: "Secure items")
            case .metadata:
                String(localized: "Name, websites or import details")
            case .passkeys:
                String(localized: "Passkeys")
            case .files:
                String(localized: "Files")
            }
        }
    }

    private struct Entry {
        let account: CredentialAccount
        let title: String
        let content: Content
        let claims: Set<Claim>
        let logins: Set<Login>
        let standaloneCard: String?
        let lookups: Set<Lookup>
        let materialByID: [UUID: Data]
        let materialByCredential: [Data: Data]

        init(_ account: CredentialAccount) throws {
            self.account = account
            let display = CredentialSummary(account).title.displaySafe
            title = display.isEmpty ? String(localized: "Credential") : display
            content = try Content(account)
            claims = try Claim.all(in: account)
            let username = Data(account.username.utf8)
            logins = Set(account.origins.compactMap { origin in
                guard !username.isEmpty, let url = URL(string: origin), let host = url.host else { return nil }
                return Login(site: CredentialMergeSuggestions.siteKey(host: host, port: url.port), username: username)
            })
            var lookups = Set(claims.map(Lookup.claim))
            lookups.formUnion(logins.map(Lookup.login))
            lookups.insert(.content(content))
            var standaloneCard: String?
            if !CredentialExchangeCodec.hasBasicAuthentication(account), account.passkeys.isEmpty {
                if let name = account.displayName?.displaySafe, !name.isEmpty {
                    lookups.insert(.title(CredentialSummary.folded(name)))
                }
                if let notes = content.notes {
                    lookups.insert(.notes(notes))
                }
                if let items = content.items {
                    lookups.insert(.items(items))
                }
                if let code = content.code {
                    lookups.insert(.code(code))
                }
                lookups.formUnion(content.files.map { .fileName($0.name) })
                for item in account.secureItems ?? [] {
                    if let card = AutofillCardValues(item) {
                        lookups.insert(.card(card.number))
                        if account.secureItems?.count == 1, account.totp == nil {
                            standaloneCard = card.number
                        }
                    } else if item.kind == .wifi, let ssid = item.value("ssid"), !ssid.isEmpty {
                        // Unrelated networks can broadcast the same SSID. A name alone never authorizes Replace.
                        lookups.insert(.network(Data(ssid.utf8)))
                    }
                }
                if let issuer = account.totp?.issuer, !issuer.isEmpty, let user = account.totp?.userName, !user.isEmpty {
                    lookups.insert(.issuer(Data(issuer.utf8), user: Data(user.utf8)))
                }
            }
            self.standaloneCard = standaloneCard
            self.lookups = lookups
            var byID: [UUID: Data] = [:]
            var byCredential: [Data: Data] = [:]
            for (key, material) in zip(account.passkeys, content.keys) {
                guard byID.updateValue(material, forKey: key.id) == nil,
                      byCredential.updateValue(material, forKey: key.credentialID) == nil else { throw CredentialVaultError.duplicateIdentifier }
            }
            materialByID = byID
            materialByCredential = byCredential
        }

        func differences(from other: Self) -> Set<Field> {
            var fields: Set<Field> = []
            if content.login != other.content.login {
                let passwordChanged = account.password.map { Data($0.utf8) } != other.account.password.map { Data($0.utf8) }
                if passwordChanged {
                    fields.insert(.password)
                }
                // Equalize the secret to compare just the username and its field descriptions, including their exact UTF-8.
                var details = account
                details.password = other.account.password
                if !passwordChanged || (try? CredentialContent.hash(.password(details))) != other.content.login {
                    fields.insert(.login)
                }
            }
            if content.code != other.content.code {
                fields.insert(.code)
            }
            if content.notes != other.content.notes {
                fields.insert(.notes)
            }
            if content.items != other.content.items {
                fields.insert(.items)
            }
            if content.metadata != other.content.metadata || content.opaqueExchange != other.content.opaqueExchange {
                fields.insert(.metadata)
            }
            if content.keys != other.content.keys || !zip(account.passkeys, other.account.passkeys).allSatisfy({ $0.hasSameTransferDetails(as: $1) }) {
                fields.insert(.passkeys)
            }
            if content.files != other.content.files
                || !zip(account.attachments ?? [], other.account.attachments ?? []).allSatisfy({ $0.hasSameFileContents(as: $1) }) {
                fields.insert(.files)
            }
            return fields
        }

        func incompatiblePasskey(with other: Self) -> Bool {
            materialByID.contains { id, material in other.materialByID[id].map { $0 != material } ?? false }
                || materialByCredential.contains { id, material in other.materialByCredential[id].map { $0 != material } ?? false }
        }

        /// Sync preserves existing passkeys on each Mac and appends new identities in incoming order.
        func preservesSharedPasskeyDetails(of saved: Self) -> Bool {
            account.passkeys.starts(with: saved.account.passkeys) { candidate, previous in
                candidate.credentialID == previous.credentialID && candidate.hasSameTransferDetails(as: previous)
            }
        }

        func markedSeparate(from other: Self) -> Bool {
            (account.notSameAs ?? []).contains { other.claims.contains(.account($0)) }
                || (other.account.notSameAs ?? []).contains { claims.contains(.account($0)) }
        }
    }

    private struct Index {
        let entries: [Entry]
        private var distinctLabels: [UUID: String] = [:]
        var positions: [Lookup: [Int]] = [:]

        init(_ accounts: [CredentialAccount]) throws {
            guard Set(accounts.map(\.id)).count == accounts.count else { throw CredentialVaultError.duplicateIdentifier }
            entries = try accounts.map(Entry.init)
            for (position, entry) in entries.enumerated() {
                for lookup in entry.lookups {
                    positions[lookup, default: []].append(position)
                }
            }
            for (title, group) in Dictionary(grouping: entries, by: \.title) where group.count > 1 {
                let ids = group.map { $0.account.id }.sorted { $0.uuidString < $1.uuidString }
                for (index, id) in ids.enumerated() {
                    // The two neighbours in lexical order include the longest shared prefix.
                    let neighbours = ids[max(0, index - 1)...min(ids.count - 1, index + 1)]
                    distinctLabels[id] = "\(title) · \(id.shortestUniquePrefix(in: Array(neighbours)))"
                }
            }
        }

        func label(_ entry: Entry) -> String {
            distinctLabels[entry.account.id] ?? entry.title
        }

        /// Claiming an identity is different from looking alike. These two checks see the entire vault even if a common title has
        /// thousands of matches and only the first few fit in the review.
        func sharedClaims(of entry: Entry) -> Set<Int> {
            Set(entry.claims.flatMap { positions[.claim($0)] ?? [] })
        }

        func duplicate(of entry: Entry, claims: Set<Int>) -> Entry? {
            func identical(at position: Int) -> Bool {
                let saved = entries[position]
                return !entry.markedSeparate(from: saved) && entry.differences(from: saved).isEmpty
            }
            guard claims.allSatisfy(identical), let match = (positions[.content(entry.content)] ?? []).first(where: identical) else { return nil }
            return entries[match]
        }

        /// An oversized group stays an explicit conflict and cannot pick a target.
        func matches(_ entry: Entry, excluding: Int? = nil) -> (entries: [Entry], more: Bool) {
            var found = Set<Int>()
            var more = false
            let limit = CredentialMergeSuggestions.bucketLimit
            for key in entry.lookups {
                guard let positions = positions[key] else { continue }
                for position in positions.prefix(limit + 1) where position != excluding {
                    found.insert(position)
                }
                if positions.count > limit + 1 {
                    more = true
                }
            }
            let ordered = found.sorted()
            return (ordered.prefix(limit).map { entries[$0] }, more || ordered.count > limit)
        }
    }

    static func rows(source: [CredentialAccount], destination: [CredentialAccount]) throws -> [Row] {
        try rows(local: Index(source), shared: Index(destination))
    }

    private static func rows(local: Index, shared: Index) throws -> [Row] {
        let compared = try local.entries.enumerated().map { position, entry in
            let targets = shared.matches(entry)
            let peers = local.matches(entry, excluding: position)
            let differences = targets.entries.map { entry.differences(from: $0) }
            let blocking = shared.sharedClaims(of: entry)
            func row(_ kind: Kind, _ choices: [Choice], fields: Set<Field> = [], reason: String? = nil, target: UUID? = nil, exact: Entry? = nil) -> Row {
                let matches = exact.map { [shared.label($0)] } ?? (
                    targets.entries.map(shared.label) + peers.entries.map { String(localized: "In local vault · \(local.label($0))") }
                )
                return Row(id: entry.account.id, title: entry.title, matches: matches, kind: kind, choices: choices,
                    differences: Field.allCases.filter(fields.contains).map(\.title), reason: reason, targetID: target)
            }
            guard VaultSyncCodec.syncable(transferable(entry.account)) != nil else {
                return row(.conflict, [.skip], reason: String(localized: "This vault can’t take this entry on this Mac."))
            }
            if let exact = shared.duplicate(of: entry, claims: blocking) {
                return row(.duplicate, [.skip], target: exact.account.id, exact: exact)
            }
            if targets.entries.isEmpty && peers.entries.isEmpty {
                return row(.new, [.copy, .skip])
            }
            var fields = differences.reduce(into: Set<Field>()) { $0.formUnion($1) }
            for peer in peers.entries {
                fields.formUnion(entry.differences(from: peer))
            }
            var choices: [Choice] = [.skip]
            if blocking.isEmpty {
                choices.append(.copy)
            }
            if targets.more || targets.entries.count > 1 {
                return row(.conflict, choices, fields: fields, reason: String(localized: "Multiple shared entries match."))
            }
            if let target = targets.entries.first {
                if entry.incompatiblePasskey(with: target) {
                    return row(.conflict, choices, fields: fields, reason: String(localized: "The matching passkeys have different key material."))
                }
                if !target.materialByCredential.allSatisfy({ entry.materialByCredential[$0.key] == $0.value }) {
                    return row(.conflict, choices, fields: fields, reason: String(localized: "Replacing this entry would remove a shared passkey."))
                }
                if !entry.preservesSharedPasskeyDetails(of: target) {
                    return row(.conflict, choices, fields: fields, reason: String(localized: "Sync keeps existing passkey details and adds new passkeys at the end."))
                }
                let identity = try CredentialExchangeCodec.externalItemID(for: entry.account)
                let sameExporter = try identity == CredentialExchangeCodec.externalItemID(for: target.account)
                let knownSource = target.account.mergedFrom?.contains { $0.accountID == entry.account.id || $0.identity == identity } == true
                let identified = entry.account.id == target.account.id || sameExporter || knownSource
                    || !entry.logins.isDisjoint(with: target.logins) || !target.materialByCredential.isEmpty
                    || (entry.standaloneCard != nil && entry.standaloneCard == target.standaloneCard)
                if identified, let proposed = try replacement(of: target, from: entry) {
                    guard VaultSyncCodec.syncable(proposed) != nil else {
                        return row(.conflict, choices, fields: fields, reason: String(localized: "This vault can’t take this entry on this Mac."))
                    }
                    choices.append(.replace)
                    return row(.conflict, choices, fields: fields, target: target.account.id)
                }
                return row(.conflict, choices, fields: fields, reason: String(localized: "The entries could not be safely identified as the same."))
            }
            return row(.conflict, choices, fields: fields, reason: String(localized: "Another entry in the local vault also matches."))
        }
        // Each forced Skip depends on its exact shared copy surviving the batch, regardless of local row order.
        let kept = Set(compared.filter { $0.kind == .duplicate }.compactMap(\.targetID))
        guard !kept.isEmpty else { return compared }
        return compared.map { row in
            guard let id = row.targetID, kept.contains(id), row.choices.contains(.replace) else { return row }
            return Row(id: row.id, title: row.title, matches: row.matches, kind: row.kind, choices: row.choices.filter { $0 != .replace },
                       differences: row.differences, reason: String(localized: "Another local entry is an exact duplicate of this shared entry."), targetID: nil)
        }
    }

    /// Only touched entries, in source order. The caller pins both input revisions through the destination commit.
    static func replacements(rows: [Row], choices: [UUID: Choice], source: [CredentialAccount], destination: [CredentialAccount]) throws -> [CredentialAccount] {
        let local = try Index(source)
        let shared = try Index(destination)
        guard try rows == Self.rows(local: local, shared: shared), choices.keys.allSatisfy(Set(source.map(\.id)).contains)
        else { throw CredentialVaultError.staleRevision }
        let byID = Dictionary(uniqueKeysWithValues: shared.entries.map { ($0.account.id, $0) })
        var writes: [CredentialAccount] = []
        var written = Set<UUID>()
        var byContent: [Content: [Entry]] = [:]
        for (entry, row) in zip(local.entries, rows) {
            let choice = choices[row.id] ?? (row.kind == .new ? .copy : row.kind == .duplicate ? .skip : nil)
            guard let choice, row.choices.contains(choice) else { throw CredentialExchangeCoordinatorError.unresolvedConflicts }
            if choice == .skip {
                continue
            }
            let account = entry.account
            let write: CredentialAccount
            if choice == .replace {
                guard let id = row.targetID, let target = byID[id], let replacement = try replacement(of: target, from: entry)
                else { throw CredentialVaultError.staleRevision }
                write = replacement
            } else {
                guard byID[account.id] == nil else { throw CredentialVaultError.duplicateIdentifier }
                write = transferable(account)
            }
            guard VaultSyncCodec.syncable(write) != nil else { throw CredentialExchangeCoordinatorError.invalidChoice }
            guard written.insert(write.id).inserted else { throw CredentialVaultError.duplicateIdentifier }
            guard !(byContent[entry.content] ?? []).contains(where: { !entry.markedSeparate(from: $0) && entry.differences(from: $0).isEmpty })
            else { throw CredentialVaultError.duplicateIdentifier }
            byContent[entry.content, default: []].append(entry)
            writes.append(write)
        }
        var held = Set<Claim>()
        for account in destination where !written.contains(account.id) {
            held.formUnion(try Claim.all(in: account))
        }
        for write in writes {
            let claims = try Claim.all(in: write)
            guard held.isDisjoint(with: claims) else { throw CredentialVaultError.duplicateIdentifier }
            held.formUnion(claims)
        }
        return writes
    }

    /// Import memory is HMAC-keyed to one vault. Its digests cannot describe a login to a different vault.
    private static func transferable(_ account: CredentialAccount) -> CredentialAccount {
        var copy = account
        copy.importTrace = nil
        copy.mergedFrom = copy.mergedFrom?.map { link in
            var clean = link
            clean.trace = nil
            return clean
        }
        return copy
    }

    private static func replacement(of target: Entry, from entry: Entry) throws -> CredentialAccount? {
        let old = target.account
        let incoming = entry.account
        guard !entry.incompatiblePasskey(with: target), entry.preservesSharedPasskeyDetails(of: target),
              !entry.markedSeparate(from: target)
        else { return nil }
        var copy = transferable(incoming)
        copy.id = old.id
        let incomingIdentity = try CredentialExchangeCodec.externalItemID(for: incoming)
        let savedIdentity = try CredentialExchangeCodec.externalItemID(for: old)
        let incomingWasImported = incoming.exchangeAccountID != nil || incoming.exchangeItemID != nil
        let savedWasImported = old.exchangeAccountID != nil || old.exchangeItemID != nil
        // The destination's exporter binding has to keep working. Distinct source and destination entries can retain both.
        var links = old.mergedFrom ?? []
        if old.id != incoming.id || savedWasImported {
            copy.exchangeAccountID = old.exchangeAccountID
            copy.exchangeItemID = old.exchangeItemID
        }
        let primary = try CredentialExchangeCodec.externalItemID(for: copy)
        var accounts = Set([copy.id])
        var identities = Set([primary])
        for link in links {
            guard accounts.insert(link.accountID).inserted, identities.insert(link.identity).inserted else { return nil }
        }
        var arriving = copy.mergedFrom ?? []
        if incomingIdentity != primary {
            if incoming.id != old.id {
                arriving.insert(MergedItemLink(accountID: incoming.id, exchangeAccountID: incomingIdentity.account, exchangeItemID: incomingIdentity.item,
                                              passwordBase: incoming.passwordBase, totpBase: incoming.totpBase), at: 0)
            } else if incomingWasImported && savedWasImported && incomingIdentity != savedIdentity {
                return nil
            }
        }
        for link in arriving {
            if links.contains(where: { $0.identity == link.identity }) {
                guard !links.contains(where: { $0.accountID == link.accountID && $0.identity != link.identity }) else { return nil }
                continue
            }
            guard accounts.insert(link.accountID).inserted, identities.insert(link.identity).inserted else { return nil }
            links.append(link)
        }
        guard links.count <= CredentialAccount.mergedFromLimit else { return nil }
        copy.mergedFrom = links.isEmpty ? nil : links
        if primary == savedIdentity {
            copy = copy.withBases(of: old)
        }
        let apart = Set((old.notSameAs ?? []) + (incoming.notSameAs ?? []))
        guard apart.count <= CredentialAccount.notSameAsLimit else { return nil }
        copy.notSameAs = apart.isEmpty ? nil : apart.sorted { $0.uuidString < $1.uuidString }
        let savedKeys = Dictionary(uniqueKeysWithValues: old.passkeys.map { ($0.credentialID, $0.id) })
        for i in copy.passkeys.indices {
            if let saved = savedKeys[copy.passkeys[i].credentialID] {
                copy.passkeys[i].id = saved
            }
        }
        return copy
    }
}
